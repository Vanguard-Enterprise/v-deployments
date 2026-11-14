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
