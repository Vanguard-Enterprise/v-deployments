#!/usr/bin/env bash
# openbao-login.sh: human/agent login to OpenBao as a Pocket ID identity via the
# OAuth 2.0 Device Authorization Grant. You click "Approve" in the browser; there
# is NO localhost callback and nothing to paste back.
#
# Why this exists: OpenBao 2.5.5's builtin `bao login -method=oidc` helper is
# broken for headless use (device mode returns "no state"; direct mode builds a
# malformed redirect_uri). This wrapper talks to Pocket ID's device endpoint
# directly, then hands the resulting id_token to a jwt-type OpenBao role.
#
# Usage:
#   ./openbao-login.sh [ROLE]
#   ROLE defaults to cli-global-admin (vault_admins group -> vault-global-admin).
# Env overrides: BAO_ADDR, OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_MOUNT.
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-https://openbao.vngenterprise.com}"
ISSUER="${OIDC_ISSUER:-https://id.vngenterprise.com}"
CLIENT_ID="${OIDC_CLIENT_ID:-118684db-4715-4c61-9220-0076b29e4ded}"   # Pocket ID "OpenBao CLI" public client
MOUNT="${OIDC_MOUNT:-oidc}"
ROLE="${1:-cli-global-admin}"
export BAO_ADDR

command -v bao >/dev/null || { echo "bao CLI not found in PATH" >&2; exit 1; }

jget() { python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))"; }

# 1) Discover endpoints, then start device authorization.
disco=$(curl -sS --max-time 15 "$ISSUER/.well-known/openid-configuration")
device_endpoint=$(printf '%s' "$disco" | jget device_authorization_endpoint)
token_endpoint=$(printf '%s' "$disco" | jget token_endpoint)
[ -n "$device_endpoint" ] && [ -n "$token_endpoint" ] || { echo "OIDC discovery failed for $ISSUER" >&2; exit 1; }
# The groups scope makes the id_token carry the `groups` claim the OpenBao role binds on.
dev=$(curl -sS --max-time 15 -X POST "$device_endpoint" \
  -d client_id="$CLIENT_ID" -d "scope=openid profile email groups")
device_code=$(printf '%s' "$dev" | jget device_code)
user_code=$(printf '%s' "$dev" | jget user_code)
verify=$(printf '%s' "$dev" | jget verification_uri_complete)
interval=$(printf '%s' "$dev" | jget interval); interval=${interval:-5}
[ -n "$device_code" ] || { echo "device_authorization failed: $dev" >&2; exit 1; }

echo "================================================================"
echo " Approve this OpenBao login in your browser:"
echo "   $verify"
echo "   (code: $user_code)"
echo "================================================================"

# 2) Poll the token endpoint until approved.
id_token=""
while :; do
  sleep "$interval"
  tok=$(curl -sS --max-time 15 -X POST "$token_endpoint" \
    -d grant_type=urn:ietf:params:oauth:grant-type:device_code \
    -d device_code="$device_code" -d client_id="$CLIENT_ID" || true)
  err=$(printf '%s' "$tok" | jget error)
  case "$err" in
    authorization_pending) continue ;;
    slow_down) interval=$((interval + 5)); continue ;;
    "" ) id_token=$(printf '%s' "$tok" | jget id_token); break ;;
    *) echo "device token error: $tok" >&2; exit 1 ;;
  esac
done
[ -n "$id_token" ] || { echo "no id_token returned" >&2; exit 1; }

# 3) Exchange the id_token for an OpenBao token (jwt-type role) and cache it.
vtoken=$(bao write -field=token "auth/$MOUNT/login" role="$ROLE" jwt="$id_token")
bao login -no-print "$vtoken"
echo "Logged in to OpenBao ($BAO_ADDR) as role '$ROLE'. Token cached."
bao token lookup -format=json | python3 -c "import sys,json;d=json.load(sys.stdin)['data'];print('  display_name:',d['display_name']);print('  policies:',d['policies']);print('  ttl:',d['ttl'])"
