# LGTMP Monitoring Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a full LGTMP (Loki + Grafana + Tempo + Mimir + Pyroscope) observability stack into the `use1` Kubernetes cluster via GitOps, decommission residual Hyplex resources, and replace the old single-pod in-cluster S3 with a new 3-node rustfs cluster.

**Architecture:** Each component is deployed via ArgoCD reading from `v-deployments` (Vanguard's GitOps repo). Each `Application` references a kustomize overlay that wraps an upstream Helm chart with `values.yaml` and ExternalSecret-backed credentials. All bulk object storage goes to the existing offsite S3 endpoint (`https://backup-storage.vngenterprise.com`) reached over the netbird tunnel; local Longhorn footprint is kept minimal. Grafana provisions dashboards/datasources/alerts from labeled ConfigMaps via a sidecar.

**Tech Stack:** Kubernetes, ArgoCD, Kustomize, Helm (via kustomize `helmCharts`), External-Secrets Operator + Vault, Longhorn, CloudNativePG, Grafana stack charts (Mimir, Loki, Tempo, Pyroscope, Grafana, Alloy), Traefik (`traefik-internal` IngressRoute), Zitadel OIDC.

**Spec reference:** `docs/superpowers/specs/2026-05-14-lgtmp-monitoring-rollout-design.md`

---

## Pre-flight: how to execute GitOps tasks

The "TDD" loop maps to GitOps as follows. Read this once before starting Phase 0; every task in this plan follows this shape.

| Code-TDD step | GitOps equivalent |
|---|---|
| Write the failing test | Write the manifest |
| Run test, expect FAIL | `kubectl apply --dry-run=server -f <file>` (catches schema errors); for kustomize: `kustomize build <overlay> \| kubectl apply --dry-run=server -f -` |
| Write minimal implementation | (already done — the manifest *is* the implementation) |
| Run test, expect PASS | `git add` + `git commit` + `git push`; wait for ArgoCD to sync; then run the verification commands |
| Commit | Already done above |

ArgoCD sync command (manual trigger if you don't want to wait for auto-sync poll):
```bash
argocd app sync <app-name> --grpc-web
# or
kubectl -n argocd patch app <app-name> --type merge -p '{"operation":{"sync":{}}}'
```

Watch a sync in progress:
```bash
kubectl -n argocd get app <app-name> -w
```

**Rollback** is `git revert <commit> && git push`. ArgoCD will prune/recreate. For emergencies: `argocd app rollback <app-name> <revision>`.

**Commit convention** (from `CLAUDE.md`):
- Prefix: `feat:`, `fix:`, `refactor:`, `docs:`
- Branch: `feature/`, `fix/`, `refactor/`, `docs/`

For this rollout, use one branch `feature/lgtmp-monitoring` and merge phase-by-phase, OR one branch per phase (`feature/monitoring-phase-N`). Either is fine; the plan assumes a single branch with multiple commits.

**Working directory:** `B:\.dev\Vanguard\v-deployments` (this is the GitOps repo). All paths in this plan are relative to that directory.

**Kubectl context:** All `kubectl` commands assume `kubectl config use-context admin@use1`. Run this once at the start of any session.

**ArgoCD CLI auth (one time):** `argocd login argocd.vngenterprise.com --sso` (or use the in-cluster `kubectl patch` form above if you don't have the CLI).

---

## File Structure (master map)

### Deletions (Phase 0)
```
applications/rustfs/                                            (entire folder)
applications/life/                                              (entire folder)
applications/agones/                                            (entire folder)
applications/redis-operator/overlays/hyplex/                    (entire folder)
argocd/applications/use1/rustfs.yaml
```

### Modifications
```
applications/longhorn/overlays/use1/kustomization.yaml          (add storageclass-single.yaml resource)
applications/mimir/overlays/use1/values.yaml                    (target=all, memcached, tenant rename, retention)
applications/grafana/overlays/use1/vanguard/values.yaml         (CNPG datasource, sidecar, Loki/Tempo/Pyroscope DS, remove sqlite persistence)
applications/grafana/overlays/use1/vanguard/kustomization.yaml  (add external-secret + datasources ConfigMap; chart version bump if needed)
```

### Renames
```
applications/alloy/                  ->  applications/alloy-metrics/
```

### Creations
```
applications/longhorn/overlays/use1/storageclass-single.yaml
applications/rustfs-cluster/                                    (new app)
applications/monitoring-buckets/                                (new app)
applications/alloy-logs/                                        (new app)
applications/alloy-receiver/                                    (new app)
applications/loki/                                              (new app)
applications/tempo/                                             (new app)
applications/pyroscope/                                         (new app)
applications/cnpg-grafana/                                      (new app)
applications/grafana/overlays/use1/vanguard/datasources.configmap.yaml
applications/grafana/overlays/use1/vanguard/external-secret-oidc.yaml
applications/grafana/overlays/use1/vanguard/alerts/             (contact-points, policies, rules)
applications/grafana/overlays/use1/vanguard/dashboards/         (kubernetes, longhorn, cnpg, traefik, argocd, monitoring-stack)

argocd/applications/use1/rustfs-cluster.yaml
argocd/applications/use1/monitoring-buckets.yaml
argocd/applications/use1/mimir.yaml
argocd/applications/use1/alloy-metrics.yaml
argocd/applications/use1/alloy-logs.yaml
argocd/applications/use1/alloy-receiver.yaml
argocd/applications/use1/grafana.yaml
argocd/applications/use1/cnpg-grafana.yaml
argocd/applications/use1/loki.yaml
argocd/applications/use1/tempo.yaml
argocd/applications/use1/pyroscope.yaml
```

### Vault pre-population (manual, outside this repo)

Before Phase 1, create these Vault paths. Each is consumed by an `ExternalSecret` that this plan creates:

```
monitoring/bucket-admin             AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINTS
monitoring/mimir                    AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINTS, TSDB_BUCKET_NAME, RULER_BUCKET_NAME
monitoring/loki                     AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINTS, BUCKET_NAME
monitoring/tempo                    (same shape as loki)
monitoring/pyroscope                (same shape as loki)
monitoring/grafana-alerting         DISCORD_PLATFORM_WEBHOOK, DISCORD_RUSTLENS_WEBHOOK, DISCORD_VANGUARD_WEBHOOK
grafana/oidc                        CLIENT_ID, CLIENT_SECRET (for Zitadel)
rustfs/cluster                      ROOT_USER, ROOT_PASSWORD
cnpg-grafana/backup                 AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (write access to cnpg-grafana-use1 bucket)
```

The bucket-admin credential is the master account on `backup-storage.vngenterprise.com` capable of `mb` and `ilm` operations. The per-signal credentials are scoped to their specific buckets. Create them in the offsite S3 admin console (or via `mc admin user add`) before running Phase 1 verification.

---

## Phase 0: Hyplex teardown

### Task 0.1: Check current Hyplex-related ArgoCD apps

**Files:** none (read-only check)

- [ ] **Step 1: Capture current state**

```bash
kubectl config use-context admin@use1
kubectl -n argocd get app -o name | sort > /tmp/argo-apps-before.txt
cat /tmp/argo-apps-before.txt
```

Expected: list includes `argocd/rustfs` and `argocd/kube-state-metrics`. There should be no `argocd/agones`, `argocd/life` Applications (they were never deployed via ArgoCD — only directory scaffolds existed). Verify this.

- [ ] **Step 2: Capture current hyplex namespaces**

```bash
kubectl get ns -o name | grep hyplex || echo "no hyplex namespaces"
kubectl -n hyplex-rustfs get all,pvc,secret,cm 2>&1 | head -30
```

Expected: `hyplex-rustfs` namespace exists with 1 rustfs pod and 1 PVC (`rustfs-data`).

### Task 0.2: Delete `argocd/applications/use1/rustfs.yaml`

**Files:**
- Delete: `argocd/applications/use1/rustfs.yaml`

- [ ] **Step 1: Delete the file**

```bash
git rm argocd/applications/use1/rustfs.yaml
```

- [ ] **Step 2: Commit**

```bash
git commit -m "refactor: delete rustfs argocd app (hyplex teardown)"
git push
```

- [ ] **Step 3: Wait for ArgoCD to prune the rustfs Application**

```bash
# Wait up to 5 min
kubectl -n argocd wait --for=delete app/rustfs --timeout=300s
```

Expected: `app/rustfs not found` — the Application is removed. The `hyplex-rustfs` namespace and its resources will be pruned by ArgoCD's `prune: true` policy on the parent `use1` app-of-apps.

- [ ] **Step 4: Verify cleanup**

```bash
kubectl get ns hyplex-rustfs 2>&1
kubectl get pv | grep hyplex-rustfs || echo "no hyplex-rustfs PVs"
```

Expected: `Error from server (NotFound): namespaces "hyplex-rustfs" not found`. No PVs remain.

### Task 0.3: Delete `applications/rustfs/`

**Files:**
- Delete: `applications/rustfs/` (entire directory)

- [ ] **Step 1: Delete the directory**

```bash
git rm -r applications/rustfs/
```

- [ ] **Step 2: Verify nothing references it**

```bash
grep -rn "applications/rustfs" argocd/ applications/ || echo "no references"
```

Expected: `no references`.

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor: delete applications/rustfs (hyplex teardown)"
```

### Task 0.4: Delete `applications/life/`

**Files:**
- Delete: `applications/life/` (entire directory)

- [ ] **Step 1: Check it isn't referenced**

```bash
grep -rn "applications/life" argocd/ applications/ || echo "no references"
```

Expected: `no references` (it has no ArgoCD app).

- [ ] **Step 2: Delete and commit**

```bash
git rm -r applications/life/
git commit -m "refactor: delete applications/life (unused)"
```

### Task 0.5: Delete `applications/agones/`

**Files:**
- Delete: `applications/agones/` (entire directory)

- [ ] **Step 1: Check it isn't referenced**

```bash
grep -rn "applications/agones" argocd/ applications/ || echo "no references"
```

Expected: `no references`.

- [ ] **Step 2: Delete and commit**

```bash
git rm -r applications/agones/
git commit -m "refactor: delete applications/agones (hyplex teardown)"
```

### Task 0.6: Delete `applications/redis-operator/overlays/hyplex/`

**Files:**
- Delete: `applications/redis-operator/overlays/hyplex/` (entire directory)

- [ ] **Step 1: Check it isn't referenced from any ArgoCD app**

```bash
grep -rn "redis-operator/overlays/hyplex" argocd/ || echo "no references"
```

Expected: `no references`.

- [ ] **Step 2: Delete and commit**

```bash
git rm -r applications/redis-operator/overlays/hyplex/
git commit -m "refactor: delete redis-operator hyplex overlay"
git push
```

### Task 0.7: Verify Hyplex teardown complete

**Files:** none (verification only)

- [ ] **Step 1: Check no hyplex resources remain**

```bash
kubectl get ns | grep -i hyplex || echo "no hyplex namespaces"
kubectl get pv | grep -iE 'hyplex|rustfs|life|agones' || echo "no hyplex/legacy PVs"
kubectl -n argocd get app -o name | sort > /tmp/argo-apps-after.txt
diff /tmp/argo-apps-before.txt /tmp/argo-apps-after.txt
```

Expected:
- No hyplex namespaces
- No leftover PVs
- Diff shows `< argocd/rustfs` removed

---

## Phase 0.5: New rustfs cluster

> **Note:** This phase depends on Phase 1 providing the `longhorn-single` StorageClass. We *create the manifests* in Phase 0.5 but only create the ArgoCD app at the end (Task 0.5.8). If you want to commit-and-deploy phase-by-phase, do Phase 1 before activating the ArgoCD app for rustfs-cluster.

### Task 0.5.1: Create rustfs-cluster base

**Files:**
- Create: `applications/rustfs-cluster/base/kustomization.yaml`
- Create: `applications/rustfs-cluster/base/namespace.yaml`

- [ ] **Step 1: Create namespace manifest**

`applications/rustfs-cluster/base/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: rustfs
```

- [ ] **Step 2: Create base kustomization**

`applications/rustfs-cluster/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

- [ ] **Step 3: Verify with kustomize build**

```bash
kustomize build applications/rustfs-cluster/base
```

Expected: Outputs just the Namespace manifest. No errors.

### Task 0.5.2: Create rustfs-cluster ExternalSecret

**Files:**
- Create: `applications/rustfs-cluster/overlays/use1/external-secret.yaml`

- [ ] **Step 1: Create ExternalSecret**

`applications/rustfs-cluster/overlays/use1/external-secret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: rustfs-root
  namespace: rustfs
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: rustfs-root
    creationPolicy: Owner
  data:
    - secretKey: ROOT_USER
      remoteRef:
        key: rustfs/cluster
        property: ROOT_USER
    - secretKey: ROOT_PASSWORD
      remoteRef:
        key: rustfs/cluster
        property: ROOT_PASSWORD
```

### Task 0.5.3: Create rustfs StatefulSet manifest

**Files:**
- Create: `applications/rustfs-cluster/overlays/use1/statefulset.yaml`

- [ ] **Step 1: Create the StatefulSet**

`applications/rustfs-cluster/overlays/use1/statefulset.yaml`:
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: rustfs
  namespace: rustfs
spec:
  serviceName: rustfs-headless
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app.kubernetes.io/name: rustfs
  template:
    metadata:
      labels:
        app.kubernetes.io/name: rustfs
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/name: rustfs
                topologyKey: kubernetes.io/hostname
      containers:
        - name: rustfs
          image: rustfs/rustfs:latest
          args:
            - server
            - http://rustfs-0.rustfs-headless.rustfs.svc.cluster.local:9000/data
            - http://rustfs-1.rustfs-headless.rustfs.svc.cluster.local:9000/data
            - http://rustfs-2.rustfs-headless.rustfs.svc.cluster.local:9000/data
            - --console-address
            - ":9001"
          env:
            - name: RUSTFS_ROOT_USER
              valueFrom: { secretKeyRef: { name: rustfs-root, key: ROOT_USER } }
            - name: RUSTFS_ROOT_PASSWORD
              valueFrom: { secretKeyRef: { name: rustfs-root, key: ROOT_PASSWORD } }
          ports:
            - name: api
              containerPort: 9000
            - name: console
              containerPort: 9001
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { cpu: 500m, memory: 1Gi }
          readinessProbe:
            httpGet: { path: /minio/health/ready, port: 9000 }
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /minio/health/live, port: 9000 }
            initialDelaySeconds: 30
            periodSeconds: 10
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: longhorn-single
        resources:
          requests:
            storage: 10Gi
```

> Note: rustfs is API-compatible with MinIO so the same health endpoints work. If `image: rustfs/rustfs:latest` is incorrect for your registry, replace with the image used by the old `applications/rustfs/` overlay before deletion (check git history with `git show HEAD~5:applications/rustfs/overlays/use1/deployment.yaml`).

### Task 0.5.4: Create rustfs Services

**Files:**
- Create: `applications/rustfs-cluster/overlays/use1/service.yaml`

- [ ] **Step 1: Create headless + ClusterIP services**

`applications/rustfs-cluster/overlays/use1/service.yaml`:
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: rustfs-headless
  namespace: rustfs
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: rustfs
  ports:
    - name: api
      port: 9000
    - name: console
      port: 9001
---
apiVersion: v1
kind: Service
metadata:
  name: rustfs
  namespace: rustfs
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: rustfs
  ports:
    - name: api
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
```

### Task 0.5.5: Create rustfs Ingresses (internal + external)

**Files:**
- Create: `applications/rustfs-cluster/overlays/use1/ingress-internal.yaml`
- Create: `applications/rustfs-cluster/overlays/use1/ingress-external.yaml`

- [ ] **Step 1: Internal ingress**

`applications/rustfs-cluster/overlays/use1/ingress-internal.yaml`:
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: rustfs-internal
  namespace: rustfs
  annotations:
    kubernetes.io/ingress.class: traefik-internal
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`rustfs.vngenterprise.com`)
      kind: Rule
      services:
        - name: rustfs
          port: 9000
  tls:
    store:
      name: default
      namespace: traefik
```

- [ ] **Step 2: External ingress**

`applications/rustfs-cluster/overlays/use1/ingress-external.yaml`:
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: rustfs-external
  namespace: rustfs
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`rustfs.vngenterprise.com`)
      kind: Rule
      services:
        - name: rustfs
          port: 9000
  tls:
    store:
      name: default
      namespace: traefik
```

### Task 0.5.6: Create rustfs-cluster overlay kustomization

**Files:**
- Create: `applications/rustfs-cluster/overlays/use1/kustomization.yaml`

- [ ] **Step 1: Create overlay kustomization**

`applications/rustfs-cluster/overlays/use1/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - external-secret.yaml
  - statefulset.yaml
  - service.yaml
  - ingress-internal.yaml
  - ingress-external.yaml
```

- [ ] **Step 2: Verify with kustomize build**

```bash
kustomize build applications/rustfs-cluster/overlays/use1
```

Expected: Outputs Namespace, ExternalSecret, StatefulSet, 2 Services, 2 IngressRoutes. No errors.

- [ ] **Step 3: Server-side dry-run**

```bash
kustomize build applications/rustfs-cluster/overlays/use1 | kubectl apply --dry-run=server -f -
```

Expected: All resources "created (server dry run)".

- [ ] **Step 4: Commit (do NOT push yet — ArgoCD app is added in Task 0.5.8 after Phase 1 lands the SC)**

```bash
git add applications/rustfs-cluster/
git commit -m "feat: add rustfs-cluster manifests (3-node general-purpose s3)"
```

### Task 0.5.7: Hold — wait for Phase 1 to land

The rustfs StatefulSet references `storageClassName: longhorn-single`. That SC is created in Task 1.1. Continue with Phase 1, then return for Task 0.5.8.

### Task 0.5.8: Create rustfs-cluster ArgoCD Application

**Files:**
- Create: `argocd/applications/use1/rustfs-cluster.yaml`

- [ ] **Step 1: Create the ArgoCD Application**

`argocd/applications/use1/rustfs-cluster.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rustfs-cluster
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/rustfs-cluster/overlays/use1/
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: rustfs
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
```

- [ ] **Step 2: Commit and push**

```bash
git add argocd/applications/use1/rustfs-cluster.yaml
git commit -m "feat: add rustfs-cluster argocd application"
git push
```

- [ ] **Step 3: Wait for ArgoCD to sync**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced app/rustfs-cluster --timeout=300s
kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy app/rustfs-cluster --timeout=600s
```

Expected: both wait commands return successfully.

### Task 0.5.9: Verify rustfs-cluster

**Files:** none (verification)

- [ ] **Step 1: Verify pods**

```bash
kubectl -n rustfs get pods -o wide
```

Expected: `rustfs-0`, `rustfs-1`, `rustfs-2` all `1/1 Running`, on three different nodes.

- [ ] **Step 2: Verify PVCs on `longhorn-single`**

```bash
kubectl -n rustfs get pvc
```

Expected: 3 PVCs `data-rustfs-0/1/2`, all `Bound`, 10Gi each, StorageClass `longhorn-single`.

- [ ] **Step 3: Verify ingress reachable**

```bash
kubectl run -it --rm debug-mc --image=minio/mc:latest --restart=Never -- sh -c \
  'mc alias set local http://rustfs.rustfs.svc:9000 "$(kubectl -n rustfs get secret rustfs-root -o jsonpath={.data.ROOT_USER} | base64 -d)" "$(kubectl -n rustfs get secret rustfs-root -o jsonpath={.data.ROOT_PASSWORD} | base64 -d)"; mc ls local'
```

> The `kubectl` inside the pod won't work — instead, run the secret lookups locally and pass the values as env:

```bash
RUSTFS_USER=$(kubectl -n rustfs get secret rustfs-root -o jsonpath='{.data.ROOT_USER}' | base64 -d)
RUSTFS_PASS=$(kubectl -n rustfs get secret rustfs-root -o jsonpath='{.data.ROOT_PASSWORD}' | base64 -d)

kubectl run -it --rm debug-mc --image=minio/mc:latest --restart=Never \
  --env=USER="$RUSTFS_USER" --env=PASS="$RUSTFS_PASS" -- \
  sh -c 'mc alias set local http://rustfs.rustfs.svc.cluster.local:9000 "$USER" "$PASS" && mc mb local/test && mc ls local && mc rb --force local/test'
```

Expected: `Bucket created successfully` then `test/` listed then bucket removed. No errors.

### Task 0.5.10: Commit Phase 0.5 complete

- [ ] **Step 1: All Phase 0.5 commits already done. Verify branch is clean and pushed.**

```bash
git status
git log --oneline -10
```

Expected: clean working tree; recent commits include all Phase 0 + 0.5 entries.

---

## Phase 1: Storage class + bucket bootstrap

### Task 1.1: Add `longhorn-single` StorageClass

**Files:**
- Create: `applications/longhorn/overlays/use1/storageclass-single.yaml`
- Modify: `applications/longhorn/overlays/use1/kustomization.yaml`

- [ ] **Step 1: Create the StorageClass manifest**

`applications/longhorn/overlays/use1/storageclass-single.yaml`:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-single
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "30"
  fromBackup: ""
  dataLocality: "best-effort"
  fsType: "ext4"
```

- [ ] **Step 2: Add resource to kustomization**

Modify `applications/longhorn/overlays/use1/kustomization.yaml` — add `storageclass-single.yaml` to the `resources` list. Result:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - external-secrets.yaml
  - storageclass-single.yaml
helmCharts:
  - name: longhorn
    version: "1.10.0"
    repo: https://charts.longhorn.io/
    releaseName: longhorn
    namespace: longhorn-system
    valuesFile: values.yaml
```

- [ ] **Step 3: Build + dry-run**

```bash
kustomize build --enable-helm applications/longhorn/overlays/use1 | grep -A8 'kind: StorageClass'
```

Expected: shows both the default `longhorn` SC (from chart) and the new `longhorn-single`.

- [ ] **Step 4: Commit and push**

```bash
git add applications/longhorn/overlays/use1/
git commit -m "feat: add longhorn-single storageclass for non-redundant workloads"
git push
```

- [ ] **Step 5: Wait for ArgoCD to sync and verify**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced app/longhorn --timeout=300s
kubectl get sc longhorn-single
```

Expected: SC exists with `driver.longhorn.io` provisioner, `Delete` reclaim policy.

### Task 1.2: Create monitoring-buckets base

**Files:**
- Create: `applications/monitoring-buckets/base/kustomization.yaml`
- Create: `applications/monitoring-buckets/base/namespace.yaml`

- [ ] **Step 1: Create namespace**

`applications/monitoring-buckets/base/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring-buckets
```

- [ ] **Step 2: Create base kustomization**

`applications/monitoring-buckets/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

### Task 1.3: Create bucket-admin ExternalSecret

**Files:**
- Create: `applications/monitoring-buckets/overlays/use1/external-secret.yaml`

- [ ] **Step 1: Create ExternalSecret**

`applications/monitoring-buckets/overlays/use1/external-secret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: bucket-admin
  namespace: monitoring-buckets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: bucket-admin
    creationPolicy: Owner
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: monitoring/bucket-admin
        property: AWS_ACCESS_KEY_ID
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: monitoring/bucket-admin
        property: AWS_SECRET_ACCESS_KEY
    - secretKey: AWS_ENDPOINTS
      remoteRef:
        key: monitoring/bucket-admin
        property: AWS_ENDPOINTS
```

### Task 1.4: Create lifecycle policy ConfigMap

**Files:**
- Create: `applications/monitoring-buckets/overlays/use1/lifecycle-configmap.yaml`

- [ ] **Step 1: Create the ConfigMap with all four lifecycle JSONs**

`applications/monitoring-buckets/overlays/use1/lifecycle-configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: bucket-lifecycle
  namespace: monitoring-buckets
data:
  mimir.json: |
    {
      "Rules": [
        {
          "ID": "expire-old-blocks",
          "Status": "Enabled",
          "Filter": { "Prefix": "" },
          "Expiration": { "Days": 30 }
        }
      ]
    }
  loki.json: |
    {
      "Rules": [
        {
          "ID": "expire-old-chunks",
          "Status": "Enabled",
          "Filter": { "Prefix": "" },
          "Expiration": { "Days": 14 }
        }
      ]
    }
  tempo.json: |
    {
      "Rules": [
        {
          "ID": "expire-old-traces",
          "Status": "Enabled",
          "Filter": { "Prefix": "" },
          "Expiration": { "Days": 7 }
        }
      ]
    }
  pyroscope.json: |
    {
      "Rules": [
        {
          "ID": "expire-old-profiles",
          "Status": "Enabled",
          "Filter": { "Prefix": "" },
          "Expiration": { "Days": 14 }
        }
      ]
    }
```

### Task 1.5: Create the bucket-bootstrap Job

**Files:**
- Create: `applications/monitoring-buckets/overlays/use1/job-bootstrap.yaml`

- [ ] **Step 1: Create the Job**

`applications/monitoring-buckets/overlays/use1/job-bootstrap.yaml`:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: bucket-bootstrap
  namespace: monitoring-buckets
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: minio/mc:latest
          envFrom:
            - secretRef: { name: bucket-admin }
          command:
            - sh
            - -c
            - |
              set -euo pipefail
              echo "Configuring mc alias for offsite..."
              mc alias set offsite "$AWS_ENDPOINTS" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"

              echo "Creating buckets (idempotent)..."
              for bucket in \
                monitoring-mimir-use1 \
                monitoring-mimir-ruler-use1 \
                monitoring-loki-use1 \
                monitoring-tempo-use1 \
                monitoring-pyroscope-use1 \
                cnpg-grafana-use1; do
                mc mb --ignore-existing "offsite/$bucket"
              done

              echo "Applying lifecycle rules..."
              mc ilm import offsite/monitoring-mimir-use1     < /lifecycle/mimir.json
              mc ilm import offsite/monitoring-loki-use1      < /lifecycle/loki.json
              mc ilm import offsite/monitoring-tempo-use1     < /lifecycle/tempo.json
              mc ilm import offsite/monitoring-pyroscope-use1 < /lifecycle/pyroscope.json

              echo "Listing buckets:"
              mc ls offsite
              echo "Done."
          volumeMounts:
            - name: lifecycle
              mountPath: /lifecycle
      volumes:
        - name: lifecycle
          configMap:
            name: bucket-lifecycle
```

The `argocd.argoproj.io/hook: Sync` annotation makes the Job run on every ArgoCD sync (so re-runs are easy). `BeforeHookCreation` ensures previous Job pods are cleaned up before the new run.

### Task 1.6: Create monitoring-buckets overlay kustomization

**Files:**
- Create: `applications/monitoring-buckets/overlays/use1/kustomization.yaml`

- [ ] **Step 1: Create overlay kustomization**

`applications/monitoring-buckets/overlays/use1/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - external-secret.yaml
  - lifecycle-configmap.yaml
  - job-bootstrap.yaml
```

- [ ] **Step 2: Verify build + dry-run**

```bash
kustomize build applications/monitoring-buckets/overlays/use1 | kubectl apply --dry-run=server -f -
```

Expected: namespace, externalsecret, configmap, job all "created (server dry run)".

### Task 1.7: Create ArgoCD Application for monitoring-buckets

**Files:**
- Create: `argocd/applications/use1/monitoring-buckets.yaml`

- [ ] **Step 1: Create the Application**

`argocd/applications/use1/monitoring-buckets.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring-buckets
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/monitoring-buckets/overlays/use1/
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring-buckets
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
```

Sync wave `-10` ensures buckets are created before any downstream monitoring app that depends on them.

- [ ] **Step 2: Commit and push**

```bash
git add applications/monitoring-buckets/ argocd/applications/use1/monitoring-buckets.yaml
git commit -m "feat: add monitoring-buckets bootstrap (mimir/loki/tempo/pyroscope/cnpg-grafana on offsite s3)"
git push
```

- [ ] **Step 3: Wait for ArgoCD sync**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced app/monitoring-buckets --timeout=300s
```

### Task 1.8: Verify buckets created

**Files:** none (verification)

- [ ] **Step 1: Inspect Job logs**

```bash
kubectl -n monitoring-buckets get jobs
kubectl -n monitoring-buckets logs job/bucket-bootstrap
```

Expected: log lines for each bucket (`Bucket created successfully` or `already exists`), then a final `mc ls offsite` listing all 6 buckets, then `Done.`

- [ ] **Step 2: Verify lifecycle rules from a debug pod**

```bash
kubectl -n monitoring-buckets run -it --rm verify-mc --image=minio/mc:latest --restart=Never \
  --env-from=secretref:bucket-admin --command -- \
  sh -c 'mc alias set offsite "$AWS_ENDPOINTS" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" && for b in monitoring-mimir-use1 monitoring-loki-use1 monitoring-tempo-use1 monitoring-pyroscope-use1; do echo "--- $b ---"; mc ilm export "offsite/$b"; done'
```

Expected: lifecycle JSON printed for each bucket showing the correct retention (30d, 14d, 7d, 14d respectively).

### Task 1.9: Return to Task 0.5.8 — activate rustfs-cluster

Now that the `longhorn-single` SC exists, return to Task 0.5.8 to commit `argocd/applications/use1/rustfs-cluster.yaml`. Then run Tasks 0.5.9–0.5.10.

(Tasks listed in 0.5 order for readability; in execution order they happen now.)

### Task 1.10: Verify Phase 1 complete

- [ ] **Step 1: Smoke check**

```bash
kubectl get sc longhorn-single
kubectl -n argocd get app monitoring-buckets -o jsonpath='{.status.sync.status} {.status.health.status}'
echo
```

Expected: `Synced Healthy`.

---

## Phase 2: Mimir promotion

### Task 2.1: Update Mimir values.yaml

**Files:**
- Modify: `applications/mimir/overlays/use1/values.yaml`

- [ ] **Step 1: Replace values.yaml contents**

Replace `applications/mimir/overlays/use1/values.yaml` with:

```yaml
# Monolithic deployment of Mimir (target=all) sized for the use1 cluster.

deploymentMode: monolithic-single-binary

minio:
  enabled: false
vaultAgent:
  enabled: false
alertmanager:
  enabled: false        # Grafana Unified Alerting handles alerting
kafka:
  enabled: false
gateway:
  enabled: true
graphite:
  enabled: false

# Disable distributed-only components (we run monolithic)
distributor:
  replicas: 0
querier:
  replicas: 0
query_frontend:
  replicas: 0
ruler:
  enabled: false        # no rule-as-a-service; alerts live in Grafana
store_gateway:
  replicas: 0
  zoneAwareReplication:
    enabled: false
compactor:
  replicas: 0
  persistentVolume:
    enabled: false

# Monolithic component definition (Mimir 'all' target)
mimir:
  structuredConfig:
    target: all
    limits:
      compactor_blocks_retention_period: 14d
      max_total_query_length: 72h
    common:
      storage:
        backend: s3
        s3:
          bucket_name: "${RULER_BUCKET_NAME}"
          endpoint: "${BUCKET_ENDPOINT}"
          insecure: false
          access_key_id: "${AWS_ACCESS_KEY_ID}"
          secret_access_key: "${AWS_SECRET_ACCESS_KEY}"
    tenant_federation:
      enabled: true
    blocks_storage:
      backend: s3
      s3:
        bucket_name: "${TSDB_BUCKET_NAME}"
      tsdb:
        block_ranges_period: ["1h"]
        retention_period: 6h
        head_compaction_interval: 15m
        head_compaction_idle_timeout: 1h
    alertmanager_storage:
      backend: s3
      s3:
        bucket_name: "${RULER_BUCKET_NAME}"
    ruler_storage:
      backend: s3
      s3:
        bucket_name: "${RULER_BUCKET_NAME}"
    ingest_storage:
      enabled: false
    ingester:
      ring:
        replication_factor: 1
      push_grpc_method_enabled: true

# The single monolithic StatefulSet
mimir-monolithic:
  enabled: true
  replicas: 1
  resources:
    requests: { cpu: 200m, memory: 1Gi }
    limits:   { cpu: 1,    memory: 3Gi }

# Keep the ingester PVC for WAL on 2-replica longhorn (diagnosis-critical)
ingester:
  statefulSet:
    enabled: true
  replicas: 1
  persistentVolume:
    size: 10Gi
    storageClass: "longhorn"
  zoneAwareReplication:
    enabled: false

# Memcached caches (in-memory)
chunks-cache:
  enabled: true
  replicas: 1
  allocatedMemory: 512
results-cache:
  enabled: true
  replicas: 1
  allocatedMemory: 256
index-cache:
  enabled: true
  replicas: 1
  allocatedMemory: 256
metadata-cache:
  enabled: true
  replicas: 1
  allocatedMemory: 128

global:
  extraEnvFrom:
    - secretRef:
        name: mimir-global-env
```

> **Chart compatibility note:** The `mimir-distributed` chart (6.0.3) is the distributed-flavored chart but supports running components co-located via `mimir.structuredConfig.target: all`. The `mimir-monolithic` block above is illustrative — the actual chart key may differ. Before applying, run `helm show values grafana/mimir-distributed --version 6.0.3 > /tmp/mimir-values.yaml` and verify:
> - Whether there's a top-level `mimir-monolithic`/`monolithic` switch
> - How to set replicas to 0 for `distributor`, `querier`, `query_frontend`, `store_gateway`, `compactor`
> - Whether `target: all` requires also disabling distributed deployment via a chart-level flag (e.g. `deploymentMode`)
>
> If 6.0.3 doesn't cleanly support monolithic, switch the chart to `grafana/mimir` (the dedicated monolithic chart) — but that requires updating `applications/mimir/overlays/use1/kustomization.yaml` to point at it. Document the choice in the Phase 2 commit.

### Task 2.2: Verify Mimir kustomize build

**Files:** none (verification)

- [ ] **Step 1: Build the kustomize overlay**

```bash
kustomize build --enable-helm applications/mimir/overlays/use1 > /tmp/mimir-rendered.yaml
echo "rendered $(wc -l < /tmp/mimir-rendered.yaml) lines"
grep -c '^kind: ' /tmp/mimir-rendered.yaml
```

Expected: ~thousands of lines; kinds include `StatefulSet`, `Service`, `ConfigMap`, `Deployment` (for memcached), `Namespace`, `ExternalSecret`, `PrometheusRule`.

- [ ] **Step 2: Server-side dry-run**

```bash
kubectl apply --dry-run=server -f /tmp/mimir-rendered.yaml | head -30
```

Expected: most resources "created (server dry run)". Some might "configured" if defaults exist.

### Task 2.3: Create Mimir ArgoCD Application

**Files:**
- Create: `argocd/applications/use1/mimir.yaml`

- [ ] **Step 1: Create the Application**

`argocd/applications/use1/mimir.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mimir
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/mimir/overlays/use1/
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: mimir
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
      - ServerSideApply=true
```

> `ServerSideApply=true` avoids the "metadata too long" issue that helm-rendered manifests sometimes hit.

- [ ] **Step 2: Commit and push**

```bash
git add applications/mimir/overlays/use1/values.yaml argocd/applications/use1/mimir.yaml
git commit -m "feat: promote mimir to monolithic deployment with 14d retention"
git push
```

### Task 2.4: Wait for Mimir sync + ready

**Files:** none (verification)

- [ ] **Step 1: Wait for ArgoCD sync**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced app/mimir --timeout=600s
```

- [ ] **Step 2: Wait for Mimir pods**

```bash
kubectl -n mimir get pods -w
```

Watch until you see:
- 1 `mimir-monolithic-0` (or similar) `1/1 Running`
- Memcached pods (`mimir-chunks-cache-0`, `mimir-index-cache-0`, `mimir-results-cache-0`, `mimir-metadata-cache-0`) all `Running`

Then `Ctrl-C`.

- [ ] **Step 3: Sanity check logs**

```bash
kubectl -n mimir logs sts/mimir-monolithic --tail=50
```

Expected: log lines about "module loaded", "starting Mimir", "ring members", no panics or repeated S3 errors.

### Task 2.5: Push a synthetic metric

**Files:** none (verification)

- [ ] **Step 1: Push a sample**

```bash
kubectl -n mimir port-forward svc/mimir-nginx 8080:80 &
PF_PID=$!
sleep 3

# Push a metric
cat <<EOF | curl -s -H "X-Scope-OrgID: metrics" -H "Content-Type: application/x-protobuf" -H "Content-Encoding: snappy" --data-binary @- http://localhost:8080/api/v1/push
$(printf 'plan_test 1 %s' $(date +%s%N | cut -c1-13))
EOF
# (The above is illustrative — the actual API requires snappy-encoded protobuf.
#  A simpler test: use Prometheus's remote_write spec with mimirtool)

kill $PF_PID
```

> Practical alternative: skip the manual push and let `alloy-metrics` (deployed in Phase 3) be the verification. For now just verify the push endpoint responds.

```bash
kubectl -n mimir port-forward svc/mimir-nginx 8080:80 &
PF_PID=$!
sleep 3
curl -s -H "X-Scope-OrgID: metrics" http://localhost:8080/prometheus/api/v1/query?query=up
kill $PF_PID
```

Expected: JSON response `{"status":"success","data":{"resultType":"vector","result":[]}}` (empty result is fine — there's no data yet, but the endpoint works).

### Task 2.6: Verify Mimir bucket activity

**Files:** none (verification)

- [ ] **Step 1: Check that Mimir is connecting to S3**

```bash
kubectl -n mimir logs sts/mimir-monolithic --tail=200 | grep -iE 's3|bucket|backend' | head -20
```

Expected: log entries about successfully opening buckets `monitoring-mimir-use1` and `monitoring-mimir-ruler-use1`, no `AccessDenied` or `NoSuchBucket` errors.

### Task 2.7: Update memory + commit progress

**Files:** none

- [ ] **Step 1: Phase 2 done. Move on to Phase 3.**

---

## Phase 3: Alloy collectors

### Task 3.1: Rename `applications/alloy/` to `applications/alloy-metrics/`

**Files:**
- Rename: `applications/alloy/` → `applications/alloy-metrics/`

- [ ] **Step 1: Rename via git mv**

```bash
git mv applications/alloy applications/alloy-metrics
```

- [ ] **Step 2: Verify nothing references the old path**

```bash
grep -rn "applications/alloy[^-]" argocd/ applications/ 2>&1 | grep -v "applications/alloy-metrics" || echo "no stale refs"
```

Expected: `no stale refs`.

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor: rename applications/alloy to applications/alloy-metrics"
```

### Task 3.2: Update alloy-metrics values for tenant rename

**Files:**
- Modify: `applications/alloy-metrics/overlays/use1/configmap.yaml`

- [ ] **Step 1: Update tenant ID from `pods` to `metrics`**

In `applications/alloy-metrics/overlays/use1/configmap.yaml`, find the `prometheus.remote_write "mimir"` block and change the `X-Scope-OrgID` header from `"pods"` to `"metrics"`. Also update the mimir endpoint to use `mimir-nginx` (the monolithic gateway service):

```hcl
prometheus.remote_write "mimir" {
  endpoint {
    url = "http://mimir-nginx.mimir.svc.cluster.local/api/v1/push"
    headers = {
      "X-Scope-OrgID" = "metrics",
    }
  }
}
```

Also update the `mimir.rules.kubernetes "pods"` block to point at the monolithic ruler endpoint (which doesn't exist if `ruler.enabled: false` — see Step 2):

- [ ] **Step 2: Remove the mimir-ruler rule sync block**

Mimir's ruler is disabled (Grafana handles alerts). Delete the entire `mimir.rules.kubernetes "pods" { … }` block from the configmap. Recording rules will continue to evaluate via Mimir's own ruler-in-the-monolith (which uses the same `target: all`), so the `PrometheusRule` CRs in the namespace still serve their purpose if you reintroduce a ruler later — for now they're just declarative and unused.

Alternative (cleaner): delete `applications/alloy-metrics/overlays/use1/prometheusrule.yaml` (the recording rules) too, since nothing evaluates them. Keep `mimir-alerts` PR-style alerts for reference but they won't fire either; they'll be replaced by Grafana alerts in Phase 7.

Decision: keep the `PrometheusRule` files in place but understand they're inert in Phase 1. Grafana alert rules replace them in Phase 7.

### Task 3.3: Create alloy-metrics ArgoCD Application

**Files:**
- Create: `argocd/applications/use1/alloy-metrics.yaml`

- [ ] **Step 1: Create the Application**

`argocd/applications/use1/alloy-metrics.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alloy-metrics
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/alloy-metrics/overlays/use1/
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: alloy-metrics
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Commit and push**

```bash
git add applications/alloy-metrics/ argocd/applications/use1/alloy-metrics.yaml
git commit -m "feat: deploy alloy-metrics daemonset (scrape kubelet/cAdvisor/KSM -> mimir)"
git push
```

- [ ] **Step 3: Wait for sync**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced app/alloy-metrics --timeout=300s
kubectl -n alloy-metrics get ds
```

Expected: alloy-metrics DS rolled out to all 6 nodes.

### Task 3.4: Verify metrics flowing to Mimir

**Files:** none (verification)

- [ ] **Step 1: Query a kubelet metric**

```bash
kubectl -n mimir port-forward svc/mimir-nginx 8080:80 &
PF_PID=$!
sleep 3
curl -s -G --data-urlencode 'query=up{job="kubelet"}' \
  -H "X-Scope-OrgID: metrics" \
  http://localhost:8080/prometheus/api/v1/query | jq '.data.result | length'
kill $PF_PID
```

Expected: `6` (one `up` series per node).

- [ ] **Step 2: Check cardinality stays sane**

```bash
kubectl -n mimir port-forward svc/mimir-nginx 8080:80 &
PF_PID=$!
sleep 3
curl -s -G --data-urlencode 'query=count(count by (__name__)({__name__=~".+"}))' \
  -H "X-Scope-OrgID: metrics" \
  http://localhost:8080/prometheus/api/v1/query | jq '.data.result[0].value[1]'
kill $PF_PID
```

Expected: a number well under `100000` (typical: 500–2000 unique metric names).

### Task 3.5: Create alloy-logs base

**Files:**
- Create: `applications/alloy-logs/base/kustomization.yaml`
- Create: `applications/alloy-logs/base/namespace.yaml`

- [ ] **Step 1: Create namespace**

`applications/alloy-logs/base/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: alloy-logs
```

- [ ] **Step 2: Create base kustomization**

`applications/alloy-logs/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

### Task 3.6: Create alloy-logs configmap

**Files:**
- Create: `applications/alloy-logs/overlays/use1/configmap.yaml`

- [ ] **Step 1: Create the Alloy config for log tailing**

`applications/alloy-logs/overlays/use1/configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: alloy-config
  namespace: alloy-logs
data:
  config.alloy: |
    // Discover all pods (the loki.source.kubernetes component below only tails
    // logs from /var/log/pods on the local node, so per-node filtering is
    // implicit via the DaemonSet mount).
    discovery.kubernetes "pods" {
      role = "pod"
    }

    // Drop kube-system logs by default (override per-pod with annotation if needed)
    discovery.relabel "pods" {
      targets = discovery.kubernetes.pods.targets
      rule {
        source_labels = ["__meta_kubernetes_namespace"]
        regex         = "kube-system"
        action        = "drop"
      }
      rule {
        action = "labelmap"
        regex  = "__meta_kubernetes_pod_label_(.+)"
      }
      rule {
        source_labels = ["__meta_kubernetes_namespace"]
        target_label  = "namespace"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_name"]
        target_label  = "pod"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_container_name"]
        target_label  = "container"
      }
    }

    // Tail container logs
    loki.source.kubernetes "pods" {
      targets    = discovery.relabel.pods.output
      forward_to = [loki.process.extract.receiver]
    }

    // Extract trace_id if present (for log<->trace correlation)
    loki.process "extract" {
      forward_to = [loki.write.loki.receiver]
      stage.regex {
        expression = `trace_id[=:]\s*(?P<trace_id>[a-fA-F0-9]{16,32})`
      }
      stage.labels {
        values = { trace_id = "" }
      }
    }

    // Push to Loki
    loki.write "loki" {
      endpoint {
        url = "http://loki.loki.svc.cluster.local:3100/loki/api/v1/push"
        headers = {
          "X-Scope-OrgID" = "logs",
        }
      }
    }
```

### Task 3.7: Create alloy-logs values + overlay kustomization

**Files:**
- Create: `applications/alloy-logs/overlays/use1/values.yaml`
- Create: `applications/alloy-logs/overlays/use1/kustomization.yaml`

- [ ] **Step 1: Create values.yaml**

> Deviation from spec §5: spec said `alloy-logs positions` would use a 1 GiB `longhorn-single` PVC. The plan uses `emptyDir` because DaemonSet PVCs require one PVC per node (extra orchestration) and the positions file is cheap to lose — on restart Alloy resumes tailing from EOF, so at worst a few seconds of duplicate logs are sent. Document in commit message.

`applications/alloy-logs/overlays/use1/values.yaml`:
```yaml
alloy:
  configMap:
    create: false
    name: alloy-config
    key: config.alloy
  mounts:
    varlog: true                    # /var/log
    dockercontainers: true          # /var/lib/docker/containers (if used)
  clustering:
    enabled: false                  # logs are node-scoped; no need to cluster
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 1Gi }

rbac:
  create: true
  clusterRules:
    - apiGroups: [""]
      resources: ["pods", "namespaces", "nodes"]
      verbs: ["get", "list", "watch"]

serviceAccount:
  create: true
  name: alloy-logs

controller:
  type: daemonset
  hostPID: false
  volumes:
    extra:
      - name: positions
        emptyDir: {}
  volumeMounts:
    extra:
      - name: positions
        mountPath: /tmp/alloy/positions
```

- [ ] **Step 2: Create overlay kustomization**

`applications/alloy-logs/overlays/use1/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - configmap.yaml
helmCharts:
  - name: alloy
    version: 1.4.0
    repo: https://grafana.github.io/helm-charts
    releaseName: alloy-logs
    namespace: alloy-logs
    valuesFile: values.yaml
```

- [ ] **Step 3: Verify build**

```bash
kustomize build --enable-helm applications/alloy-logs/overlays/use1 > /tmp/alloy-logs-rendered.yaml
echo "rendered $(wc -l < /tmp/alloy-logs-rendered.yaml) lines"
```

Expected: thousands of lines.

- [ ] **Step 4: Commit (but no ArgoCD app yet — alloy-logs deploys after Loki in Phase 5)**

```bash
git add applications/alloy-logs/
git commit -m "feat: add alloy-logs manifests (deploy pending loki)"
```

### Task 3.8: Create alloy-receiver base + manifests

**Files:**
- Create: `applications/alloy-receiver/base/kustomization.yaml`
- Create: `applications/alloy-receiver/base/namespace.yaml`
- Create: `applications/alloy-receiver/overlays/use1/configmap.yaml`
- Create: `applications/alloy-receiver/overlays/use1/values.yaml`
- Create: `applications/alloy-receiver/overlays/use1/service.yaml`
- Create: `applications/alloy-receiver/overlays/use1/kustomization.yaml`

- [ ] **Step 1: Base namespace + kustomization**

`applications/alloy-receiver/base/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: alloy-receiver
```

`applications/alloy-receiver/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

- [ ] **Step 2: Configmap (OTLP receivers + Tempo/Pyroscope exporters)**

`applications/alloy-receiver/overlays/use1/configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: alloy-config
  namespace: alloy-receiver
data:
  config.alloy: |
    // OTLP receiver
    otelcol.receiver.otlp "default" {
      grpc {
        endpoint = "0.0.0.0:4317"
      }
      http {
        endpoint = "0.0.0.0:4318"
      }
      output {
        traces  = [otelcol.processor.batch.traces.input]
      }
    }

    otelcol.processor.batch "traces" {
      output {
        traces = [otelcol.exporter.otlp.tempo.input]
      }
    }

    otelcol.exporter.otlp "tempo" {
      client {
        endpoint = "tempo.tempo.svc.cluster.local:4317"
        headers  = { "X-Scope-OrgID" = "traces" }
        tls { insecure = true }
      }
    }

    // Pyroscope ingest endpoint exposed at :4040; alloy proxies to pyroscope
    pyroscope.receive_http "default" {
      http {
        listen_address = "0.0.0.0"
        listen_port    = 4040
      }
      forward_to = [pyroscope.write.default.receiver]
    }

    pyroscope.write "default" {
      endpoint {
        url = "http://pyroscope.pyroscope.svc.cluster.local:4040"
        headers = {
          "X-Scope-OrgID" = "profiles",
        }
      }
    }
```

- [ ] **Step 3: Values.yaml**

`applications/alloy-receiver/overlays/use1/values.yaml`:
```yaml
alloy:
  configMap:
    create: false
    name: alloy-config
    key: config.alloy
  clustering:
    enabled: true
    portName: http
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 1Gi }
  extraPorts:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
    - name: otlp-http
      port: 4318
      targetPort: 4318
      protocol: TCP
    - name: pyroscope
      port: 4040
      targetPort: 4040
      protocol: TCP

rbac:
  create: true

serviceAccount:
  create: true
  name: alloy-receiver

controller:
  type: statefulset
  replicas: 2
```

- [ ] **Step 4: Stable service for apps to target**

`applications/alloy-receiver/overlays/use1/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: alloy-receiver
  namespace: alloy-receiver
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: alloy-receiver
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
    - name: pyroscope
      port: 4040
      targetPort: 4040
```

- [ ] **Step 5: Overlay kustomization**

`applications/alloy-receiver/overlays/use1/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - configmap.yaml
  - service.yaml
helmCharts:
  - name: alloy
    version: 1.4.0
    repo: https://grafana.github.io/helm-charts
    releaseName: alloy-receiver
    namespace: alloy-receiver
    valuesFile: values.yaml
```

- [ ] **Step 6: Verify build**

```bash
kustomize build --enable-helm applications/alloy-receiver/overlays/use1 > /tmp/alloy-rx-rendered.yaml
echo "rendered $(wc -l < /tmp/alloy-rx-rendered.yaml) lines"
```

- [ ] **Step 7: Commit (no ArgoCD app yet — deploys after Tempo + Pyroscope in Phase 6)**

```bash
git add applications/alloy-receiver/
git commit -m "feat: add alloy-receiver manifests (deploy pending tempo/pyroscope)"
git push
```

### Task 3.9: Phase 3 complete

- [ ] **Step 1: Status check**

```bash
git log --oneline -10
kubectl -n alloy-metrics get ds
```

Expected: alloy-metrics DS Running on all 6 nodes; alloy-logs and alloy-receiver manifests in repo but no ArgoCD apps yet.

---

## Phase 4: Grafana + CNPG

### Task 4.1: Create cnpg-grafana base

**Files:**
- Create: `applications/cnpg-grafana/base/kustomization.yaml`
- Create: `applications/cnpg-grafana/base/namespace.yaml`

- [ ] **Step 1: Namespace**

`applications/cnpg-grafana/base/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: grafana
```

(Same namespace as Grafana so the cluster and Grafana co-locate.)

- [ ] **Step 2: Base kustomization**

`applications/cnpg-grafana/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

### Task 4.2: Create cnpg-grafana ExternalSecret for backups

**Files:**
- Create: `applications/cnpg-grafana/overlays/use1/external-secret.yaml`

- [ ] **Step 1: ExternalSecret**

`applications/cnpg-grafana/overlays/use1/external-secret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cnpg-grafana-backup
  namespace: grafana
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: cnpg-grafana-backup
    creationPolicy: Owner
  data:
    - secretKey: ACCESS_KEY_ID
      remoteRef:
        key: cnpg-grafana/backup
        property: AWS_ACCESS_KEY_ID
    - secretKey: ACCESS_SECRET_KEY
      remoteRef:
        key: cnpg-grafana/backup
        property: AWS_SECRET_ACCESS_KEY
```

### Task 4.3: Create cnpg-grafana Cluster CR

**Files:**
- Create: `applications/cnpg-grafana/overlays/use1/cluster.yaml`

- [ ] **Step 1: Cluster CR**

`applications/cnpg-grafana/overlays/use1/cluster.yaml`:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: grafana-db
  namespace: grafana
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16
  storage:
    size: 2Gi
    storageClass: longhorn
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 1Gi }
  bootstrap:
    initdb:
      database: grafana
      owner: grafana
  backup:
    barmanObjectStore:
      destinationPath: s3://cnpg-grafana-use1
      endpointURL: https://backup-storage.vngenterprise.com
      s3Credentials:
        accessKeyId:
          name: cnpg-grafana-backup
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: cnpg-grafana-backup
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
      data:
        compression: gzip
    retentionPolicy: "14d"
```

### Task 4.4: Create cnpg-grafana overlay kustomization

**Files:**
- Create: `applications/cnpg-grafana/overlays/use1/kustomization.yaml`

- [ ] **Step 1: Kustomization**

`applications/cnpg-grafana/overlays/use1/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - external-secret.yaml
  - cluster.yaml
```

- [ ] **Step 2: Verify**

```bash
kustomize build applications/cnpg-grafana/overlays/use1 | kubectl apply --dry-run=server -f -
```

Expected: namespace, ExternalSecret, Cluster all "created (server dry run)".

### Task 4.5: Create cnpg-grafana ArgoCD Application

**Files:**
- Create: `argocd/applications/use1/cnpg-grafana.yaml`

- [ ] **Step 1: Application manifest**

`argocd/applications/use1/cnpg-grafana.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cnpg-grafana
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/cnpg-grafana/overlays/use1/
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: grafana
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
```

- [ ] **Step 2: Commit and push**

```bash
git add applications/cnpg-grafana/ argocd/applications/use1/cnpg-grafana.yaml
git commit -m "feat: add cnpg-grafana single-instance postgres for grafana"
git push
```

- [ ] **Step 3: Wait for cluster ready**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced app/cnpg-grafana --timeout=300s
kubectl -n grafana wait --for=condition=Ready cluster/grafana-db --timeout=600s
```

- [ ] **Step 4: Verify postgres ready**

```bash
kubectl -n grafana get cluster grafana-db
kubectl -n grafana get pods -l cnpg.io/cluster=grafana-db
```

Expected: cluster `1/1 Ready`, one `grafana-db-1` pod Running.

### Task 4.6: Create Grafana OIDC ExternalSecret

**Files:**
- Create: `applications/grafana/overlays/use1/vanguard/external-secret-oidc.yaml`

- [ ] **Step 1: ExternalSecret**

`applications/grafana/overlays/use1/vanguard/external-secret-oidc.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-oidc
  namespace: grafana
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: grafana-oidc
    creationPolicy: Owner
  data:
    - secretKey: GF_AUTH_GENERIC_OAUTH_CLIENT_ID
      remoteRef:
        key: grafana/oidc
        property: CLIENT_ID
    - secretKey: GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET
      remoteRef:
        key: grafana/oidc
        property: CLIENT_SECRET
```

### Task 4.7: Update Grafana values.yaml

**Files:**
- Modify: `applications/grafana/overlays/use1/vanguard/values.yaml`

- [ ] **Step 1: Replace values.yaml with the new shape**

Replace `applications/grafana/overlays/use1/vanguard/values.yaml` with:

```yaml
# Single-replica Grafana backed by CNPG postgres. Datasources/dashboards/alerts
# come from labeled ConfigMaps via the sidecar.

replicas: 1

deploymentStrategy:
  type: Recreate            # single replica, no rolling required

# Sidecar for ConfigMap-driven provisioning
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    searchNamespace: ALL
    folderAnnotation: grafana_dashboard_folder
    provider:
      foldersFromFilesStructure: true
  datasources:
    enabled: true
    label: grafana_datasource
    labelValue: "1"
    searchNamespace: ALL
  alerts:
    enabled: true
    label: grafana_alert
    labelValue: "1"
    searchNamespace: ALL
  notifiers:
    enabled: false

# CNPG postgres backend (replaces sqlite)
persistence:
  enabled: false           # no PVC; state in postgres
grafana.ini:
  database:
    type: postgres
    host: grafana-db-rw.grafana.svc.cluster.local:5432
    name: grafana
    user: grafana
    # Password sourced from env (CNPG generates the secret 'grafana-db-app')
  server:
    root_url: https://grafana.vngenterprise.com
    serve_from_sub_path: false
  auth.generic_oauth:
    enabled: true
    name: "Vanguard SSO"
    allow_sign_up: true
    auth_url: https://accounts.vngenterprise.com/oauth/v2/authorize
    token_url: https://accounts.vngenterprise.com/oauth/v2/token
    api_url:   https://accounts.vngenterprise.com/oidc/v1/userinfo
    role_attribute_path: "contains(groups[*], 'monitoring_admin') && 'GrafanaAdmin' || contains(groups[*], 'monitoring_editor') && 'Editor' || 'Viewer'"
    allow_assign_grafana_admin: true
    role_attribute_strict: true
    email_attribute_name: "email:primary"
    email_attribute_path: email
    scopes: "openid email profile offline_access roles"
    auto_login: true
    use_pkce: true
    use_refresh_token: true
  unified_alerting:
    enabled: true
  alerting:
    enabled: false

# Inject DB password + OIDC secrets from kubernetes Secrets
envFrom:
  - secretRef:
      name: grafana-oidc
env:
  GF_DATABASE_PASSWORD:
    valueFrom:
      secretKeyRef:
        name: grafana-db-app
        key: password

# Resources
resources:
  requests: { cpu: 100m, memory: 256Mi }
  limits:   { cpu: 500m, memory: 1Gi }

# Memcached / image pull / serviceMonitor — leave at chart defaults
```

> The CNPG operator creates a Secret `grafana-db-app` containing `username`, `password`, `dbname`, `uri` etc. (this is how all the other Vanguard services consume CNPG). The `GF_DATABASE_PASSWORD` env above references it.

### Task 4.8: Update Grafana kustomization to include the OIDC ExternalSecret

**Files:**
- Modify: `applications/grafana/overlays/use1/vanguard/kustomization.yaml`

- [ ] **Step 1: Add external-secret-oidc.yaml to resources**

Update to:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - grafana.vngenterprise.com.yaml
  - external-secret-oidc.yaml
  - datasources.configmap.yaml
helmCharts:
  - name: grafana
    version: "10.1.4"
    repo: https://grafana.github.io/helm-charts
    releaseName: grafana
    namespace: grafana
    valuesFile: values.yaml
```

### Task 4.9: Create the initial datasources ConfigMap (Mimir only)

**Files:**
- Create: `applications/grafana/overlays/use1/vanguard/datasources.configmap.yaml`

- [ ] **Step 1: ConfigMap with Mimir datasource**

`applications/grafana/overlays/use1/vanguard/datasources.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: grafana
  labels:
    grafana_datasource: "1"
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Mimir
        uid: mimir
        type: prometheus
        access: proxy
        url: http://mimir-nginx.mimir.svc.cluster.local/prometheus
        isDefault: true
        editable: false
        jsonData:
          httpHeaderName1: "X-Scope-OrgID"
          alertmanagerUid: mimir-am-stub
        secureJsonData:
          httpHeaderValue1: "metrics"
```

Loki, Tempo, and Pyroscope are added to this ConfigMap in their respective phases. The sidecar reloads when the ConfigMap changes — no Grafana restart needed.

### Task 4.10: Verify Grafana kustomize build

**Files:** none (verification)

- [ ] **Step 1: Build + dry-run**

```bash
kustomize build --enable-helm applications/grafana/overlays/use1/vanguard > /tmp/grafana-rendered.yaml
kubectl apply --dry-run=server -f /tmp/grafana-rendered.yaml | head -30
```

Expected: most resources "created (server dry run)".

### Task 4.11: Create Grafana ArgoCD Application

**Files:**
- Create: `argocd/applications/use1/grafana.yaml`

- [ ] **Step 1: Application**

`argocd/applications/use1/grafana.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: grafana
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/grafana/overlays/use1/vanguard/
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: grafana
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Commit and push**

```bash
git add applications/grafana/ argocd/applications/use1/grafana.yaml
git commit -m "feat: deploy grafana with cnpg backend, zitadel oidc, sidecar provisioning"
git push
```

- [ ] **Step 3: Wait for sync + ready**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced app/grafana --timeout=600s
kubectl -n grafana wait --for=condition=Available deploy/grafana --timeout=600s
```

### Task 4.12: Verify Grafana login + Mimir datasource

**Files:** none (verification)

- [ ] **Step 1: Open Grafana UI**

Over netbird, visit `https://grafana.vngenterprise.com`. Click "Sign in with Vanguard SSO". Authenticate via Zitadel. Verify you land in Grafana with appropriate role (depends on your Zitadel groups).

- [ ] **Step 2: Verify Mimir datasource**

In Grafana → Connections → Data sources → Mimir → "Save & test". Expected: "Data source is working".

- [ ] **Step 3: Run a query**

In Grafana → Explore → select Mimir → query `up{job="kubelet"}`. Expected: 6 series, one per node.

---

## Phase 5: Loki + alloy-logs deploy

### Task 5.1: Create loki base

**Files:**
- Create: `applications/loki/base/kustomization.yaml`
- Create: `applications/loki/base/namespace.yaml`

- [ ] **Step 1: Namespace**

`applications/loki/base/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: loki
```

- [ ] **Step 2: Base kustomization**

`applications/loki/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

### Task 5.2: Create Loki ExternalSecret

**Files:**
- Create: `applications/loki/overlays/use1/external-secret.yaml`

- [ ] **Step 1: ExternalSecret**

`applications/loki/overlays/use1/external-secret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: loki-global-env
  namespace: loki
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: loki-global-env
    creationPolicy: Owner
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: monitoring/loki
        property: AWS_ACCESS_KEY_ID
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: monitoring/loki
        property: AWS_SECRET_ACCESS_KEY
    - secretKey: AWS_ENDPOINTS
      remoteRef:
        key: monitoring/loki
        property: AWS_ENDPOINTS
    - secretKey: BUCKET_NAME
      remoteRef:
        key: monitoring/loki
        property: BUCKET_NAME
```

### Task 5.3: Create Loki values.yaml

**Files:**
- Create: `applications/loki/overlays/use1/values.yaml`

- [ ] **Step 1: Values**

`applications/loki/overlays/use1/values.yaml`:
```yaml
deploymentMode: SingleBinary

loki:
  auth_enabled: true
  schemaConfig:
    configs:
      - from: 2026-01-01
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  storage:
    type: s3
    bucketNames:
      chunks: ${BUCKET_NAME}
      ruler:  ${BUCKET_NAME}
      admin:  ${BUCKET_NAME}
    s3:
      endpoint: ${AWS_ENDPOINTS}
      accessKeyId: ${AWS_ACCESS_KEY_ID}
      secretAccessKey: ${AWS_SECRET_ACCESS_KEY}
      s3ForcePathStyle: true
      insecure: false
  limits_config:
    retention_period: 168h           # 7 days
    reject_old_samples: true
    reject_old_samples_max_age: 24h
    max_global_streams_per_user: 10000
  compactor:
    retention_enabled: true
    delete_request_store: s3
  commonConfig:
    replication_factor: 1
  storage_config:
    tsdb_shipper:
      active_index_directory: /var/loki/tsdb-index
      cache_location: /var/loki/tsdb-cache
      cache_ttl: 24h

singleBinary:
  replicas: 1
  resources:
    requests: { cpu: 200m, memory: 1Gi }
    limits:   { cpu: 1,    memory: 3Gi }
  persistence:
    enabled: true
    size: 10Gi
    storageClass: longhorn
  extraEnvFrom:
    - secretRef:
        name: loki-global-env

# Disable the components we don't use in monolithic mode
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0
distributor:
  replicas: 0
ingester:
  replicas: 0
querier:
  replicas: 0
queryFrontend:
  replicas: 0
queryScheduler:
  replicas: 0
compactor:
  replicas: 0
indexGateway:
  replicas: 0

# Memcached caches
chunksCache:
  enabled: true
  replicas: 1
  allocatedMemory: 512
resultsCache:
  enabled: true
  replicas: 1
  allocatedMemory: 256

gateway:
  enabled: false        # alloy-logs writes directly to the singleBinary service

monitoring:
  selfMonitoring:
    enabled: false
  lokiCanary:
    enabled: false

test:
  enabled: false
```

### Task 5.4: Create Loki overlay kustomization

**Files:**
- Create: `applications/loki/overlays/use1/kustomization.yaml`

- [ ] **Step 1: Kustomization**

`applications/loki/overlays/use1/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - external-secret.yaml
helmCharts:
  - name: loki
    version: "6.16.0"
    repo: https://grafana.github.io/helm-charts
    releaseName: loki
    namespace: loki
    valuesFile: values.yaml
```

> Verify the chart version exists: `helm search repo grafana/loki -l | head` (chart `6.16.0` is recent as of writing; bump to the current latest if needed).

- [ ] **Step 2: Build + dry-run**

```bash
kustomize build --enable-helm applications/loki/overlays/use1 > /tmp/loki-rendered.yaml
kubectl apply --dry-run=server -f /tmp/loki-rendered.yaml | head -20
```

### Task 5.5: Create Loki ArgoCD Application

**Files:**
- Create: `argocd/applications/use1/loki.yaml`

- [ ] **Step 1: Application**

`argocd/applications/use1/loki.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/loki/overlays/use1/
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: loki
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Commit and push**

```bash
git add applications/loki/ argocd/applications/use1/loki.yaml
git commit -m "feat: deploy loki singlebinary with offsite s3 backend, 7d retention"
git push
```

- [ ] **Step 3: Wait for ready**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced app/loki --timeout=600s
kubectl -n loki wait --for=condition=Ready pod -l app.kubernetes.io/component=single-binary --timeout=600s
```

### Task 5.6: Deploy alloy-logs

**Files:**
- Create: `argocd/applications/use1/alloy-logs.yaml`

- [ ] **Step 1: ArgoCD app for alloy-logs (manifests committed back in Task 3.7)**

`argocd/applications/use1/alloy-logs.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alloy-logs
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/alloy-logs/overlays/use1/
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: alloy-logs
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Commit and push**

```bash
git add argocd/applications/use1/alloy-logs.yaml
git commit -m "feat: activate alloy-logs argocd application"
git push
```

- [ ] **Step 3: Wait for DS rollout**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced app/alloy-logs --timeout=300s
kubectl -n alloy-logs rollout status ds/alloy-logs --timeout=300s
```

Expected: DS rolled out to all 6 nodes.

### Task 5.7: Add Loki to Grafana datasources

**Files:**
- Modify: `applications/grafana/overlays/use1/vanguard/datasources.configmap.yaml`

- [ ] **Step 1: Append Loki datasource**

Update the ConfigMap to include Loki:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: grafana
  labels:
    grafana_datasource: "1"
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Mimir
        uid: mimir
        type: prometheus
        access: proxy
        url: http://mimir-nginx.mimir.svc.cluster.local/prometheus
        isDefault: true
        editable: false
        jsonData:
          httpHeaderName1: "X-Scope-OrgID"
        secureJsonData:
          httpHeaderValue1: "metrics"

      - name: Loki
        uid: loki
        type: loki
        access: proxy
        url: http://loki.loki.svc.cluster.local:3100
        editable: false
        jsonData:
          httpHeaderName1: "X-Scope-OrgID"
          derivedFields:
            - matcherRegex: 'trace_id[=:]\s*([a-fA-F0-9]{16,32})'
              name: TraceID
              datasourceUid: tempo
              url: '$${__value.raw}'
        secureJsonData:
          httpHeaderValue1: "logs"
```

- [ ] **Step 2: Commit and push**

```bash
git add applications/grafana/overlays/use1/vanguard/datasources.configmap.yaml
git commit -m "feat: add loki grafana datasource with trace_id derived field"
git push
```

- [ ] **Step 3: Wait for sidecar reload**

The sidecar polls the cluster every ~30s. Wait ~1 min and refresh Grafana.

### Task 5.8: Verify logs flowing

**Files:** none (verification)

- [ ] **Step 1: Query in Grafana Explore**

In Grafana → Explore → select Loki → query `{namespace="default"}` over last 5 min. Expected: log lines visible.

- [ ] **Step 2: Verify chunks landing in S3**

```bash
kubectl -n monitoring-buckets run -it --rm check-loki --image=minio/mc:latest --restart=Never \
  --env-from=secretref:bucket-admin --command -- \
  sh -c 'mc alias set offsite "$AWS_ENDPOINTS" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" && mc ls --recursive offsite/monitoring-loki-use1 | head -10'
```

Expected (after ~1h, when first chunks flush): listing of `fake/` and `index_*` objects. If empty in the first few minutes, that's normal — Loki batches chunks.

---

## Phase 6: Tempo + Pyroscope + alloy-receiver

### Task 6.1: Create tempo manifests

**Files:**
- Create: `applications/tempo/base/kustomization.yaml`
- Create: `applications/tempo/base/namespace.yaml`
- Create: `applications/tempo/overlays/use1/external-secret.yaml`
- Create: `applications/tempo/overlays/use1/values.yaml`
- Create: `applications/tempo/overlays/use1/kustomization.yaml`

- [ ] **Step 1: Base**

`applications/tempo/base/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tempo
```

`applications/tempo/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

- [ ] **Step 2: ExternalSecret**

`applications/tempo/overlays/use1/external-secret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: tempo-global-env
  namespace: tempo
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: tempo-global-env
    creationPolicy: Owner
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef: { key: monitoring/tempo, property: AWS_ACCESS_KEY_ID }
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef: { key: monitoring/tempo, property: AWS_SECRET_ACCESS_KEY }
    - secretKey: AWS_ENDPOINTS
      remoteRef: { key: monitoring/tempo, property: AWS_ENDPOINTS }
    - secretKey: BUCKET_NAME
      remoteRef: { key: monitoring/tempo, property: BUCKET_NAME }
```

- [ ] **Step 3: Values**

`applications/tempo/overlays/use1/values.yaml`:
```yaml
tempo:
  multitenancyEnabled: true
  structuredConfig:
    storage:
      trace:
        backend: s3
        s3:
          bucket: ${BUCKET_NAME}
          endpoint: ${AWS_ENDPOINTS}
          access_key: ${AWS_ACCESS_KEY_ID}
          secret_key: ${AWS_SECRET_ACCESS_KEY}
          forcepathstyle: true
          insecure: false
    compactor:
      compaction:
        block_retention: 72h            # 3 days
    metrics_generator:
      processors: []                    # disabled in phase 1
    ingester:
      max_block_duration: 5m

persistence:
  enabled: true
  size: 10Gi
  storageClass: longhorn-single

resources:
  requests: { cpu: 100m, memory: 512Mi }
  limits:   { cpu: 500m, memory: 2Gi }

extraEnvFrom:
  - secretRef:
      name: tempo-global-env
```

- [ ] **Step 4: Kustomization**

`applications/tempo/overlays/use1/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - external-secret.yaml
helmCharts:
  - name: tempo
    version: "1.14.0"
    repo: https://grafana.github.io/helm-charts
    releaseName: tempo
    namespace: tempo
    valuesFile: values.yaml
```

> The `tempo` chart (singular, monolithic) is distinct from `tempo-distributed`. Verify with `helm search repo grafana/tempo`.

### Task 6.2: Create Tempo ArgoCD Application

**Files:**
- Create: `argocd/applications/use1/tempo.yaml`

- [ ] **Step 1: Application**

`argocd/applications/use1/tempo.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tempo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/tempo/overlays/use1/
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: tempo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Commit and push**

```bash
git add applications/tempo/ argocd/applications/use1/tempo.yaml
git commit -m "feat: deploy tempo monolithic with offsite s3 backend, 3d retention"
git push
```

- [ ] **Step 3: Wait for ready**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced app/tempo --timeout=600s
kubectl -n tempo wait --for=condition=Ready pod --all --timeout=600s
```

### Task 6.3: Create pyroscope manifests

**Files:**
- Create: `applications/pyroscope/base/kustomization.yaml`
- Create: `applications/pyroscope/base/namespace.yaml`
- Create: `applications/pyroscope/overlays/use1/external-secret.yaml`
- Create: `applications/pyroscope/overlays/use1/values.yaml`
- Create: `applications/pyroscope/overlays/use1/kustomization.yaml`

- [ ] **Step 1: Base**

`applications/pyroscope/base/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: pyroscope
```

`applications/pyroscope/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

- [ ] **Step 2: ExternalSecret**

`applications/pyroscope/overlays/use1/external-secret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: pyroscope-global-env
  namespace: pyroscope
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: pyroscope-global-env
    creationPolicy: Owner
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef: { key: monitoring/pyroscope, property: AWS_ACCESS_KEY_ID }
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef: { key: monitoring/pyroscope, property: AWS_SECRET_ACCESS_KEY }
    - secretKey: AWS_ENDPOINTS
      remoteRef: { key: monitoring/pyroscope, property: AWS_ENDPOINTS }
    - secretKey: BUCKET_NAME
      remoteRef: { key: monitoring/pyroscope, property: BUCKET_NAME }
```

- [ ] **Step 3: Values**

`applications/pyroscope/overlays/use1/values.yaml`:
```yaml
pyroscope:
  components:
    # Single-binary deployment — disable other component flavors
    distributor: { kind: Deployment, replicaCount: 0 }
    ingester:    { kind: StatefulSet, replicaCount: 0 }
    querier:     { kind: Deployment, replicaCount: 0 }
    storeGateway: { kind: StatefulSet, replicaCount: 0 }
    compactor:   { kind: StatefulSet, replicaCount: 0 }
  structuredConfig:
    storage:
      backend: s3
      s3:
        bucket_name: ${BUCKET_NAME}
        endpoint: ${AWS_ENDPOINTS}
        access_key_id: ${AWS_ACCESS_KEY_ID}
        secret_access_key: ${AWS_SECRET_ACCESS_KEY}
        force_path_style: true
        insecure: false
    limits:
      retention_period: 168h        # 7 days
    multitenancy_enabled: true

# Single binary
single_binary:
  enabled: true
  replicas: 1
  persistence:
    enabled: true
    size: 10Gi
    storageClassName: longhorn-single
  resources:
    requests: { cpu: 100m, memory: 512Mi }
    limits:   { cpu: 500m, memory: 2Gi }
  extraEnvFrom:
    - secretRef:
        name: pyroscope-global-env
```

> The pyroscope helm chart's structure changes between versions — verify with `helm show values grafana/pyroscope --version <ver>` and adjust keys (`single_binary` vs `pyroscope.deployment.mode: single_binary` etc.) accordingly. The current latest at writing supports the form above.

- [ ] **Step 4: Kustomization**

`applications/pyroscope/overlays/use1/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - external-secret.yaml
helmCharts:
  - name: pyroscope
    version: "1.13.0"
    repo: https://grafana.github.io/helm-charts
    releaseName: pyroscope
    namespace: pyroscope
    valuesFile: values.yaml
```

### Task 6.4: Create Pyroscope ArgoCD Application

**Files:**
- Create: `argocd/applications/use1/pyroscope.yaml`

- [ ] **Step 1: Application**

`argocd/applications/use1/pyroscope.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pyroscope
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/pyroscope/overlays/use1/
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: pyroscope
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Commit and push**

```bash
git add applications/pyroscope/ argocd/applications/use1/pyroscope.yaml
git commit -m "feat: deploy pyroscope single-binary with offsite s3, 7d retention"
git push
```

- [ ] **Step 3: Wait for ready**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced app/pyroscope --timeout=600s
kubectl -n pyroscope wait --for=condition=Ready pod --all --timeout=600s
```

### Task 6.5: Deploy alloy-receiver

**Files:**
- Create: `argocd/applications/use1/alloy-receiver.yaml`

- [ ] **Step 1: Application**

`argocd/applications/use1/alloy-receiver.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alloy-receiver
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/alloy-receiver/overlays/use1/
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: alloy-receiver
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Commit and push**

```bash
git add argocd/applications/use1/alloy-receiver.yaml
git commit -m "feat: activate alloy-receiver argocd application"
git push
```

- [ ] **Step 3: Wait for ready**

```bash
kubectl -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced app/alloy-receiver --timeout=300s
kubectl -n alloy-receiver get pods
```

Expected: 2 alloy-receiver pods Running.

### Task 6.6: Add Tempo + Pyroscope to Grafana datasources

**Files:**
- Modify: `applications/grafana/overlays/use1/vanguard/datasources.configmap.yaml`

- [ ] **Step 1: Append Tempo and Pyroscope to the ConfigMap**

Update to:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: grafana
  labels:
    grafana_datasource: "1"
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Mimir
        uid: mimir
        type: prometheus
        access: proxy
        url: http://mimir-nginx.mimir.svc.cluster.local/prometheus
        isDefault: true
        editable: false
        jsonData:
          httpHeaderName1: "X-Scope-OrgID"
        secureJsonData:
          httpHeaderValue1: "metrics"

      - name: Loki
        uid: loki
        type: loki
        access: proxy
        url: http://loki.loki.svc.cluster.local:3100
        editable: false
        jsonData:
          httpHeaderName1: "X-Scope-OrgID"
          derivedFields:
            - matcherRegex: 'trace_id[=:]\s*([a-fA-F0-9]{16,32})'
              name: TraceID
              datasourceUid: tempo
              url: '$${__value.raw}'
        secureJsonData:
          httpHeaderValue1: "logs"

      - name: Tempo
        uid: tempo
        type: tempo
        access: proxy
        url: http://tempo.tempo.svc.cluster.local:3200
        editable: false
        jsonData:
          httpHeaderName1: "X-Scope-OrgID"
          tracesToLogsV2:
            datasourceUid: loki
            tags: [{ key: "service.name", value: "service" }, { key: "namespace" }, { key: "pod" }]
            filterByTraceID: true
            spanStartTimeShift: '-1m'
            spanEndTimeShift: '1m'
          tracesToMetrics:
            datasourceUid: mimir
            tags: [{ key: "service.name", value: "service" }, { key: "namespace" }]
          serviceMap:
            datasourceUid: mimir
          nodeGraph:
            enabled: true
        secureJsonData:
          httpHeaderValue1: "traces"

      - name: Pyroscope
        uid: pyroscope
        type: grafana-pyroscope-datasource
        access: proxy
        url: http://pyroscope.pyroscope.svc.cluster.local:4040
        editable: false
        jsonData:
          httpHeaderName1: "X-Scope-OrgID"
        secureJsonData:
          httpHeaderValue1: "profiles"
```

- [ ] **Step 2: Commit and push**

```bash
git add applications/grafana/overlays/use1/vanguard/datasources.configmap.yaml
git commit -m "feat: add tempo+pyroscope grafana datasources with correlation links"
git push
```

- [ ] **Step 3: Wait ~1 min for sidecar to reload**

### Task 6.7: Verify traces + profiles

**Files:** none (verification)

- [ ] **Step 1: Push a test OTLP trace from a debug pod**

```bash
kubectl run -it --rm otlp-test --image=alpine/curl:latest --restart=Never -- sh -c '
apk add --no-cache curl &&
curl -v -X POST http://alloy-receiver.alloy-receiver.svc.cluster.local:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d "{
    \"resourceSpans\": [{
      \"resource\": {\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"plan-test\"}}]},
      \"scopeSpans\": [{
        \"spans\": [{
          \"traceId\": \"5b8efff798038103d269b633813fc60c\",
          \"spanId\": \"eee19b7ec3c1b173\",
          \"name\": \"test-span\",
          \"startTimeUnixNano\": \"$(date +%s%N)\",
          \"endTimeUnixNano\": \"$(date +%s%N)\"
        }]
      }]
    }]
  }"
'
```

- [ ] **Step 2: Query trace in Grafana**

In Grafana → Explore → Tempo → search by service name `plan-test`. Expected: trace appears within ~60s.

- [ ] **Step 3: Verify Pyroscope endpoint is up**

```bash
kubectl -n pyroscope port-forward svc/pyroscope 4040:4040 &
PF=$!
sleep 3
curl -s -H "X-Scope-OrgID: profiles" http://localhost:4040/ready
echo
kill $PF
```

Expected: `ready`.

---

## Phase 7: Alerts + dashboards bootstrap

### Task 7.1: Create grafana-alerting ExternalSecret

**Files:**
- Create: `applications/grafana/overlays/use1/vanguard/alerts/external-secret.yaml`

- [ ] **Step 1: ExternalSecret for alerting webhooks**

`applications/grafana/overlays/use1/vanguard/alerts/external-secret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-alerting
  namespace: grafana
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: grafana-alerting
    creationPolicy: Owner
  data:
    - secretKey: DISCORD_PLATFORM_WEBHOOK
      remoteRef: { key: monitoring/grafana-alerting, property: DISCORD_PLATFORM_WEBHOOK }
    - secretKey: DISCORD_RUSTLENS_WEBHOOK
      remoteRef: { key: monitoring/grafana-alerting, property: DISCORD_RUSTLENS_WEBHOOK }
    - secretKey: DISCORD_VANGUARD_WEBHOOK
      remoteRef: { key: monitoring/grafana-alerting, property: DISCORD_VANGUARD_WEBHOOK }
```

### Task 7.2: Create contact-points ConfigMap

**Files:**
- Create: `applications/grafana/overlays/use1/vanguard/alerts/contact-points.configmap.yaml`

- [ ] **Step 1: Contact points**

`applications/grafana/overlays/use1/vanguard/alerts/contact-points.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-contact-points
  namespace: grafana
  labels:
    grafana_alert: "1"
data:
  contact-points.yaml: |
    apiVersion: 1
    contactPoints:
      - orgId: 1
        name: discord-platform
        receivers:
          - uid: discord-platform
            type: discord
            settings:
              url: $DISCORD_PLATFORM_WEBHOOK
              use_discord_username: false
              message: |
                **{{ .Status }}** - {{ .CommonLabels.alertname }}
                {{ range .Alerts }}
                  *Severity*: {{ .Labels.severity }}
                  *Namespace*: {{ .Labels.namespace }}
                  *Summary*: {{ .Annotations.summary }}
                {{ end }}

      - orgId: 1
        name: discord-rustlens
        receivers:
          - uid: discord-rustlens
            type: discord
            settings:
              url: $DISCORD_RUSTLENS_WEBHOOK

      - orgId: 1
        name: discord-vanguard
        receivers:
          - uid: discord-vanguard
            type: discord
            settings:
              url: $DISCORD_VANGUARD_WEBHOOK

      # Stubs ready to enable — fill the Vault key and uncomment.
      # - orgId: 1
      #   name: email-platform
      #   receivers:
      #     - uid: email-platform
      #       type: email
      #       settings:
      #         addresses: ops@vngenterprise.com
      # - orgId: 1
      #   name: pagerduty-critical
      #   receivers:
      #     - uid: pagerduty-critical
      #       type: pagerduty
      #       settings:
      #         integrationKey: $PAGERDUTY_INTEGRATION_KEY
```

Grafana resolves `$DISCORD_*_WEBHOOK` from env vars; we'll wire the env in Task 7.5.

### Task 7.3: Create notification-policies ConfigMap

**Files:**
- Create: `applications/grafana/overlays/use1/vanguard/alerts/notification-policies.configmap.yaml`

- [ ] **Step 1: Policies**

`applications/grafana/overlays/use1/vanguard/alerts/notification-policies.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-notification-policies
  namespace: grafana
  labels:
    grafana_alert: "1"
data:
  policies.yaml: |
    apiVersion: 1
    policies:
      - orgId: 1
        receiver: discord-platform
        group_by: [alertname, namespace]
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 12h
        routes:
          - receiver: discord-rustlens
            object_matchers:
              - [team, "=", rustlens]
            continue: false
          - receiver: discord-vanguard
            object_matchers:
              - [team, "=", vanguard]
            continue: false
```

### Task 7.4: Create the platform alert rule groups

**Files:**
- Create: `applications/grafana/overlays/use1/vanguard/alerts/rules-platform.configmap.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/alerts/rules-kubernetes.configmap.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/alerts/rules-longhorn.configmap.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/alerts/rules-cnpg.configmap.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/alerts/rules-argocd.configmap.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/alerts/rules-traefik.configmap.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/alerts/rules-monitoring.configmap.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/alerts/rules-heartbeat.configmap.yaml`

- [ ] **Step 1: Platform rules (start with `isPaused: true`)**

`applications/grafana/overlays/use1/vanguard/alerts/rules-platform.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-rules-platform
  namespace: grafana
  labels:
    grafana_alert: "1"
    grafana_dashboard_folder: "platform"
data:
  rules.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: platform
        folder: platform
        interval: 1m
        rules:
          - uid: node-not-ready
            title: NodeNotReady
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 300, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'kube_node_status_condition{condition="Ready",status="true"} == 0'
                  refId: A
            noDataState: OK
            for: 5m
            labels:
              severity: critical
              team: platform
            annotations:
              summary: "Node {{ $labels.node }} is not Ready"

          - uid: node-mem-pressure
            title: NodeMemoryPressure
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 300, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'kube_node_status_condition{condition="MemoryPressure",status="true"} == 1'
                  refId: A
            for: 5m
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "Node {{ $labels.node }} under memory pressure"

          - uid: node-disk-pressure
            title: NodeDiskPressure
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 300, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'kube_node_status_condition{condition="DiskPressure",status="true"} == 1'
                  refId: A
            for: 5m
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "Node {{ $labels.node }} under disk pressure"

          - uid: fs-usage-high
            title: NodeFilesystemHighUsage
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 300, to: 0 }
                datasourceUid: mimir
                model:
                  expr: '(node_filesystem_size_bytes - node_filesystem_avail_bytes) / node_filesystem_size_bytes > 0.85'
                  refId: A
            for: 10m
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "Filesystem {{ $labels.mountpoint }} on {{ $labels.instance }} is >85% used"

          - uid: kubelet-down
            title: KubeletDown
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 300, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'up{job="kubelet"} == 0'
                  refId: A
            for: 5m
            labels:
              severity: critical
              team: platform
            annotations:
              summary: "Kubelet on {{ $labels.node }} is down"
```

- [ ] **Step 2: Kubernetes rules**

`applications/grafana/overlays/use1/vanguard/alerts/rules-kubernetes.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-rules-kubernetes
  namespace: grafana
  labels:
    grafana_alert: "1"
data:
  rules.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: kubernetes
        folder: platform
        interval: 1m
        rules:
          - uid: pod-crashloop
            title: PodCrashLoopBackOff
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 900, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'increase(kube_pod_container_status_restarts_total[15m]) > 5'
                  refId: A
            for: 5m
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} restarting frequently"

          - uid: pod-pending
            title: PodPendingTooLong
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 600, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'kube_pod_status_phase{phase="Pending"} == 1'
                  refId: A
            for: 10m
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} pending >10m"

          - uid: ds-rollout-incomplete
            title: DaemonSetRolloutIncomplete
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 600, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'kube_daemonset_status_number_ready != kube_daemonset_status_desired_number_scheduled'
                  refId: A
            for: 15m
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "DaemonSet {{ $labels.namespace }}/{{ $labels.daemonset }} not fully rolled out"

          - uid: deploy-replicas-mismatch
            title: DeploymentReplicasMismatch
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 600, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'kube_deployment_status_replicas != kube_deployment_spec_replicas'
                  refId: A
            for: 15m
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} replicas mismatch"

          - uid: pvc-usage-high
            title: PVCUsageHigh
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 600, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.90'
                  refId: A
            for: 10m
            labels:
              severity: critical
              team: platform
            annotations:
              summary: "PVC {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} >90% full"
```

- [ ] **Step 3: Longhorn rules**

`applications/grafana/overlays/use1/vanguard/alerts/rules-longhorn.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-rules-longhorn
  namespace: grafana
  labels:
    grafana_alert: "1"
data:
  rules.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: longhorn
        folder: platform
        interval: 1m
        rules:
          - uid: lh-volume-degraded
            title: LonghornVolumeDegraded
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 600, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'longhorn_volume_robustness == 2'
                  refId: A
            for: 5m
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "Longhorn volume {{ $labels.volume }} is degraded"

          - uid: lh-volume-faulted
            title: LonghornVolumeFaulted
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 300, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'longhorn_volume_robustness == 3'
                  refId: A
            for: 2m
            labels:
              severity: critical
              team: platform
            annotations:
              summary: "Longhorn volume {{ $labels.volume }} FAULTED"
```

- [ ] **Step 4: CNPG, ArgoCD, Traefik rule groups**

`applications/grafana/overlays/use1/vanguard/alerts/rules-cnpg.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-rules-cnpg
  namespace: grafana
  labels:
    grafana_alert: "1"
data:
  rules.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: cnpg
        folder: platform
        interval: 1m
        rules:
          - uid: cnpg-primary-down
            title: CNPGPrimaryDown
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 300, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'cnpg_pg_replication_in_recovery == 0 unless on(namespace, cluster) cnpg_pg_replication_in_recovery'
                  refId: A
            for: 2m
            labels:
              severity: critical
              team: platform
            annotations:
              summary: "CNPG cluster {{ $labels.namespace }}/{{ $labels.cluster }} primary appears down"

          - uid: cnpg-replication-lag
            title: CNPGReplicationLag
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 300, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'cnpg_pg_replication_lag_seconds > 60'
                  refId: A
            for: 10m
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "CNPG replication lag >60s for {{ $labels.namespace }}/{{ $labels.cluster }}"
```

`applications/grafana/overlays/use1/vanguard/alerts/rules-argocd.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-rules-argocd
  namespace: grafana
  labels:
    grafana_alert: "1"
data:
  rules.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: argocd
        folder: platform
        interval: 1m
        rules:
          - uid: argocd-app-out-of-sync
            title: ArgoCDAppOutOfSync
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 1800, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'argocd_app_info{sync_status!="Synced"}'
                  refId: A
            for: 30m
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "ArgoCD app {{ $labels.name }} out of sync >30m"

          - uid: argocd-app-degraded
            title: ArgoCDAppDegraded
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 600, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'argocd_app_info{health_status="Degraded"}'
                  refId: A
            for: 10m
            labels:
              severity: critical
              team: platform
            annotations:
              summary: "ArgoCD app {{ $labels.name }} Degraded"
```

`applications/grafana/overlays/use1/vanguard/alerts/rules-traefik.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-rules-traefik
  namespace: grafana
  labels:
    grafana_alert: "1"
data:
  rules.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: traefik
        folder: platform
        interval: 1m
        rules:
          - uid: traefik-5xx-rate
            title: Traefik5xxRate
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 300, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'sum(rate(traefik_service_requests_total{code=~"5.."}[5m])) / sum(rate(traefik_service_requests_total[5m])) > 0.01'
                  refId: A
            for: 5m
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "Traefik 5xx rate >1% over 5m"

          - uid: cert-expiry
            title: CertificateExpiringSoon
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 86400, to: 0 }
                datasourceUid: mimir
                model:
                  expr: '(traefik_tls_certs_not_after - time()) / 86400 < 7'
                  refId: A
            for: 1h
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "Cert {{ $labels.sans }} expires in <7d"
```

- [ ] **Step 5: Monitoring-stack rules**

`applications/grafana/overlays/use1/vanguard/alerts/rules-monitoring.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-rules-monitoring
  namespace: grafana
  labels:
    grafana_alert: "1"
data:
  rules.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: monitoring
        folder: platform
        interval: 1m
        rules:
          - uid: mimir-ingester-unhealthy
            title: MimirIngesterUnhealthy
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 300, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'mimir_ring_members{state="Unhealthy", name="ingester"} > 0'
                  refId: A
            for: 5m
            labels:
              severity: critical
              team: platform
            annotations:
              summary: "Mimir ingester unhealthy"

          - uid: loki-ingester-down
            title: LokiIngesterDown
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 300, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'up{namespace="loki"} == 0'
                  refId: A
            for: 5m
            labels:
              severity: critical
              team: platform
            annotations:
              summary: "Loki appears down"

          - uid: tempo-ingester-down
            title: TempoIngesterDown
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 300, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'up{namespace="tempo"} == 0'
                  refId: A
            for: 5m
            labels:
              severity: critical
              team: platform
            annotations:
              summary: "Tempo appears down"

          - uid: alloy-dropped-samples
            title: AlloyDroppedSamples
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 600, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'rate(alloy_prometheus_remote_write_samples_failed_total[10m]) > 0'
                  refId: A
            for: 10m
            labels:
              severity: warning
              team: platform
            annotations:
              summary: "Alloy is dropping samples on remote_write"
```

- [ ] **Step 6: Heartbeat rule (initially paused; enable when ready)**

`applications/grafana/overlays/use1/vanguard/alerts/rules-heartbeat.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-rules-heartbeat
  namespace: grafana
  labels:
    grafana_alert: "1"
data:
  rules.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: heartbeat
        folder: platform
        interval: 1m
        rules:
          - uid: weekly-heartbeat
            title: WeeklyHeartbeat
            condition: A
            isPaused: true
            data:
              - refId: A
                relativeTimeRange: { from: 60, to: 0 }
                datasourceUid: mimir
                model:
                  expr: 'vector(1)'
                  refId: A
            for: 0s
            labels:
              severity: info
              team: platform
            annotations:
              summary: "Monitoring pipeline heartbeat — if you see this on Discord weekly, alerting works"
```

> The mute-timings configuration to fire this only on Fridays at noon lives in a future ConfigMap — for now it stays paused and is manually unpaused to test, then re-paused.

### Task 7.5: Wire alerting env into Grafana values

**Files:**
- Modify: `applications/grafana/overlays/use1/vanguard/values.yaml`

- [ ] **Step 1: Add alerting webhook env**

Append to `envFrom`:
```yaml
envFrom:
  - secretRef:
      name: grafana-oidc
  - secretRef:
      name: grafana-alerting
```

### Task 7.6: Register alerts subdir in kustomization

**Files:**
- Modify: `applications/grafana/overlays/use1/vanguard/kustomization.yaml`

- [ ] **Step 1: Update kustomization to include the alerts folder**

The alerts ConfigMaps need to be applied. Create `applications/grafana/overlays/use1/vanguard/alerts/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - external-secret.yaml
  - contact-points.configmap.yaml
  - notification-policies.configmap.yaml
  - rules-platform.configmap.yaml
  - rules-kubernetes.configmap.yaml
  - rules-longhorn.configmap.yaml
  - rules-cnpg.configmap.yaml
  - rules-argocd.configmap.yaml
  - rules-traefik.configmap.yaml
  - rules-monitoring.configmap.yaml
  - rules-heartbeat.configmap.yaml
```

Then update the parent kustomization `applications/grafana/overlays/use1/vanguard/kustomization.yaml` to include `./alerts`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - grafana.vngenterprise.com.yaml
  - external-secret-oidc.yaml
  - datasources.configmap.yaml
  - ./alerts
helmCharts:
  - name: grafana
    version: "10.1.4"
    repo: https://grafana.github.io/helm-charts
    releaseName: grafana
    namespace: grafana
    valuesFile: values.yaml
```

### Task 7.7: Commit alerting bootstrap (rules paused)

- [ ] **Step 1: Commit and push**

```bash
git add applications/grafana/overlays/use1/vanguard/alerts/ applications/grafana/overlays/use1/vanguard/values.yaml applications/grafana/overlays/use1/vanguard/kustomization.yaml
git commit -m "feat: bootstrap grafana alerting (contact points, policies, paused rules)"
git push
```

- [ ] **Step 2: Wait for sidecar reload**

```bash
sleep 60
kubectl -n grafana exec deploy/grafana -c grafana -- ls /etc/grafana/provisioning/alerting 2>&1 | head -20
```

Expected: alerts files exist in the provisioning directory.

### Task 7.8: Enable rule groups one at a time

> Each enable is a 1-line ConfigMap edit (`isPaused: true` → `isPaused: false` on each rule), then commit/push. Wait 1 hour between groups to catch any rule firing spuriously on existing infra.

- [ ] **Step 1: Enable platform group**

Edit `applications/grafana/overlays/use1/vanguard/alerts/rules-platform.configmap.yaml` — change every `isPaused: true` to `isPaused: false`.

```bash
git add applications/grafana/overlays/use1/vanguard/alerts/rules-platform.configmap.yaml
git commit -m "feat: enable platform alert rules"
git push
sleep 3600     # 1 hour soak
```

- [ ] **Step 2: Confirm Discord receives expected alerts (or quiet)**

Check `#discord-platform` (or wherever `DISCORD_PLATFORM_WEBHOOK` points). Expected: either silence (no infra issues) or alerts you can immediately diagnose and ack.

- [ ] **Step 3: Repeat for `rules-kubernetes`, `rules-longhorn`, `rules-cnpg`, `rules-argocd`, `rules-traefik`, `rules-monitoring`**

For each:
1. Flip `isPaused: false`
2. Commit + push
3. Soak 1h
4. Verify Discord activity makes sense

### Task 7.9: Test cross-team routing with a synthetic alert

**Files:** none (verification, optional)

- [ ] **Step 1: Add a temporary test rule with `team=rustlens`**

In Grafana UI → Alerting → Create alert rule → expr `vector(1)`, label `team=rustlens`, for 0s → save and let it fire once.

Expected: Discord notification lands in `#discord-rustlens` (not `#discord-platform`). Then delete the test rule.

### Task 7.10: Bootstrap day-one dashboards

**Files:**
- Create: `applications/grafana/overlays/use1/vanguard/dashboards/kustomization.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/dashboards/kubernetes.configmap.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/dashboards/longhorn.configmap.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/dashboards/cnpg.configmap.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/dashboards/traefik.configmap.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/dashboards/argocd.configmap.yaml`
- Create: `applications/grafana/overlays/use1/vanguard/dashboards/monitoring-stack.configmap.yaml`

- [ ] **Step 1: Fetch and wrap each dashboard JSON into a ConfigMap**

For each dashboard listed below, download the JSON from grafana.com (or the maintainer repo) and embed it under `data:` keyed by `<name>.json`. The sidecar reads the value as the dashboard.

Pattern (use `kubernetes-cluster.json` as example):

```bash
# Download
curl -s 'https://grafana.com/api/dashboards/15760/revisions/29/download' > /tmp/k8s-cluster.json
```

`applications/grafana/overlays/use1/vanguard/dashboards/kubernetes.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-kubernetes-cluster
  namespace: grafana
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_dashboard_folder: Kubernetes
data:
  kubernetes-cluster.json: |
    <paste contents of /tmp/k8s-cluster.json here, ENSURING the
     "datasource": { ... "uid": "<some-id>" ... } references are
     replaced with "uid": "mimir">
```

> **Important**: Most community dashboards embed a `datasource.uid` that won't match our `mimir`/`loki`/`tempo` uids. Either:
> 1. Run `sed -i 's/"uid": "[^"]*"/"uid": "${DS_PROMETHEUS}"/g' /tmp/k8s-cluster.json` and let Grafana variable-substitute, OR
> 2. Replace UIDs with the exact strings `mimir`, `loki`, `tempo`, `pyroscope` as defined in our datasources ConfigMap.
>
> Approach (2) is preferred for read-only provisioned dashboards.

Recommended dashboard IDs (verify they still exist on grafana.com before embedding):
- Kubernetes Cluster: `15760`
- Kubernetes Views / Nodes: `15759`
- Kubernetes Views / Pods: `15761`
- Longhorn: `16888`
- CNPG: `20417`
- Traefik 3: `17346`
- ArgoCD: `14584`
- Mimir overview: `17407`
- Loki overview: `15141`
- Tempo overview: `19395`
- Alloy: `21323`

- [ ] **Step 2: Create dashboards/kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kubernetes.configmap.yaml
  - longhorn.configmap.yaml
  - cnpg.configmap.yaml
  - traefik.configmap.yaml
  - argocd.configmap.yaml
  - monitoring-stack.configmap.yaml
```

- [ ] **Step 3: Add `./dashboards` to the parent kustomization**

Modify `applications/grafana/overlays/use1/vanguard/kustomization.yaml`:
```yaml
resources:
  - namespace.yaml
  - grafana.vngenterprise.com.yaml
  - external-secret-oidc.yaml
  - datasources.configmap.yaml
  - ./alerts
  - ./dashboards
helmCharts:
  - ...
```

- [ ] **Step 4: Commit and push**

```bash
git add applications/grafana/overlays/use1/vanguard/dashboards/ applications/grafana/overlays/use1/vanguard/kustomization.yaml
git commit -m "feat: bootstrap day-one grafana dashboards (k8s, longhorn, cnpg, traefik, argocd, monitoring-stack)"
git push
```

- [ ] **Step 5: Verify in Grafana**

Wait ~1 min for sidecar reload. Visit Grafana → Dashboards. Expected: folders `Kubernetes`, `Longhorn`, `CNPG`, `Traefik`, `ArgoCD`, `Monitoring`, each with their dashboards. Open one and verify panels render data.

---

## Final: Definition of Done

### Task F.1: All ArgoCD apps Synced + Healthy

- [ ] **Step 1: Audit**

```bash
kubectl -n argocd get app -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status | sort
```

Expected: every new app (`mimir`, `loki`, `tempo`, `pyroscope`, `grafana`, `cnpg-grafana`, `alloy-metrics`, `alloy-logs`, `alloy-receiver`, `monitoring-buckets`, `rustfs-cluster`) is `Synced Healthy`. No app shows `Degraded` or `OutOfSync`.

### Task F.2: Cross-signal smoke test

- [ ] **Step 1: One query per datasource via Grafana Explore**

In Grafana UI, switch the Explore datasource between Mimir/Loki/Tempo/Pyroscope and run:
- Mimir: `up{job="kubelet"}` → 6 results
- Loki: `{namespace="default"}` over last 15m → some log lines
- Tempo: search by service name `plan-test` → the test trace from Task 6.7
- Pyroscope: query against the `pyroscope` profile namespace — empty is acceptable until workloads are instrumented

### Task F.3: Storage footprint check

- [ ] **Step 1: Verify Longhorn consumption**

```bash
kubectl get pvc -A | grep -E 'longhorn|longhorn-single'
```

Expected: total new monitoring + rustfs PVCs sum to roughly the budget in the spec (~70 GiB physical for monitoring + ~30 GiB for rustfs).

```bash
kubectl get pv | awk '$5=="Bound"' | wc -l
```

### Task F.4: Heartbeat enable (optional, after one week of soak)

- [ ] **Step 1: Unpause the heartbeat rule + add mute-timing**

Edit `applications/grafana/overlays/use1/vanguard/alerts/rules-heartbeat.configmap.yaml` — flip `isPaused: false`. (Mute-timings for Friday-noon-only firing is deferred — for now the rule fires every minute, but evaluated only by humans noticing if Discord goes silent. A future improvement adds Grafana `muteTimings:` provisioning.)

```bash
git add applications/grafana/overlays/use1/vanguard/alerts/rules-heartbeat.configmap.yaml
git commit -m "feat: enable monitoring weekly heartbeat alert"
git push
```

---

## Self-review checklist (run during execution, not at plan write time)

Before claiming completion:

- [ ] Every ArgoCD app listed in §17 of the spec exists and is `Synced Healthy`
- [ ] No `hyplex-*` namespace remains
- [ ] `applications/rustfs/`, `applications/life/`, `applications/agones/`, `applications/redis-operator/overlays/hyplex/` are deleted from git
- [ ] `applications/pelican/` is preserved in git (verify: `ls applications/pelican/`)
- [ ] `applications/cert-manager/overlays/use1/hyplex.gg.yaml` still exists
- [ ] `longhorn-single` StorageClass exists
- [ ] All 6 monitoring buckets exist on offsite S3 with correct lifecycle rules
- [ ] Grafana login via Zitadel works end-to-end over netbird
- [ ] Mimir, Loki, Tempo, Pyroscope datasources are green in Grafana
- [ ] At least one alert has fired to Discord (`#discord-platform`)
- [ ] Cross-team alert routing tested (rule with `team=rustlens` lands in `#discord-rustlens`)

---

**Deviations from spec to flag in commit messages:**

- §5 storage strategy claimed `alloy-logs positions` would use a 1Gi PVC on `longhorn-single`. The plan uses `emptyDir` because DaemonSet PVCs are awkward (one PVC per node requires extra orchestration); positions reset on pod restart is acceptable. Document this in the alloy-logs commit message.
