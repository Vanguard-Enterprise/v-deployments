# LGTMP Monitoring Stack Rollout — Design

**Status:** Approved (design)
**Date:** 2026-05-14
**Cluster:** `use1`
**Owner:** Platform (Frank Dobrovolny)

---

## 1. Goal

Deploy a full LGTMP observability stack (Loki, Grafana, Tempo, Mimir, Pyroscope) into the `use1` cluster, fully managed via the existing ArgoCD + Kustomize + Helm GitOps pattern, with all bulk storage on offsite S3 (`https://backup-storage.vngenterprise.com`, reached over netbird) and minimal local Longhorn footprint.

In the same change, decommission residual Hyplex resources and replace the old single-pod in-cluster S3 (`hyplex-rustfs`) with a new 3-node rustfs cluster in a non-Hyplex-named namespace.

## 2. Constraints & decisions

| Topic | Decision |
|---|---|
| Signals | Metrics, Logs, Traces, Profiles (full LGTMP) |
| Deployment mode | Monolithic / single-binary across the board (Mimir `target=all`, Loki `SingleBinary`, Tempo monolithic, Pyroscope single-binary). Future migration to distributed is allowed when the cluster grows. |
| Bulk storage | Offsite S3 over netbird (`https://backup-storage.vngenterprise.com`), one bucket per signal |
| Local storage philosophy | Keep small; remote can be beefy |
| Tenancy | Single tenant per signal (`metrics`, `logs`, `traces`, `profiles`) |
| Retention | Short / cheap profile — Metrics 14d, Logs 7d, Traces 3d, Profiles 7d |
| Grafana auth | Zitadel OIDC SSO |
| Grafana ingress | Internal-only (`traefik-internal`, netbird required) |
| Grafana DB | CNPG Postgres, `instances: 1` |
| Dashboards / alerts / datasources | Grafana sidecar discovery via labelled ConfigMaps |
| Alerting | Grafana Unified Alerting (no Mimir alertmanager, no separate Alertmanager pod) |
| Alert routing | Label-based per team — `discord-platform`, `discord-rustlens`, `discord-vanguard`, plus disabled stubs for email/slack/pagerduty |
| Collector layout | Three Alloy workloads — `alloy-metrics` (DS, existing), `alloy-logs` (DS, new), `alloy-receiver` (StS ×2, new) |
| Hot caches | Memcached pods (in-memory) for Mimir/Loki/Tempo; not on rustfs |
| New rustfs | 3-node StatefulSet in namespace `rustfs` on `rustfs.vngenterprise.com`, general-purpose (NOT for monitoring data), 3 × 10 GiB on `longhorn-single` SC |

## 3. Architecture overview

```
                            ┌────────────────────────────────────────┐
   workloads ──── metrics ─→│ alloy-metrics (DS)  ─── remote_write ──┼─→ Mimir (monolithic)   ─→ S3: monitoring-mimir-use1
                            │                                        │                          + monitoring-mimir-ruler-use1
   pod stdout ──── logs ───→│ alloy-logs (DS)     ─── loki push ─────┼─→ Loki  (SingleBinary)  ─→ S3: monitoring-loki-use1
                            │                                        │
   OTLP /                   │ alloy-receiver (StS, 2 replicas)       │
   profiles  ──── traces ──→│   OTLP + tempo push + pyro push ───────┼─→ Tempo (monolithic)    ─→ S3: monitoring-tempo-use1
                            │                                        │
                            │                                        └─→ Pyroscope (single)    ─→ S3: monitoring-pyroscope-use1
                            └────────────────────────────────────────┘
                                                                            ▲
                                                                            │ queries
                            ┌────────────────────────────────────────┐     │
            Zitadel OIDC ──→│ Grafana (HA=1, CNPG-backed)            │─────┘
                            │   sidecar discovers dashboards /       │
                            │   datasources / alerts from ConfigMaps │
                            │   unified alerting → Discord per team  │
                            └────────────────────────────────────────┘
                                          ▲
                                 traefik-internal (netbird only)
```

### Namespaces

Existing kept: `mimir`, `alloy-metrics`, `monitoring` (kube-state-metrics stays here).
Existing deleted: `hyplex-rustfs`.
New: `loki`, `tempo`, `pyroscope`, `grafana`, `alloy-logs`, `alloy-receiver`, `rustfs`.

### ArgoCD applications

New under `argocd/applications/use1/`: `mimir.yaml`, `loki.yaml`, `tempo.yaml`, `pyroscope.yaml`, `grafana.yaml`, `cnpg-grafana.yaml`, `alloy-metrics.yaml`, `alloy-logs.yaml`, `alloy-receiver.yaml`, `monitoring-buckets.yaml`, `rustfs-cluster.yaml`.
Deleted: `rustfs.yaml` (and any agones / life Applications if present).
All apps: `automated: { prune: true, selfHeal: true }`, `syncOptions: [ApplyOutOfSyncOnly=true]` — same pattern as the existing apps.

## 4. Component sizing

| Component | Mode | Replicas | CPU req/lim | Mem req/lim | Local PVC | SC |
|---|---|---|---|---|---|---|
| Mimir | monolithic (`target=all`) | 1 StS | 200m / 1 | 1Gi / 3Gi | 10Gi WAL+compactor | `longhorn` (2-rep) |
| Loki | SingleBinary | 1 StS | 200m / 1 | 1Gi / 3Gi | 10Gi WAL+boltdb-shipper | `longhorn` (2-rep) |
| Tempo | monolithic | 1 StS | 100m / 500m | 512Mi / 2Gi | 10Gi WAL | `longhorn-single` |
| Pyroscope | single-binary | 1 StS | 100m / 500m | 512Mi / 2Gi | 10Gi WAL | `longhorn-single` |
| Grafana | single | 1 Dep | 100m / 500m | 256Mi / 1Gi | — | — |
| CNPG `grafana-db` | Postgres | `instances: 1` | 100m / 500m | 256Mi / 1Gi | 2Gi | `longhorn` (2-rep) |
| alloy-metrics | DS (existing) | one per node | 100m / 500m | 256Mi / 1Gi | — | — |
| alloy-logs | DS | one per node | 100m / 500m | 256Mi / 1Gi | 1Gi positions | `longhorn-single` |
| alloy-receiver | StS | 2 | 100m / 500m | 256Mi / 1Gi | — | — |
| Memcached (per cache) | Deployment | 1 each | 50m / 200m | 128Mi / 512Mi | — | — |

Memcached instances: `mimir-chunks-cache`, `mimir-index-cache`, `mimir-results-cache`, `loki-chunks-cache`, `loki-results-cache`, `tempo-bloom-cache`. Roughly 6 pods, ~3 GiB total RAM, no persistent storage.

## 5. Storage layout

### Offsite S3 (bulk)

| Bucket | Holds | Lifecycle |
|---|---|---|
| `monitoring-mimir-use1` | TSDB blocks | Expire after 30d (covers 14d retention + safety) |
| `monitoring-mimir-ruler-use1` | Recording/alerting rules + alertmanager state | No expiry |
| `monitoring-loki-use1` | Log chunks + boltdb-shipper index | Expire after 14d |
| `monitoring-tempo-use1` | Trace blocks | Expire after 7d |
| `monitoring-pyroscope-use1` | Profile blocks | Expire after 14d |
| `cnpg-grafana-use1` | CNPG basebackups + WAL | Per CNPG defaults |

Retention is enforced *primarily* by each application's compactor; S3 lifecycle is a safety net at ~2× retention.

### Vault keys (one per signal)

```
secret/monitoring/mimir        → AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
                                  AWS_ENDPOINTS, TSDB_BUCKET_NAME, RULER_BUCKET_NAME
secret/monitoring/loki         → AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
                                  AWS_ENDPOINTS, BUCKET_NAME
secret/monitoring/tempo        → (same shape)
secret/monitoring/pyroscope    → (same shape)
secret/monitoring/bucket-admin → admin creds used by the bucket-bootstrap Jobs
secret/monitoring/grafana-alerting → DISCORD_PLATFORM_WEBHOOK, DISCORD_RUSTLENS_WEBHOOK,
                                     DISCORD_VANGUARD_WEBHOOK, stubs for slack/email/pagerduty
secret/grafana/oidc            → CLIENT_ID, CLIENT_SECRET for Zitadel
secret/rustfs/cluster          → root access key / secret for the new rustfs cluster
```

All ExternalSecrets use the existing `vault-backend` ClusterSecretStore.

### Local storage strategy

| PVC group | Storage class | Replicas | Rationale |
|---|---|---|---|
| Mimir WAL, Loki WAL, CNPG `grafana-db` | `longhorn` | 2 | Diagnosis-critical or hard-to-rebuild state |
| Tempo WAL, Pyroscope WAL, alloy-logs positions | `longhorn-single` | 1 | Cheap-to-lose / short-flush data |
| Rustfs PVCs (3 × 10 GiB) | `longhorn-single` | 1 | Rustfs erasure coding provides redundancy across pods |

A new StorageClass `longhorn-single` is added in Phase 1 (`numberOfReplicas: "1"`, `dataLocality: best-effort`, `staleReplicaTimeout: "30"`, `allowVolumeExpansion: true`).

**Total local Longhorn consumption (new):** ~70 GiB physical for monitoring WAL + Grafana DB; ~30 GiB physical for new rustfs.

## 6. Data flow

### Metrics
```
workload pod ──[/metrics]──► alloy-metrics (DS, this node)
                                 │ scrape, drop high-cardinality labels
                                 ▼ remote_write to http://mimir-nginx.mimir.svc/api/v1/push (X-Scope-OrgID: metrics)
                             Mimir distributor → ingester (WAL on PVC)
                                 │ every 1h block flush
                                 ▼
                             S3: monitoring-mimir-use1
                                 │
                             compactor (every 1h) ──► dedupe / merge / 14d retention
                                 │
                             Grafana (datasource: Mimir, tenant=metrics)
```

Sources scraped: kubelet, cAdvisor, kube-state-metrics, ServiceMonitors/PodMonitors labelled `instance: primary`. ServiceMonitor discovery is already configured in the current Alloy scaffold and is kept as-is.

### Logs
```
/var/log/pods/*/*.log ──► alloy-logs (DS, this node)
                            │ parse pod/namespace/container, drop kube-system noise
                            ▼ loki.write to http://loki.loki.svc:3100/loki/api/v1/push (X-Scope-OrgID: logs)
                          Loki ingester (WAL on PVC) ──► chunks to S3 (boltdb-shipper)
                            │
                          compactor ──► 7d retention
                            │
                          Grafana (datasource: Loki, tenant=logs)
```

### Traces
```
app (OTel SDK) ──[OTLP gRPC :4317 / HTTP :4318]──► alloy-receiver (StS, ClusterIP svc)
                                                      │ otelcol.exporter
                                                      ▼ http://tempo.tempo.svc:4317 (X-Scope-OrgID: traces)
                                                  Tempo ingester ──► blocks to S3 ──► 3d retention
                                                      │
                                                  Grafana (datasource: Tempo, tenant=traces)
```

### Profiles
```
app (Pyroscope SDK or eBPF) ──► alloy-receiver
                                  │ pyroscope.write
                                  ▼ http://pyroscope.pyroscope.svc:4040/ingest (X-Scope-OrgID: profiles)
                                Pyroscope ──► blocks to S3 ──► 7d retention
                                  │
                                Grafana (datasource: Pyroscope, tenant=profiles)
```

### Cross-signal correlation

- **Logs ↔ Traces:** Loki datasource `derivedFields` extracts `trace_id` → link to Tempo
- **Traces ↔ Logs:** Tempo datasource `tracesToLogsV2` jumps from span → filtered Loki logs (same pod/timeframe)
- **Traces ↔ Metrics:** Tempo datasource `tracesToMetrics` links span → RED metrics window
- Tempo `metrics-generator` stays disabled in phase 1 — correlation works without it.

### App-side integration

| Signal | What workloads must do |
|---|---|
| Metrics | Add a `ServiceMonitor` / `PodMonitor` with label `instance: primary` |
| Logs | Nothing — anything writing to stdout/stderr is picked up automatically |
| Traces | Point OTel SDK exporter at `alloy-receiver.alloy-receiver.svc.cluster.local:4317` |
| Profiles | Point Pyroscope SDK at `alloy-receiver.alloy-receiver.svc.cluster.local:4040` |

## 7. Alerting & dashboards as code

### Mechanism

Grafana's Helm chart sidecar watches the cluster for ConfigMaps and provisions their contents into Grafana:

| Label | Provisions |
|---|---|
| `grafana_datasource=1` | Datasources |
| `grafana_dashboard=1` | Dashboard JSON |
| `grafana_alert=1` | Alert rule groups, contact points, notification policies |

Datasources are marked `editable: false` in provisioning — the only way to change one is a git commit.

### Datasources

One ConfigMap at `applications/grafana/overlays/use1/vanguard/datasources.configmap.yaml`:

- **Mimir** → `http://mimir-nginx.mimir.svc/prometheus`, header `X-Scope-OrgID: metrics`
- **Loki** → `http://loki.loki.svc:3100`, header `X-Scope-OrgID: logs`, `derivedFields` for `trace_id` → Tempo
- **Tempo** → `http://tempo.tempo.svc:3200`, header `X-Scope-OrgID: traces`, `tracesToLogsV2` → Loki, `tracesToMetrics` → Mimir
- **Pyroscope** → `http://pyroscope.pyroscope.svc:4040`, header `X-Scope-OrgID: profiles`

### Alert routing (per-team)

Every alert rule carries `team` and optionally `service` labels. Notification policies route by `team`.

| Contact point | Vault key | Owns |
|---|---|---|
| `discord-platform` | `monitoring/grafana-alerting` → `DISCORD_PLATFORM_WEBHOOK` | Kubernetes / Longhorn / Traefik / ArgoCD / monitoring itself |
| `discord-rustlens` | `monitoring/grafana-alerting` → `DISCORD_RUSTLENS_WEBHOOK` | Rustlens services |
| `discord-vanguard` | `monitoring/grafana-alerting` → `DISCORD_VANGUARD_WEBHOOK` | Vanguard services |
| Stubs (disabled): `email-*`, `slack-*`, `pagerduty-critical` | Vault keys blank | Enable by populating Vault and uncommenting the route |

Notification-policy tree:

```
root (default) → discord-platform
├── team=rustlens          → discord-rustlens
│     └── severity=critical → discord-rustlens + pagerduty-critical (when enabled)
├── team=vanguard          → discord-vanguard
└── (no team label)        → discord-platform   # safety net
```

Defaults made explicit: `group_by: [alertname, namespace]`, `group_wait: 30s`, `group_interval: 5m`, `repeat_interval: 12h`.

### Alert rule ownership

| Path | Owner | `team` label |
|---|---|---|
| `applications/grafana/overlays/use1/vanguard/alerts/` | Platform | `platform` (cluster-level rules) |
| `applications/rustlens/overlays/use1/alerts.configmap.yaml` | Rustlens | `rustlens` |
| `applications/vanguard-*/overlays/use1/alerts.configmap.yaml` | Vanguard | `vanguard` |

The sidecar picks up `grafana_alert=1` ConfigMaps from anywhere in the cluster. Adding a new team = add contact point + route + service-side alerts ConfigMap, all in one PR.

### Day-one rule groups (platform-owned)

| Folder | Rules |
|---|---|
| `platform` | Node not ready, NodeMemoryPressure, NodeDiskPressure, Filesystem >85% used, kubelet down |
| `kubernetes` | Pod CrashLoopBackOff, PodPending >10m, DaemonSet rollout incomplete, Deployment replicas mismatch, PVC >90% used |
| `longhorn` | Volume degraded, backup failed, node disk pressure |
| `cnpg` | Replication lag, primary down, backup failed |
| `argocd` | App OutOfSync >30m, App Degraded |
| `traefik` | 5xx rate >1% / 5m, certificate <7d to expiry |
| `monitoring` | Mimir/Loki/Tempo ingester unhealthy, dropped scrapes, S3 push failures, bucket near-quota |

All rules start with `enabled: false` and are turned on one folder at a time during Phase 7 with a 1-hour soak between.

### Day-one dashboards (platform-owned)

`Kubernetes` (kubernetes-mixin: cluster/nodes/pods/deployments/statefulsets/PV/networking), `Longhorn`, `CNPG`, `Traefik`, `ArgoCD`, `Monitoring stack` (Mimir, Loki, Tempo, Pyroscope, Alloy health).

Service teams ship their own dashboards next to their service overlays with label `grafana_dashboard=1`.

## 8. Phase 0 — Hyplex teardown

### Delete
- `applications/rustfs/` (entire folder)
- `applications/life/` (entire folder)
- `applications/agones/` (entire folder)
- `applications/redis-operator/overlays/hyplex/` (entire folder; keep base + use1 overlays)
- `argocd/applications/use1/rustfs.yaml`
- Any ArgoCD apps for `agones`, `life` if present (verify with `kubectl get app -n argocd`)

### Keep
- `applications/cert-manager/overlays/use1/hyplex.gg.yaml` (cert still wanted)
- `applications/pelican/` (kept in repo, no ArgoCD app — dormant)
- `applications/netbird/overlays/use1-clients/s3-forward-config.yaml` (forwards to a remote endpoint, not the local rustfs)

### Verification
- `kubectl get ns` shows no `hyplex-*` namespaces
- `kubectl get pv` shows no Released volumes from deleted PVCs
- `kubectl get app -n argocd` shows no orphaned apps from this phase

## 9. Phase 0.5 — New rustfs cluster

New folder `applications/rustfs-cluster/` (different name from deleted `applications/rustfs/` to avoid git-history confusion):

- 3-replica StatefulSet, namespace `rustfs`
- PVCs: 3 × 10 GiB on `longhorn-single` (depends on Phase 1 providing the SC; Phase 0.5 can be merged but app won't be Healthy until Phase 1 lands)
- Erasure coding 2+1 across the 3 pods
- Two ingresses (mirroring the old shape):
  - `ingress-internal.yaml` via `traefik-internal` → `rustfs.vngenterprise.com`
  - `ingress-external.yaml` via `traefik` → same hostname
- ExternalSecret `rustfs-root` from Vault `rustfs/cluster`
- ArgoCD app `argocd/applications/use1/rustfs-cluster.yaml`

**Use cases (A1):** general-purpose cluster object store. NOT used for monitoring metrics/logs/traces/profiles — those go to offsite S3.

## 10. Phase 1 — Storage class & object-store prep

### `longhorn-single` StorageClass

Add to `applications/longhorn/overlays/use1/`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-single
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "30"
  fromBackup: ""
  dataLocality: "best-effort"
```

### Bucket-bootstrap Jobs

New `applications/monitoring-buckets/` kustomize app. Each bucket gets a `Job` that:

1. Uses `minio/mc:latest` image
2. Reads admin creds from ExternalSecret (Vault `monitoring/bucket-admin`)
3. `mc alias set offsite https://backup-storage.vngenterprise.com ...`
4. `mc mb --ignore-existing offsite/<bucket>`
5. `mc ilm import offsite/<bucket> < /etc/lifecycle/<bucket>.json`

Jobs are idempotent and re-runnable. Each downstream monitoring ArgoCD app declares an ArgoCD `Sync` wave so the buckets-app runs first.

**Buckets created:** `monitoring-mimir-use1`, `monitoring-mimir-ruler-use1`, `monitoring-loki-use1`, `monitoring-tempo-use1`, `monitoring-pyroscope-use1`, `cnpg-grafana-use1`.

## 11. Phase 2 — Mimir

Promote the existing `applications/mimir/overlays/use1/` scaffold from "scaffold" to "deployed":

- Add `argocd/applications/use1/mimir.yaml`
- Update `values.yaml`:
  - `target: all` (monolithic mode)
  - Single replica StS
  - Memcached caches enabled: `chunks-cache`, `index-cache`, `results-cache`
  - Tenant rename: `pods` → `metrics`
  - Compactor retention `14d`
  - WAL PVC stays on `longhorn` SC (2 replicas)

Verification: pod Ready 5 min, synthetic push via `curl` → query returns it, TSDB block lands in S3 within 1h.

## 12. Phase 3 — Alloy collectors

### Rename existing
- `applications/alloy/` → `applications/alloy-metrics/`
- Update `argocd/applications/use1/` filename to match

### New: `applications/alloy-logs/`
- DaemonSet, mounts `/var/log/pods` (RO) and `/var/lib/docker/containers` (RO)
- Config: `loki.source.kubernetes` discovers pods → `loki.process` parses → `loki.write` to `http://loki.loki.svc:3100/loki/api/v1/push` with `X-Scope-OrgID: logs`
- Drop `kube-system` noise by default (configurable allowlist)
- Positions file on `longhorn-single` 1 GiB PVC

### New: `applications/alloy-receiver/`
- StatefulSet, 2 replicas, ClusterIP service `alloy-receiver`
- Config: `otelcol.receiver.otlp` (gRPC :4317, HTTP :4318) → fan out:
  - traces → `otelcol.exporter.otlp` → `tempo.tempo.svc:4317` with `X-Scope-OrgID: traces`
  - profiles → `pyroscope.write` → `pyroscope.pyroscope.svc:4040/ingest` with `X-Scope-OrgID: profiles`

**Note on phase ordering:** `alloy-logs` is *built* in Phase 3 but only *deployed* after Phase 5 (Loki exists). `alloy-receiver` is built in Phase 3, deployed after Phase 6 (Tempo + Pyroscope exist). `alloy-metrics` deploys immediately after Phase 2.

## 13. Phase 4 — Grafana + CNPG

### `applications/cnpg-grafana/`
- `Cluster` CR with `instances: 1`
- Backup to S3 bucket `cnpg-grafana-use1` (via Phase 1 bootstrap)
- ExternalSecret for backup creds and superuser
- ArgoCD app `cnpg-grafana.yaml`

### `applications/grafana/overlays/use1/vanguard/`
- Promote to deployed with `argocd/applications/use1/grafana.yaml`
- Helm `grafana/grafana` chart
- Sidecar enabled with all four label classes
- `grafana.ini`:
  - `auth.generic_oauth` configured for Zitadel via OIDC discovery URL
  - `database` block pointing at `grafana-db-rw.cnpg-grafana.svc:5432`
- ExternalSecret `grafana-oidc` from Vault `grafana/oidc`
- ExternalSecret `grafana-db` from CNPG's generated app-user secret
- Ingress via `traefik-internal`, host `grafana.vngenterprise.com`, TLS via cert-manager
- Datasource ConfigMap initially contains only Mimir (others added in their phases)

Verification: CNPG `1/1`, Grafana pod Ready, OIDC login works, Mimir datasource green, test dashboard renders.

## 14. Phase 5 — Loki

`applications/loki/` (new):

- Helm `grafana/loki` chart
- `deploymentMode: SingleBinary`
- S3 backend via Vault-backed env (`monitoring/loki`)
- Tenant `logs`, retention 7d
- Memcached for `chunks-cache` and `results-cache`
- WAL on `longhorn` 10 GiB
- ArgoCD app

Then deploy `alloy-logs` from Phase 3. Add Loki to Grafana's datasource ConfigMap.

Verification: Loki Ready, alloy-logs DS rolled out on all 6 nodes, Grafana Explore query `{namespace="default"}` returns lines.

## 15. Phase 6 — Tempo + Pyroscope

### `applications/tempo/`
- Helm `grafana/tempo` chart, monolithic mode
- S3 backend (`monitoring/tempo`), tenant `traces`, retention 3d
- WAL on `longhorn-single` 10 GiB
- Memcached for bloom cache
- Metrics-generator disabled (phase 1)
- ArgoCD app

### `applications/pyroscope/`
- Helm `grafana/pyroscope` chart, single-binary
- S3 backend (`monitoring/pyroscope`), tenant `profiles`, retention 7d
- WAL on `longhorn-single` 10 GiB
- ArgoCD app

Deploy `alloy-receiver` from Phase 3. Add Tempo and Pyroscope to Grafana's datasource ConfigMap.

Verification: both pods Ready, debug pod can push an OTLP test span and a profile, both visible in Grafana within 60s.

## 16. Phase 7 — Alerts + dashboards bootstrap

### `applications/grafana/overlays/use1/vanguard/alerts/`

- `contact-points.configmap.yaml` — Discord channels + disabled stubs (`grafana_alert=1`)
- `notification-policies.configmap.yaml` — routing tree (`grafana_alert=1`)
- `rules-platform.configmap.yaml`, `rules-kubernetes.configmap.yaml`, `rules-longhorn.configmap.yaml`, `rules-cnpg.configmap.yaml`, `rules-argocd.configmap.yaml`, `rules-traefik.configmap.yaml`, `rules-monitoring.configmap.yaml` (`grafana_alert=1`)
- Each rule group ships with `enabled: false`; enable one folder at a time, 1 hour soak between.

### `applications/grafana/overlays/use1/vanguard/dashboards/`

- `kubernetes.configmap.yaml`, `longhorn.configmap.yaml`, `cnpg.configmap.yaml`, `traefik.configmap.yaml`, `argocd.configmap.yaml`, `monitoring-stack.configmap.yaml` (`grafana_dashboard=1`)

### Weekly heartbeat

```yaml
- alert: WeeklyHeartbeat
  expr: vector(1)
  for: 0s
  labels: { team: platform, severity: info }
  annotations: { summary: "Monitoring pipeline heartbeat" }
```

Muted by mute-timings except for one minute per week (Friday noon). Catches silent breakage of the entire alerting pipeline.

## 17. Repo layout

```
v-deployments/
├── applications/
│   ├── alloy-metrics/           # was: alloy/ (renamed)
│   ├── alloy-logs/              # NEW
│   ├── alloy-receiver/          # NEW
│   ├── mimir/                   # exists, promoted
│   ├── loki/                    # NEW
│   ├── tempo/                   # NEW
│   ├── pyroscope/               # NEW
│   ├── grafana/                 # exists, promoted
│   ├── cnpg-grafana/            # NEW
│   ├── monitoring-buckets/      # NEW (bucket-bootstrap Jobs)
│   ├── rustfs-cluster/          # NEW (replaces old applications/rustfs/)
│   ├── longhorn/                # exists — add longhorn-single SC
│   └── (deleted: rustfs/, life/, agones/, redis-operator/overlays/hyplex/)
└── argocd/applications/use1/
    ├── mimir.yaml               # NEW
    ├── loki.yaml                # NEW
    ├── tempo.yaml               # NEW
    ├── pyroscope.yaml           # NEW
    ├── grafana.yaml             # NEW
    ├── cnpg-grafana.yaml        # NEW
    ├── alloy-metrics.yaml       # NEW (no current ArgoCD app for alloy)
    ├── alloy-logs.yaml          # NEW
    ├── alloy-receiver.yaml      # NEW
    ├── monitoring-buckets.yaml  # NEW
    ├── rustfs-cluster.yaml      # NEW
    └── (deleted: rustfs.yaml)
```

## 18. Verification & rollback

### Per-phase done-check

| Phase | Verification |
|---|---|
| 0 | `kubectl get ns` shows no `hyplex-*`; ArgoCD shows no orphan apps; `kubectl get pv` shows no Released volumes from deleted PVCs |
| 0.5 | 3/3 rustfs pods Ready; `mc` from a debug pod can list buckets; create+delete a 1KB object round-trip |
| 1 | `kubectl get sc longhorn-single` exists; 6 buckets exist on offsite endpoint (`mc ls`); lifecycle rules applied |
| 2 | Mimir pod Ready 5 min; `curl` push synthetic sample → query returns it; TSDB block lands in S3 within 1h |
| 3 | Each node has `alloy-metrics` pod Ready; Mimir queries `up{job="kubelet"}` returns 6 nodes; cluster cardinality < 100k series |
| 4 | CNPG `1/1`; Grafana pod Ready; OIDC login works via Zitadel; Mimir datasource green; one test dashboard renders |
| 5 | Loki SingleBinary pod Ready; `alloy-logs` DS rolled out; Grafana Explore query `{namespace="kube-system"}` returns lines |
| 6 | Tempo + Pyroscope Ready; `alloy-receiver` accepts OTLP test span from a debug pod; trace appears in Grafana within 60s |
| 7 | Test alert with `team=platform` fires within 60s → Discord receives it; test alert with `team=rustlens` routes to rustlens contact point |

### Definition of done

- All 11 new ArgoCD apps Synced + Healthy
- `https://grafana.vngenterprise.com` (over netbird) logs in via Zitadel, all four datasources green
- Each datasource returns at least one query: metric for a kubelet, log for a kube-system pod, trace from a debug pod, profile from a debug pod
- At least one alert routes to `discord-platform` and at least one routes to a service-team channel
- Total local Longhorn consumption under 200 GiB across all monitoring + rustfs PVCs
- Weekly heartbeat alert has fired at least once on Discord

### Rollback strategy

Every phase is its own ArgoCD `Application` — rollback is `argocd app rollback <name>` or revert the git commit + sync.

| Risk | Mitigation |
|---|---|
| Hyplex teardown deletes something still referenced | Phase 0 lists exactly what's deleted; the netbird s3-forward-config stays; pelican stays in repo |
| Bucket-bootstrap Job fails (creds or netbird) | Job is idempotent and re-runnable; downstream apps stay OutOfSync until Job succeeds |
| Mimir scaffold promotion misconfigured | Pod CrashLoop → ArgoCD Degraded → no impact to anything else; rollback by deleting the new ArgoCD app |
| Alloy DaemonSets cause node memory pressure | Memory limits set; metrics DS is already running 66d under same limits — safe baseline. Logs DS rolls out node-by-node |
| Grafana datasource ConfigMap typo bricks dashboards | Datasources marked `editable: false` but errors surface in Grafana logs; sidecar reloads on next ConfigMap update |
| Alert flood on Day 1 | Each rule group starts `enabled: false`; enable one folder per hour |
| Tempo/Pyroscope WAL loss on node failure (1-replica SC) | Up to 5 min of traces or 1h of profiles lost — accepted tradeoff |

## 19. Out of scope (deferred)

- Distributed deployment modes (Mimir microservices, Loki SimpleScalable, Tempo distributed) — revisit when cluster grows
- Mimir alertmanager + ruler (separate from Grafana Unified Alerting) — only needed if rule-as-a-service requirements emerge
- Tempo metrics-generator — adds derived RED metrics from traces, defer until service teams adopt tracing
- Multi-tenant rollout (per-namespace tenant IDs) — single tenant per signal is sufficient today
- Memcached HA — single replica per cache; if a cache pod restarts, downstream component refills it
- Long-retention metrics (90d+) — bump retention configs when needed
- Tracing/profiling instrumentation of existing services — opt-in per service, not part of this rollout
