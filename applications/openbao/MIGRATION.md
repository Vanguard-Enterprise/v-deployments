# Vault → OpenBao migration (use1)

Migrating HashiCorp Vault (1.20.4, `vault` ns) to OpenBao (v2.5.5, `openbao` ns),
swapping AWS KMS auto-unseal for OpenBao's **static seal** (no cloud, $0).

**Why:** Vault UI is unusable past 1.20.4 (pins us to that version) + BUSL/IBM
licensing; OpenBao is MPL/Linux-Foundation and ships the static seal in OSS.

**Why this is low-risk:** the *only* consumer is External Secrets Operator (ESO);
the Agent Injector and CSI provider are both disabled. The data is *only* KV-v2
(mount `kv`). So this is an export/import of static key/value pairs + recreating
one k8s-auth role, one OIDC auth method, and a few policies — run side-by-side,
cut over with a one-line ESO edit, fully reversible until Phase 4.

> ⚠️ We do **not** transplant Raft storage. OpenBao (forked from Vault 1.14)
> cannot read a Raft DB written by Vault 1.20. We rebuild config + copy KV.

---

## Phase 1 — Parallel OpenBao (DONE — this PR, additive)

GitOps only, nothing in `vault` ns is touched:

- `applications/openbao/{base,overlays/use1}` — chart 0.28.4, static seal, Raft HA x3
- `argocd/applications/use1/openbao.yaml` — auto-discovered by the `use1` app-of-apps
- ingress `openbao.vngenterprise.com`, ServiceMonitor, PrometheusRule

> After merge, ArgoCD auto-syncs and the pods will **crashloop until the seal
> Secret exists** (Phase 2.1). That's expected and isolated to the `openbao` ns.
> Create the seal Secret right before/after merge to avoid the noise.

---

## Phase 2 — Bring-up (operational; run against the live cluster)

### 2.1 Create the static-seal key Secret
This is the root of trust. Plain k8s Secret — **NOT** via ESO (ESO depends on
OpenBao being unsealed; circular). Store the key offline too (password manager).

```bash
# 32 random bytes, base64-encoded (the env:// value OpenBao expects)
SEAL_KEY=$(openssl rand -base64 32)
kubectl create namespace openbao --dry-run=client -o yaml | kubectl apply -f -
kubectl -n openbao create secret generic openbao-seal --from-literal=seal-key="$SEAL_KEY"
echo "SAVE THIS OFFLINE: $SEAL_KEY"
```
> Trust boundary note: with the static seal, anyone with BOTH a Raft snapshot AND
> this Secret can unseal. Mitigate: etcd encryption-at-rest + tight RBAC on the
> `openbao` ns. (AWS KMS protected snapshots even from cluster admins; this is the
> deliberate trade for dropping the cloud dependency.)

### 2.2 Initialize
Let ArgoCD sync the `openbao` app (or `kubectl -n openbao rollout status sts/openbao`).
Pods come up sealed/uninitialized.

```bash
kubectl -n openbao exec -it openbao-0 -- bao operator init -format=json > openbao-init.json
# Static seal auto-unseals on restart; the "recovery keys" here are for
# break-glass + future seal migration. STORE openbao-init.json OFFLINE, then
# delete the local copy. Capture the root token for Phase 2b/2c bootstrap.
```
Join followers if they didn't auto-join via retry_join:
```bash
for i in 1 2; do kubectl -n openbao exec openbao-$i -- \
  bao operator raft join http://openbao-0.openbao-internal.openbao.svc.cluster.local:8200; done
kubectl -n openbao exec openbao-0 -- bao operator raft list-peers   # expect 3, 1 leader
```

### 2.3 Enable KV-v2 at the same mount as Vault
```bash
export VAULT_TOKEN=<root-token-from-init>   # bao CLI reads VAULT_* env
kubectl -n openbao exec -it openbao-0 -- sh -c 'BAO_TOKEN=$VAULT_TOKEN bao secrets enable -path=kv kv-v2'
```

---

## Phase 2b — Recreate auth methods + policies

These live ONLY in running Vault, not in git. **First capture them** (read-only,
against live Vault — see the export block in the PR discussion), then re-apply to
OpenBao verbatim. Paste the export back and these get codified here + committed.

```bash
# k8s auth (the ESO path) — mount `use1`, role `external-secrets`
bao auth enable -path=use1 kubernetes
bao write auth/use1/config \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
bao write auth/use1/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=<eso-policy> ttl=1h          # <-- fill from Vault export

# policies (one bao policy write per policy from `vault policy read`)
bao policy write <name> <name>.hcl
```

## Phase 2c — OIDC (Zitadel) login

Reuse the existing Zitadel `vault-ui` app (client `356671706259064302`) so Vault
and OpenBao can both log in during migration. **Additive Zitadel change** — add:

```
redirectUris +=
  https://openbao.vngenterprise.com/ui/vault/auth/oidc/oidc/callback   # VERIFY exact UI path once UI is up
  https://openbao.vngenterprise.com/oidc/callback
allowedOrigins += https://openbao.vngenterprise.com
```
> The OpenBao UI is a rebranded Vault UI; the `/ui/vault/auth/...` callback path
> MAY differ. Confirm from the OIDC error on first login attempt and fix the URI.

Re-apply the OIDC auth method from the Vault export, pointed at the same Zitadel
discovery URL, plus OpenBao's own `allowed_redirect_uris`:
```bash
bao auth enable oidc
bao write auth/oidc/config oidc_discovery_url="https://<zitadel>/..." \
  oidc_client_id="356671706259064302" oidc_client_secret="<secret>" default_role="<role>"
bao write auth/oidc/role/<role> \
  allowed_redirect_uris="https://openbao.vngenterprise.com/ui/vault/auth/oidc/oidc/callback,https://openbao.vngenterprise.com/oidc/callback,http://localhost:8250/oidc/callback" \
  user_claim="sub" policies="<policies>" ...   # <-- match Vault export (bound_claims etc.)
```
Verify: log into `https://openbao.vngenterprise.com` via Zitadel → correct policies.

---

## Phase 3 — Copy KV data

Static, idempotent, re-runnable; both systems live. Values exist only in Vault.

```bash
# Recursively copy every kv/ path from Vault -> OpenBao via the same API.
# Run with VAULT_ADDR/TOKEN for source, then target. (helper script: copy-kv.sh)
```
> A `copy-kv.sh` will be added alongside this doc once the auth/policy export is
> in, so it runs end-to-end with the right mounts. Spot-check a few secrets after:
> `bao kv get kv/monitoring/grafana-admin`.

---

## Phase 4 — Cutover ESO (one line, reversible)

Edit `applications/external-secrets/overlays/use1/ClusterSecretStore.yaml`:
```diff
-      server: "http://vault.vault.svc.cluster.local:8200"
+      server: "http://openbao.openbao.svc.cluster.local:8200"
```
Path (`kv`), auth mount (`use1`), role (`external-secrets`) all unchanged — ESO's
`vault` provider speaks to OpenBao natively. Then force a refresh and verify:
```bash
kubectl annotate es -A --all force-sync=$(date +%s) --overwrite   # or per-ES
# confirm all 28 ExternalSecrets: SecretSynced=True
kubectl get externalsecret -A
```
**Rollback = revert that one line.**

---

## Phase 5 — Decommission (after a soak period)

1. Delete `applications/vault/` + `argocd/applications/use1/vault.yaml` (ArgoCD prunes the `vault` ns).
2. Delete the **AWS KMS key** `bad6b270-36ce-463a-a426-43ffb30bf140` (us-east-1) and the `eks-creds` Secret — **first** confirm nothing else mounts `eks-creds` (pyroscope's S3 creds are separate KV data, not this k8s Secret):
   `grep -rn "eks-creds" applications/`
3. Prune the `vault.vngenterprise.com` redirect URIs + origin from the Zitadel `vault-ui` app; optionally rename project/app VAULT → OPENBAO.
4. Final URL = `openbao.vngenterprise.com` (decided: keep, don't reclaim the vault host).

---

## Rollback summary
- Phases 1–3: OpenBao is parallel; just don't cut over. Delete the `openbao` app to remove it.
- Phase 4: revert the one ESO `server:` line.
- Phase 5 is the point of no return — only after OpenBao has soaked.
