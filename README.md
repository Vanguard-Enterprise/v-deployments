# Cluster Application Statuses

This repository hosts the Argo CD application definitions that manage the platform
deployments for multiple regions. The badges below mirror the live status of each
application so operators can quickly determine whether a deployment is healthy.

badge go bye bye

### sign of consent
i used to do this by myself no clanker, but claude is in a point where i trust it to manage manifests.
## Cupboard rebuild staging

`argocd/applications/use1/cupboard-rebuild.yaml` deploys the rebuilt application to
`https://cupboard-staging.vngenterprise.com` through internal Traefik. Its overlay
is `applications/cupboard-rebuild/overlays/use1`. The `cupboard-rebuild` namespace
holds one Next.js runtime, one Rust API runtime, and a fresh CloudNativePG cluster.
The inactive legacy Cupboard overlays are not used.
Both single-replica Deployments use Recreate because USE1 has no spare requested
CPU for surge pods. Releases and restarts briefly interrupt the web/API while
replacing their pods; PostgreSQL and saved configuration remain in place.

Promote both images together from a successful Cupboard main-branch `Check` run.
Set their `sha-<commit>` tags in `workload.yaml`, render with
`kubectl kustomize applications/cupboard-rebuild/overlays/use1`, and merge a reviewed
PR. Argo CD syncs main automatically. The API performs forward database migrations
on startup. Check migration compatibility before rolling image tags back.

CloudNativePG generates `cupboard-app`, including the database URI consumed by the
API. External Secrets reads `secret_key` from OpenBao
`kv/cupboard/rebuild/staging` and the existing GHCR credential from
`dockerconfig/aliencord-github`. Preserve the encryption key alongside database
backups; changing it without re-encryption makes saved RCON passwords unreadable.
The web runtime receives no database or encryption credentials.

File and logo uploads use the private Wasabi bucket `cupboard-staging-use1` in
`us-east-2`. External Secrets reads `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
and `BUCKET_NAME` from OpenBao `kv/cupboard/rebuild/staging-s3` into the API's
`cupboard-storage` Secret. The key belongs to Wasabi user `svc-cupboard`, whose
only permission is the managed policy `cupboard-staging-use1-rw`: get, put, and
delete on `organizations/*/files/*` and `organizations/*/logos/*`. Back up the
bucket together with the database, because file metadata lives in PostgreSQL.

Inspect the deployment with:

```bash
kubectl --context use1-oidc -n argocd get application cupboard-rebuild
kubectl --context use1-oidc -n cupboard-rebuild get pods,clusters,externalsecrets
kubectl --context use1-oidc -n cupboard-rebuild rollout status deployment/cupboard-api
kubectl --context use1-oidc -n cupboard-rebuild rollout status deployment/cupboard-web
```

The namespace and database opt out of Argo pruning. PostgreSQL uses retained
Longhorn storage. Restarts and image promotion must preserve the database and
OpenBao key. Staging has one database instance and no off-cluster backup schedule;
configure and test backups before treating it as production storage.

## Pocket ID

`argocd/applications/use1/pocket-id.yaml` deploys [Pocket ID](https://github.com/pocket-id/pocket-id),
the passkey-only OIDC provider for every app login (Grafana, Argo CD, OpenBao,
kubectl, NetBird, Wasabi), at `https://id.vngenterprise.com`. Its overlay is
`applications/pocket-id/overlays/use1`.

The route is public through external Traefik, limited by the `cloudflare-only`
middleware to Cloudflare edges, the pod CIDR, and the LAN. `cloudflare-ddns`
manages the proxied `id.vngenterprise.com` record.

Pocket ID runs one replica with Recreate, because multi-instance support is not
released yet (pocket-id/pocket-id#1549). Uploaded logos and profile pictures are
stored in Postgres (`FILE_BACKEND=database`), so the pod keeps no state on disk.

CloudNativePG cluster `pocket-id-db` (one instance, Longhorn) generates
`pocket-id-db-app`, whose `uri` is the database connection string. External
Secrets reads `encryption_key` from OpenBao `kv/pocket-id/use1` into the
`pocket-id` Secret. Keep that key with any database backup: Pocket ID encrypts
stored secrets with it. The database archives WAL and takes base backups at
03:00 and 15:00 UTC to the Wasabi bucket `cnpg-pocket-id-use1` (30 day
retention, Wasabi us-east-2), using the `svc-pocket-id` key from OpenBao `kv/pocket-id/backup`.

The first person to open `https://id.vngenterprise.com/setup` becomes the admin,
so finish setup right after the first deploy.

```bash
kubectl --context use1-oidc -n argocd get application pocket-id
kubectl --context use1-oidc -n pocket-id get pods,clusters,externalsecrets
kubectl --context use1-oidc -n pocket-id logs deploy/pocket-id
```

## MCP hub

`argocd/applications/use1/mcp-hub.yaml` deploys the MCP hub from
[Vanguard-Enterprise/mcp-hub](https://github.com/Vanguard-Enterprise/mcp-hub)
into the `mcp-hub` namespace (overlay `applications/mcp-hub/overlays/use1`):
one endpoint, `https://mcp.vngenterprise.com/mcp`, and one Pocket ID login for
every self-hosted MCP server. Backends are sections of the hub: `netbird` (read
tools for every NetBird object type, create/update/delete for groups, policies,
routes, setup keys, DNS, and peers) and `pocketid` (Pocket ID administration:
users, groups and memberships, OIDC clients and secrets, APIs, sign-up tokens,
SCIM, the audit log, and the configuration; read tools hide credentials).

Access is per section and per Pocket ID group, set in
`applications/mcp-hub/overlays/use1/access-policy.json`: `read` groups get the
section's read tools, `write` groups get read and write tools, everyone else
gets nothing from it. The hub reads the caller's groups from Pocket ID's
userinfo endpoint (cached for a minute), so adding or removing someone from
`mcp_netbird_read`, `mcp_netbird_write`, `mcp_pocketid_read`, or
`mcp_pocketid_write` in Pocket ID is all it takes. `mcp_pocketid_write` can
change every group, these included, so keep it to Pocket ID admins. The
policy is generated into a ConfigMap with a content hash, so editing it rolls
the Deployment. `hub_whoami` shows a caller their groups and access.

The route sits on internal Traefik (10.1.50.176) and is reached over the LAN or
NetBird; the A record lives in the NetBird DNS zone `vngenterprise.com`. There
is no Traefik auth middleware: the hub is an OAuth resource server for Pocket ID
access tokens and answers `401` with RFC 9728 resource metadata, so MCP clients
such as Claude Code run the PKCE login themselves. Pocket ID holds the public
client "MCP Hub" (callback `http://localhost/callback`, any port) restricted to
the `mcp_*` groups, and the API resource `https://mcp.vngenterprise.com/mcp`.
Write tools are annotated as mutating and force a confirmation prompt in Claude
Code; each write is logged with the caller's Pocket ID subject.

The image is `ghcr.io/vanguard-enterprise/mcp-hub:main`, built by the mcp-hub CI
on every push to `main`; Argo CD Image Updater pins the digest in the overlay
kustomization. The Deployment uses RollingUpdate with `maxUnavailable: 0`, and a
pod is ready only after OIDC discovery against Pocket ID succeeded.

Secrets come from OpenBao through External Secrets: `kv/mcp-hub/netbird` key
`netbird_api_token` (a NetBird Personal Access Token) feeds `NETBIRD_API_TOKEN`,
and `kv/mcp-hub/pocket-id` key `pocketid_api_key` (a Pocket ID admin API key,
created at `/settings/admin/api-keys`; it expires, so renew it there and update
OpenBao) feeds `POCKETID_API_KEY`.
The `use1` policy grants ESO read on `kv/data/mcp-hub/*`.

```bash
kubectl --context use1-oidc -n argocd get application mcp-hub
kubectl --context use1-oidc -n mcp-hub get pods,externalsecrets,ingressroute
kubectl --context use1-oidc -n mcp-hub logs deploy/mcp-hub
```


## Vanguard Nexus

`argocd/applications/use1/vanguard-nexus.yaml` deploys the
[Vanguard Nexus](https://github.com/Vanguard-Enterprise/v-nexus) demo at
`https://nexus.vngenterprise.com` through internal Traefik, so it is reachable over
NetBird and the LAN only. The NetBird `vngenterprise.com` DNS zone holds the
`nexus` A record (10.1.50.176). Its overlay is `applications/vanguard-nexus/overlays/use1`.
This is an early build, not a release.

The `vanguard-nexus` namespace holds the server (one replica, Recreate) and the
CloudNativePG cluster `vn-db`, whose generated `vn-db-app` Secret supplies the database
URL. The server applies its migrations at startup. The agent challenge key is
generated in the cluster by an External Secrets `Password` generator and never
rotated; it signs only one-minute challenges, so it needs no backup. The database has
one instance and no backup schedule: treat its data as disposable.

Sign-in uses the Pocket ID public client `Vanguard Nexus (use1)` (PKCE, no secret),
limited to the `vn-admins` group, whose members also get the VN installation admin
role.

The `vn-agent` namespace runs the agent, which inventories use1 itself with a
read-only ClusterRole (nodes, namespaces, deployments, statefulsets, daemonsets; no
pods, Secrets, or ConfigMaps). It talks to the server over the in-cluster Service.
Its enrollment token is single-use and kept out of Git. To enroll (or re-enroll after
revoking the agent), register the cluster in the VN UI, copy the token, then:

```bash
kubectl --context use1-oidc -n vn-agent create secret generic vn-agent-enrollment \
  --from-file=token=<file holding the token> \
  --dry-run=client -o yaml | kubectl --context use1-oidc apply --server-side --force-conflicts -f -
kubectl --context use1-oidc -n vn-agent delete secret vn-agent-identity --ignore-not-found
kubectl --context use1-oidc -n vn-agent rollout restart deployment/vn-agent
```

Until a token is present the agent pod restarts. After it enrolls it keeps its
identity in `vn-agent-identity`, which it creates itself.

Argo CD Image Updater moves both images to the newest `sha-<commit>` tag that v-nexus
CI publishes from main.

```bash
kubectl --context use1-oidc -n argocd get application vanguard-nexus
kubectl --context use1-oidc -n vanguard-nexus get pods,clusters,externalsecrets
kubectl --context use1-oidc -n vn-agent logs deployment/vn-agent
```

## n8n

`argocd/applications/use1/n8n.yaml` deploys [n8n](https://n8n.io) for day-to-day
automations. Its overlay is `applications/n8n/overlays/use1`. It uses two hosts:

- `https://n8n.vngenterprise.com` is the editor, on internal Traefik (10.1.50.176),
  reachable over NetBird and the LAN only. The A record is in the NetBird DNS zone
  `vngenterprise.com`.
- `https://n8n-hooks.vngenterprise.com` is public through external Traefik and
  Cloudflare (`cloudflare-only` middleware, record managed by `cloudflare-ddns`).
  It routes only `/webhook/` (production webhooks). The UI, REST API, test
  webhooks and forms are not served there.

n8n runs one replica with Recreate in regular mode, so schedules fire once.
CloudNativePG cluster `n8n-db` stores workflows, credentials and 14 days of
execution history. External Secrets reads `encryption_key` from OpenBao
`kv/n8n/use1` into `N8N_ENCRYPTION_KEY`. Keep the key with any database backup,
because every stored credential is encrypted with it. The database has no
off-cluster backup yet.

Egress is open to the public internet on 80 and 443 for the APIs workflows call,
but private ranges (LAN, cluster and NetBird) are blocked, so workflows cannot
reach internal services. Add a rule to `networkpolicy.yaml` for one that must.

The first visit to the editor creates the owner account.
