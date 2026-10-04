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
