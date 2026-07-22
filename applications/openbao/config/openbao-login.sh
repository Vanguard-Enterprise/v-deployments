#!/usr/bin/env bash
# openbao-login.sh — human/agent login to OpenBao as a Zitadel identity via the
# OAuth 2.0 Device Authorization Grant. You click "Approve" in the browser; there
# is NO localhost callback and nothing to paste back.
#
# Why this exists: OpenBao 2.5.5's builtin `bao login -method=oidc` helper is
# broken for headless use (device mode returns "no state"; direct mode builds a
# malformed redirect_uri). This wrapper talks to Zitadel's device endpoint
# directly, then hands the resulting id_token to a jwt-type OpenBao role.
#
# Usage:
#   ./openbao-login.sh [ROLE]
#   ROLE defaults to cli-global-admin (Frank -> vault-global-admin).
# Env overrides: BAO_ADDR, OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_MOUNT.
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-https://openbao.vngenterprise.com}"
ISSUER="${OIDC_ISSUER:-https://accounts.vngenterprise.com}"
CLIENT_ID="${OIDC_CLIENT_ID:-382833937707238909}"   # Zitadel "openbao-cli" public app
MOUNT="${OIDC_MOUNT:-oidc}"
ROLE="${1:-cli-global-admin}"
export BAO_ADDR

command -v bao >/dev/null || { echo "bao CLI not found in PATH" >&2; exit 1; }

jget() { python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))"; }

# 1) Start device authorization.
dev=$(curl -sS --max-time 15 -X POST "$ISSUER/oauth/v2/device_authorization" \
  -d client_id="$CLIENT_ID" -d "scope=openid profile email")
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
  tok=$(curl -sS --max-time 15 -X POST "$ISSUER/oauth/v2/token" \
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
