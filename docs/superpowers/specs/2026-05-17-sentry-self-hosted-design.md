# Sentry Self-Hosted Rollout — Design

**Status:** Approved (design)
**Date:** 2026-05-17
**Cluster:** `use1`
**Owner:** Platform (Frank Dobrovolny)

---

## 1. Goal

Stand up a self-hosted Sentry in the `use1` cluster — full feature set (errors, releases, performance, profiling, session replay, native crash symbolication, cron monitoring) — managed by the existing ArgoCD + Kustomize + Helm GitOps pattern, with identity provided by the existing Zitadel instance via SAML2 SSO.

UI is internal-only on netbird (`sentry.vngenterprise.com`); a separate public hostname (`s-metrics.vngenterprise.com`) exposes only the Relay ingest endpoint so browsers and external SDKs can submit events without exposing the admin UI.

Bulk blobs (attachments, source maps, release artifacts, replay recordings) live in the existing offsite S3 (`https://backup-storage.vngenterprise.com`) over netbird, mirroring the LGTMP storage pattern. ClickHouse + Kafka + Redis stay on local Longhorn with short retention.

## 2. Constraints & decisions

| Topic | Decision |
|---|---|
| Feature set | Errors + releases + performance + profiling + replays + symbolication + crons (all OSS-available features enabled) |
| Deployment mode | Community `sentry-kubernetes/charts` Helm chart, wrapped in `applications/sentry/{base,overlays/use1}` kustomize |
| Postgres | CNPG, `instances: 1`, mirrors `cnpg-grafana` |
| Redis | Existing `redis-operator` with a new `applications/redis-operator/overlays/sentry/` overlay (mirrors `redis-rustlens`) — RedisReplication + Sentinel |
| Kafka / Zookeeper | Chart-bundled (Bitnami), single broker, KRaft mode where chart supports it |
| ClickHouse | Chart-bundled, single replica |
| Memcached | Chart-bundled, single replica |
| Identity | Zitadel **SAML2** application (Sentry OSS does **not** support generic OIDC — that is a paid SaaS feature). One-time bootstrap in the Sentry org-settings UI, then enforced via `config.yml` flag. |
| Role mapping | SAML attribute → Sentry org role. Zitadel group `sentry_admin` → Sentry "Manager"; everyone else lands as "Member". |
| UI ingress | `sentry.vngenterprise.com` via `traefik-internal` (netbird required); TLS via cert-manager |
| Ingest ingress | `s-metrics.vngenterprise.com` via public `traefik`; TLS via cert-manager; routes only to the Relay Service |
| Event retention | 30d in ClickHouse for events, transactions, profiles, replays (Sentry `cleanup` nightly Job) |
| Filestore | S3 bucket `sentry-filestore-use1` on offsite endpoint, lifecycle expire 45d |
| Postgres backup | S3 bucket `cnpg-sentry-use1` (CNPG barman) |
| Local storage | `longhorn` (2-rep) only for CNPG; everything else on `longhorn-single` |
| Email | SMTP via Vault-backed creds (optional; used for password-reset / invite emails — most flows go through SAML) |
| Observability | PodMonitors → Mimir, stdout → Loki, Grafana dashboard + `rules-sentry.configmap.yaml` alerts routed to `discord-platform` |

## 3. Architecture overview

```
                 ┌─────────────────────────────────────────────────────┐
   public  ─────►│  traefik (public)                                    │
   browsers      │    s-metrics.vngenterprise.com  ──► sentry-relay svc │
   mobile        │                                                      │
                 └──────────────────────┬───────────────────────────────┘
                                        │ POST /api/<project>/envelope/
                                        ▼
                  ┌──────────────────────────────────────────┐
                  │  Relay (StS, 2 replicas)                 │   ← ingest only
                  │    project config cache → Kafka producer │
                  └──────────────────────────────────────────┘
                                        │
                                        ▼
   ┌─────────────────────────────┐   ┌────────────────────────────────────┐
   │ Kafka + Zookeeper           │ ◄─┤ ingest-consumer-events             │
   │  chart-bundled, 1 broker    │   │ ingest-consumer-transactions       │
   │  KRaft if chart supports    │   │ ingest-consumer-attachments        │
   └──────────────┬──────────────┘   │ ingest-consumer-replays            │
                  │                  │ ingest-profiles                    │
                  ▼                  │ post-process-forwarder             │
   ┌─────────────────────────────┐   │ snuba-consumers (errors, txn,      │
   │ Snuba (api / web)           │   │   replays, profiles, sessions)     │
   │  query layer over CH        │   │ worker, cron, cleanup              │
   └──────────────┬──────────────┘   └──────────────┬─────────────────────┘
                  │                                 │
                  ▼                                 ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │ ClickHouse (chart-bundled, 1 replica)                            │
   │   events / transactions / profiles / replays — 30d retention     │
   │   PVC: longhorn-single, 50 GiB                                   │
   └──────────────────────────────────────────────────────────────────┘

   ┌─────────────────────────────┐   ┌────────────────────────────────────┐
   │ sentry-web (Deployment)     │──►│ CNPG cluster `sentry-db` (1 inst.) │
   │   Django UI + GraphQL + API │   │   longhorn 2-rep, 5 GiB            │
   │ sentry-symbolicator (StS)   │   │   barman backup → cnpg-sentry-use1 │
   │ sentry-vroom (Deployment)   │   └────────────────────────────────────┘
   └──────────────┬──────────────┘
                  │
                  ▼
   ┌─────────────────────────────┐   ┌────────────────────────────────────┐
   │ Redis (redis-operator)      │   │ Filestore (S3 over netbird)        │
   │  RedisReplication: 3        │   │   bucket sentry-filestore-use1     │
   │  Sentinel: 3                │   │   attachments / source maps /      │
   │  longhorn-single, 2 GiB     │   │   release artifacts / replays      │
   └─────────────────────────────┘   │   lifecycle expire 45d             │
                                     └────────────────────────────────────┘
            ▲
            │ TLS, cert-manager
   ┌────────┴───────────┐
   │ traefik-internal   │  sentry.vngenterprise.com ──► sentry-web (UI)
   │ netbird only       │     Zitadel SAML2 SSO enforced
   └────────────────────┘
```

### Namespaces

| Namespace | Created by | Holds |
|---|---|---|
| `sentry` | new (this rollout) | Sentry chart resources (web, relay, snuba, ClickHouse, Kafka, Zookeeper, Memcached, all consumers + workers, Symbolicator, Vroom), the two IngressRoutes, all ExternalSecrets, plus the CNPG `Cluster` `sentry-db` (mirrors how `cnpg-grafana` lives in the `grafana` namespace) |
| `sentry-redis` | new | RedisReplication + Sentinel, ExternalSecret for redis password (mirrors `rustlens-redis` namespace from `redis-rustlens` overlay) |

### ArgoCD applications

New under `argocd/applications/use1/`:

- `cnpg-sentry.yaml` — points at `applications/cnpg-sentry/overlays/use1`, deploys into namespace `sentry`
- `redis-sentry.yaml` — points at `applications/redis-operator/overlays/sentry`, deploys into namespace `sentry-redis`
- `sentry.yaml` — points at `applications/sentry/overlays/use1`, deploys into namespace `sentry`

All three use the project standard: `automated: { prune: true, selfHeal: true }`, `syncOptions: [ApplyOutOfSyncOnly=true, CreateNamespace=true, ServerSideApply=true]`.

Sync order is enforced by ArgoCD sync waves: `cnpg-sentry` (wave 0) and `redis-sentry` (wave 0) before `sentry` (wave 1). Because the CNPG `Cluster` and the Sentry chart both live in the `sentry` namespace, `sentry-db-app` (CNPG-generated app-user secret) is referenced directly by the chart's `externalPostgresql.existingSecret` — no cross-namespace reflection needed.

## 4. Component sizing

| Component | Workload | Replicas | CPU req/lim | Mem req/lim | PVC | SC |
|---|---|---|---|---|---|---|
| sentry-web | Deployment | 2 | 200m / 1 | 512Mi / 2Gi | — | — |
| sentry-relay | StatefulSet | 2 | 200m / 1 | 256Mi / 1Gi | 2Gi (project config cache) | `longhorn-single` |
| sentry-worker | Deployment | 2 | 200m / 1 | 512Mi / 2Gi | — | — |
| sentry-cron | Deployment | 1 | 50m / 200m | 128Mi / 512Mi | — | — |
| sentry-ingest-consumer-* | Deployment (one per topic) | 1 each | 100m / 500m | 256Mi / 1Gi | — | — |
| sentry-post-process-forwarder | Deployment | 1 | 100m / 500m | 256Mi / 1Gi | — | — |
| sentry-snuba-api | Deployment | 1 | 100m / 500m | 256Mi / 1Gi | — | — |
| sentry-snuba-consumer-* | Deployment (one per dataset) | 1 each | 100m / 500m | 256Mi / 1Gi | — | — |
| sentry-symbolicator | StatefulSet | 1 | 200m / 1 | 512Mi / 2Gi | 5Gi cache | `longhorn-single` |
| sentry-vroom | Deployment | 1 | 100m / 500m | 256Mi / 1Gi | — | — |
| ClickHouse | StatefulSet | 1 | 500m / 2 | 2Gi / 8Gi | 50Gi | `longhorn-single` |
| Kafka | StatefulSet | 1 | 300m / 1 | 1Gi / 4Gi | 20Gi | `longhorn-single` |
| Zookeeper (if not KRaft) | StatefulSet | 1 | 100m / 500m | 256Mi / 1Gi | 5Gi | `longhorn-single` |
| Memcached | Deployment | 1 | 50m / 200m | 256Mi / 512Mi | — | — |
| Redis (`redis-sentry`) | RedisReplication + Sentinel | 3 + 3 | 50m / 200m | 128Mi / 512Mi | 2Gi each | `longhorn-single` |
| CNPG `sentry-db` | Postgres | 1 | 100m / 500m | 256Mi / 1Gi | 5Gi | `longhorn` (2-rep) |

**Total local Longhorn footprint:** ~100 GiB physical (50 ClickHouse + 20 Kafka + 5 Zookeeper + 6 Redis + 5 CNPG ×2 + 2 Relay ×2 + 5 Symbolicator).

## 5. Storage layout

### Offsite S3 buckets (bulk)

| Bucket | Holds | Lifecycle |
|---|---|---|
| `sentry-filestore-use1` | Attachments, source maps, release artifacts, replay recordings | Expire after 45d (covers 30d retention + safety) |
| `cnpg-sentry-use1` | CNPG basebackups + WAL for `sentry-db` | Per CNPG defaults (`retentionPolicy: 14d`) |

Both buckets are reached via `https://backup-storage.vngenterprise.com` over netbird, same pattern as monitoring buckets. The `monitoring-buckets` Job from the LGTMP rollout is extended (or a new `sentry-buckets` Job is added) to create these two buckets and apply lifecycle.

### Vault keys

```
secret/sentry/web              → SECRET_KEY (Django), SENTRY_OPTIONS_SYSTEM_ADMIN_EMAIL
secret/sentry/filestore        → AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
                                  AWS_ENDPOINTS, BUCKET_NAME
secret/sentry/saml             → IDP_SSO_URL, IDP_ENTITY_ID, IDP_X509_CERT
                                  (populated in Phase 3, after Zitadel SAML app is created)
secret/sentry/smtp             → host, port, user, password, from_email (optional)
secret/sentry/clickhouse       → password for the `sentry` and `default` users
secret/sentry/kafka            → SASL creds (only if chart-bundled Kafka is configured with auth)
secret/cnpg/sentry             → CNPG superuser
secret/cnpg/sentry/backup      → AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY for cnpg-sentry-use1
secret/redis/sentry            → password for redis-replication
```

All ExternalSecrets reference the existing `vault-backend` ClusterSecretStore.

### Local storage strategy

| PVC group | StorageClass | Replicas | Rationale |
|---|---|---|---|
| CNPG `sentry-db` | `longhorn` | 2 | Auth + project + alert metadata; expensive to lose |
| ClickHouse, Kafka, Zookeeper, Redis, Relay cache, Symbolicator cache | `longhorn-single` | 1 | Event data is short-retention; blob durability lives in S3; cache PVCs rebuild on restart |

## 6. Data flow

### Event ingest (browsers + backends)

```
SDK ──[ HTTPS, DSN https://<key>@s-metrics.vngenterprise.com/<project> ]──►
   public traefik
      │ Host == s-metrics.vngenterprise.com
      ▼
   IngressRoute (sentry namespace) ──► svc/sentry-relay:3000
      │ Relay validates project key, rate-limits, scrubs PII
      ▼
   Kafka topic (events / transactions / attachments / replays / profiles)
      │
      ▼
   ingest-consumer-<topic> ──► Snuba consumer ──► ClickHouse INSERT
                                        │
                                        ▼
                                  post-process-forwarder
                                        │  (rule engine, alerts, issue grouping)
                                        ▼
                                  CNPG sentry-db
                                  (issue/event metadata,
                                   alerts state, releases)
```

### UI / API (humans)

```
browser on netbird ──[ https://sentry.vngenterprise.com ]──►
   traefik-internal
      │
      ▼
   IngressRoute ──► svc/sentry-web:9000 (Django)
      │  unauthenticated → 302 to Zitadel SAML SSO endpoint
      ▼
   Zitadel SAML2 IdP ──► returns signed SAML assertion ──► sentry-web /saml/acs/
      │  session cookie set
      ▼
   Sentry queries Snuba (events) + CNPG (metadata) + Redis (cache)
      + S3 (attachments / source maps / replay recordings on demand)
```

### Filestore reads (source-map / replay playback / attachment download)

```
sentry-web ──► boto3-style S3 call ──[ over netbird ]──► backup-storage.vngenterprise.com/sentry-filestore-use1/<key>
```

### App-side integration

| Source | What workloads must do |
|---|---|
| Backend services (Go, Python, Node) | Add Sentry SDK, set `SENTRY_DSN=https://<key>@s-metrics.vngenterprise.com/<project>` env var |
| Browser apps (Rustlens frontend, mancini-beer, others) | Include `@sentry/browser` (or framework wrapper), point at `s-metrics.vngenterprise.com` DSN, ensure CSP/CORS allow the host |
| Source map upload (CI) | `sentry-cli` or build-plugin uploads release artifacts to `sentry.vngenterprise.com` (UI host, since this is admin API) — CI runners must be on netbird OR the API hostname needs a separate public IngressRoute (defer; CI on netbird is simpler) |

## 7. Zitadel integration

### Why SAML2, not OIDC

Sentry OSS supports a small set of auth providers (`saml2`, `google`, `github`, `azuredevops`). **Generic OIDC is a paid SaaS-only feature.** Therefore Sentry talks to Zitadel via SAML2.

Zitadel ships full SAML2 IdP support, so this is a clean integration on Zitadel's side too.

### Setup sequence

1. **In Zitadel admin console** (`accounts.vngenterprise.com`):
   - Create a new **SAML** application under the existing Vanguard project (peer of the existing Grafana OIDC app)
   - Name: `sentry-vng`
   - ACS URL: `https://sentry.vngenterprise.com/saml/acs/`
   - Entity ID: `https://sentry.vngenterprise.com/saml/metadata/`
   - NameID format: `email`
   - Add attribute mappings:
     - `email` → `Email`
     - `first_name` → `FirstName`
     - `last_name` → `LastName`
     - `groups` → `Groups` (multi-valued)
   - Create two Zitadel groups if they don't already exist: `sentry_admin`, `sentry_user`
   - Grant the Vanguard org access to the app

2. **Export from Zitadel:**
   - SSO endpoint URL
   - IdP Entity ID
   - IdP X.509 signing certificate

3. **Store in Vault** under `secret/sentry/saml` (keys `IDP_SSO_URL`, `IDP_ENTITY_ID`, `IDP_X509_CERT`).

4. **In Sentry config** (`overlays/use1/values.yaml`, mounted into `config.yml`):
   ```yaml
   config:
     configYml:
       auth.providers.saml2.enabled: true
       auth.allow-registration: false
       auth.idp.metadata.url: ""              # using explicit fields instead
   ```
   Sentry's `config.yml` does not directly hold per-IdP SAML fields; those are configured per organization through the SSO setup page in the UI, but the fields are populated from environment variables exported by `envFromSecrets: [sentry-saml]`. The SSO setup screen in the Sentry org-settings UI is run once by an admin user (Phase 3) using the Vault values as input.

5. **Lock down local auth** after SAML is verified:
   ```yaml
   config:
     configYml:
       auth.allow-registration: false
   ```
   And in `sentry.conf.py`:
   ```python
   SENTRY_FEATURES["organizations:sso-saml2"] = True
   SENTRY_FEATURES["auth:register"] = False
   ```

### Role mapping

Sentry org roles available: `member`, `admin`, `manager`, `owner`. SAML attribute statements from Zitadel include `Groups`. Sentry's per-organization SSO setup screen lets admins map IdP groups to Sentry org roles:

| Zitadel group | Sentry role |
|---|---|
| `sentry_admin` | `manager` |
| `sentry_user` | `member` |
| (no group) | login denied (`require_link: true`) |

Bootstrap-time superuser (`SENTRY_OPTIONS_SYSTEM_ADMIN_EMAIL`) is a local account used only to configure the SAML provider for the first time. After Phase 3 verification, the local password is rotated and the account is kept only for emergency recovery (not used day-to-day).

## 8. Helm chart wiring

Helm release name: `sentry`. Chart: `sentry-kubernetes/sentry`. Pinned to a specific chart version in `kustomization.yaml` via `helmCharts:`.

### `applications/sentry/base/`

- `namespace.yaml` (namespace `sentry`)
- `kustomization.yaml` with `helmCharts:` block, pinned version, base values file
- `values.yaml` (chart defaults that apply to all overlays — almost everything stays in overlay)

### `applications/sentry/overlays/use1/`

- `kustomization.yaml` — `resources: [../../base, ...overlay files]`, plus chart value overlay
- `values.yaml` — feature-flag enables, replica counts, resources, dependency disables (Postgres, Redis), `externalPostgresql` block pointing at `sentry-db-rw.cnpg-sentry.svc:5432`, `externalRedis` block pointing at `redis-sentinel.redis-sentry.svc:26379`, `filestore` block configured for S3
- `external-secret-saml.yaml` — pulls `secret/sentry/saml` from Vault
- `external-secret-filestore.yaml` — pulls `secret/sentry/filestore`
- `external-secret-smtp.yaml` — pulls `secret/sentry/smtp`
- `external-secret-web.yaml` — pulls `secret/sentry/web` (SECRET_KEY etc.)
- `external-secret-clickhouse.yaml` — pulls `secret/sentry/clickhouse`
- `external-secret-redis.yaml` — pulls `secret/redis/sentry` (so chart's `externalRedis.existingSecret` points at it)
- (no `external-secret-cnpg-app.yaml` needed — CNPG generates `sentry-db-app` in the same `sentry` namespace; the chart references it directly via `externalPostgresql.existingSecret`)
- `sentry.vngenterprise.com.yaml` — Traefik `IngressRoute` on `traefik-internal`, TLS via cert-manager
- `s-metrics.vngenterprise.com.yaml` — Traefik `IngressRoute` on public `traefik`, TLS via cert-manager, routes only `/api/<project>/envelope/`, `/api/<project>/store/`, `/api/<project>/security/`, `/api/<project>/minidump/` paths to `sentry-relay`
- `podmonitors.yaml` — PodMonitor resources for sentry-web, sentry-relay, sentry-worker, kafka, clickhouse, snuba (each component exposes Prometheus metrics on a known port — chart documents these)

### Key `values.yaml` knobs (overlay)

```yaml
# disable bundled persistence backends — we own them
postgresql:
  enabled: false
externalPostgresql:
  host: sentry-db-rw.sentry.svc.cluster.local
  port: 5432
  database: sentry
  username: sentry
  existingSecret: sentry-db-app          # CNPG-generated, replicated into sentry ns
  existingSecretKey: password

redis:
  enabled: false
externalRedis:
  host: redis-sentinel.sentry-redis.svc.cluster.local
  port: 26379
  sentinel: true
  masterName: mymaster
  existingSecret: redis-sentry
  existingSecretKey: password

# bundled
kafka:
  enabled: true
  replicaCount: 1
  persistence: { size: 20Gi, storageClass: longhorn-single }
zookeeper:
  enabled: true                          # disabled iff chart supports KRaft and we opt in
  replicaCount: 1
  persistence: { size: 5Gi, storageClass: longhorn-single }
clickhouse:
  enabled: true
  replicas: 1
  persistence: { size: 50Gi, storageClass: longhorn-single }
memcached:
  enabled: true
  replicaCount: 1

# Sentry features
sentry:
  web:
    replicas: 2
    resources: { requests: { cpu: 200m, memory: 512Mi }, limits: { cpu: 1, memory: 2Gi } }
  worker:
    replicas: 2
  relay:
    replicas: 2
    persistence: { enabled: true, size: 2Gi, storageClass: longhorn-single }
  symbolicator:
    enabled: true
    replicas: 1
    persistence: { enabled: true, size: 5Gi, storageClass: longhorn-single }
  vroom:
    enabled: true

filestore:
  backend: s3
  s3:
    bucketName: sentry-filestore-use1
    endpointUrl: https://backup-storage.vngenterprise.com
    accessKey: "" # via env from external-secret-filestore
    secretKey: ""
    signatureVersion: s3v4
    addressingStyle: path

ingress:
  enabled: false                         # we manage IngressRoutes separately

config:
  configYml: |
    system.url-prefix: 'https://sentry.vngenterprise.com'
    system.internal-url-prefix: 'http://sentry-web.sentry.svc.cluster.local:9000'
    mail.host: '${SENTRY_SMTP_HOST}'
    mail.port: '${SENTRY_SMTP_PORT}'
    mail.username: '${SENTRY_SMTP_USER}'
    mail.password: '${SENTRY_SMTP_PASSWORD}'
    mail.from: '${SENTRY_SMTP_FROM}'
    auth.allow-registration: false
  sentryConfPy: |
    SENTRY_FEATURES['organizations:sso-saml2'] = True
    SENTRY_FEATURES['auth:register'] = False
    SENTRY_OPTIONS['system.event-retention-days'] = 30
```

## 9. Ingress

### `sentry.vngenterprise.com` (internal UI)

- `IngressRoute` on `traefik-internal`, entrypoint `websecure`
- `Match`: `Host(\`sentry.vngenterprise.com\`)`
- `Service`: `sentry-web` port 9000
- TLS: `cert-manager` `Certificate` for `sentry.vngenterprise.com`, ClusterIssuer `letsencrypt-cloudflare` (matches grafana pattern)
- DNS: CNAME to internal traefik LB IP (cloudflare-ddns app already handles internal records via the DNS-only flag)
- Sentry app itself enforces SAML2 SSO — the ingress is "open" but auth happens inside the app

### `s-metrics.vngenterprise.com` (public Relay ingest)

- `IngressRoute` on public `traefik`, entrypoint `websecure`
- `Match`:
  ```
  Host(`s-metrics.vngenterprise.com`) && (
    PathPrefix(`/api/`) ||
    PathRegexp(`^/api/[0-9]+/(envelope|store|security|minidump|attachment|unreal)/.*`)
  )
  ```
  Restricting paths means even if someone discovers the host, the admin UI and dashboards are unreachable. All non-ingest paths return 404 from Traefik (no upstream Service routed).
- `Service`: `sentry-relay` port 3000
- TLS: `cert-manager` `Certificate` for `s-metrics.vngenterprise.com`
- DNS: CNAME to public traefik LB IP
- Optional Traefik middleware: `RateLimit` (e.g., 100 req/s per source) — defer to Phase 5 hardening if abuse appears

### Why a separate hostname?

- Reduces attack surface on the dashboard (only people on netbird can even attempt to reach the UI)
- Avoids leaking that "sentry" runs here in DNS (less brand-obvious, marginal value)
- Lets us apply different middleware to ingest (rate limit, IP allowlists) without affecting humans on the UI

## 10. Observability (LGTMP integration)

### Metrics

PodMonitor per major component, all in the `sentry` namespace, label `instance: primary` so the existing `alloy-metrics` discovery picks them up:

| Component | Port | Path |
|---|---|---|
| sentry-web | 9000 | `/_health/` (custom metrics handler exposes Prometheus format on `/_metrics`) |
| sentry-relay | 3000 | `/metrics` |
| sentry-worker | 9000 | `/metrics` (celery exporter) |
| sentry-snuba-api | 1218 | `/metrics` |
| kafka | 7071 | `/metrics` (Bitnami chart enables JMX exporter) |
| clickhouse | 9363 | `/metrics` |
| zookeeper | 7000 | `/metrics` |

If a component doesn't expose Prometheus natively, ship a sidecar exporter (statsd-exporter for Sentry's statsd output is a known path).

### Logs

stdout from all pods → `alloy-logs` → Loki tenant `logs`. Useful queries:
- `{namespace="sentry"} |~ "ERROR"` — Sentry's own errors
- `{namespace="sentry", app="sentry-relay"} |~ "rate_limited"` — abuse on the public ingest

### Dashboards

New `applications/grafana/overlays/use1/vanguard/dashboards/files/sentry.json` covering:
- Web req/s + p95 latency
- Relay ingest rate (events/s, transactions/s, attachments/s)
- Kafka consumer lag per topic
- ClickHouse insert rate + disk usage
- Snuba query latency
- Postgres connections + slow queries (from CNPG metrics)
- Redis ops/s + memory

### Alerts

New `applications/grafana/overlays/use1/vanguard/alerts/rules-sentry.configmap.yaml`, label `grafana_alert=1`, routed via existing `team=platform` policy to `discord-platform`:

| Rule | Threshold |
|---|---|
| SentryWebDown | up{job="sentry-web"} == 0 for 5m |
| SentryRelayDown | up{job="sentry-relay"} == 0 for 5m |
| SentryKafkaConsumerLag | sum by (topic) (kafka_consumergroup_lag) > 10000 for 10m |
| SentryClickHouseDiskHigh | clickhouse_disk_used / clickhouse_disk_total > 0.8 |
| SentryClickHouseDown | up{job="clickhouse"} == 0 for 5m |
| SentryWeb5xx | rate(sentry_web_responses_total{status=~"5.."}[5m]) > 0.01 * rate(sentry_web_responses_total[5m]) |
| SentryEventsDropped | rate(sentry_events_dropped_total[5m]) > 0 for 10m |
| SentryRelayQueueDepth | sentry_relay_envelopes_queued > 5000 for 5m |
| SentryFilestoreS3Errors | rate(sentry_filestore_s3_errors_total[5m]) > 0 for 5m |

All rules ship with `enabled: false`; enable one at a time during Phase 6.

## 11. Phase 0 — Prep

### Buckets

Add to the existing `applications/monitoring-buckets/` Job (or new `applications/sentry-buckets/` with the same shape):

- Bucket `sentry-filestore-use1` with lifecycle `Expiration.Days = 45`
- Bucket `cnpg-sentry-use1` with no lifecycle (CNPG retention takes care of it)

Both reached via `https://backup-storage.vngenterprise.com` using `secret/monitoring/bucket-admin` (already exists, no new admin creds needed).

### Vault keys

Pre-create with placeholder values (real values go in during their respective phases):

- `secret/sentry/web` — `SECRET_KEY = openssl rand -base64 50`, `SENTRY_OPTIONS_SYSTEM_ADMIN_EMAIL = frank@dobrovolny.dev`
- `secret/sentry/filestore` — real S3 creds (separate IAM user / sub-account from monitoring creds for blast-radius isolation)
- `secret/sentry/clickhouse` — `openssl rand -base64 32`
- `secret/cnpg/sentry` + `secret/cnpg/sentry/backup` — Postgres superuser + backup creds
- `secret/redis/sentry` — `openssl rand -base64 32`
- `secret/sentry/saml` — placeholders (filled in Phase 3)
- `secret/sentry/smtp` — actual SMTP creds if email flows desired; else leave blank (Sentry will log mail to console)

### Verification

- `mc ls offsite/sentry-filestore-use1` returns empty bucket
- `mc ls offsite/cnpg-sentry-use1` returns empty bucket
- All Vault paths exist with the right keys

## 12. Phase 1 — CNPG `sentry-db` and `redis-sentry`

### `applications/cnpg-sentry/overlays/use1/`

Mirror of `cnpg-grafana` — the `Cluster` lives in namespace `sentry` (same as the Sentry chart, mirroring `cnpg-grafana` which lives in `grafana`):

- `cluster.yaml` — `Cluster` CR, namespace `sentry`, `instances: 1`, image `ghcr.io/cloudnative-pg/postgresql:16`, storage 5 GiB on `longhorn`, backup → `cnpg-sentry-use1`
- `external-secret.yaml` — backup creds from Vault `cnpg/sentry/backup`
- `podmonitor.yaml` — same shape as `cnpg-grafana` PodMonitor
- `kustomization.yaml`

Database init: `bootstrap.initdb.database: sentry`, `owner: sentry`. CNPG generates `sentry-db-app` (app-user creds) and `sentry-db-superuser` directly in the `sentry` namespace, where the Sentry chart references them.

### `applications/redis-operator/overlays/sentry/`

Mirror of `applications/redis-operator/overlays/rustlens/` — namespace pattern `<consumer>-redis`:

- `namespace.yaml` — namespace `sentry-redis`
- `external-secrets.yaml` — pull `secret/redis/sentry` into namespace
- `redis-replication.yaml` — `RedisReplication` CR, 3 replicas, 2 GiB on `longhorn-single`, password from ExternalSecret
- `redis-sentinel.yaml` — `RedisSentinel` CR, 3 replicas, master name `mymaster`
- `kustomization.yaml`

### Verification

- `kubectl get cluster -n sentry` → `sentry-db` is `Cluster in healthy state`
- `kubectl exec -n sentry sentry-db-1 -- psql -U postgres -c "\l"` shows `sentry` database
- `kubectl get secret sentry-db-app -n sentry` exists (chart-consumed)
- `kubectl get redisreplication,redissentinel -n sentry-redis` → both Ready, 3+3 pods
- A debug pod can `redis-cli -h redis-sentinel.sentry-redis.svc -p 26379 SENTINEL get-master-addr-by-name mymaster` and get the primary

## 13. Phase 2 — Sentry core (errors only)

Deploy the chart with most features off so a misconfig doesn't take everything down at once.

### Initial overlay values

```yaml
sentry:
  symbolicator: { enabled: false }
  vroom:        { enabled: false }
  features:
    organizations:performance-view: false
    organizations:profiling: false
    organizations:session-replay: false
    auth:register: true               # temporary, for first-time admin login
config:
  sentryConfPy: |
    SENTRY_OPTIONS['system.event-retention-days'] = 30
```

### Sequence

1. Confirm `kubectl get secret sentry-db-app -n sentry` exists (Phase 1 should have produced it)
2. ArgoCD sync `sentry` app
3. Wait for `sentry-db-init` Job to complete (`kubectl logs job/sentry-db-init -n sentry`)
4. Web pods come up; bootstrap superuser created from `SENTRY_OPTIONS_SYSTEM_ADMIN_EMAIL` + random password (visible in `kubectl logs job/sentry-db-init`)
5. Reach `https://sentry.vngenterprise.com` over netbird, log in as the bootstrap user
6. Create a project `internal-smoke-test`
7. From a debug pod inside the cluster, throw a fake event:
   ```bash
   curl -X POST -H "Content-Type: application/json" \
     "http://sentry-relay.sentry.svc.cluster.local:3000/api/<id>/store/" \
     -H "X-Sentry-Auth: Sentry sentry_key=<key>" \
     -d '{"message":"hello from rollout","level":"info"}'
   ```
8. Event appears in the project's issue stream within 30s

### Verification

- All Sentry pods Ready
- `kubectl logs deploy/sentry-web -n sentry | grep -i error` clean
- Smoke-test event visible in UI
- Mimir queries `up{namespace="sentry"}` shows all sentry-* pods
- Loki query `{namespace="sentry"}` returns startup lines

## 14. Phase 3 — Zitadel SAML2

### Steps

1. **Zitadel**: create SAML app as described in §7. Export SSO URL, Entity ID, X.509 cert.
2. **Vault**: populate `secret/sentry/saml` with the three values. ExternalSecret reconciler picks them up within `refreshInterval` (1h) or force with `kubectl annotate externalsecret sentry-saml -n sentry force-sync=$(date +%s)`.
3. **Sentry UI**: as the bootstrap admin, navigate to `Settings → Auth → SAML2 → Configure`. Paste in the three values from Vault (or rely on env-var-driven config if the chart wires `envFromSecrets: [sentry-saml]` into `sentry-web`).
4. **Verify SAML round-trip**: open an incognito browser, hit `https://sentry.vngenterprise.com`, expect redirect to `accounts.vngenterprise.com`, log in with a Zitadel user that's in the `sentry_user` group, expect to land back in Sentry as a Member of the org.
5. **Lock down local auth**: in Sentry UI org-settings → Auth → toggle "Require SSO". Update overlay `values.yaml` with `auth:register: false` and resync to make the change idempotent.
6. **Rotate bootstrap admin password** to something only stored in Vault (`secret/sentry/web/admin_recovery_password`). Don't delete the account — it's an emergency break-glass if SAML breaks.

### Group → role mapping

In Sentry UI → Settings → Auth → SAML2 → Attribute Statements, set:

| SAML attribute | Sentry mapping |
|---|---|
| `Groups` contains `sentry_admin` | org role `manager` |
| `Groups` contains `sentry_user` | org role `member` |
| neither | login denied |

This mapping lives in CNPG (Sentry persists it in Postgres), not in git — but the *intent* lives in this spec.

### Verification

- Incognito browser SSO works for a Zitadel user in `sentry_user`
- Bootstrap admin password is rotated and stored in Vault
- Local-password login form is hidden on the login page
- A Zitadel user not in either group gets "access denied" after SAML login

## 15. Phase 4 — Enable the rest of the feature set

One feature at a time, 24h soak between, to keep blame easy if ingestion breaks.

### 4a — Performance (transactions)

Flip `organizations:performance-view: true`. Verify a synthetic transaction submitted via SDK appears in the Performance tab.

### 4b — Profiling

Enable `vroom.enabled: true`, flip `organizations:profiling: true`. Verify a debug pod running the Python profiling SDK produces a flamegraph.

### 4c — Session replay

Flip `organizations:session-replay: true`. Verify a browser SDK sample replay lands in S3 (look at `mc ls offsite/sentry-filestore-use1/<org>/<project>/replays/`) and renders in the UI.

### 4d — Symbolicator (native crashes)

Enable `symbolicator.enabled: true`. Useful only if a native workload exists; verify a stripped Rust binary produces a symbolicated stack via debug-info upload. (May be deferred entirely until first native crash appears.)

### 4e — Cron monitoring

Flip `organizations:crons: true`. Verify a heartbeat from a fake cron job updates the monitor status.

### Verification per sub-phase

- New feature works end-to-end with a synthetic sample
- No new error spikes in `{namespace="sentry"} |~ "(?i)error|exception"` Loki query
- Kafka consumer lag stays bounded
- ClickHouse disk growth stays linear (no runaway from a misconfigured retention)

## 16. Phase 5 — Public Relay ingest

### Steps

1. Add DNS record: `s-metrics.vngenterprise.com` → public traefik LB
2. Add `applications/sentry/overlays/use1/s-metrics.vngenterprise.com.yaml` IngressRoute (paths restricted as in §9)
3. Add cert-manager `Certificate` (auto-renewed)
4. Pick a low-blast-radius first cutover — e.g., Rustlens backend. Update its `SENTRY_DSN` to use the new public host, redeploy
5. From a public network (not on netbird), verify event lands in Sentry within 30s
6. Confirm the UI host is *not* reachable on `s-metrics.vngenterprise.com` (should return 404)
7. Cut over remaining services one at a time

### Browser apps

For Rustlens frontend / mancini-beer / others:
- Update `@sentry/browser` `Sentry.init({ dsn: 'https://<key>@s-metrics.vngenterprise.com/<project>' })`
- Add `s-metrics.vngenterprise.com` to CSP `connect-src` and `img-src`
- Verify a JS error fires off in DevTools and lands in Sentry

### Verification

- A browser on a coffee-shop wifi produces an event in Sentry
- The Sentry admin UI cannot be reached from the public hostname
- Traefik logs show only `/api/*` paths being forwarded; everything else 404s at the edge

## 17. Phase 6 — Observability + alerts

### Steps

1. Add PodMonitors per §10 in `applications/sentry/overlays/use1/podmonitors.yaml`
2. Add Sentry dashboard JSON to `applications/grafana/overlays/use1/vanguard/dashboards/files/sentry.json` and register in the dashboards kustomization
3. Add `applications/grafana/overlays/use1/vanguard/alerts/rules-sentry.configmap.yaml` with all rules `enabled: false`
4. Enable rules one at a time, 1h soak between, exactly like LGTMP §16 alert bootstrap

### Verification

- Mimir returns metrics from all PodMonitor targets
- Grafana "Sentry" dashboard renders with non-zero panels
- A test alert (e.g., scale `sentry-web` to 0 replicas) routes to `discord-platform` within 60s

## 18. Repo layout

```
v-deployments/
├── applications/
│   ├── sentry/                                 # NEW
│   │   ├── base/
│   │   │   ├── kustomization.yaml             (helmCharts: sentry, pinned version)
│   │   │   ├── namespace.yaml
│   │   │   └── values.yaml                    (chart-wide defaults)
│   │   └── overlays/use1/
│   │       ├── kustomization.yaml
│   │       ├── values.yaml                    (env-specific overrides)
│   │       ├── external-secret-web.yaml
│   │       ├── external-secret-saml.yaml
│   │       ├── external-secret-filestore.yaml
│   │       ├── external-secret-smtp.yaml
│   │       ├── external-secret-clickhouse.yaml
│   │       ├── external-secret-redis.yaml
│   │       ├── external-secret-cnpg-app.yaml  (reflects CNPG-generated secret)
│   │       ├── podmonitors.yaml
│   │       ├── sentry.vngenterprise.com.yaml
│   │       └── s-metrics.vngenterprise.com.yaml
│   ├── cnpg-sentry/                            # NEW (mirrors cnpg-grafana)
│   │   └── overlays/use1/
│   │       ├── kustomization.yaml
│   │       ├── cluster.yaml
│   │       ├── external-secret.yaml
│   │       └── podmonitor.yaml
│   ├── redis-operator/
│   │   └── overlays/
│   │       └── sentry/                         # NEW (mirrors rustlens)
│   │           ├── kustomization.yaml
│   │           ├── namespace.yaml
│   │           ├── external-secrets.yaml
│   │           ├── redis-replication.yaml
│   │           └── redis-sentinel.yaml
│   ├── grafana/overlays/use1/vanguard/
│   │   ├── alerts/rules-sentry.configmap.yaml  # NEW (added in Phase 6)
│   │   └── dashboards/files/sentry.json        # NEW (added in Phase 6)
│   └── monitoring-buckets/                     # MODIFIED — add sentry buckets to existing Job
└── argocd/applications/use1/
    ├── sentry.yaml                             # NEW
    ├── cnpg-sentry.yaml                        # NEW
    └── redis-sentry.yaml                       # NEW
```

## 19. Verification & rollback

### Per-phase done-check

| Phase | Verification |
|---|---|
| 0 | Two new offsite buckets exist with lifecycle; all Vault paths exist with right keys (placeholders ok for `saml`) |
| 1 | CNPG `sentry-db` Healthy 1/1; `redis-sentry` RedisReplication+Sentinel Ready 3+3; sentinel returns a master |
| 2 | All Sentry pods Ready; smoke event submitted from a debug pod is visible in the UI within 30s; Mimir sees the namespace pods |
| 3 | Incognito SSO via Zitadel works for a `sentry_user`; local password login is hidden; bootstrap admin password rotated |
| 4 | Each sub-feature (performance, profiling, replay, symbolicator, crons) verified via a synthetic sample; ClickHouse disk growth linear; Kafka lag bounded |
| 5 | Browser on a public network produces an event; UI host is not reachable on `s-metrics`; first production service (Rustlens backend) cut over and producing events |
| 6 | Grafana Sentry dashboard renders; test alert routes to `discord-platform` within 60s |

### Definition of done

- All 3 new ArgoCD apps Synced + Healthy
- `https://sentry.vngenterprise.com` (over netbird) logs in via Zitadel SAML, no local-password form visible
- At least one cluster service and one browser app are reporting events to `s-metrics.vngenterprise.com`
- All five feature sub-areas (errors, performance, profiling, replays, crons) verified by synthetic samples
- Grafana dashboard for Sentry shows non-zero values for all panels
- At least one alert from `rules-sentry` has fired in test (scale-to-zero exercise) and routed to `discord-platform`
- Total local Longhorn consumption stays within ~120 GiB across all new PVCs
- `cleanup` cron has run at least once and pruned events older than 30d

### Rollback strategy

Every phase corresponds to a single ArgoCD `Application` or a single git commit on an existing one — rollback is `argocd app rollback <name>` or revert the git commit + sync.

| Risk | Mitigation |
|---|---|
| Chart-bundled ClickHouse OOM-kills | 8 GiB limit per pod; 50 GiB PVC keeps growth bounded; 30d retention enforced by cleanup; SentryClickHouseDiskHigh alert at 80% |
| Kafka single broker is a SPOF | Accepted tradeoff; on failure Sentry stops ingesting but UI stays up reading historical data from ClickHouse + Postgres. Recoverable by restoring the Kafka PVC. |
| SAML misconfig bricks login | Bootstrap admin account kept with rotated Vault-stored password; can re-enable local login by editing `auth.allow-registration: false` → `true` and resync |
| Public Relay endpoint abused for spam events | Per-project rate limits in Sentry itself; Traefik path restrictions; optional Traefik `RateLimit` middleware deferred until needed |
| CNPG sentry-db loses primary | 2-replica Longhorn PVC + barman backup to offsite S3; restore = `Cluster` `bootstrap.recovery` from latest basebackup |
| Filestore S3 endpoint unreachable | Sentry web stays up but source-map / replay rendering returns 5xx; SentryFilestoreS3Errors alert; ClickHouse-stored events still queryable |
| Source-map upload from CI requires netbird | Accepted — CI runners are on netbird already. If not, add a third public IngressRoute scoped to `/api/0/organizations/<org>/releases/*` paths later. |

## 20. Out of scope (deferred)

- HA ClickHouse (cluster mode with replicas), HA Kafka (3+ brokers) — revisit if ingest volume justifies it
- SCIM auto-provisioning for users (Sentry SaaS-paid feature; manual provisioning via Zitadel groups is fine for a small team)
- Tempo trace export of Sentry's own internals (Sentry has OTLP support — nice-to-have, would let us see traces of the system that records traces)
- Custom data-scrubbing rules beyond chart defaults (defer until first PII concern surfaces)
- Multi-tenant Sentry (separate orgs per team) — single org with project-level isolation is sufficient today
- Traefik `RateLimit` middleware on the public ingest endpoint — add when first abuse pattern shows up
- Public API hostname for CI source-map upload (`api.sentry.vngenterprise.com`) — defer; CI on netbird works fine
- Cross-cluster Sentry (one Sentry serving multiple K8s clusters) — irrelevant until a second cluster exists
- Long retention (90d+) — bump `event-retention-days` and resize ClickHouse PVC when needed
