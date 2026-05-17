# Sentry Self-Hosted Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a self-hosted Sentry into the `use1` Kubernetes cluster via GitOps, with full feature set (errors, releases, performance, profiling, replays, native crash symbolication, cron monitoring), CNPG-backed Postgres, Redis via the existing redis-operator, chart-bundled Kafka/ClickHouse, and Zitadel SAML2 SSO. The UI is internal-only on netbird (`sentry.vngenterprise.com`); a separate public hostname (`s-metrics.vngenterprise.com`) exposes only the Relay ingest endpoint.

**Architecture:** Three new ArgoCD `Applications` deploy from `v-deployments`: `cnpg-sentry` (CNPG `Cluster` `sentry-db` in namespace `sentry`), `redis-sentry` (`RedisReplication` + `RedisSentinel` in namespace `sentry-redis`), and `sentry` (the `sentry-kubernetes/sentry` Helm chart wrapped via kustomize `helmCharts:` in namespace `sentry`). Bulk blobs (attachments, source maps, replay recordings, release artifacts) go to S3 bucket `sentry-filestore-use1` on the existing offsite endpoint over netbird. CNPG basebackups go to `cnpg-sentry-use1`. Two Traefik IngressRoutes split UI from ingest.

**Tech Stack:** Kubernetes, ArgoCD, Kustomize, Helm via kustomize `helmCharts`, External-Secrets Operator + Vault, Longhorn (`longhorn` and `longhorn-single` StorageClasses), CloudNativePG, OT-Container-Kit Redis Operator, Sentry self-hosted Helm chart (`sentry-kubernetes/sentry`), chart-bundled Kafka + ClickHouse + Memcached, Traefik (public + `traefik-internal` IngressRoutes), cert-manager, Zitadel SAML2.

**Spec reference:** `docs/superpowers/specs/2026-05-17-sentry-self-hosted-design.md`

---

## Pre-flight: how to execute GitOps tasks

The "TDD" loop maps to GitOps as follows. Every task in this plan follows this shape.

| Code-TDD step | GitOps equivalent |
|---|---|
| Write the failing test | Write the manifest |
| Run test, expect FAIL | `kustomize build <overlay>` then `kubectl apply --dry-run=server -k <overlay>` (catches schema errors) |
| Write minimal implementation | (already done — the manifest *is* the implementation) |
| Run test, expect PASS | `git add` + `git commit` + `git push`; wait for ArgoCD to sync; run verification commands |
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

For this rollout, use a single branch `feature/sentry-self-hosted` with phase-by-phase commits. PR + merge to `main` at the end of each phase (or all at once at the end if working solo).

**Working directory:** `B:\.dev\Vanguard\v-deployments`. All paths in this plan are relative to that directory.

**Kubectl context:** `kubectl config use-context admin@use1` — run once at session start.

**Kustomize Helm rendering:** This repo uses `helmCharts:` inside `kustomization.yaml`. ArgoCD must be configured with `--enable-helm` for the kustomize build options; the existing apps (zitadel, alloy-metrics) prove this is already enabled in this cluster. The CLI equivalent is `kustomize build --enable-helm <path>`.

**MinIO Client (mc):** Phase 0 uses `mc` to create offsite S3 buckets. Run from any shell that can reach `https://backup-storage.vngenterprise.com` (the operator's workstation on netbird, or via a debug pod in the cluster).

---

## File Structure (master map)

### Creations

```
applications/sentry/                                              (new app — Helm chart wrap)
  base/
    kustomization.yaml
    namespace.yaml
    values.yaml
  overlays/use1/
    kustomization.yaml
    values.yaml
    external-secret-web.yaml
    external-secret-saml.yaml
    external-secret-filestore.yaml
    external-secret-smtp.yaml
    external-secret-clickhouse.yaml
    external-secret-redis.yaml
    podmonitors.yaml
    sentry.vngenterprise.com.yaml
    s-metrics.vngenterprise.com.yaml

applications/cnpg-sentry/                                         (new app — CNPG cluster)
  overlays/use1/
    kustomization.yaml
    cluster.yaml
    external-secret.yaml
    podmonitor.yaml

applications/redis-operator/overlays/sentry/                      (new overlay)
    kustomization.yaml
    namespace.yaml
    external-secrets.yaml
    redis-replication.yaml
    redis-sentinel.yaml

applications/grafana/overlays/use1/vanguard/alerts/
    rules-sentry.configmap.yaml                                   (new; added in Phase 6)
applications/grafana/overlays/use1/vanguard/dashboards/files/
    sentry.json                                                   (new; added in Phase 6)

argocd/applications/use1/
    cnpg-sentry.yaml                                              (new)
    redis-sentry.yaml                                             (new)
    sentry.yaml                                                   (new)
```

### Modifications

```
applications/grafana/overlays/use1/vanguard/alerts/kustomization.yaml
    (register rules-sentry.configmap.yaml in Phase 6)

applications/grafana/overlays/use1/vanguard/dashboards/kustomization.yaml
    (register sentry.json in Phase 6 — only if dashboards are managed via kustomize generator;
     if they are picked up by sidecar via a different mechanism, this step adapts to that.)
```

### Vault pre-population (manual, outside this repo)

Before Phase 1, create these Vault paths. Each is consumed by an `ExternalSecret` created in this plan. Use the existing `vault-backend` ClusterSecretStore.

```
sentry/web                  SECRET_KEY, SENTRY_OPTIONS_SYSTEM_ADMIN_EMAIL, SENTRY_OPTIONS_SYSTEM_ADMIN_PASSWORD
sentry/saml                 IDP_SSO_URL, IDP_ENTITY_ID, IDP_X509_CERT
                            (placeholders ok until Phase 3 — populate with the literal string "PENDING")
sentry/filestore            AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
                            AWS_ENDPOINT_URL, BUCKET_NAME
sentry/smtp                 HOST, PORT, USER, PASSWORD, FROM_EMAIL
                            (leave blank values if you don't want email; the chart will skip mail)
sentry/clickhouse           DEFAULT_PASSWORD, SENTRY_PASSWORD
cnpg/sentry/backup          AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
                            AWS_ENDPOINT_URL, BUCKET_NAME
redis/sentry                password
```

Generate random values where appropriate:
```bash
# 64-byte SECRET_KEY (Django format)
openssl rand -base64 64

# 32-char passwords for ClickHouse, Redis
openssl rand -base64 32
```

**Bootstrap admin email/password** is the *only* local Sentry user you'll create; it exists only to configure SAML in Phase 3 and is rotated immediately after.

### Helm chart version

The community chart lives at `https://sentry-kubernetes.github.io/charts`. Pin to a specific version in `applications/sentry/base/kustomization.yaml`. This plan uses **chart version `26.0.0`** as a placeholder; before starting Phase 2, run:

```bash
helm repo add sentry https://sentry-kubernetes.github.io/charts
helm repo update
helm search repo sentry/sentry --versions | head -5
```

and bump the version pin to the latest stable that supports the feature flags in this plan.

---

## Phase 0: Prep (buckets + Vault)

This phase has no in-cluster impact; it preps external state so later phases can pull creds and write to S3.

### Task 0.1: Verify prerequisites

**Files:** none (read-only checks)

- [ ] **Step 1: Set kubectl context**

```bash
kubectl config use-context admin@use1
```

- [ ] **Step 2: Confirm prerequisite operators / classes exist**

```bash
kubectl get crd | grep -E 'externalsecret|redisreplication|cluster.postgresql.cnpg|ingressroute'
kubectl get sc | grep -E 'longhorn|longhorn-single'
kubectl -n argocd get app | grep -E 'external-secrets|redis-operator|cloudnative-postgres|traefik|cert-manager'
```

Expected:
- `externalsecrets.external-secrets.io`, `redisreplications.redis.redis.opstreelabs.in`, `clusters.postgresql.cnpg.io`, `ingressroutes.traefik.io` all listed
- Both `longhorn` (2-rep) and `longhorn-single` (1-rep) StorageClasses present
- All five ArgoCD apps (external-secrets, redis-operator, cloudnative-postgres, traefik, cert-manager) Synced + Healthy

- [ ] **Step 3: Confirm netbird connectivity to offsite S3**

```bash
# From your workstation while on netbird
curl -sI https://backup-storage.vngenterprise.com | head -3
```

Expected: HTTP/2 200 (or 403 — both prove DNS + TLS work; 200 with `<Owner>` in body proves anonymous-list endpoint is reachable).

### Task 0.2: Create offsite S3 buckets

**Files:** none (manual operation against external S3)

- [ ] **Step 1: Configure mc alias**

```bash
mc alias set offsite https://backup-storage.vngenterprise.com <ADMIN_ACCESS_KEY> <ADMIN_SECRET_KEY>
mc admin info offsite
```

Expected: cluster info table with online status. (Admin creds live in Vault `monitoring/bucket-admin` per the LGTMP rollout; pull them from Vault before running this.)

- [ ] **Step 2: Create the two new buckets**

```bash
mc mb --ignore-existing offsite/sentry-filestore-use1
mc mb --ignore-existing offsite/cnpg-sentry-use1
mc ls offsite | grep -E 'sentry-filestore-use1|cnpg-sentry-use1'
```

Expected: both buckets listed.

- [ ] **Step 3: Apply 45-day lifecycle on sentry-filestore-use1**

Write the lifecycle JSON to a temp file:
```json
{
  "Rules": [
    {
      "ID": "expire-45d",
      "Status": "Enabled",
      "Filter": { "Prefix": "" },
      "Expiration": { "Days": 45 }
    }
  ]
}
```

```bash
cat > /tmp/sentry-filestore-lifecycle.json <<'EOF'
{"Rules":[{"ID":"expire-45d","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":45}}]}
EOF
mc ilm import offsite/sentry-filestore-use1 < /tmp/sentry-filestore-lifecycle.json
mc ilm ls offsite/sentry-filestore-use1
```

Expected: rule listed with 45-day expiration. (No lifecycle on `cnpg-sentry-use1` — CNPG enforces its own 14-day retention.)

- [ ] **Step 4: Smoke-test write + read on sentry-filestore-use1**

```bash
echo "hello-sentry" > /tmp/sentry-smoketest
mc cp /tmp/sentry-smoketest offsite/sentry-filestore-use1/smoketest.txt
mc cat offsite/sentry-filestore-use1/smoketest.txt
mc rm offsite/sentry-filestore-use1/smoketest.txt
```

Expected: `hello-sentry` printed, then file removed.

### Task 0.3: Create dedicated IAM users for sentry buckets

For blast-radius isolation, create per-bucket IAM-style users (separate from the monitoring user). Method depends on your S3 backend; common shapes:

- [ ] **Step 1: Create user `sentry-filestore` with R/W on `sentry-filestore-use1`**

```bash
# RustFS / MinIO admin user create
mc admin user add offsite sentry-filestore <SENTRY_FILESTORE_PASSWORD>
mc admin policy attach offsite readwrite --user=sentry-filestore --bucket=sentry-filestore-use1
# (exact command varies — use your S3 backend's documented per-bucket policy attach)
```

- [ ] **Step 2: Create user `cnpg-sentry-backup` with R/W on `cnpg-sentry-use1`**

```bash
mc admin user add offsite cnpg-sentry-backup <CNPG_SENTRY_PASSWORD>
mc admin policy attach offsite readwrite --user=cnpg-sentry-backup --bucket=cnpg-sentry-use1
```

- [ ] **Step 3: Verify each user can list only its bucket**

```bash
mc alias set sentry-filestore https://backup-storage.vngenterprise.com sentry-filestore <SENTRY_FILESTORE_PASSWORD>
mc ls sentry-filestore
```

Expected: only `sentry-filestore-use1` visible.

### Task 0.4: Populate Vault paths

- [ ] **Step 1: Generate secrets**

```bash
SECRET_KEY=$(openssl rand -base64 64 | tr -d '\n')
ADMIN_PW=$(openssl rand -base64 32 | tr -d '\n')
CH_DEFAULT_PW=$(openssl rand -base64 32 | tr -d '\n')
CH_SENTRY_PW=$(openssl rand -base64 32 | tr -d '\n')
REDIS_PW=$(openssl rand -base64 32 | tr -d '\n')

echo "SECRET_KEY=$SECRET_KEY"
echo "ADMIN_PW=$ADMIN_PW"
echo "CH_DEFAULT_PW=$CH_DEFAULT_PW"
echo "CH_SENTRY_PW=$CH_SENTRY_PW"
echo "REDIS_PW=$REDIS_PW"
```

- [ ] **Step 2: Write Vault keys (using vault CLI)**

```bash
export VAULT_ADDR=https://vault.vngenterprise.com   # adjust to your actual endpoint
vault login -method=oidc                            # or whichever method

vault kv put secret/sentry/web \
  SECRET_KEY="$SECRET_KEY" \
  SENTRY_OPTIONS_SYSTEM_ADMIN_EMAIL="frank@dobrovolny.dev" \
  SENTRY_OPTIONS_SYSTEM_ADMIN_PASSWORD="$ADMIN_PW"

vault kv put secret/sentry/saml \
  IDP_SSO_URL="PENDING" \
  IDP_ENTITY_ID="PENDING" \
  IDP_X509_CERT="PENDING"

vault kv put secret/sentry/filestore \
  AWS_ACCESS_KEY_ID="sentry-filestore" \
  AWS_SECRET_ACCESS_KEY="<SENTRY_FILESTORE_PASSWORD>" \
  AWS_ENDPOINT_URL="https://backup-storage.vngenterprise.com" \
  BUCKET_NAME="sentry-filestore-use1"

vault kv put secret/sentry/smtp \
  HOST="" PORT="587" USER="" PASSWORD="" FROM_EMAIL="sentry@vngenterprise.com"

vault kv put secret/sentry/clickhouse \
  DEFAULT_PASSWORD="$CH_DEFAULT_PW" \
  SENTRY_PASSWORD="$CH_SENTRY_PW"

vault kv put secret/cnpg/sentry/backup \
  AWS_ACCESS_KEY_ID="cnpg-sentry-backup" \
  AWS_SECRET_ACCESS_KEY="<CNPG_SENTRY_PASSWORD>" \
  AWS_ENDPOINT_URL="https://backup-storage.vngenterprise.com" \
  BUCKET_NAME="cnpg-sentry-use1"

vault kv put secret/redis/sentry password="$REDIS_PW"
```

- [ ] **Step 3: Verify Vault paths**

```bash
vault kv get secret/sentry/web | head -10
vault kv get secret/sentry/saml | head -10
vault kv get secret/sentry/filestore | head -10
vault kv get secret/sentry/clickhouse | head -10
vault kv get secret/cnpg/sentry/backup | head -10
vault kv get secret/redis/sentry | head -10
```

Expected: each path returns the keys you set, with values masked or truncated.

### Task 0.5: Create the feature branch

- [ ] **Step 1: Branch off main**

```bash
cd /b/.dev/Vanguard/v-deployments   # or your repo path
git switch main
git pull
git switch -c feature/sentry-self-hosted
```

Expected: `Switched to a new branch 'feature/sentry-self-hosted'`.

---

## Phase 1: CNPG `sentry-db` + `sentry-redis`

Two small ArgoCD apps that have to exist *before* the main Sentry chart syncs.

### Task 1.1: Create `applications/cnpg-sentry/overlays/use1/` directory

**Files:**
- Create: `applications/cnpg-sentry/overlays/use1/cluster.yaml`

- [ ] **Step 1: Create the CNPG `Cluster`**

`applications/cnpg-sentry/overlays/use1/cluster.yaml`:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: sentry-db
  namespace: sentry
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16
  storage:
    size: 5Gi
    storageClass: longhorn
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 1Gi }
  bootstrap:
    initdb:
      database: sentry
      owner: sentry
  backup:
    barmanObjectStore:
      destinationPath: s3://cnpg-sentry-use1
      endpointURL: https://backup-storage.vngenterprise.com
      s3Credentials:
        accessKeyId:
          name: cnpg-sentry-backup
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: cnpg-sentry-backup
          key: ACCESS_SECRET_KEY
      wal:
        compression: gzip
      data:
        compression: gzip
    retentionPolicy: "14d"
```

### Task 1.2: Create `cnpg-sentry` ExternalSecret

**Files:**
- Create: `applications/cnpg-sentry/overlays/use1/external-secret.yaml`

- [ ] **Step 1: Create ExternalSecret for backup creds**

`applications/cnpg-sentry/overlays/use1/external-secret.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cnpg-sentry-backup
  namespace: sentry
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: cnpg-sentry-backup
    creationPolicy: Owner
  data:
    - secretKey: ACCESS_KEY_ID
      remoteRef:
        key: cnpg/sentry/backup
        property: AWS_ACCESS_KEY_ID
    - secretKey: ACCESS_SECRET_KEY
      remoteRef:
        key: cnpg/sentry/backup
        property: AWS_SECRET_ACCESS_KEY
```

### Task 1.3: Create `cnpg-sentry` PodMonitor

**Files:**
- Create: `applications/cnpg-sentry/overlays/use1/podmonitor.yaml`

- [ ] **Step 1: Mirror the cnpg-grafana PodMonitor**

`applications/cnpg-sentry/overlays/use1/podmonitor.yaml`:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: sentry-db-cnpg
  namespace: sentry
  labels:
    instance: primary
spec:
  selector:
    matchLabels:
      cnpg.io/cluster: sentry-db
  podMetricsEndpoints:
    - port: metrics
      interval: 60s
```

### Task 1.4: Create `cnpg-sentry` kustomization

**Files:**
- Create: `applications/cnpg-sentry/overlays/use1/kustomization.yaml`

- [ ] **Step 1: Write the kustomization**

`applications/cnpg-sentry/overlays/use1/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - external-secret.yaml
  - cluster.yaml
  - podmonitor.yaml
```

- [ ] **Step 2: Validate kustomize build**

```bash
kustomize build applications/cnpg-sentry/overlays/use1
```

Expected: three rendered manifests (Cluster, ExternalSecret, PodMonitor) with `namespace: sentry`.

- [ ] **Step 3: Dry-run apply**

The `sentry` namespace doesn't exist yet — this is fine, the Sentry ArgoCD app creates it via `CreateNamespace=true`. For now just verify the manifests parse:

```bash
kustomize build applications/cnpg-sentry/overlays/use1 | kubectl apply --dry-run=client -f -
```

Expected: all three resources show `dry run`. (Don't use `--dry-run=server` here because the ns doesn't exist.)

### Task 1.5: Create the `redis-operator/overlays/sentry/` overlay

**Files:**
- Create: `applications/redis-operator/overlays/sentry/namespace.yaml`
- Create: `applications/redis-operator/overlays/sentry/external-secrets.yaml`
- Create: `applications/redis-operator/overlays/sentry/redis-replication.yaml`
- Create: `applications/redis-operator/overlays/sentry/redis-sentinel.yaml`
- Create: `applications/redis-operator/overlays/sentry/kustomization.yaml`

- [ ] **Step 1: Namespace**

`applications/redis-operator/overlays/sentry/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: sentry-redis
```

- [ ] **Step 2: ExternalSecret**

`applications/redis-operator/overlays/sentry/external-secrets.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: sentry-redis-secrets
  namespace: sentry-redis
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: sentry-redis-secrets
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: redis/sentry
        property: password
```

- [ ] **Step 3: RedisReplication**

`applications/redis-operator/overlays/sentry/redis-replication.yaml`:
```yaml
apiVersion: redis.redis.opstreelabs.in/v1beta2
kind: RedisReplication
metadata:
  name: sentry-redis
  namespace: sentry-redis
spec:
  clusterSize: 3
  podSecurityContext:
    runAsUser: 1000
    fsGroup: 1000
  kubernetesConfig:
    image: quay.io/opstree/redis:v7.4.7
    imagePullPolicy: IfNotPresent
    redisSecret:
      name: sentry-redis-secrets
      key: password
  redisExporter:
    enabled: true
    image: quay.io/opstree/redis-exporter:v1.44.0
  storage:
    volumeClaimTemplate:
      spec:
        storageClassName: longhorn-single
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 2Gi
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchExpressions:
                - key: app
                  operator: In
                  values:
                    - sentry-redis
            topologyKey: kubernetes.io/hostname
```

- [ ] **Step 4: RedisSentinel**

`applications/redis-operator/overlays/sentry/redis-sentinel.yaml`:
```yaml
apiVersion: redis.redis.opstreelabs.in/v1beta2
kind: RedisSentinel
metadata:
  name: sentry-redis-sentinel
  namespace: sentry-redis
spec:
  clusterSize: 3
  podSecurityContext:
    runAsUser: 1000
    fsGroup: 1000
  redisSentinelConfig:
    redisReplicationName: sentry-redis
    masterGroupName: "mymaster"
    redisPort: "6379"
    quorum: "2"
    parallelSyncs: "1"
    failoverTimeout: "180000"
    downAfterMilliseconds: "30000"
  kubernetesConfig:
    image: quay.io/opstree/redis-sentinel:v7.4.7
    imagePullPolicy: IfNotPresent
    redisSecret:
      name: sentry-redis-secrets
      key: password
  redisExporter:
    enabled: true
    image: quay.io/opstree/redis-exporter:v1.44.0
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchExpressions:
                - key: app
                  operator: In
                  values:
                    - sentry-redis-sentinel
            topologyKey: kubernetes.io/hostname
```

- [ ] **Step 5: Kustomization**

`applications/redis-operator/overlays/sentry/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - external-secrets.yaml
  - redis-replication.yaml
  - redis-sentinel.yaml
```

- [ ] **Step 6: Validate**

```bash
kustomize build applications/redis-operator/overlays/sentry | kubectl apply --dry-run=client -f -
```

Expected: 4 resources rendered without errors.

### Task 1.6: Create the ArgoCD `Application` for `cnpg-sentry`

**Files:**
- Create: `argocd/applications/use1/cnpg-sentry.yaml`

- [ ] **Step 1: Write the Application**

`argocd/applications/use1/cnpg-sentry.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cnpg-sentry
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/cnpg-sentry/overlays/use1/
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: sentry
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
      - ServerSideApply=true
```

### Task 1.7: Create the ArgoCD `Application` for `redis-sentry`

**Files:**
- Create: `argocd/applications/use1/redis-sentry.yaml`

- [ ] **Step 1: Write the Application**

`argocd/applications/use1/redis-sentry.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: redis-sentry
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/redis-operator/overlays/sentry
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: sentry-redis
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
```

### Task 1.8: Commit Phase 1, push, and sync

- [ ] **Step 1: Stage and commit**

```bash
git add applications/cnpg-sentry/ \
        applications/redis-operator/overlays/sentry/ \
        argocd/applications/use1/cnpg-sentry.yaml \
        argocd/applications/use1/redis-sentry.yaml
git status
git commit -m "feat: add cnpg-sentry CNPG Cluster and sentry-redis (Phase 1, sentry rollout)"
git push -u origin feature/sentry-self-hosted
```

- [ ] **Step 2: Open a PR and merge to main (or stay on the branch if you'd rather deploy from feature branch — set targetRevision: feature/sentry-self-hosted on both Applications during the rollout, then flip back to main at the end)**

Recommended: open PR, get it green, squash-merge. Sentry Applications track `main`.

- [ ] **Step 3: Wait for ArgoCD to pick up the new Applications**

```bash
kubectl -n argocd get app cnpg-sentry redis-sentry -w
```

Expected within 3 min: both apps move to `Synced` + `Healthy`. If still `Unknown` after 3 min, manually trigger:
```bash
argocd app sync cnpg-sentry --grpc-web
argocd app sync redis-sentry --grpc-web
```

### Task 1.9: Verify Phase 1

- [ ] **Step 1: CNPG cluster healthy**

```bash
kubectl get cluster -n sentry sentry-db
kubectl get pod -n sentry -l cnpg.io/cluster=sentry-db
```

Expected:
- `sentry-db` STATUS = `Cluster in healthy state`, READY = `1`
- One pod `sentry-db-1` Ready 1/1

- [ ] **Step 2: Database is initialized**

```bash
kubectl exec -n sentry sentry-db-1 -c postgres -- psql -U postgres -c "\l"
```

Expected: list of databases includes `sentry`.

- [ ] **Step 3: App-user secret was generated**

```bash
kubectl get secret -n sentry sentry-db-app sentry-db-superuser
kubectl get secret -n sentry sentry-db-app -o jsonpath='{.data.username}' | base64 -d; echo
```

Expected: both secrets exist; username decodes to `sentry`.

- [ ] **Step 4: Backup ExternalSecret materialized**

```bash
kubectl get secret -n sentry cnpg-sentry-backup -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d; echo
```

Expected: prints `cnpg-sentry-backup` (the username), proving Vault → ExternalSecret reconciled.

- [ ] **Step 5: Backup ran**

```bash
kubectl get backup -n sentry
# Also confirm WAL files appear in offsite:
mc ls offsite/cnpg-sentry-use1/ | head
```

Expected: at least one basebackup exists or is in progress; WAL files appear within ~15 min of cluster creation.

- [ ] **Step 6: Redis replication + sentinel healthy**

```bash
kubectl get redisreplication,redissentinel -n sentry-redis
kubectl get pod -n sentry-redis
```

Expected:
- `RedisReplication/sentry-redis` and `RedisSentinel/sentry-redis-sentinel` both with `Ready: 3/3`
- 6 pods running (3 replication + 3 sentinel)

- [ ] **Step 7: Sentinel returns a primary**

```bash
kubectl run -n sentry-redis redis-debug --rm -it --image=quay.io/opstree/redis:v7.4.7 --restart=Never -- \
  redis-cli -h sentry-redis-sentinel.sentry-redis.svc.cluster.local -p 26379 \
  SENTINEL get-master-addr-by-name mymaster
```

Expected: two-line response with the primary pod IP and port `6379`.

---

## Phase 2: Sentry core (errors only)

Deploy the Helm chart with most feature flags off. Verify a single smoke event lands.

### Task 2.1: Create `applications/sentry/base/`

**Files:**
- Create: `applications/sentry/base/namespace.yaml`
- Create: `applications/sentry/base/values.yaml`
- Create: `applications/sentry/base/kustomization.yaml`

- [ ] **Step 1: Namespace**

`applications/sentry/base/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: sentry
```

- [ ] **Step 2: Base values (chart-wide defaults — almost everything is in the overlay)**

`applications/sentry/base/values.yaml`:
```yaml
# Chart-wide defaults for the Sentry self-hosted Helm chart.
# Environment-specific overrides live in overlays/<env>/values.yaml.

# We never want the chart-managed ingress — we own IngressRoutes ourselves.
ingress:
  enabled: false

# We never want chart-bundled Postgres or Redis — we use CNPG and redis-operator.
postgresql:
  enabled: false
redis:
  enabled: false

# Chart-bundled dependencies stay on:
kafka:
  enabled: true
zookeeper:
  enabled: true
clickhouse:
  enabled: true
memcached:
  enabled: true

# Chart-bundled rabbitmq / nginx are not used (we route to relay/web directly).
rabbitmq:
  enabled: false
nginx:
  enabled: false

# Disable demo data
demoMode:
  enabled: false
```

- [ ] **Step 3: Base kustomization with Helm chart reference**

`applications/sentry/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: sentry
resources:
  - namespace.yaml
helmCharts:
  - name: sentry
    version: "26.0.0"   # bump to current stable; see Pre-flight § Helm chart version
    repo: https://sentry-kubernetes.github.io/charts
    releaseName: sentry
    valuesFile: values.yaml
    namespace: sentry
```

- [ ] **Step 4: Validate the chart actually renders**

```bash
kustomize build --enable-helm applications/sentry/base | head -40
kustomize build --enable-helm applications/sentry/base | wc -l
```

Expected: many hundreds of lines (the chart renders ~30+ resources). If chart version `26.0.0` doesn't exist, the build will fail with `chart "sentry" version "26.0.0" not found`; bump to a real version.

### Task 2.2: Create `applications/sentry/overlays/use1/` ExternalSecrets

**Files:**
- Create: `applications/sentry/overlays/use1/external-secret-web.yaml`
- Create: `applications/sentry/overlays/use1/external-secret-saml.yaml`
- Create: `applications/sentry/overlays/use1/external-secret-filestore.yaml`
- Create: `applications/sentry/overlays/use1/external-secret-smtp.yaml`
- Create: `applications/sentry/overlays/use1/external-secret-clickhouse.yaml`
- Create: `applications/sentry/overlays/use1/external-secret-redis.yaml`

- [ ] **Step 1: Web (SECRET_KEY + bootstrap admin)**

`applications/sentry/overlays/use1/external-secret-web.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: sentry-web
  namespace: sentry
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: sentry-web
    creationPolicy: Owner
  data:
    - secretKey: SENTRY_SECRET_KEY
      remoteRef: { key: sentry/web, property: SECRET_KEY }
    - secretKey: SENTRY_OPTIONS_SYSTEM_ADMIN_EMAIL
      remoteRef: { key: sentry/web, property: SENTRY_OPTIONS_SYSTEM_ADMIN_EMAIL }
    - secretKey: SENTRY_OPTIONS_SYSTEM_ADMIN_PASSWORD
      remoteRef: { key: sentry/web, property: SENTRY_OPTIONS_SYSTEM_ADMIN_PASSWORD }
```

- [ ] **Step 2: SAML (placeholders until Phase 3)**

`applications/sentry/overlays/use1/external-secret-saml.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: sentry-saml
  namespace: sentry
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: sentry-saml
    creationPolicy: Owner
  data:
    - secretKey: IDP_SSO_URL
      remoteRef: { key: sentry/saml, property: IDP_SSO_URL }
    - secretKey: IDP_ENTITY_ID
      remoteRef: { key: sentry/saml, property: IDP_ENTITY_ID }
    - secretKey: IDP_X509_CERT
      remoteRef: { key: sentry/saml, property: IDP_X509_CERT }
```

- [ ] **Step 3: Filestore (S3 creds for blob storage)**

`applications/sentry/overlays/use1/external-secret-filestore.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: sentry-filestore
  namespace: sentry
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: sentry-filestore
    creationPolicy: Owner
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef: { key: sentry/filestore, property: AWS_ACCESS_KEY_ID }
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef: { key: sentry/filestore, property: AWS_SECRET_ACCESS_KEY }
    - secretKey: AWS_ENDPOINT_URL
      remoteRef: { key: sentry/filestore, property: AWS_ENDPOINT_URL }
    - secretKey: BUCKET_NAME
      remoteRef: { key: sentry/filestore, property: BUCKET_NAME }
```

- [ ] **Step 4: SMTP**

`applications/sentry/overlays/use1/external-secret-smtp.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: sentry-smtp
  namespace: sentry
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: sentry-smtp
    creationPolicy: Owner
  data:
    - secretKey: SENTRY_SMTP_HOST
      remoteRef: { key: sentry/smtp, property: HOST }
    - secretKey: SENTRY_SMTP_PORT
      remoteRef: { key: sentry/smtp, property: PORT }
    - secretKey: SENTRY_SMTP_USER
      remoteRef: { key: sentry/smtp, property: USER }
    - secretKey: SENTRY_SMTP_PASSWORD
      remoteRef: { key: sentry/smtp, property: PASSWORD }
    - secretKey: SENTRY_SMTP_FROM
      remoteRef: { key: sentry/smtp, property: FROM_EMAIL }
```

- [ ] **Step 5: ClickHouse**

`applications/sentry/overlays/use1/external-secret-clickhouse.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: sentry-clickhouse-secret
  namespace: sentry
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: sentry-clickhouse-secret
    creationPolicy: Owner
  data:
    - secretKey: default-password
      remoteRef: { key: sentry/clickhouse, property: DEFAULT_PASSWORD }
    - secretKey: sentry-password
      remoteRef: { key: sentry/clickhouse, property: SENTRY_PASSWORD }
```

- [ ] **Step 6: Redis (chart reads this Secret to connect to redis-operator-managed Redis)**

`applications/sentry/overlays/use1/external-secret-redis.yaml`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: sentry-redis-secret
  namespace: sentry
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: sentry-redis-secret
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef: { key: redis/sentry, property: password }
```

### Task 2.3: Create `applications/sentry/overlays/use1/values.yaml`

**Files:**
- Create: `applications/sentry/overlays/use1/values.yaml`

- [ ] **Step 1: Overlay values — Phase 2 baseline (most features off)**

`applications/sentry/overlays/use1/values.yaml`:
```yaml
# Sentry self-hosted overlay for the use1 cluster, Phase 2 baseline.
# Subsequent phases (3-6) flip feature flags in-place.

# === System URLs ===
system:
  url: "https://sentry.vngenterprise.com"
  adminEmail: "frank@dobrovolny.dev"

# === External Postgres (CNPG sentry-db, same namespace) ===
postgresql:
  enabled: false
externalPostgresql:
  host: sentry-db-rw.sentry.svc.cluster.local
  port: 5432
  database: sentry
  username: sentry
  existingSecret: sentry-db-app
  existingSecretKey: password

# === External Redis (sentry-redis namespace, sentinel-fronted) ===
redis:
  enabled: false
externalRedis:
  host: sentry-redis-sentinel.sentry-redis.svc.cluster.local
  port: 26379
  useSentinel: true
  sentinelMasterName: mymaster
  existingSecret: sentry-redis-secret
  existingSecretKey: password

# === Chart-bundled deps ===
kafka:
  enabled: true
  replicaCount: 1
  persistence:
    enabled: true
    size: 20Gi
    storageClass: longhorn-single
  resources:
    requests: { cpu: 300m, memory: 1Gi }
    limits:   { cpu: 1,    memory: 4Gi }

zookeeper:
  enabled: true
  replicaCount: 1
  persistence:
    enabled: true
    size: 5Gi
    storageClass: longhorn-single

clickhouse:
  enabled: true
  replicas: 1
  clickhouse:
    persistentVolumeClaim:
      enabled: true
      dataPersistentVolume:
        enabled: true
        storageClassName: longhorn-single
        accessModes: [ReadWriteOnce]
        storage: 50Gi
  existingSecret: sentry-clickhouse-secret
  existingSecretKey: default-password

memcached:
  enabled: true
  replicaCount: 1

# === Sentry web ===
sentry:
  web:
    replicas: 2
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { cpu: 1,    memory: 2Gi }
    env:
      - name: SENTRY_SECRET_KEY
        valueFrom: { secretKeyRef: { name: sentry-web, key: SENTRY_SECRET_KEY } }
    envFromSecrets:
      - sentry-smtp

  # === Sentry worker (celery) ===
  worker:
    replicas: 2
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { cpu: 1,    memory: 2Gi }

  # === Cron beat ===
  cron:
    enabled: true
    resources:
      requests: { cpu: 50m, memory: 128Mi }
      limits:   { cpu: 200m, memory: 512Mi }

  # === Relay (ingest) ===
  relay:
    enabled: true
    replicas: 2
    persistence:
      enabled: true
      size: 2Gi
      storageClass: longhorn-single
    resources:
      requests: { cpu: 200m, memory: 256Mi }
      limits:   { cpu: 1,    memory: 1Gi }

  # === Snuba (query layer) ===
  snuba:
    api:
      replicas: 1
    consumer:
      # one consumer per dataset; chart enables errors/transactions by default
      replicas: 1

  # === Ingest consumers (split per topic) ===
  ingestConsumerEvents:
    replicas: 1
  ingestConsumerTransactions:
    replicas: 1
  ingestConsumerAttachments:
    replicas: 1
  ingestReplayRecordings:
    replicas: 1
  ingestProfiles:
    replicas: 1

  postProcessForwarder:
    replicas: 1

  # === Symbolicator (native crashes) — OFF for Phase 2 ===
  symbolicator:
    enabled: false

  # === Vroom (profiling backend) — OFF for Phase 2 ===
  vroom:
    enabled: false

  # === Feature flags ===
  features:
    enableProfiling: false
    enableSessionReplay: false
    enableFeedback: false
    orgSubdomains: false

# === Filestore ===
filestore:
  backend: s3
  s3:
    bucketName: sentry-filestore-use1
    endpointUrl: https://backup-storage.vngenterprise.com
    accessKey: ""                     # populated via env (see below)
    secretKey: ""
    signatureVersion: s3v4
    addressingStyle: path
    region: us-east-1

# === Auth: allow local registration ONLY during Phase 2 bootstrap ===
auth:
  register: true

# === Ingress: we own IngressRoutes ourselves ===
ingress:
  enabled: false

# === Config ===
config:
  configYml: |
    system.url-prefix: 'https://sentry.vngenterprise.com'
    system.internal-url-prefix: 'http://sentry-web.sentry.svc.cluster.local:9000'
    mail.host: '${SENTRY_SMTP_HOST}'
    mail.port: '${SENTRY_SMTP_PORT}'
    mail.username: '${SENTRY_SMTP_USER}'
    mail.password: '${SENTRY_SMTP_PASSWORD}'
    mail.from: '${SENTRY_SMTP_FROM}'
    mail.use-tls: true
    auth.allow-registration: true
    filestore.backend: 's3'
    filestore.options:
      bucket_name: 'sentry-filestore-use1'
      endpoint_url: 'https://backup-storage.vngenterprise.com'
      access_key: '${SENTRY_FILESTORE_ACCESS_KEY}'
      secret_key: '${SENTRY_FILESTORE_SECRET_KEY}'
      signature_version: 's3v4'
      addressing_style: 'path'
      region_name: 'us-east-1'
  sentryConfPy: |
    SENTRY_OPTIONS['system.event-retention-days'] = 30

# === Extra env (filestore creds + relay/admin password injection) ===
extraEnv:
  - name: SENTRY_FILESTORE_ACCESS_KEY
    valueFrom: { secretKeyRef: { name: sentry-filestore, key: AWS_ACCESS_KEY_ID } }
  - name: SENTRY_FILESTORE_SECRET_KEY
    valueFrom: { secretKeyRef: { name: sentry-filestore, key: AWS_SECRET_ACCESS_KEY } }
```

> **Heads-up:** the exact key names (`externalPostgresql.useSentinel`, `clickhouse.clickhouse.persistentVolumeClaim.*`, `filestore.s3.*`, `sentry.features.*`) depend on the chart's values.yaml schema and may have changed between chart versions. After the build error in step 4 of Task 2.1 surfaces the right shape, cross-check this file against `helm show values sentry/sentry --version <pinned>` and rename any keys that the chart's schema rejects. The structure above matches chart `26.x`.

### Task 2.4: Create the two Sentry IngressRoutes

**Files:**
- Create: `applications/sentry/overlays/use1/sentry.vngenterprise.com.yaml`
- Create: `applications/sentry/overlays/use1/s-metrics.vngenterprise.com.yaml`

- [ ] **Step 1: Internal UI IngressRoute**

`applications/sentry/overlays/use1/sentry.vngenterprise.com.yaml`:
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: sentry-web
  namespace: sentry
  annotations:
    kubernetes.io/ingress.class: traefik-internal
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`sentry.vngenterprise.com`)
      kind: Rule
      services:
        - name: sentry-web
          port: 9000
  tls:
    store:
      name: default
      namespace: traefik
```

- [ ] **Step 2: Public Relay ingest IngressRoute (paths restricted)**

`applications/sentry/overlays/use1/s-metrics.vngenterprise.com.yaml`:
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: sentry-relay-public
  namespace: sentry
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  entryPoints:
    - websecure
  routes:
    - match: |
        Host(`s-metrics.vngenterprise.com`) && (
          PathPrefix(`/api/`) &&
          PathRegexp(`^/api/[0-9]+/(envelope|store|security|minidump|attachment|unreal)/?.*`)
        )
      kind: Rule
      services:
        - name: sentry-relay
          port: 3000
  tls:
    store:
      name: default
      namespace: traefik
```

- [ ] **Step 3: Verify Traefik accepts both manifests**

```bash
kubectl apply --dry-run=client -f applications/sentry/overlays/use1/sentry.vngenterprise.com.yaml
kubectl apply --dry-run=client -f applications/sentry/overlays/use1/s-metrics.vngenterprise.com.yaml
```

Expected: no errors. If `PathRegexp` returns a Traefik CRD validation error, check your Traefik version (this matcher was added in Traefik 3.0); fall back to a series of `PathPrefix` rules if needed:
```yaml
- match: |
    Host(`s-metrics.vngenterprise.com`) && (
      PathPrefix(`/api/`)
    )
```
…and rely on Sentry's Relay to 404 non-ingest paths.

### Task 2.5: Create PodMonitors (skeleton; filled in Phase 6)

**Files:**
- Create: `applications/sentry/overlays/use1/podmonitors.yaml`

- [ ] **Step 1: Create the file with just the web PodMonitor for now**

`applications/sentry/overlays/use1/podmonitors.yaml`:
```yaml
# All PodMonitors live in this file. Added incrementally per phase.
# Phase 2: sentry-web only. Phase 6 expands to relay, worker, snuba, kafka, clickhouse.
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: sentry-web
  namespace: sentry
  labels:
    instance: primary
spec:
  selector:
    matchLabels:
      app: sentry
      role: web
  podMetricsEndpoints:
    - port: http
      path: /_metrics
      interval: 60s
```

> Cross-check the exact `selector.matchLabels` keys by running `kubectl get pod -n sentry -l role=web --show-labels` after Sentry comes up. If labels differ (e.g., `app.kubernetes.io/name=sentry`, `app.kubernetes.io/component=web`), edit this file and resync.

### Task 2.6: Create the overlay kustomization

**Files:**
- Create: `applications/sentry/overlays/use1/kustomization.yaml`

- [ ] **Step 1: Reference base + all overlay resources + chart value override**

`applications/sentry/overlays/use1/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: sentry
resources:
  - ../../base
  - external-secret-web.yaml
  - external-secret-saml.yaml
  - external-secret-filestore.yaml
  - external-secret-smtp.yaml
  - external-secret-clickhouse.yaml
  - external-secret-redis.yaml
  - podmonitors.yaml
  - sentry.vngenterprise.com.yaml
  - s-metrics.vngenterprise.com.yaml
helmCharts:
  - name: sentry
    version: "26.0.0"        # keep in sync with base/kustomization.yaml
    repo: https://sentry-kubernetes.github.io/charts
    releaseName: sentry
    valuesFile: values.yaml
    namespace: sentry
```

> **Why re-declare `helmCharts` in the overlay:** kustomize's `helmCharts` directive doesn't currently let an overlay *extend* a base's `valuesFile`; it has to redeclare the chart with the overlay's `valuesFile`. The base's chart entry is effectively a placeholder for dry rendering during development. This is the same workaround `applications/zitadel/` and `applications/alloy-metrics/` use.

- [ ] **Step 2: Validate the chart renders with overlay values**

```bash
kustomize build --enable-helm applications/sentry/overlays/use1 > /tmp/sentry-rendered.yaml
wc -l /tmp/sentry-rendered.yaml
grep -E '^kind:' /tmp/sentry-rendered.yaml | sort | uniq -c
```

Expected: thousands of lines; counts include Deployment, StatefulSet, Service, ConfigMap, Secret, Job, IngressRoute, PodMonitor, ExternalSecret, Namespace, CronJob.

- [ ] **Step 3: Dry-run apply**

```bash
kustomize build --enable-helm applications/sentry/overlays/use1 | kubectl apply --dry-run=client -f -
```

Expected: every resource shows "created (dry run)". Any error here means a schema mismatch — fix before committing.

### Task 2.7: Create the ArgoCD `Application` for `sentry`

**Files:**
- Create: `argocd/applications/use1/sentry.yaml`

- [ ] **Step 1: Write the Application**

`argocd/applications/use1/sentry.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sentry
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/sentry/overlays/use1
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: sentry
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
      - CreateNamespace=true
      - ServerSideApply=true
```

### Task 2.8: Commit Phase 2, push, sync

- [ ] **Step 1: Stage and commit**

```bash
git add applications/sentry/ argocd/applications/use1/sentry.yaml
git status
git commit -m "feat: deploy sentry self-hosted (Phase 2: errors-only baseline)"
git push
```

- [ ] **Step 2: Merge to main (or update Application targetRevision if running off-branch)**

Same approach as Task 1.8.

- [ ] **Step 3: Watch the sync**

```bash
kubectl -n argocd get app sentry -w
```

Expected within 15-20 min (chart pulls many images): Synced + Healthy. First sync of a Sentry chart is slow because of:
- DB migrations Job (`sentry-db-init`) takes 5-10 min
- ClickHouse schema bootstrap takes 2-3 min
- Kafka topic creation: 1-2 min

If it gets stuck on `Progressing`, look at:
```bash
kubectl get pod -n sentry --sort-by=.metadata.creationTimestamp
kubectl logs -n sentry job/sentry-db-init
```

### Task 2.9: Verify Phase 2 — pods + smoke event

- [ ] **Step 1: All pods Ready**

```bash
kubectl get pod -n sentry
```

Expected: ~25-30 pods, all Ready. Common patterns:
- `sentry-web-*` ×2
- `sentry-worker-*` ×2
- `sentry-cron-*` ×1
- `sentry-relay-*` ×2
- `sentry-snuba-api-*` ×1
- `sentry-snuba-consumer-events-*`, `-transactions-*`, `-replays-*`, `-profiles-*` (1 each)
- `sentry-ingest-consumer-events-*`, `-transactions-*`, `-attachments-*` etc. (1 each)
- `sentry-post-process-forwarder-*` ×1
- `sentry-kafka-0`, `sentry-zookeeper-0`, `sentry-clickhouse-0`, `sentry-memcached-*`

- [ ] **Step 2: No CrashLoopBackOff**

```bash
kubectl get pod -n sentry --field-selector=status.phase!=Running 2>&1 | grep -v "No resources"
```

Expected: empty (everything Running).

- [ ] **Step 3: Web is reachable from inside the cluster**

```bash
kubectl run -n sentry curl-debug --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sI http://sentry-web.sentry.svc.cluster.local:9000/_health/
```

Expected: `HTTP/1.1 200 OK`.

- [ ] **Step 4: Configure cloudflare-ddns / DNS for sentry.vngenterprise.com**

Confirm:
```bash
dig sentry.vngenterprise.com +short
```

Expected: resolves to the internal Traefik LB IP. If not, add the record to the `cloudflare-ddns` config (this repo's `applications/cloudflare-ddns/`).

- [ ] **Step 5: Visit https://sentry.vngenterprise.com over netbird**

In a browser on netbird: open `https://sentry.vngenterprise.com`. Expected: Sentry login page renders (no SAML yet — local password form visible).

- [ ] **Step 6: Log in as bootstrap admin**

Email from Vault `secret/sentry/web/SENTRY_OPTIONS_SYSTEM_ADMIN_EMAIL`; password from `SENTRY_OPTIONS_SYSTEM_ADMIN_PASSWORD`. If the chart's `sentry-db-init` Job didn't auto-create the user, run:

```bash
kubectl exec -n sentry deploy/sentry-web -- \
  sentry createuser --email frank@dobrovolny.dev --password '<ADMIN_PW>' --superuser --no-input
```

- [ ] **Step 7: Create a smoke-test project**

In the UI: Settings → Projects → Create Project → "Internal" → Platform "Other (HTTP)". Name it `smoke-test`. Copy the DSN.

- [ ] **Step 8: Submit a synthetic event from a debug pod**

```bash
DSN_PUBLIC_KEY="<from project settings>"
PROJECT_ID="<from project settings>"

kubectl run -n sentry curl-event --rm -it --image=curlimages/curl --restart=Never -- \
  curl -X POST "http://sentry-relay.sentry.svc.cluster.local:3000/api/${PROJECT_ID}/store/" \
    -H "Content-Type: application/json" \
    -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_client=manual/1.0, sentry_timestamp=$(date +%s), sentry_key=${DSN_PUBLIC_KEY}" \
    -d '{"message":"hello from phase 2 smoke test","level":"info","platform":"other"}'
```

Expected: HTTP 200 with `{"id":"..."}` response.

- [ ] **Step 9: Confirm the event appears in the UI**

Within 30 seconds, the `smoke-test` project's Issues tab shows "hello from phase 2 smoke test". If not, check `kubectl logs -n sentry deploy/sentry-relay` and `kubectl logs -n sentry deploy/sentry-ingest-consumer-events`.

- [ ] **Step 10: Confirm filestore S3 connectivity**

Upload a tiny attachment via the UI (Issue → Attach file) or push an attachment via the SDK. Then:
```bash
mc ls offsite/sentry-filestore-use1/ | head -5
```
Expected: at least one object exists.

---

## Phase 3: Zitadel SAML2 SSO

### Task 3.1: Create the SAML application in Zitadel

**Files:** none (Zitadel console operation)

- [ ] **Step 1: Log into Zitadel**

Open `https://accounts.vngenterprise.com` and log in with an admin account.

- [ ] **Step 2: Navigate to your Vanguard project**

The same project that holds the Grafana OIDC app (client_id `356670791548470770` per the grafana overlay).

- [ ] **Step 3: Create a new SAML application**

- Click "+ New" → "SAML"
- Name: `sentry-vng`
- Choose "Configuration with metadata URL or upload" if you have a metadata file; otherwise "Configuration with manual data input" and supply:
  - ACS URL: `https://sentry.vngenterprise.com/saml/acs/`
  - Entity ID: `https://sentry.vngenterprise.com/saml/metadata/`
  - NameID format: `email`
- Save.

- [ ] **Step 4: Set attribute mapping**

In the new app's "Token settings" / "Attribute mapping":
- `Email` → user email primary
- `FirstName` → user given name
- `LastName` → user family name
- `Groups` → groups (multi-value, all of user's group memberships)

- [ ] **Step 5: Create two Zitadel groups (if they don't exist)**

In the project's "Roles" or "Groups" section:
- `sentry_admin`
- `sentry_user`

Grant the Vanguard org's existing user pool access to one of these (e.g., add yourself to `sentry_admin`).

- [ ] **Step 6: Export the SAML metadata bits**

From the app's "URLs" / "Identity Provider" tab, copy three values:
- SSO endpoint URL → save as `IDP_SSO_URL`
- IdP Entity ID → save as `IDP_ENTITY_ID`
- X.509 Signing Certificate (paste the `-----BEGIN CERTIFICATE----- … -----END CERTIFICATE-----` block) → save as `IDP_X509_CERT`

### Task 3.2: Populate Vault with the real SAML values

- [ ] **Step 1: Update `secret/sentry/saml`**

```bash
vault kv put secret/sentry/saml \
  IDP_SSO_URL="https://accounts.vngenterprise.com/saml/v2/SSO" \
  IDP_ENTITY_ID="https://accounts.vngenterprise.com/saml/v2/metadata" \
  IDP_X509_CERT="$(cat /tmp/zitadel-saml.crt)"
```

(Exact URL formats depend on Zitadel's tenant settings — use what you copied in Task 3.1, Step 6.)

- [ ] **Step 2: Force the ExternalSecret to re-sync**

```bash
kubectl -n sentry annotate externalsecret sentry-saml \
  force-sync=$(date +%s) --overwrite
```

Then verify the underlying Secret updated:
```bash
kubectl -n sentry get secret sentry-saml -o jsonpath='{.data.IDP_SSO_URL}' | base64 -d; echo
```

Expected: prints the Zitadel SSO URL (no longer `PENDING`).

### Task 3.3: Configure SAML in the Sentry UI

**Files:** none (UI operation)

- [ ] **Step 1: Log into Sentry as the bootstrap admin**

- [ ] **Step 2: Settings → Auth → SAML2 → Configure SAML2**

Paste:
- Identity Provider Issuer URL → value of `IDP_SSO_URL`
- Identity Provider SSO URL → same
- Identity Provider X509 Certificate → value of `IDP_X509_CERT`

- [ ] **Step 3: Attribute mappings**

- User identifier attribute: `Email`
- User email attribute: `Email`
- First name attribute: `FirstName`
- Last name attribute: `LastName`

- [ ] **Step 4: Enable SSO**

Toggle "Require SSO for everyone in this organization" to ON (will require re-login).

- [ ] **Step 5: Save**

### Task 3.4: Verify SAML round-trip

- [ ] **Step 1: Open an incognito browser**

Visit `https://sentry.vngenterprise.com` (over netbird).

- [ ] **Step 2: Expect redirect to Zitadel**

Should bounce to `accounts.vngenterprise.com/login`.

- [ ] **Step 3: Log in as a Zitadel user in the `sentry_admin` group**

Use a real Zitadel account (NOT the bootstrap admin — that's a local Sentry account, not a Zitadel user).

- [ ] **Step 4: Expect landing on the Sentry dashboard**

Browser ends up on `https://sentry.vngenterprise.com/organizations/<your-org>/` logged in as the Zitadel user.

- [ ] **Step 5: Verify the user was provisioned with the right role**

Settings → Members → find the user → role should be inferable from the `sentry_admin` group attribute. (If Sentry didn't auto-set role, change it manually.)

### Task 3.5: Lock down local auth

**Files:**
- Modify: `applications/sentry/overlays/use1/values.yaml`

- [ ] **Step 1: Edit `values.yaml` — disable local registration**

Change:
```yaml
auth:
  register: true
```
to:
```yaml
auth:
  register: false
```

And in the `config.configYml` block, change `auth.allow-registration: true` to `auth.allow-registration: false`.

Append to `config.sentryConfPy`:
```python
SENTRY_FEATURES['organizations:sso-saml2'] = True
SENTRY_FEATURES['auth:register'] = False
```

- [ ] **Step 2: Validate**

```bash
kustomize build --enable-helm applications/sentry/overlays/use1 | grep -A 2 "allow-registration"
```

Expected: shows `auth.allow-registration: false`.

- [ ] **Step 3: Commit + push + sync**

```bash
git add applications/sentry/overlays/use1/values.yaml
git commit -m "feat(sentry): enforce SAML SSO, disable local registration (Phase 3)"
git push
argocd app sync sentry --grpc-web
```

- [ ] **Step 4: Verify the login page no longer shows the local password form**

In incognito: `https://sentry.vngenterprise.com` — expect immediate redirect to Zitadel; no email/password form visible.

### Task 3.6: Rotate the bootstrap admin password

**Files:** none (Vault + Sentry CLI op)

- [ ] **Step 1: Generate a new password**

```bash
NEW_ADMIN_PW=$(openssl rand -base64 48 | tr -d '\n')
echo "$NEW_ADMIN_PW"
```

- [ ] **Step 2: Set it on the Sentry account**

```bash
kubectl exec -n sentry deploy/sentry-web -- \
  sentry changepassword --password "$NEW_ADMIN_PW" frank@dobrovolny.dev
```

- [ ] **Step 3: Store the new password in Vault under a separate "recovery" key**

```bash
vault kv put secret/sentry/web/admin-recovery \
  EMAIL="frank@dobrovolny.dev" \
  PASSWORD="$NEW_ADMIN_PW"
```

- [ ] **Step 4: Verify the bootstrap admin still works as a break-glass**

In incognito: visit `https://sentry.vngenterprise.com/auth/login/sentry/` (the local-login bypass path). Log in with new password. Confirm access. Log out.

(If SAML breaks, you'll need this path to get back in.)

---

## Phase 4: Enable the remaining features

One feature at a time. Wait 24h between sub-phases to keep blame easy if ingest breaks.

### Task 4.1 (sub-phase 4a): Enable Performance / transactions

**Files:**
- Modify: `applications/sentry/overlays/use1/values.yaml`

- [ ] **Step 1: Flip the feature flag**

In `values.yaml`, append to `config.sentryConfPy`:
```python
SENTRY_FEATURES['organizations:performance-view'] = True
SENTRY_FEATURES['organizations:transaction-metrics-extraction'] = True
```

The chart's `ingest-consumer-transactions` consumer is already enabled in Phase 2 — the flag just exposes the UI.

- [ ] **Step 2: Commit + push + sync**

```bash
git add applications/sentry/overlays/use1/values.yaml
git commit -m "feat(sentry): enable performance/transactions (Phase 4a)"
git push
argocd app sync sentry --grpc-web
```

- [ ] **Step 3: Verify**

- In UI: "Performance" tab appears in left nav.
- Send a synthetic transaction from a debug pod:

```bash
PROJECT_ID="<smoke-test project id>"
DSN_PUBLIC_KEY="<smoke-test public key>"
TS=$(date +%s)
kubectl run -n sentry curl-txn --rm -it --image=curlimages/curl --restart=Never -- sh -c "
  curl -X POST 'http://sentry-relay.sentry.svc.cluster.local:3000/api/${PROJECT_ID}/envelope/' \
    -H 'Content-Type: application/x-sentry-envelope' \
    -H 'X-Sentry-Auth: Sentry sentry_version=7, sentry_client=manual/1.0, sentry_timestamp=${TS}, sentry_key=${DSN_PUBLIC_KEY}' \
    --data-binary @- <<'EOF'
{\"event_id\":\"$(uuidgen | tr -d -)\",\"sent_at\":\"$(date -u +%FT%TZ)\"}
{\"type\":\"transaction\"}
{\"type\":\"transaction\",\"transaction\":\"smoke-test-tx\",\"start_timestamp\":${TS}.0,\"timestamp\":$((TS+1)).0,\"contexts\":{\"trace\":{\"trace_id\":\"$(uuidgen | tr -d -)\",\"span_id\":\"$(openssl rand -hex 8)\",\"op\":\"smoke\"}}}
EOF
"
```

- Performance tab shows `smoke-test-tx` with ~1s duration within 60s.

- [ ] **Step 4: 24h soak**

Monitor `{namespace="sentry"} |~ "(?i)error"` in Loki and Kafka consumer lag (Sentry's own `sentry_events_in_flight_total` metric, or via `kafka-consumer-groups.sh`).

### Task 4.2 (sub-phase 4b): Enable Profiling + Vroom

**Files:**
- Modify: `applications/sentry/overlays/use1/values.yaml`

- [ ] **Step 1: Enable Vroom and the feature flag**

In `values.yaml`:
```yaml
sentry:
  vroom:
    enabled: true
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 1Gi }
  features:
    enableProfiling: true
```

And append to `config.sentryConfPy`:
```python
SENTRY_FEATURES['organizations:profiling'] = True
SENTRY_FEATURES['organizations:profiling-ui'] = True
```

- [ ] **Step 2: Commit + push + sync**

```bash
git add applications/sentry/overlays/use1/values.yaml
git commit -m "feat(sentry): enable profiling + vroom (Phase 4b)"
git push
argocd app sync sentry --grpc-web
```

- [ ] **Step 3: Verify**

```bash
kubectl get pod -n sentry -l app=sentry-vroom
kubectl get pod -n sentry -l app=sentry-ingest-profiles
```

Expected: both pods Ready.

- [ ] **Step 4: Generate a sample profile**

From a debug pod with the Python SDK:
```bash
kubectl run -n sentry py-profile --rm -it --image=python:3.12-slim --restart=Never -- bash -c '
  pip install sentry-sdk[pure_eval] &&
  python - <<EOF
import sentry_sdk, time
sentry_sdk.init(
  dsn="http://${DSN_PUBLIC_KEY}@sentry-relay.sentry.svc.cluster.local:3000/${PROJECT_ID}",
  traces_sample_rate=1.0, profiles_sample_rate=1.0,
)
with sentry_sdk.start_transaction(op="task", name="profile-smoke"):
  time.sleep(0.5)
  sum(i*i for i in range(1_000_000))
sentry_sdk.flush()
EOF'
```

Expected: in UI → Profiling → see a flamegraph for `profile-smoke`.

- [ ] **Step 5: 24h soak**

### Task 4.3 (sub-phase 4c): Enable Session Replay

**Files:**
- Modify: `applications/sentry/overlays/use1/values.yaml`

- [ ] **Step 1: Flip the flag**

In `values.yaml`, append to `config.sentryConfPy`:
```python
SENTRY_FEATURES['organizations:session-replay'] = True
SENTRY_FEATURES['organizations:session-replay-ui'] = True
SENTRY_FEATURES['organizations:session-replay-recording-scrubbing'] = True
```

And in `sentry.features`:
```yaml
sentry:
  features:
    enableSessionReplay: true
```

- [ ] **Step 2: Commit + push + sync**

```bash
git add applications/sentry/overlays/use1/values.yaml
git commit -m "feat(sentry): enable session replay (Phase 4c)"
git push
argocd app sync sentry --grpc-web
```

- [ ] **Step 3: Generate a sample replay**

From a real browser app (e.g., open `https://rustlens.example/...` after instrumenting it; see Phase 5 Task 5.4 for SDK config), or from a one-off HTML file:
```html
<!DOCTYPE html><html><body><script src="https://browser.sentry-cdn.com/8.0.0/bundle.replay.min.js"></script><script>
  Sentry.init({
    dsn: "https://<key>@sentry.vngenterprise.com/<project>",   // internal DSN works for testing
    integrations: [Sentry.replayIntegration()],
    replaysSessionSampleRate: 1.0,
  });
  setTimeout(() => Sentry.captureException(new Error("replay smoke")), 2000);
</script></body></html>
```

Load it in a browser on netbird. Wait 1-2 min.

- [ ] **Step 4: Verify**

```bash
mc ls offsite/sentry-filestore-use1/ --recursive | grep replay | head -5
```

Expected: at least one `replays/...` object exists. In UI → Replays → see the recording.

- [ ] **Step 5: 24h soak**

### Task 4.4 (sub-phase 4d): Enable Symbolicator (native crash symbolication)

**Files:**
- Modify: `applications/sentry/overlays/use1/values.yaml`

> Only useful if you ship native (C/C++/Rust) binaries. Skip and revisit when first native crash appears if you don't.

- [ ] **Step 1: Enable Symbolicator**

In `values.yaml`:
```yaml
sentry:
  symbolicator:
    enabled: true
    replicas: 1
    persistence:
      enabled: true
      size: 5Gi
      storageClass: longhorn-single
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { cpu: 1,    memory: 2Gi }
```

- [ ] **Step 2: Commit + push + sync**

```bash
git add applications/sentry/overlays/use1/values.yaml
git commit -m "feat(sentry): enable symbolicator (Phase 4d)"
git push
argocd app sync sentry --grpc-web
```

- [ ] **Step 3: Verify pod Ready**

```bash
kubectl get pod -n sentry -l app=sentry-symbolicator
```

- [ ] **Step 4: Smoke (only if a native binary is available)**

Build a Rust binary with `RUSTFLAGS=-C debuginfo=2`, upload the symbol file via `sentry-cli upload-dif`, deliberately crash it, observe symbolicated frames in the UI. If you don't have a target, mark this sub-phase done and move on.

### Task 4.5 (sub-phase 4e): Enable Cron monitoring

**Files:**
- Modify: `applications/sentry/overlays/use1/values.yaml`

- [ ] **Step 1: Flip flag**

In `values.yaml`, append to `config.sentryConfPy`:
```python
SENTRY_FEATURES['organizations:crons'] = True
SENTRY_FEATURES['organizations:crons-issue-platform'] = True
```

- [ ] **Step 2: Commit + push + sync**

```bash
git add applications/sentry/overlays/use1/values.yaml
git commit -m "feat(sentry): enable cron monitoring (Phase 4e)"
git push
argocd app sync sentry --grpc-web
```

- [ ] **Step 3: Verify**

- UI → Crons → "Add monitor" works
- Create a monitor `daily-smoke` with schedule `0 9 * * *`
- Send a heartbeat:
```bash
MONITOR_SLUG="daily-smoke"
DSN_PUBLIC_KEY="<from smoke-test project>"
PROJECT_ID="<from smoke-test project>"
kubectl run -n sentry cron-smoke --rm -it --image=curlimages/curl --restart=Never -- \
  curl -X POST "http://sentry-relay.sentry.svc.cluster.local:3000/api/${PROJECT_ID}/cron/${MONITOR_SLUG}/${DSN_PUBLIC_KEY}/?status=ok"
```
- Monitor's last check-in updates within 60s.

---

## Phase 5: Public Relay ingest

### Task 5.1: DNS for s-metrics.vngenterprise.com

**Files:** depends on your DNS workflow.

- [ ] **Step 1: Confirm the record exists**

```bash
dig s-metrics.vngenterprise.com +short
```

Expected: resolves to the public Traefik LB IP. If not:
- If using `cloudflare-ddns`: add the record to `applications/cloudflare-ddns/...` and commit
- If managed elsewhere: add an A or CNAME pointing to your public Traefik LB

### Task 5.2: Cert-manager Certificate

**Files:**
- Possibly modify: existing certificate configuration (depends on whether the cluster auto-generates certs from IngressRoute TLS spec or uses explicit Certificate resources)

- [ ] **Step 1: Check current pattern**

```bash
kubectl get certificate -A | head
```

If certs are auto-managed by a Traefik tls store, no extra resource is needed (the IngressRoute we created in Phase 2 Task 2.4 references the `default` TLS store). If certs are explicit:

- [ ] **Step 2: Create a Certificate**

Add to `applications/sentry/overlays/use1/`:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: s-metrics-vngenterprise-com
  namespace: sentry
spec:
  secretName: s-metrics-vngenterprise-com-tls
  issuerRef:
    name: letsencrypt-cloudflare
    kind: ClusterIssuer
  dnsNames:
    - s-metrics.vngenterprise.com
```

Add this file to `kustomization.yaml` resources, commit, push, sync.

### Task 5.3: First service cutover — Rustlens backend

- [ ] **Step 1: Locate Rustlens backend's env config**

```bash
grep -rn "SENTRY_DSN\|sentry" applications/rustlens/ 2>/dev/null | head
```

- [ ] **Step 2: Create a Sentry project for Rustlens backend**

In UI: Projects → "Create Project" → Platform "Rust" (or whichever) → Name `rustlens-backend`. Copy the DSN — it'll be `https://<key>@sentry.vngenterprise.com/<project_id>`.

- [ ] **Step 3: Edit the DSN to use the public ingest host**

The DSN that goes in env vars must use `s-metrics.vngenterprise.com`, not `sentry.vngenterprise.com`:

```
https://<key>@s-metrics.vngenterprise.com/<project_id>
```

- [ ] **Step 4: Add the DSN to Rustlens via Vault + ExternalSecret**

Add `secret/rustlens/sentry` with `DSN=https://<key>@s-metrics.vngenterprise.com/<project_id>`. Create an ExternalSecret in the Rustlens overlay that exposes `SENTRY_DSN`. Wire into the Rustlens backend's env. Commit.

- [ ] **Step 5: Verify event lands**

After Rustlens backend rolls out and emits its first error (or you trigger one deliberately), check the UI's `rustlens-backend` project for the event.

### Task 5.4: Browser-app cutover

- [ ] **Step 1: Create a Sentry project for the browser app**

UI: "Create Project" → Platform "JavaScript" or framework variant. Note DSN; rewrite host to `s-metrics.vngenterprise.com`.

- [ ] **Step 2: Add SDK to the browser app**

```html
<script src="https://browser.sentry-cdn.com/8.x/bundle.tracing.replay.min.js"></script>
<script>
  Sentry.init({
    dsn: "https://<key>@s-metrics.vngenterprise.com/<project>",
    integrations: [Sentry.browserTracingIntegration(), Sentry.replayIntegration()],
    tracesSampleRate: 0.1,
    replaysSessionSampleRate: 0.1,
    replaysOnErrorSampleRate: 1.0,
  });
</script>
```

- [ ] **Step 3: Add `s-metrics.vngenterprise.com` to CSP**

In whichever app's CSP / web-server config, ensure:
```
connect-src 'self' https://s-metrics.vngenterprise.com;
img-src 'self' data: https://s-metrics.vngenterprise.com;
```

- [ ] **Step 4: From a public network (NOT netbird), throw a JS error in browser DevTools**

```js
throw new Error("public-relay smoke test")
```

Expected: event in Sentry within 30s. Verify by IP — confirm the request goes to `s-metrics.vngenterprise.com` in DevTools network tab.

### Task 5.5: Confirm UI is not reachable on the public host

- [ ] **Step 1: From a public network**

```bash
curl -sI https://s-metrics.vngenterprise.com/
curl -sI https://s-metrics.vngenterprise.com/organizations/
curl -sI https://s-metrics.vngenterprise.com/auth/login/
```

Expected: all return 404 from Traefik (no upstream matched). Only `/api/<project>/envelope/...` and the other ingest paths return 200/4xx from Relay.

---

## Phase 6: Observability + alerts

### Task 6.1: Discover correct PodMonitor selectors

**Files:**
- Modify: `applications/sentry/overlays/use1/podmonitors.yaml`

- [ ] **Step 1: Inspect labels on each Sentry pod class**

```bash
kubectl get pod -n sentry --show-labels | head -40
```

Make a note of which labels distinguish: web, relay, worker, snuba-api, ingest-consumer, post-process-forwarder, kafka, clickhouse, zookeeper.

- [ ] **Step 2: Expand `podmonitors.yaml`**

`applications/sentry/overlays/use1/podmonitors.yaml`:
```yaml
# Sentry observability: PodMonitors for all major components.
# All labelled `instance: primary` so alloy-metrics scrape config picks them up.
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: sentry-web
  namespace: sentry
  labels:
    instance: primary
spec:
  selector:
    matchLabels:
      app: sentry
      role: web
  podMetricsEndpoints:
    - port: http
      path: /_metrics
      interval: 60s
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: sentry-relay
  namespace: sentry
  labels:
    instance: primary
spec:
  selector:
    matchLabels:
      app: sentry
      role: relay
  podMetricsEndpoints:
    - port: relay
      path: /metrics
      interval: 60s
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: sentry-worker
  namespace: sentry
  labels:
    instance: primary
spec:
  selector:
    matchLabels:
      app: sentry
      role: worker
  podMetricsEndpoints:
    - port: http
      path: /metrics
      interval: 60s
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: sentry-snuba
  namespace: sentry
  labels:
    instance: primary
spec:
  selector:
    matchLabels:
      app: sentry
      role: snuba-api
  podMetricsEndpoints:
    - port: api
      path: /metrics
      interval: 60s
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: sentry-kafka
  namespace: sentry
  labels:
    instance: primary
spec:
  selector:
    matchLabels:
      app.kubernetes.io/instance: sentry
      app.kubernetes.io/name: kafka
  podMetricsEndpoints:
    - port: metrics
      interval: 60s
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: sentry-clickhouse
  namespace: sentry
  labels:
    instance: primary
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: clickhouse
  podMetricsEndpoints:
    - port: metrics
      interval: 60s
```

> Adjust label keys after running `kubectl get pod --show-labels` in Step 1. Selectors above match chart `26.x` conventions but may differ slightly per version.

- [ ] **Step 3: Validate, commit, sync**

```bash
kustomize build --enable-helm applications/sentry/overlays/use1 | grep -A 3 "kind: PodMonitor" | head -40
git add applications/sentry/overlays/use1/podmonitors.yaml
git commit -m "feat(sentry): add PodMonitors for web, relay, worker, snuba, kafka, clickhouse (Phase 6)"
git push
argocd app sync sentry --grpc-web
```

- [ ] **Step 4: Verify Mimir scrape targets are live**

In Grafana → Explore → Mimir datasource:
```
up{namespace="sentry"}
```
Expected: returns rows for each PodMonitor target, all `1`.

### Task 6.2: Create the Sentry Grafana dashboard

**Files:**
- Create: `applications/grafana/overlays/use1/vanguard/dashboards/files/sentry.json`
- Modify: `applications/grafana/overlays/use1/vanguard/dashboards/kustomization.yaml`

- [ ] **Step 1: Create a minimal dashboard JSON skeleton**

`applications/grafana/overlays/use1/vanguard/dashboards/files/sentry.json`:
```json
{
  "annotations": { "list": [] },
  "editable": false,
  "schemaVersion": 39,
  "tags": ["sentry", "platform"],
  "title": "Sentry",
  "uid": "sentry-overview",
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "Web pods up",
      "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "mimir" },
      "targets": [
        { "expr": "sum(up{namespace=\"sentry\", job=~\"sentry-web.*\"})", "refId": "A" }
      ]
    },
    {
      "id": 2,
      "type": "stat",
      "title": "Relay pods up",
      "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "mimir" },
      "targets": [
        { "expr": "sum(up{namespace=\"sentry\", job=~\"sentry-relay.*\"})", "refId": "A" }
      ]
    },
    {
      "id": 3,
      "type": "timeseries",
      "title": "Relay events accepted/s",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 },
      "datasource": { "type": "prometheus", "uid": "mimir" },
      "targets": [
        { "expr": "sum(rate(sentry_relay_events_accepted_total[5m]))", "refId": "A" }
      ]
    },
    {
      "id": 4,
      "type": "timeseries",
      "title": "ClickHouse disk used",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 4 },
      "datasource": { "type": "prometheus", "uid": "mimir" },
      "targets": [
        { "expr": "clickhouse_metric_filesystemmainpath_used_bytes / clickhouse_metric_filesystemmainpath_total_bytes", "refId": "A" }
      ]
    },
    {
      "id": 5,
      "type": "timeseries",
      "title": "Kafka consumer lag",
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 12 },
      "datasource": { "type": "prometheus", "uid": "mimir" },
      "targets": [
        { "expr": "sum by (topic, consumergroup) (kafka_consumergroup_lag)", "refId": "A", "legendFormat": "{{topic}} / {{consumergroup}}" }
      ]
    }
  ]
}
```

> This skeleton ships as a starting point. Tune metric names against what your PodMonitors actually expose — confirm with Grafana Explore before assuming.

- [ ] **Step 2: Register in dashboards kustomization**

Inspect the existing pattern first:
```bash
cat applications/grafana/overlays/use1/vanguard/dashboards/kustomization.yaml
```

Apply the same generator/registration shape used by other dashboards (likely a `configMapGenerator` block with `files: [files/sentry.json]` and the `grafana_dashboard=1` label).

- [ ] **Step 3: Validate**

```bash
kustomize build applications/grafana/overlays/use1/vanguard | grep -A 2 "name: sentry"
```

Expected: a ConfigMap named something like `sentry-dashboard` with `grafana_dashboard: "1"` label.

- [ ] **Step 4: Commit + sync**

```bash
git add applications/grafana/overlays/use1/vanguard/dashboards/
git commit -m "feat(grafana): add Sentry dashboard"
git push
argocd app sync grafana --grpc-web
```

- [ ] **Step 5: Verify in Grafana UI**

Navigate to Dashboards → look for "Sentry". Open it; panels should show data.

### Task 6.3: Create Sentry alert rules ConfigMap (all disabled initially)

**Files:**
- Create: `applications/grafana/overlays/use1/vanguard/alerts/rules-sentry.configmap.yaml`
- Modify: `applications/grafana/overlays/use1/vanguard/alerts/kustomization.yaml`

- [ ] **Step 1: Create the rules ConfigMap**

`applications/grafana/overlays/use1/vanguard/alerts/rules-sentry.configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rules-sentry
  namespace: grafana
  labels:
    grafana_alert: "1"
data:
  rules-sentry.yaml: |
    apiVersion: 1
    groups:
      - orgId: 1
        name: sentry
        folder: sentry
        interval: 1m
        rules:
          - uid: sentry-web-down
            title: SentryWebDown
            condition: A
            data:
              - refId: A
                datasourceUid: mimir
                model:
                  expr: 'up{namespace="sentry", job=~"sentry-web.*"} == 0'
                  refId: A
            noDataState: OK
            execErrState: Error
            for: 5m
            annotations:
              summary: "Sentry web pod down for 5m"
            labels:
              team: platform
              severity: warning
            isPaused: true

          - uid: sentry-relay-down
            title: SentryRelayDown
            condition: A
            data:
              - refId: A
                datasourceUid: mimir
                model:
                  expr: 'up{namespace="sentry", job=~"sentry-relay.*"} == 0'
                  refId: A
            noDataState: OK
            execErrState: Error
            for: 5m
            annotations:
              summary: "Sentry relay pod down for 5m"
            labels:
              team: platform
              severity: warning
            isPaused: true

          - uid: sentry-kafka-consumer-lag
            title: SentryKafkaConsumerLag
            condition: A
            data:
              - refId: A
                datasourceUid: mimir
                model:
                  expr: 'sum by (topic) (kafka_consumergroup_lag{namespace="sentry"}) > 10000'
                  refId: A
            noDataState: OK
            execErrState: Error
            for: 10m
            annotations:
              summary: "Kafka consumer lag >10k on {{ $labels.topic }}"
            labels:
              team: platform
              severity: warning
            isPaused: true

          - uid: sentry-clickhouse-disk-high
            title: SentryClickHouseDiskHigh
            condition: A
            data:
              - refId: A
                datasourceUid: mimir
                model:
                  expr: 'clickhouse_metric_filesystemmainpath_used_bytes / clickhouse_metric_filesystemmainpath_total_bytes > 0.8'
                  refId: A
            noDataState: OK
            execErrState: Error
            for: 10m
            annotations:
              summary: "Sentry ClickHouse disk >80% used"
            labels:
              team: platform
              severity: critical
            isPaused: true

          - uid: sentry-clickhouse-down
            title: SentryClickHouseDown
            condition: A
            data:
              - refId: A
                datasourceUid: mimir
                model:
                  expr: 'up{namespace="sentry", app_kubernetes_io_name="clickhouse"} == 0'
                  refId: A
            noDataState: OK
            execErrState: Error
            for: 5m
            annotations:
              summary: "Sentry ClickHouse down for 5m"
            labels:
              team: platform
              severity: critical
            isPaused: true

          - uid: sentry-relay-queue-depth
            title: SentryRelayQueueDepth
            condition: A
            data:
              - refId: A
                datasourceUid: mimir
                model:
                  expr: 'sentry_relay_envelopes_queued > 5000'
                  refId: A
            noDataState: OK
            execErrState: Error
            for: 5m
            annotations:
              summary: "Relay queue depth >5k for 5m"
            labels:
              team: platform
              severity: warning
            isPaused: true

          - uid: sentry-filestore-s3-errors
            title: SentryFilestoreS3Errors
            condition: A
            data:
              - refId: A
                datasourceUid: mimir
                model:
                  expr: 'rate(sentry_filestore_s3_errors_total[5m]) > 0'
                  refId: A
            noDataState: OK
            execErrState: Error
            for: 5m
            annotations:
              summary: "Sentry S3 filestore errors >0/s for 5m"
            labels:
              team: platform
              severity: warning
            isPaused: true
```

> The exact `model.datasourceUid` may differ — confirm by inspecting your Mimir datasource UID in the datasources ConfigMap. The above uses `mimir` which matches the LGTMP rollout.

- [ ] **Step 2: Register in alerts kustomization**

Edit `applications/grafana/overlays/use1/vanguard/alerts/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - external-secret.yaml
  - templates.configmap.yaml
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
  - rules-sentry.configmap.yaml
```

- [ ] **Step 3: Commit + sync**

```bash
git add applications/grafana/overlays/use1/vanguard/alerts/rules-sentry.configmap.yaml \
        applications/grafana/overlays/use1/vanguard/alerts/kustomization.yaml
git commit -m "feat(grafana): add sentry alert rules (Phase 6, all disabled)"
git push
argocd app sync grafana --grpc-web
```

- [ ] **Step 4: Verify rules appear in Grafana UI**

Alerting → Alert rules → folder `sentry` → all 7 rules listed, all "Paused".

### Task 6.4: Enable alert rules one at a time

For each rule, with 1h soak between:

- [ ] **SentryWebDown:** In Grafana UI → Alerting → `sentry` folder → SentryWebDown → Edit → toggle "Pause evaluation" OFF → Save. Then `kustomize` change `isPaused: true` → `false` for that rule. Commit `feat(grafana): enable SentryWebDown alert (Phase 6)`. Wait 1h.

- [ ] Verify test: deliberately fail it once
```bash
kubectl scale deploy/sentry-web -n sentry --replicas=0
```
Wait 6 min. Confirm Discord `#platform` receives the alert. Then:
```bash
kubectl scale deploy/sentry-web -n sentry --replicas=2
```
Wait for resolution notification.

- [ ] Repeat for: **SentryRelayDown**, **SentryKafkaConsumerLag**, **SentryClickHouseDiskHigh**, **SentryClickHouseDown**, **SentryRelayQueueDepth**, **SentryFilestoreS3Errors**. One per 1h.

---

## Final Verification (Definition of Done)

### Task DoD.1: All ArgoCD apps healthy

```bash
kubectl -n argocd get app cnpg-sentry redis-sentry sentry
```

Expected: all three Synced + Healthy.

### Task DoD.2: SSO is the only login path

In incognito on netbird: `https://sentry.vngenterprise.com` — immediate redirect to `accounts.vngenterprise.com`, no local form visible.

### Task DoD.3: Public ingest works, UI doesn't

From a public network:
```bash
curl -sI https://s-metrics.vngenterprise.com/                   # 404
curl -sI https://s-metrics.vngenterprise.com/auth/login/        # 404
curl -sI https://s-metrics.vngenterprise.com/api/1/envelope/    # 4xx with Sentry headers (relay reached)
```

### Task DoD.4: All feature areas verified

- [ ] Errors: smoke event in `smoke-test` project
- [ ] Performance: synthetic transaction in `smoke-test`
- [ ] Profiling: flamegraph from `profile-smoke`
- [ ] Replays: at least one replay object in `sentry-filestore-use1` and visible in UI
- [ ] Crons: `daily-smoke` monitor has at least one check-in
- [ ] Symbolicator: either verified with a native binary or explicitly deferred

### Task DoD.5: Production cutover for one service

At least one production service (Rustlens backend) is configured with `s-metrics.vngenterprise.com` DSN and has produced at least one event in the last 24h.

### Task DoD.6: Observability green

```bash
# Mimir
# Grafana → Explore → up{namespace="sentry"} → all targets 1
# Grafana → Sentry dashboard → all panels non-empty
# Grafana → Alerting → sentry folder → all rules unpaused
```

### Task DoD.7: Storage footprint within budget

```bash
kubectl get pvc -A | grep -E 'sentry|cnpg-sentry'
```

Sum the capacities. Expected total ≤ ~120 GiB across all sentry-related PVCs.

### Task DoD.8: Nightly cleanup runs

After 30+ days of operation:
```bash
kubectl get cronjob -n sentry | grep cleanup
kubectl logs -n sentry job/sentry-cleanup-<recent>
```

Expected: at least one `sentry-cleanup` CronJob has run successfully and deleted rows older than 30d.

### Task DoD.9: Final PR + merge

If the rollout was on `feature/sentry-self-hosted`:
```bash
git push
gh pr create --title "feat: self-hosted Sentry on use1 with Zitadel SAML" \
  --body "$(cat <<'EOF'
## Summary
- Adds self-hosted Sentry to the use1 cluster via the community Helm chart
- CNPG `sentry-db` (single-instance) for Postgres metadata
- redis-operator `sentry-redis` (3+3) for cache/queue
- Zitadel SAML2 SSO with sentry_admin / sentry_user group mapping
- Split UI/ingest: `sentry.vngenterprise.com` (internal, traefik-internal) and `s-metrics.vngenterprise.com` (public, ingest paths only)
- Filestore (attachments, source maps, replays) on offsite S3 with 45-day lifecycle
- 30-day event retention in chart-bundled ClickHouse + Kafka
- Grafana dashboard + alert rules routed to discord-platform

## Test plan
- [x] All 3 ArgoCD apps Synced + Healthy
- [x] SSO via Zitadel — no local-password form visible
- [x] Smoke event from internal debug pod
- [x] Synthetic transaction visible in Performance tab
- [x] Sample profile renders as flamegraph
- [x] Replay object in S3 + visible in UI
- [x] Cron monitor check-in
- [x] Public ingest works from public network; UI not reachable on public host
- [x] At least one production service cut over (Rustlens backend)
- [x] Grafana Sentry dashboard panels populated
- [x] All 7 alert rules enabled and at least one test alert routed to Discord
EOF
)"
```

---

## Out of scope (deferred)

These are explicitly NOT in this plan. Open follow-ups when needed.

- HA ClickHouse (cluster mode), HA Kafka (3+ brokers)
- SCIM auto-provisioning (Sentry SaaS-paid feature)
- Tempo trace export of Sentry's own internals
- Custom data-scrubbing rules beyond chart defaults
- Multi-tenant Sentry orgs per team
- Traefik `RateLimit` middleware on the public ingest endpoint
- Public API hostname for CI source-map upload (CI on netbird suffices today)
- Long retention (90d+)
