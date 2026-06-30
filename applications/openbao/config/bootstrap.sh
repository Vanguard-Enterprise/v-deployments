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
# Break-glass admin (Zitadel-independent): SA openbao-break-glass -> global-admin.
bao write auth/use1/role/break-glass \
  bound_service_account_names="openbao-break-glass" \
  bound_service_account_namespaces="openbao" \
  token_policies="vault-global-admin" \
  token_ttl="15m"

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

# Redirect URIs: OpenBao UI + CLI loopback. The UI builds the callback from the
# 'vault' module prefix (confirmed via server logs), so it is
# /ui/vault/auth/<mount>/oidc/callback — NOT /ui/auth/... despite rootURL=/ui/.
REDIRECTS="https://openbao.vngenterprise.com/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback,http://127.0.0.1:8250/oidc/callback"

# Per-role bound_claims on `sub` (Zitadel user ID) — an ALLOWLIST so a user can
# only assume a role they're entitled to (Zitadel's native roles claim is a
# nested map OpenBao can't bound_claims-match; sub is a flat string that can).
#
# MAINTENANCE: update these sub lists when Zitadel grants change. Sources of
# truth = Zitadel VAULT project grants (users/grants/_search). Roles with no
# grantees are locked to a sentinel sub that matches nobody.
# (Scalable alternative: a Zitadel Action that emits a flat `roles` array claim,
#  then bound_claims on `roles` — auto-syncs with grants. Not set up yet.)
SUB_FRANK="355717786942637389"   # vault_global_admin, rustlens-admin
SUB_SEM="355982315320509547"     # rustlens-admin
SUB_KAPPU="355846454918513997"   # rustlens-admin

oidc_role() { # name  policy  bound_claims_json ("" = open, no sub restriction)
  python3 - "$1" "$2" "$3" "$REDIRECTS" <<'PY' | bao write "auth/oidc/role/$1" -
import json, sys
name, policy, bc, redirects = sys.argv[1:5]
body = {
  "user_claim": "sub",
  "oidc_scopes": ["openid", "profile", "email"],
  "bound_audiences": ["356671706259064302"],
  "allowed_redirect_uris": redirects.split(","),
  "token_policies": [policy],
  "token_ttl": 28800,
  "role_type": "oidc",
  "verbose_oidc_logging": False,
}
if bc:
  body["bound_claims"] = {"sub": json.loads(bc)}
print(json.dumps(body))
PY
}
# default: open (any authenticated Zitadel user) but maps to the no-access
# `default` policy — used as the OIDC default_role fallback.
oidc_role default         default                ""
oidc_role global-admin    vault-global-admin     "[\"$SUB_FRANK\"]"
oidc_role rustlens-admin  vault-rustlens-admin   "[\"$SUB_FRANK\",\"$SUB_SEM\",\"$SUB_KAPPU\"]"
oidc_role global-readonly vault-global-readonly  "[\"__no-grantees__\"]"

echo "==> Done. Verify: bao policy list ; bao auth list"
