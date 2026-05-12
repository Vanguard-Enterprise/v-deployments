# Longhorn Backups → rustfs `backup-storage` over NetBird

**Date:** 2026-05-12
**Cluster:** `use1`
**Status:** Draft — awaiting implementation

## 1. Goal

Configure Longhorn to back up cluster volumes to a rustfs S3 instance that lives
in a different datacenter and is reachable **only** over the NetBird mesh
(`backup-storage.vngenterprise.com`, HTTPS:443, valid public TLS cert). Reuse
the existing 3-replica `netbird-client` StatefulSet in cluster as the data path
— no host-level NetBird changes.

This replaces the previous Cloudflare R2 backup target, which has been disabled
since some prior date (commented out in `applications/longhorn/overlays/use1/values.yaml`).

## 2. Non-goals

- Backup encryption-at-rest (Longhorn `CRYPTO_KEY_*`). Tracked as a follow-up.
- Pinning the `rustfs/rustfs:latest` image in `applications/rustfs`. Out of
  scope; flagged for future cleanup.
- Multi-cluster / multi-region backup target setup.
- Disaster-recovery restore drills. Verified manually post-rollout.

## 3. Architecture

```
Longhorn manager / engine pods (longhorn-system)
        │  S3 API → https://backup-storage.vngenterprise.com/longhorn-use1
        ▼
   CoreDNS (kube-system)
        │  rewrite name backup-storage.vngenterprise.com
        │     → backup-storage.netbird-client.svc.cluster.local
        ▼
   Service: backup-storage.netbird-client.svc (ClusterIP, 443/tcp)
        │  endpoints from 3 netbird-client pods
        ▼
   socat sidecar (port 443, raw TCP pass-through) ──┐
        │                                            │  pod also runs the
        │                                            │  existing netbird client
        ▼                                            │  (NetBird peer)
   WireGuard tunnel via NetBird ◄────────────────────┘
        │
        ▼
   rustfs S3 @ backup-storage.vngenterprise.com:443
   (TLS terminates here; cert validates against public CA)
```

### Key properties

- **TLS end-to-end** between Longhorn and rustfs. The socat sidecar shuttles raw
  bytes — it never decrypts.
- **NetBird WireGuard tunnel** carries the off-cluster hop and provides
  additional transport encryption.
- **Three replicas** of the sidecar (one per netbird-client pod) supply built-in
  redundancy. The ClusterIP Service load-balances across whichever pods are
  healthy.
- **No Longhorn Helm chart changes** beyond values + a new credential secret +
  recurring jobs.

## 4. rustfs preparation (operator-executed runbook)

Performed manually by the operator against the rustfs admin console in the
remote datacenter. The runbook is required because credentials never touch this
repo; we cannot script it from inside the cluster prior to bootstrap.

### 4.1 Create bucket

Using the rustfs admin console (or `mc` against the rustfs S3 endpoint via
NetBird):

| Parameter | Value |
| --- | --- |
| Bucket name | `longhorn-use1` |
| Region | `us-east-1` (dummy; required by AWS SDK, ignored by rustfs) |
| Object locking | off |
| Versioning | off (Longhorn manages its own retention) |

### 4.2 Create access policy `longhorn-use1-rw`

Scope: full read/write on `longhorn-use1` only.

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

### 4.3 Create service account bound to that policy

Generate an access key pair scoped exclusively to the new policy. Record:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

### 4.4 Write secret to Vault

Path: `longhorn/backup-storage` (new path; do not overwrite `longhorn/backups`
which retains historical R2 credentials).

```bash
vault kv put longhorn/backup-storage \
  AWS_ACCESS_KEY_ID='<from 4.3>' \
  AWS_SECRET_ACCESS_KEY='<from 4.3>' \
  AWS_ENDPOINTS='https://backup-storage.vngenterprise.com'
```

`AWS_ENDPOINTS` deliberately uses the real public hostname; the cluster
CoreDNS rewrite (§6) makes that hostname resolve to the in-cluster Service so
TLS SNI/cert verification continues to work.

## 5. In-cluster routing changes

All edits land in `applications/netbird/overlays/use1-clients/` and are picked
up by the existing `netbird-clients` ArgoCD application (auto-sync,
self-heal).

### 5.1 Add `s3-forward` sidecar to `statefulset.yaml`

Second container in each pod of the `netbird-client` StatefulSet runs
`haproxy:2.8.10` (Debian/glibc) as a pure TCP forwarder. Its config is
templated at container start by a small wrapper script that reads the local
NetBird daemon's nameserver from `/etc/resolv.conf` and injects it into the
haproxy `resolvers` section. This is the only practical way to do it: each
pod's NetBird daemon runs its own embedded DNS server at its own WG IP, so
the nameserver differs per pod and cannot be hardcoded.

```yaml
- name: s3-forward
  image: haproxy:2.8.10
  imagePullPolicy: IfNotPresent
  command:
    - /bin/sh
    - -c
    - |
      set -eu
      i=0
      while ! grep -qE "^nameserver 100\.107\." /etc/resolv.conf; do
        i=$((i+1))
        [ $i -ge 60 ] && { echo "[s3-forward] gave up after 120s" >&2; exit 1; }
        echo "[s3-forward] waiting for NetBird DNS (attempt $i)"
        sleep 2
      done
      ns=$(awk '/^nameserver 100\.107\./ {print $2; exit}' /etc/resolv.conf)
      sed "s|__NETBIRD_DNS_IP__|$ns|g" \
        /usr/local/etc/haproxy/haproxy.cfg > /run/haproxy/haproxy.cfg
      exec haproxy -W -db -f /run/haproxy/haproxy.cfg
  ports:
    - name: s3
      containerPort: 443
      protocol: TCP
  volumeMounts:
    - name: s3-forward-config
      mountPath: /usr/local/etc/haproxy
      readOnly: true
    - name: s3-forward-runtime
      mountPath: /run/haproxy
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 200m
      memory: 128Mi
  securityContext:
    capabilities:
      drop:
        - ALL
      add:
        - NET_BIND_SERVICE
    runAsNonRoot: false
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
```

The haproxy config (mounted from `s3-forward-config` ConfigMap) defines a TCP
frontend on `:443` and a backend that points at `backup-storage.vngenterprise.com:443`,
with a `resolvers netbird-dns` block whose nameserver is `__NETBIRD_DNS_IP__`
(substituted at startup). `resolve-prefer ipv4`, `init-addr none`, and no
`check` directive — haproxy never marks the server administratively DOWN on
DNS hiccups; it just keeps re-resolving per `hold valid` and trusts the
upstream.

Two additional volumes are added at the pod spec level:

```yaml
volumes:
  - name: s3-forward-config       # the haproxy config template
    configMap:
      name: s3-forward-config
  - name: s3-forward-runtime      # writable scratch for sed-substituted config
    emptyDir:
      medium: Memory
      sizeLimit: 1Mi
```

Failed attempts along the way (recorded so we don't redo them):

1. **`alpine/socat`** — musl libc `getaddrinfo` fails with "Name has no
   usable address" against NetBird's resolv.conf shape (`ndots:5` + 6
   search domains). `nslookup` from the same container works; libc-based
   resolution doesn't. Bypassed temporarily with a hardcoded NetBird IP,
   then replaced.
2. **`haproxy` with hardcoded nameserver** — only the pod whose NetBird IP
   matched the hardcode could resolve. Other pods silently failed forwards.
3. **`haproxy` with `parse-resolv-conf`** — haproxy parses
   `/etc/resolv.conf` before NetBird overwrites it, ends up with the
   kubelet-injected cluster CoreDNS IP, which resolves
   `backup-storage.vngenterprise.com` to our own Service ClusterIP via the
   CoreDNS rewrite — a forwarding loop. Wrapper-substituted nameserver is
   the working approach.

Notes:

- TLS terminates end-to-end at rustfs; haproxy is pure TCP forwarding in
  `mode tcp`, so the in-cluster client's SNI for
  `backup-storage.vngenterprise.com` reaches rustfs unmodified and the
  public cert verifies.
- No NET_ADMIN required for the sidecar. NET_BIND_SERVICE is added so
  haproxy can bind 443 cleanly even if the image's USER changes in future
  versions. The pod runs in a `pod-security.kubernetes.io/enforce: privileged`
  namespace, so root works too.
- The wrapper waits up to ~120s for NetBird DNS to be installed. In practice
  it completes in 0–10s after pod start.

### 5.2 New `backup-storage-service.yaml`

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

Endpoint set = the three `netbird-client` pods; kube-proxy load-balances.

### 5.3 Update `kustomization.yaml`

Add `backup-storage-service.yaml` to `resources`.

## 6. CoreDNS rewrite

Delivery mechanism: **new GitOps app** `applications/coredns-config`.

CoreDNS is not currently in the GitOps repo (cluster-default install). We
introduce a thin Kustomize app that owns a single ConfigMap patch overlaying
the existing `coredns` ConfigMap in `kube-system`.

Rewrite line to add to the `Corefile` data inside the `.:53 { ... }` block:

```
rewrite name backup-storage.vngenterprise.com backup-storage.netbird-client.svc.cluster.local
```

The patch is scoped to a single hostname; all other DNS behavior is unchanged.
After the patch is applied, CoreDNS reloads automatically (Kubernetes-managed
CoreDNS watches its ConfigMap).

ArgoCD application for the new path:

- `applications/coredns-config/overlays/use1/` (kustomize patch)
- `argocd/applications/use1/coredns-config.yaml` (ArgoCD `Application`)
- Sync wave ordering: must apply before `longhorn` sync so the first backup
  target poll resolves correctly. Set
  `argocd.argoproj.io/sync-wave: "-10"`.

## 7. Longhorn changes

All edits in `applications/longhorn/`.

### 7.1 Re-enable `defaultBackupStore` in `overlays/use1/values.yaml`

Replace the commented R2 block with:

```yaml
defaultBackupStore:
  backupTarget: s3://longhorn-use1@us-east-1/
  backupTargetCredentialSecret: longhorn-backup-storage
  pollInterval: 300
```

The `@us-east-1` region suffix is required by the AWS SDK signature flow and
ignored by rustfs.

### 7.2 Rename ExternalSecret to `longhorn-backup-storage`

`overlays/use1/external-secrets.yaml` becomes:

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
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: "longhorn/backup-storage"
        property: "AWS_SECRET_ACCESS_KEY"
    - secretKey: AWS_ENDPOINTS
      remoteRef:
        key: "longhorn/backup-storage"
        property: "AWS_ENDPOINTS"
```

The old `longhorn-backup-r2` ExternalSecret is removed in the same change.

### 7.3 Re-enable recurring backup jobs

Edit `base/jobs/kustomization.yaml` to re-enable:

- `backup-6.yaml` — hourly (cron `0 * * * *`), retain 24 (existing schedule preserved; filename predates the schedule tuning)
- `backup-daily.yaml` — daily at 00:00, retain 7
- `backup-weekly.yaml` — weekly on Sunday at 00:00, retain 4
- `backup-monthly.yaml` — monthly on the 1st at 00:00, retain 4
- `system-backup-24.yaml` — full system backup daily at 02:15, retain 14

Rename the recurring job names from `r2-backup-*` → `backup-*` inside the YAMLs
to drop the now-obsolete R2 prefix. The `default` group selector remains
unchanged and continues to target every volume that opts into the
`default` recurring-job group.

### 7.4 Sanity-check `default-recurring-job.yaml`

Confirm the Longhorn `Setting` resource still references the `default` group
selector and does not pin to the old `r2-backup-*` names. (Current contents:
`allow-recurring-job-while-volume-detached: "true"`. No rename impact.)

## 8. Component boundaries & responsibilities

| Component | Owns | Communicates via |
| --- | --- | --- |
| rustfs (remote DC) | Bucket, IAM policy, scoped service account, TLS cert | HTTPS:443 over NetBird |
| Vault `longhorn/backup-storage` | Credentials, endpoint URL | External Secrets Operator |
| ExternalSecret `longhorn-backup-storage` | Materializes K8s Secret in `longhorn-system` | Vault read |
| `netbird-client` StatefulSet | NetBird mesh participation + S3 TCP forward | WireGuard out, ClusterIP in |
| Service `backup-storage.netbird-client.svc` | Load-balanced cluster-internal S3 endpoint | kube-proxy |
| CoreDNS rewrite | Hostname → Service mapping | DNS |
| Longhorn `defaultBackupStore` | Backup target wiring | K8s Secret + S3 |
| Longhorn `RecurringJob` resources | Schedule + retention | Longhorn engine |

Each unit is independently testable: rustfs reachability without Longhorn,
sidecar reachability without rustfs creds, CoreDNS rewrite without backups,
backup target health without recurring jobs.

## 9. Verification plan

After ArgoCD syncs the changes, in this order:

1. `kubectl -n netbird-client get pods` — all three pods Ready 2/2.
2. From a sidecar:
   ```bash
   kubectl -n netbird-client exec netbird-client-0 -c s3-forward -- \
     nc -zv backup-storage.vngenterprise.com 443
   ```
   Expect connection success.
3. CoreDNS rewrite:
   ```bash
   kubectl -n longhorn-system run dns-test --rm -it --image=busybox \
     --restart=Never -- nslookup backup-storage.vngenterprise.com
   ```
   Should return the ClusterIP of `backup-storage.netbird-client.svc`.
4. Longhorn UI → Backup → BackupTarget shows healthy / no errors.
5. Manual backup of a small test PVC; confirm objects land in the
   `longhorn-use1` bucket.
6. Wait for first scheduled `backup-6` run; confirm successful run in
   Longhorn UI and bucket objects.

## 10. Rollout order

1. **rustfs side (operator):** create bucket, policy, key.
2. **Vault (operator):** write `longhorn/backup-storage`.
3. **Repo PRs (this design):**
   1. `applications/netbird/overlays/use1-clients` — sidecar + Service.
   2. `applications/coredns-config` — new app + Argo `Application`.
   3. `applications/longhorn/overlays/use1` + `base/jobs` — values, secret
      rename, recurring jobs.
4. **ArgoCD syncs** (auto). The sync-wave on `coredns-config` ensures DNS is
   rewritten before Longhorn first polls.
5. **Verification (§9).**

## 11. Failure modes & mitigations

| Failure | Symptom | Mitigation |
| --- | --- | --- |
| Sidecar pod restart | Brief connection refused during pod recreation | Other 2/3 endpoints carry traffic; Longhorn retries backup poll. |
| `backup-storage.vngenterprise.com` DNS change on NetBird side | Sidecar starts but upstream connects fail | Each pod restart re-resolves via socat. Persistent failure surfaces in Longhorn UI within `pollInterval` (5 min). |
| Vault unreachable | ExternalSecret stale; existing Secret content remains valid until rotated | Longhorn keeps using last-known creds; alert via ESO metrics. |
| CoreDNS rewrite removed by accident | Longhorn loses backup target | Rewrite is GitOps-owned in `applications/coredns-config`; ArgoCD self-heal restores. |
| rustfs bucket deleted | Backups fail with NoSuchBucket | Detected at next poll, surfaces in Longhorn UI. Operator action required. |

## 12. Risks acknowledged

- **CoreDNS is cluster-wide.** The rewrite is hostname-scoped so blast radius
  is one DNS name, but the patched ConfigMap is shared infra.
- **`rustfs/rustfs:latest`** image tag (in the in-cluster rustfs at
  `applications/rustfs`) is not pinned. Unrelated to this change; flagged here
  to avoid being forgotten.
- **No backup encryption-at-rest.** rustfs storage + WireGuard tunnel are the
  only protections. Add `CRYPTO_KEY_*` to the credential secret in a follow-up
  if at-rest encryption is required.

## 13. Open items deferred

- Encryption-at-rest for backups.
- Cross-cluster restore drill / runbook.
- rustfs image pinning.
