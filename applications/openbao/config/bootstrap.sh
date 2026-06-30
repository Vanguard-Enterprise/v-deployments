#!/usr/bin/env bash
# Configure a fresh OpenBao to match the source Vault: KV-v2 engine, policies,
# Kubernetes auth (ESO), and OIDC auth (Zitadel). Idempotent — safe to re-run.
#
# Requires:
#   BAO_ADDR              e.g. https://openbao.vngenterprise.com
#   BAO_TOKEN             an OpenBao token with admin (root for bootstrap)
#   OIDC_CLIENT_SECRET    Zitadel client secret for app 356671706259064302
#
# Usage:  BAO_ADDR=... BAO_TOKEN=... OIDC_CLIENT_SECRET=... ./bootstrap.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${BAO_ADDR:?set BAO_ADDR}"
: "${BAO_TOKEN:?set BAO_TOKEN}"

echo "==> KV-v2 at kv/"
bao secrets enable -path=kv kv-v2 2>/dev/null || echo "   (already enabled)"

echo "==> Policies"
for f in "$HERE"/policies/*.hcl; do
  name="$(basename "$f" .hcl)"
  # source policy names were prefixed vault-* except use1; keep the same names
  case "$name" in
    use1) pol="use1" ;;
    *)    pol="vault-$name" ;;
  esac
  echo "   policy: $pol"
  bao policy write "$pol" "$f"
done

echo "==> Kubernetes auth at use1/"
bao auth enable -path=use1 kubernetes 2>/dev/null || echo "   (already enabled)"
# In-cluster: OpenBao uses its own mounted SA JWT + CA as reviewer (local CA JWT).
bao write auth/use1/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  disable_iss_validation=true
bao write auth/use1/role/external-secrets \
  bound_service_account_names="external-secrets" \
  bound_service_account_namespaces="external-secrets" \
  token_policies="use1" \
  token_ttl="1h"

if [ -z "${OIDC_CLIENT_SECRET:-}" ]; then
  echo "==> OIDC auth: SKIPPED (set OIDC_CLIENT_SECRET to configure human login)"
  echo "==> Core done. Verify: bao policy list ; bao auth list"
  exit 0
fi

echo "==> OIDC auth (Zitadel)"
bao auth enable oidc 2>/dev/null || echo "   (already enabled)"
bao write auth/oidc/config \
  oidc_discovery_url="https://accounts.vngenterprise.com" \
  oidc_client_id="356671706259064302" \
  oidc_client_secret="$OIDC_CLIENT_SECRET" \
  default_role="default"

# Redirect URIs: OpenBao UI + CLI loopback. OpenBao's UI rootURL is /ui/ (Vault
# used /ui/vault/), so the UI callback is /ui/auth/<mount>/oidc/callback.
REDIRECTS="https://openbao.vngenterprise.com/ui/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback,http://127.0.0.1:8250/oidc/callback"

oidc_role() { # name policy
  bao write "auth/oidc/role/$1" \
    user_claim="sub" \
    oidc_scopes="openid,profile,email" \
    bound_audiences="356671706259064302" \
    allowed_redirect_uris="$REDIRECTS" \
    token_policies="$2" \
    token_ttl="28800" \
    role_type="oidc"
}
oidc_role default        default
oidc_role global-admin   vault-global-admin
oidc_role global-readonly vault-global-readonly
oidc_role hyplex-admin   vault-hyplex-admin
oidc_role rustlens-admin vault-rustlens-admin

echo "==> Done. Verify: bao policy list ; bao auth list"
