# OpenBao (use1)

OpenBao runs as a 3-node Raft cluster (`openbao-0/1/2`, namespace `openbao`) at
`https://openbao.vngenterprise.com`, with the static seal (auto-unseal from a
key in a plain Kubernetes Secret). External Secrets reads everything under the
KV-v2 mount `kv/`. Human login goes through Pocket ID; see
`.claude/skills/openbao/SKILL.md` for logins, break-glass and raft repair.

## Rebuild from scratch

Use this only when the cluster's Raft data is lost.

1. Create the static-seal Secret before OpenBao starts. External Secrets cannot
   provide it, because External Secrets depends on OpenBao being unsealed. Keep
   the key offline too (password manager): anyone with both a Raft snapshot and
   this key can unseal.

   ```bash
   SEAL_KEY=$(openssl rand -base64 32)
   kubectl create namespace openbao --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n openbao create secret generic openbao-seal --from-literal=seal-key="$SEAL_KEY"
   ```

2. Let Argo CD sync the `openbao` app, then initialize. The recovery keys and
   root token in `openbao-init.json` go offline; delete the local copy after
   bootstrap.

   ```bash
   kubectl -n openbao exec -it openbao-0 -- bao operator init -format=json > openbao-init.json
   ```

   Join followers if they did not join through `retry_join`:

   ```bash
   for i in 1 2; do kubectl -n openbao exec openbao-$i -- \
     bao operator raft join http://openbao-0.openbao-internal.openbao.svc.cluster.local:8200; done
   kubectl -n openbao exec openbao-0 -- bao operator raft list-peers   # expect 3, 1 leader
   ```

3. Run `config/bootstrap.sh` with the root token. It creates the `kv/` mount,
   policies, Kubernetes auth (External Secrets and break-glass), and Pocket ID
   OIDC login. The header lists the required environment variables.

4. Restore the KV data. Every ExternalSecret then resyncs on its own.
