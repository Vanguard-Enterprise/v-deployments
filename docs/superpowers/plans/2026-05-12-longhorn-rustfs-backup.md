# Longhorn → rustfs Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Longhorn (`use1` cluster) to back up to rustfs `backup-storage.vngenterprise.com` (HTTPS:443, valid public cert) reached over NetBird, using the existing 3-replica `netbird-client` StatefulSet as a TCP-forward data path.

**Architecture:** Add a `socat` sidecar to each `netbird-client` pod that pass-through-forwards TCP/443 to `backup-storage.vngenterprise.com:443`. Expose via a ClusterIP Service in the `netbird-client` namespace. Add a CoreDNS `rewrite` so `backup-storage.vngenterprise.com` resolves to that Service from inside the cluster, preserving TLS SNI / cert verification end-to-end. Configure Longhorn's `defaultBackupStore` to point at the real hostname, with credentials sourced from a new Vault path via ExternalSecrets.

**Tech Stack:** Kubernetes, Kustomize, ArgoCD (auto-sync + self-heal), Longhorn 1.10.0 (Helm), External Secrets Operator (Vault backend), socat, CoreDNS, NetBird.

**Operator boundaries:**
- **Operator must execute** Task 1 (rustfs bucket + Vault write) before any cluster-side change syncs. Cluster work (Tasks 2–8) can be staged in PRs first but must not be merged before Vault is populated, otherwise the new ExternalSecret fails to materialize and Longhorn alarms.
- **Operator must approve** the CoreDNS-affecting step (per repo CLAUDE.md, K8s mutations need explicit permission). The plan delivers it via GitOps, so the approval is "merge the PR".

---

## File Structure

### New files

| Path | Responsibility |
| --- | --- |
| `applications/netbird/overlays/use1-clients/backup-storage-service.yaml` | ClusterIP Service in `netbird-client` ns fronting the new sidecar |
| `applications/coredns-config/base/namespace-placeholder.yaml` | Empty placeholder so kustomize has at least one resource (CoreDNS lives in kube-system, no new ns needed) — _not actually created if the patch + Argo app reference is enough; see Task 5_ |
| `applications/coredns-config/base/kustomization.yaml` | Base kustomization |
| `applications/coredns-config/overlays/use1/kustomization.yaml` | Patch over kube-system/coredns ConfigMap |
| `applications/coredns-config/overlays/use1/coredns-rewrite.yaml` | The strategic-merge patch carrying the rewrite line |
| `argocd/applications/use1/coredns-config.yaml` | ArgoCD `Application` registering the new app with sync-wave `-10` |

### Modified files

| Path | Change |
| --- | --- |
| `applications/netbird/overlays/use1-clients/statefulset.yaml` | Add `s3-forward` sidecar container (socat, 443) |
| `applications/netbird/overlays/use1-clients/kustomization.yaml` | Add the new Service resource |
| `applications/longhorn/overlays/use1/external-secrets.yaml` | Rename target/source: `longhorn-backup-r2` → `longhorn-backup-storage`, remoteRef key → `longhorn/backup-storage` |
| `applications/longhorn/overlays/use1/values.yaml` | Replace commented R2 block with active `defaultBackupStore` pointing at `s3://longhorn-use1@us-east-1/`, secret `longhorn-backup-storage` |
| `applications/longhorn/base/jobs/kustomization.yaml` | Re-enable the four backup jobs + system-backup job |
| `applications/longhorn/base/jobs/backup-6.yaml` | Rename job: `r2-backup-hourly` → `backup-hourly` (schedule/retention unchanged) |
| `applications/longhorn/base/jobs/backup-daily.yaml` | Rename job: `r2-backup-daily` → `backup-daily` |
| `applications/longhorn/base/jobs/backup-weekly.yaml` | Rename job: `r2-backup-weekly` → `backup-weekly` |
| `applications/longhorn/base/jobs/backup-monthly.yaml` | Rename job: `r2-backup-monthly` → `backup-monthly` |

`applications/longhorn/base/jobs/system-backup-24.yaml` is already named `system-backup-daily` (not `r2-*`), no rename required — only its kustomization entry needs uncommenting.

---

## Task 1: Operator runbook — rustfs bucket, scoped credentials, Vault write

**Files:** None in repo. Operator-executed against rustfs in the remote DC and Vault.

This must complete BEFORE Tasks 6/7 reach `main` and ArgoCD syncs Longhorn, or the ExternalSecret will fail to materialize.

- [ ] **Step 1: Connect to the remote rustfs admin console**

You should already be on the NetBird mesh from your workstation. Open the rustfs admin console for `backup-storage.vngenterprise.com` (port and path per that instance's setup — likely `https://backup-storage.vngenterprise.com:9001` or behind an internal-only ingress). Log in with the existing rustfs root credentials.

- [ ] **Step 2: Create the bucket**

In the rustfs console, create a new bucket:

| Setting | Value |
| --- | --- |
| Name | `longhorn-use1` |
| Region | `us-east-1` |
| Object Locking | disabled |
| Versioning | disabled |

(Or, if `mc` is configured: `mc mb backup-storage/longhorn-use1`.)

- [ ] **Step 3: Create scoped IAM policy `longhorn-use1-rw`**

In the rustfs console under Identity → Policies, create policy `longhorn-use1-rw` with this document:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::longhorn-use1"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::longhorn-use1/*"]
    }
  ]
}
```

- [ ] **Step 4: Create a service account bound to that policy**

In rustfs console, create a new service account. Attach **only** the `longhorn-use1-rw` policy. Save the generated access key and secret to your password manager temporarily. Do NOT paste them into chat or commit them.

- [ ] **Step 5: Write the credentials to Vault**

From a machine with `vault` CLI configured and authenticated:

```bash
vault kv put longhorn/backup-storage \
  AWS_ACCESS_KEY_ID='<from Step 4>' \
  AWS_SECRET_ACCESS_KEY='<from Step 4>' \
  AWS_ENDPOINTS='https://backup-storage.vngenterprise.com'
```

- [ ] **Step 6: Verify Vault contents**

```bash
vault kv get -format=json longhorn/backup-storage | jq '.data.data | keys'
```

Expected output:

```
[
  "AWS_ACCESS_KEY_ID",
  "AWS_ENDPOINTS",
  "AWS_SECRET_ACCESS_KEY"
]
```

- [ ] **Step 7: Sanity-check the bucket is reachable from the NetBird mesh**

From your workstation (which is on NetBird):

```bash
curl -sI https://backup-storage.vngenterprise.com/longhorn-use1/
```

Expected: an HTTP response (`200`, `403`, or `404` — anything other than connection failure or TLS error). Specifically, no `curl: (60) SSL certificate problem` and no `Could not resolve host`.

---

## Task 2: Add `s3-forward` socat sidecar to the `netbird-client` StatefulSet

**Files:**
- Modify: `applications/netbird/overlays/use1-clients/statefulset.yaml`

- [ ] **Step 1: Read current state**

The file currently has a single container (`client`, the netbird daemon). We are adding a second container in the same `containers:` list.

- [ ] **Step 2: Apply the edit**

Replace this section in `applications/netbird/overlays/use1-clients/statefulset.yaml`:

```yaml
      containers:
        - name: client
          image: netbirdio/netbird:0.70.4
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: netbird-client-setup
          env:
            - name: NB_MANAGEMENT_URL
              value: https://netbird.vngenterprise.com
          volumeMounts:
            - name: client-data
              mountPath: /var/lib/netbird
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
```

with this section:

```yaml
      containers:
        - name: client
          image: netbirdio/netbird:0.70.4
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: netbird-client-setup
          env:
            - name: NB_MANAGEMENT_URL
              value: https://netbird.vngenterprise.com
          volumeMounts:
            - name: client-data
              mountPath: /var/lib/netbird
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
        - name: s3-forward
          image: alpine/socat:latest
          args:
            - "-d"
            - "TCP-LISTEN:443,fork,reuseaddr"
            - "TCP:backup-storage.vngenterprise.com:443"
          ports:
            - name: s3
              containerPort: 443
              protocol: TCP
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
          securityContext:
            capabilities:
              drop:
                - ALL
            runAsNonRoot: false
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
```

- [ ] **Step 3: Validate the kustomize build locally**

```bash
cd B:/.dev/Vanguard/v-deployments
kubectl kustomize applications/netbird/overlays/use1-clients | grep -A 25 "name: s3-forward"
```

Expected: prints the new container block with the args/ports/resources you just added.

- [ ] **Step 4: Commit**

```bash
cd B:/.dev/Vanguard/v-deployments
git add applications/netbird/overlays/use1-clients/statefulset.yaml
git commit -m "feat(netbird-clients): add s3-forward socat sidecar for longhorn backups"
```

---

## Task 3: Create the `backup-storage` ClusterIP Service

**Files:**
- Create: `applications/netbird/overlays/use1-clients/backup-storage-service.yaml`
- Modify: `applications/netbird/overlays/use1-clients/kustomization.yaml`

- [ ] **Step 1: Create the Service manifest**

Write `applications/netbird/overlays/use1-clients/backup-storage-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backup-storage
  namespace: netbird-client
spec:
  type: ClusterIP
  selector:
    app: netbird-client
  ports:
    - name: s3
      port: 443
      targetPort: s3
      protocol: TCP
```

- [ ] **Step 2: Wire it into the overlay's kustomization**

Edit `applications/netbird/overlays/use1-clients/kustomization.yaml`. Replace:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - service.yaml
  - statefulset.yaml
  - external-secret.yaml
  - namespace.yaml
```

with:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - service.yaml
  - statefulset.yaml
  - external-secret.yaml
  - namespace.yaml
  - backup-storage-service.yaml
```

- [ ] **Step 3: Validate the kustomize build**

```bash
cd B:/.dev/Vanguard/v-deployments
kubectl kustomize applications/netbird/overlays/use1-clients | grep -B 1 -A 12 "name: backup-storage"
```

Expected: prints the Service manifest with `port: 443`, `targetPort: s3`, selector `app: netbird-client`.

- [ ] **Step 4: Commit**

```bash
cd B:/.dev/Vanguard/v-deployments
git add applications/netbird/overlays/use1-clients/backup-storage-service.yaml applications/netbird/overlays/use1-clients/kustomization.yaml
git commit -m "feat(netbird-clients): add backup-storage ClusterIP service"
```

---

## Task 4: Create the `coredns-config` GitOps app — base + overlay

**Files:**
- Create: `applications/coredns-config/base/kustomization.yaml`
- Create: `applications/coredns-config/overlays/use1/kustomization.yaml`
- Create: `applications/coredns-config/overlays/use1/coredns-rewrite.yaml`

The strategy is a **strategic-merge ConfigMap patch** against the existing
`kube-system/coredns` ConfigMap, replacing only the `Corefile` data key. Other
keys (if any) are preserved by kustomize's strategic-merge semantics for
ConfigMaps.

> **Note on CoreDNS Corefile content:** The patch below assumes the standard
> kubeadm-installed CoreDNS Corefile. If your cluster's CoreDNS Corefile
> differs, Task 4 Step 2 captures the live Corefile first and asks you to
> reconcile before writing the patch.

- [ ] **Step 1: Capture the live Corefile for reference**

```bash
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' > /tmp/coredns-corefile.live
cat /tmp/coredns-corefile.live
```

Expected: prints the Corefile content. It will look something like:

```
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
```

If your live Corefile differs structurally, STOP and reconcile manually — the
patch in Step 4 must match the actual content shape.

- [ ] **Step 2: Create the base kustomization (empty resources, common labels)**

Write `applications/coredns-config/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
commonLabels:
  app.kubernetes.io/name: coredns-config
```

This base intentionally has no resources — all content lives in the overlay
because CoreDNS is cluster-specific.

- [ ] **Step 3: Create the rewrite patch manifest**

Write `applications/coredns-config/overlays/use1/coredns-rewrite.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        rewrite name backup-storage.vngenterprise.com backup-storage.netbird-client.svc.cluster.local
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
```

**Reconcile this body with `/tmp/coredns-corefile.live` from Step 1.** Copy the
live content verbatim and insert ONLY the new line:

```
rewrite name backup-storage.vngenterprise.com backup-storage.netbird-client.svc.cluster.local
```

immediately after the `ready` directive. Do not change any other content.

- [ ] **Step 4: Create the overlay kustomization referencing the rewrite**

Write `applications/coredns-config/overlays/use1/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - coredns-rewrite.yaml
```

We use a full resource (not a strategic-merge patch) so ArgoCD owns the
Corefile content. This is intentional: ArgoCD self-heal will restore the
rewrite if anything strips it.

- [ ] **Step 5: Validate the kustomize build**

```bash
cd B:/.dev/Vanguard/v-deployments
kubectl kustomize applications/coredns-config/overlays/use1
```

Expected: prints the ConfigMap manifest with the rewrite line present in
`data.Corefile`.

- [ ] **Step 6: Commit**

```bash
cd B:/.dev/Vanguard/v-deployments
git add applications/coredns-config
git commit -m "feat(coredns): add backup-storage.vngenterprise.com rewrite for longhorn"
```

---

## Task 5: Register the CoreDNS-config app with ArgoCD

**Files:**
- Create: `argocd/applications/use1/coredns-config.yaml`

- [ ] **Step 1: Create the ArgoCD Application manifest**

Write `argocd/applications/use1/coredns-config.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: coredns-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
spec:
  project: default
  source:
    repoURL: https://github.com/Vanguard-Enterprise/v-deployments
    path: applications/coredns-config/overlays/use1
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      selfHeal: true
      prune: false
    syncOptions:
      - ApplyOutOfSyncOnly=true
```

`prune: false` is deliberate — if the app is ever deleted, we do NOT want
ArgoCD to delete the kube-system/coredns ConfigMap.

- [ ] **Step 2: Check that the parent app-of-apps will pick this up**

```bash
ls B:/.dev/Vanguard/v-deployments/argocd/applications/use1/coredns-config.yaml
cat B:/.dev/Vanguard/v-deployments/argocd/app-of-apps/use1.yaml
```

Expected: the file exists and `use1.yaml` references the directory (it
likely uses `directory.recurse: true` to pick all `.yaml` files in
`applications/use1/`). If it does NOT recurse, edit that file to include
`coredns-config.yaml` in its resource list.

- [ ] **Step 3: Commit**

```bash
cd B:/.dev/Vanguard/v-deployments
git add argocd/applications/use1/coredns-config.yaml
git commit -m "feat(argocd): register coredns-config application for use1"
```

---

## Task 6: Rename the Longhorn backup ExternalSecret to `longhorn-backup-storage`

**Files:**
- Modify: `applications/longhorn/overlays/use1/external-secrets.yaml`

- [ ] **Step 1: Replace the file contents**

Replace the entire contents of `applications/longhorn/overlays/use1/external-secrets.yaml` with:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: longhorn-backup-storage
  namespace: longhorn-system
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: longhorn-backup-storage
    creationPolicy: Owner
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: "longhorn/backup-storage"
        property: "AWS_ACCESS_KEY_ID"
    - secretKey: AWS_ENDPOINTS
      remoteRef:
        key: "longhorn/backup-storage"
        property: "AWS_ENDPOINTS"
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: "longhorn/backup-storage"
        property: "AWS_SECRET_ACCESS_KEY"
```

- [ ] **Step 2: Validate kustomize build**

```bash
cd B:/.dev/Vanguard/v-deployments
kubectl kustomize applications/longhorn/overlays/use1 | grep -A 30 "kind: ExternalSecret"
```

Expected: shows the new ExternalSecret with target name `longhorn-backup-storage` and Vault key `longhorn/backup-storage`.

- [ ] **Step 3: Commit**

```bash
cd B:/.dev/Vanguard/v-deployments
git add applications/longhorn/overlays/use1/external-secrets.yaml
git commit -m "refactor(longhorn): rename backup secret r2 -> backup-storage"
```

---

## Task 7: Re-enable `defaultBackupStore` in Longhorn Helm values

**Files:**
- Modify: `applications/longhorn/overlays/use1/values.yaml`

- [ ] **Step 1: Apply the edit**

In `applications/longhorn/overlays/use1/values.yaml`, replace the commented block at lines 11–19:

```yaml
# R2 backups are disabled. To re-enable, restore the values below and
# add the backup jobs back to base/jobs/kustomization.yaml.
#
# defaultBackupStore:
#   backupTarget: s3://longhorn-backups@auto/
#   backupTargetCredentialSecret: longhorn-backup-r2
#   pollInterval: 300
defaultBackupStore:
  backupTarget: ""
```

with:

```yaml
defaultBackupStore:
  backupTarget: s3://longhorn-use1@us-east-1/
  backupTargetCredentialSecret: longhorn-backup-storage
  pollInterval: 300
```

- [ ] **Step 2: Validate kustomize build**

```bash
cd B:/.dev/Vanguard/v-deployments
kubectl kustomize applications/longhorn/overlays/use1 2>&1 | head -5
```

Expected: builds without errors. (Note: `kubectl kustomize` does not render
Helm charts; ArgoCD does. Just verify no syntax error.)

- [ ] **Step 3: Commit**

```bash
cd B:/.dev/Vanguard/v-deployments
git add applications/longhorn/overlays/use1/values.yaml
git commit -m "feat(longhorn): re-enable defaultBackupStore against backup-storage"
```

---

## Task 8: Rename and re-enable Longhorn recurring backup jobs

**Files:**
- Modify: `applications/longhorn/base/jobs/backup-6.yaml`
- Modify: `applications/longhorn/base/jobs/backup-daily.yaml`
- Modify: `applications/longhorn/base/jobs/backup-weekly.yaml`
- Modify: `applications/longhorn/base/jobs/backup-monthly.yaml`
- Modify: `applications/longhorn/base/jobs/kustomization.yaml`

We are preserving the existing schedules and retention numbers from each
file (they were tuned previously); we ONLY drop the now-misleading `r2-`
prefix from the resource names. `system-backup-24.yaml` is already named
`system-backup-daily` and needs no rename.

- [ ] **Step 1: Rename `backup-6.yaml` job**

In `applications/longhorn/base/jobs/backup-6.yaml`, change line 4:

```yaml
  name: r2-backup-hourly
```

to:

```yaml
  name: backup-hourly
```

- [ ] **Step 2: Rename `backup-daily.yaml` job**

In `applications/longhorn/base/jobs/backup-daily.yaml`, change line 4:

```yaml
  name: r2-backup-daily
```

to:

```yaml
  name: backup-daily
```

- [ ] **Step 3: Rename `backup-weekly.yaml` job**

In `applications/longhorn/base/jobs/backup-weekly.yaml`, change line 4:

```yaml
  name: r2-backup-weekly
```

to:

```yaml
  name: backup-weekly
```

- [ ] **Step 4: Rename `backup-monthly.yaml` job**

In `applications/longhorn/base/jobs/backup-monthly.yaml`, change line 4:

```yaml
  name: r2-backup-monthly
```

to:

```yaml
  name: backup-monthly
```

- [ ] **Step 5: Re-enable jobs in `kustomization.yaml`**

Replace the entire contents of `applications/longhorn/base/jobs/kustomization.yaml` with:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - backup-6.yaml
  - backup-daily.yaml
  - backup-weekly.yaml
  - backup-monthly.yaml
  - system-backup-24.yaml
  - snapshot-30.yaml
```

- [ ] **Step 6: Validate kustomize build**

```bash
cd B:/.dev/Vanguard/v-deployments
kubectl kustomize applications/longhorn/overlays/use1 | grep -E "kind: RecurringJob|  name:" | grep -B 0 -A 1 "RecurringJob"
```

Expected: lists all six RecurringJob resources with their new names (no
`r2-` prefix anywhere): `backup-hourly`, `backup-daily`, `backup-weekly`,
`backup-monthly`, `system-backup-daily`, `snapshot-30m`.

- [ ] **Step 7: Commit**

```bash
cd B:/.dev/Vanguard/v-deployments
git add applications/longhorn/base/jobs/
git commit -m "feat(longhorn): re-enable backup recurring jobs, drop r2 prefix"
```

---

## Task 9: Open PR and merge in dependency order

**Files:** None local. PR ordering only.

The four-commit history from Tasks 2–8 can be a single PR. ArgoCD will sync
all touched apps automatically. The sync-wave on `coredns-config` ensures
CoreDNS reloads before Longhorn first polls the new backup target.

- [ ] **Step 1: Push the branch**

```bash
cd B:/.dev/Vanguard/v-deployments
git push -u origin HEAD
```

- [ ] **Step 2: Verify Task 1 (rustfs + Vault) is already complete**

If the operator (Task 1) has NOT yet written the Vault secret, hold the
merge. The ExternalSecret would fail to materialize, Longhorn would alarm
on missing backup-target credentials, and ArgoCD would surface degraded
status until corrected.

Confirm Vault has the secret:

```bash
vault kv get -format=json longhorn/backup-storage | jq '.data.data | keys'
```

Expected: `["AWS_ACCESS_KEY_ID","AWS_ENDPOINTS","AWS_SECRET_ACCESS_KEY"]`

- [ ] **Step 3: Open the PR**

```bash
cd B:/.dev/Vanguard/v-deployments
gh pr create --title "feat: longhorn backups → rustfs backup-storage via netbird" --body "$(cat <<'EOF'
## Summary

- Adds `s3-forward` socat sidecar to `netbird-client` StatefulSet and a `backup-storage` ClusterIP Service so cluster pods can reach rustfs `backup-storage.vngenterprise.com` over NetBird.
- New `coredns-config` ArgoCD app patches kube-system/coredns to rewrite `backup-storage.vngenterprise.com` → in-cluster Service (preserves TLS SNI / cert verification).
- Re-enables Longhorn `defaultBackupStore` pointing at `s3://longhorn-use1@us-east-1/` with credentials sourced from Vault path `longhorn/backup-storage`.
- Renames and re-enables recurring backup jobs (drops `r2-` prefix).

Requires Vault path `longhorn/backup-storage` to be populated BEFORE merge.

## Test plan

- [ ] Operator has created bucket `longhorn-use1` and scoped service account on remote rustfs
- [ ] Vault path `longhorn/backup-storage` populated with AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINTS
- [ ] ArgoCD shows `netbird-clients`, `coredns-config`, `longhorn` all Synced/Healthy
- [ ] All 3 `netbird-client-*` pods Ready 2/2
- [ ] DNS rewrite verified: in-cluster nslookup of `backup-storage.vngenterprise.com` returns the new Service ClusterIP
- [ ] Longhorn UI BackupTarget shows green
- [ ] Manual backup of a test PVC succeeds and objects appear in `longhorn-use1`
EOF
)"
```

- [ ] **Step 4: Merge**

After CI passes and any human reviewers approve. ArgoCD auto-sync will
pick up the changes within ~3 minutes.

---

## Task 10: Post-deploy verification

**Files:** None. Live-cluster checks.

Run these in order. **STOP and investigate at the first failure** rather
than continuing.

- [ ] **Step 1: ExternalSecret materialized**

```bash
kubectl -n longhorn-system get externalsecret longhorn-backup-storage -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
kubectl -n longhorn-system get secret longhorn-backup-storage -o jsonpath='{.data}' | jq 'keys'
```

Expected first line: `True`
Expected second output: `["AWS_ACCESS_KEY_ID","AWS_ENDPOINTS","AWS_SECRET_ACCESS_KEY"]`

- [ ] **Step 2: netbird-client pods all Ready 2/2**

```bash
kubectl -n netbird-client get pods
```

Expected: `netbird-client-0`, `netbird-client-1`, `netbird-client-2` all `READY 2/2 STATUS Running`.

- [ ] **Step 3: Sidecar can reach backup-storage**

```bash
kubectl -n netbird-client exec netbird-client-0 -c s3-forward -- \
  nc -zv backup-storage.vngenterprise.com 443
```

Expected: `backup-storage.vngenterprise.com (...) open` or `succeeded!`. The
`alpine/socat` image includes BusyBox `nc`.

- [ ] **Step 4: Service has all three endpoints**

```bash
kubectl -n netbird-client get endpoints backup-storage
```

Expected: ENDPOINTS column shows three `<podIP>:443` entries.

- [ ] **Step 5: CoreDNS rewrite is live**

```bash
kubectl -n longhorn-system run dns-test --rm -i --restart=Never --image=busybox -- \
  nslookup backup-storage.vngenterprise.com
```

Expected:

```
Name:    backup-storage.vngenterprise.com
Address: <ClusterIP of backup-storage.netbird-client.svc>
```

Cross-check the ClusterIP:

```bash
kubectl -n netbird-client get svc backup-storage -o jsonpath='{.spec.clusterIP}{"\n"}'
```

The two IPs must match.

- [ ] **Step 6: Longhorn BackupTarget is healthy**

```bash
kubectl -n longhorn-system get backuptarget default -o jsonpath='{.status.available}{"\n"}{.status.conditions}{"\n"}'
```

Expected: `available: true`, no error conditions. Alternatively, open the
Longhorn UI (via your existing port-forward / ingress) → Backup → Backup
Target — the indicator should be green.

- [ ] **Step 7: Manual backup smoke test**

Pick a tiny existing PVC, or create a 100Mi test PVC. From the Longhorn UI,
trigger a manual backup. Wait for completion (a few minutes for tiny data).

Then verify the object exists in rustfs:

```bash
# From your workstation on the NetBird mesh
mc ls backup-storage/longhorn-use1/
```

Expected: at least one `backupstore/` and/or `volumes/` prefix is present.

- [ ] **Step 8: Wait for first scheduled recurring backup**

The `backup-hourly` job runs at the top of the hour. Within ~70 minutes
of go-live, confirm:

```bash
kubectl -n longhorn-system get recurringjob backup-hourly -o jsonpath='{.status}{"\n"}'
```

Expected: status shows recent execution time and no error.

---

## Self-Review

**Spec coverage:**

| Spec section | Covered by |
| --- | --- |
| §3 Architecture | Tasks 2, 3, 4, 5, 7 |
| §4 rustfs preparation | Task 1 |
| §5.1 socat sidecar | Task 2 |
| §5.2 Service | Task 3 |
| §5.3 kustomization update | Task 3 |
| §6 CoreDNS rewrite via GitOps | Tasks 4, 5 |
| §7.1 defaultBackupStore | Task 7 |
| §7.2 ExternalSecret rename | Task 6 |
| §7.3 recurring jobs re-enabled | Task 8 |
| §7.4 default-recurring-job sanity check | N/A — no rename needed, existing Setting is independent of job names |
| §8 component boundaries | Implicit in task structure |
| §9 Verification plan | Task 10 |
| §10 Rollout order | Task 9 gates merge on Task 1 completion |

**Placeholder scan:** No "TBD", "TODO", or "fill in details" in any task. Every code block is complete; every command shows expected output. The CoreDNS Corefile in Task 4 Step 3 is fully written; Step 1 instructs the operator to reconcile if the live Corefile differs, with explicit STOP guidance.

**Type consistency:**
- Service name `backup-storage` consistent across Task 3 (manifest), Task 10 Step 4 (endpoints), Task 10 Step 5 (ClusterIP cross-check).
- Sidecar container name `s3-forward` consistent across Task 2 (manifest), Task 10 Step 3 (exec).
- Port name `s3` consistent on container (Task 2) and Service `targetPort` (Task 3).
- Vault path `longhorn/backup-storage` consistent across Task 1 Step 5, Task 6 manifest, Task 9 Step 2.
- Bucket name `longhorn-use1` consistent across Task 1, Task 7 backupTarget, Task 10 Step 7.
- Secret name `longhorn-backup-storage` consistent across Task 6 (ExternalSecret name + target name), Task 7 (`backupTargetCredentialSecret`), Task 10 Step 1.
- Job names (`backup-hourly`, `backup-daily`, `backup-weekly`, `backup-monthly`) consistent across Task 8 and Task 10 Step 8.

No drift identified.
