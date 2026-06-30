#!/usr/bin/env bash
# Copy all KV-v2 secrets from the source Vault to the target OpenBao.
# Idempotent (overwrites destination paths), re-runnable, read-only on source.
#
# Requires:
#   VAULT_ADDR / VAULT_TOKEN   source Vault (read access to kv/)
#   BAO_ADDR   / BAO_TOKEN      target OpenBao (write access to kv/)
#   MOUNT (optional, default "kv")
#   DRY_RUN=1 (optional)        list what would be copied, write nothing
#
# Usage: VAULT_ADDR=.. VAULT_TOKEN=.. BAO_ADDR=.. BAO_TOKEN=.. ./copy-kv.sh
set -euo pipefail
: "${VAULT_ADDR:?}" "${VAULT_TOKEN:?}" "${BAO_ADDR:?}" "${BAO_TOKEN:?}"

exec python3 - "$@" <<'PY'
import json, os, subprocess, sys

MOUNT = os.environ.get("MOUNT", "kv")
DRY   = os.environ.get("DRY_RUN") == "1"

def vault(*args):
    return subprocess.run(["vault", *args], check=True,
                          capture_output=True, text=True).stdout

def list_keys(prefix):
    try:
        out = vault("kv", "list", "-format=json", f"{MOUNT}/{prefix}")
    except subprocess.CalledProcessError:
        return []
    return json.loads(out)

def get_secret(path):
    out = vault("kv", "get", "-format=json", f"{MOUNT}/{path}")
    return json.loads(out)["data"]["data"]

def put_secret(path, kv):
    args = ["bao", "kv", "put", f"{MOUNT}/{path}"]
    for k, v in kv.items():
        if not isinstance(v, str):
            v = json.dumps(v)
        args.append(f"{k}={v}")
    subprocess.run(args, check=True, capture_output=True, text=True)

count = 0
def walk(prefix=""):
    global count
    for k in list_keys(prefix):
        full = prefix + k
        if k.endswith("/"):
            walk(full)
        else:
            kv = get_secret(full)
            if DRY:
                print(f"  would copy {MOUNT}/{full} ({len(kv)} keys)")
            else:
                put_secret(full, kv)
                print(f"  copied {MOUNT}/{full} ({len(kv)} keys)")
            count += 1

print(f"==> {'DRY RUN: ' if DRY else ''}copy {MOUNT}/* "
      f"from {os.environ['VAULT_ADDR']} -> {os.environ['BAO_ADDR']}")
walk()
print(f"==> Done. {count} secrets {'found' if DRY else 'copied'}.")
if not DRY:
    print(f"    Spot-check: bao kv get {MOUNT}/monitoring/grafana-admin")
PY
