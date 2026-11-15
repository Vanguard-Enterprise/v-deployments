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

`argocd/applications/use1/mcp-hub.yaml` deploys the self-hosted MCP servers from
[Vanguard-Enterprise/mcp-hub](https://github.com/Vanguard-Enterprise/mcp-hub)
into the `mcp-hub` namespace (overlay `applications/mcp-hub/overlays/use1`).
The first server is `mcp-netbird` at `https://mcp-netbird.vngenterprise.com/mcp`:
read tools for every NetBird object type plus create, update, and delete tools
for groups, policies, routes, setup keys, DNS, and peers. Write tools are
annotated as mutating (`readOnlyHint: false`, deletes and updates
`destructiveHint: true`); whether a client asks before running them is the
client's approval policy, so keep write tools out of any auto-approve list.
Each write is logged with the caller's Pocket ID subject (NetBird's own log
only sees the PAT owner).

Routes sit on internal Traefik (10.1.50.176) and are reached over the LAN or
NetBird; the A records live in the NetBird DNS zone `vngenterprise.com`. There
is no Traefik auth middleware: each server is an OAuth resource server that
validates Pocket ID access tokens (JWKS of `https://id.vngenterprise.com`) and
answers `401` with RFC 9728 resource metadata, so MCP clients such as Claude Code
run the PKCE login themselves. Pocket ID holds the public client "NetBird MCP"
(callback `http://localhost/callback`, any port) restricted to the `mcp_users`
group, and the API resource `https://mcp-netbird.vngenterprise.com/mcp`.

Images are `ghcr.io/vanguard-enterprise/mcp-<server>:main`, built by the mcp-hub
CI on every push to `main`; Argo CD Image Updater pins the digest in the overlay
kustomization. Deployments use RollingUpdate with `maxUnavailable: 0`, and a pod
is ready only after OIDC discovery against Pocket ID succeeded.

Secrets come from OpenBao through External Secrets: `kv/mcp-hub/netbird` key
`netbird_api_token` (a NetBird Personal Access Token) feeds `NETBIRD_API_TOKEN`.
The `use1` policy grants ESO read on `kv/data/mcp-hub/*`.

```bash
kubectl --context use1-oidc -n argocd get application mcp-hub
kubectl --context use1-oidc -n mcp-hub get pods,externalsecrets,ingressroute
kubectl --context use1-oidc -n mcp-hub logs deploy/mcp-netbird
```
