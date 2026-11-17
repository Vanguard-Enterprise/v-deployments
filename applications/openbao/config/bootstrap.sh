#!/usr/bin/env bash
# Configure a fresh OpenBao to match the source Vault: KV-v2 engine, policies,
# Kubernetes auth (ESO), and OIDC auth (Pocket ID). Idempotent, safe to re-run.
#
# Requires:
#   BAO_ADDR              e.g. https://openbao.vngenterprise.com
#   BAO_TOKEN             an OpenBao token with admin (root for bootstrap)
#   OIDC_CLIENT_SECRET    Pocket ID "OpenBao UI" client secret (kv/pocket-id/clients/openbao-ui)
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
# Break-glass admin (IdP-independent): SA openbao-break-glass -> global-admin.
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

# Human login through Pocket ID (https://id.vngenterprise.com).
# Clients (Pocket ID admin, OIDC Clients), both restricted to the vault_admins group:
#   "OpenBao UI"  confidential, browser login. Secret: kv/pocket-id/clients/openbao-ui
#   "OpenBao CLI" public, device-code grant only (openbao-login.sh, jwt role below)
# Get the secret for this section with:
#   OIDC_CLIENT_SECRET="$(bao kv get -field=client_secret kv/pocket-id/clients/openbao-ui)"
UI_CLIENT_ID="1550a318-bcac-408b-93c1-7478fe57d3ed"
CLI_CLIENT_ID="118684db-4715-4c61-9220-0076b29e4ded"

echo "==> OIDC auth (Pocket ID)"
bao auth enable oidc 2>/dev/null || echo "   (already enabled)"
bao write auth/oidc/config \
  oidc_discovery_url="https://id.vngenterprise.com" \
  oidc_client_id="$UI_CLIENT_ID" \
  oidc_client_secret="$OIDC_CLIENT_SECRET" \
  default_role="default"

# Redirect URI for the browser (UI) OIDC login. The UI builds the callback from
# the 'vault' module prefix (confirmed via server logs): /ui/vault/auth/<mount>/oidc/callback
# (NOT /ui/auth/... despite rootURL=/ui/). It must match the callback URL registered
# on the Pocket ID "OpenBao UI" client. CLI login does not use a redirect: it goes
# through the device-flow wrapper (openbao-login.sh, jwt role below). See the openbao skill.
REDIRECTS="https://openbao.vngenterprise.com/ui/vault/auth/oidc/oidc/callback"

# Access is granted by Pocket ID group membership: with the groups scope, Pocket ID
# emits a flat `groups` array that bound_claims matches directly. A group that does
# not exist in Pocket ID matches nobody.
oidc_role() { # name  policy  group ("" = open, no group restriction)
  python3 - "$1" "$2" "$3" "$REDIRECTS" "$UI_CLIENT_ID" <<'PY' | bao write "auth/oidc/role/$1" -
import json, sys
name, policy, group, redirects, aud = sys.argv[1:6]
body = {
  "user_claim": "sub",
  "oidc_scopes": ["openid", "profile", "email", "groups"],
  "bound_audiences": [aud],
  "allowed_redirect_uris": redirects.split(","),
  "token_policies": [policy],
  "token_ttl": 28800,
  "role_type": "oidc",
  "verbose_oidc_logging": False,
}
if group:
  body["bound_claims"] = {"groups": [group]}
print(json.dumps(body))
PY
}
# default: open (any user the Pocket ID client admits) but maps to the no-access
# `default` policy. Used as the OIDC default_role fallback.
oidc_role default         default                ""
oidc_role global-admin    vault-global-admin     vault_admins
oidc_role global-readonly vault-global-readonly  vault_readonly

# CLI/agent login roles (role_type=jwt): headless device-flow login via
# openbao-login.sh, which drives the Pocket ID device authorization grant on the
# public "OpenBao CLI" client and posts the id_token here. Audience = that client id.
# (bao's native OIDC login helper is broken in 2.5.5, hence this path. See skill.)
jwt_role() { # name  policy  group
  python3 - "$1" "$2" "$3" "$CLI_CLIENT_ID" <<'PY' | bao write "auth/oidc/role/$1" -
import json,sys
name,policy,group,aud=sys.argv[1:5]
print(json.dumps({"role_type":"jwt","user_claim":"sub","bound_audiences":[aud],
 "bound_claims":{"groups":[group]},"token_policies":[policy],"token_ttl":28800,"token_type":"service"}))
PY
}
jwt_role cli-global-admin vault-global-admin vault_admins

echo "==> Done. Verify: bao policy list ; bao auth list"
