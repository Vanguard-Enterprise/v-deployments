---
name: openbao
description: Authenticate to the use1 OpenBao (secrets backend) and run admin/cluster ops. Use whenever you need an OpenBao token — reading/writing kv secrets, managing policies/auth/roles, raft/cluster operations, or when a task says "log in to OpenBao / bao / vault". Covers the human OIDC login (device-style click-approve, no localhost paste) and the machine break-glass login.
---

# OpenBao (use1) auth & ops

OpenBao is the secrets backend on the **use1** cluster (replaced Vault). API is plain HTTP internally
(`http://openbao.openbao.svc.cluster.local:8200`, `tls_disable=1`) and public at
`https://openbao.vngenterprise.com`. Raft HA, 3 nodes (`openbao-0/1/2`), auto-unseal via `static` seal.
KV-v2 mount = `kv/`. kubectl context = `use1-oidc`.

## Which login do I want?

- **Acting as the human user (Frank / a Pocket ID identity)** → OIDC device-flow login. Use this when the
  task is "log in as me", or needs a real person's grants. Requires the user to click **Approve** once.
- **Machine / automation / cluster ops (no human)** → break-glass k8s login. No browser. Use for raft
  repair, policy edits, or anything an agent must do unattended.

## 1. Human login — device flow, click-approve, NO localhost paste

Use the wrapper `applications/openbao/config/openbao-login.sh`. It runs the Pocket ID **Device
Authorization Grant** and exchanges the resulting id_token for an OpenBao token via a jwt-type role — so
the user just clicks **Approve** in the browser; there is no localhost callback and nothing to paste back.

```bash
applications/openbao/config/openbao-login.sh [role]      # role defaults to cli-global-admin
```

To ask the user for a login: run it (in the background so you can read its output), then relay the printed
`https://id.vngenterprise.com/device?user_code=XXXXXXXX` URL and **wait**. When they approve, the
wrapper caches the token (`bao token lookup` then works). The device code expires in ~5 min, so ask
them to approve promptly; if it lapses (`expired_token`), just re-run.

jwt login roles (bound to the caller's Pocket ID `groups` claim; add more mirroring the `oidc` roles as needed):
- `cli-global-admin` → `vault-global-admin` (members of the Pocket ID `vault_admins` group). Others (`global-admin`/... ) are
  `role_type=oidc` for the browser UI, NOT usable with this wrapper.

Under the hood: dedicated **public** Pocket ID client "OpenBao CLI" (client `118684db-4715-4c61-9220-0076b29e4ded`,
device grant, no secret, restricted to `vault_admins`) → id_token → `bao write auth/oidc/login role=cli-global-admin jwt=<id_token>`
against a `role_type=jwt` role whose `bound_audiences=[118684db-4715-4c61-9220-0076b29e4ded]`, `bound_claims.groups=[vault_admins]`.

Do NOT use `bao login -method=oidc callbackmode=direct|device` — both are broken in OpenBao 2.5.5 (device
= `no state returned`; direct = the CLI builds a malformed redirect_uri). The wrapper exists because of this.

## 2. Machine / break-glass login (unattended)

IdP-independent admin via k8s auth. SA `openbao-break-glass` (ns `openbao`) → `vault-global-admin`,
15m TTL. Run from a host with kubectl access to `use1-oidc`:

```bash
C=use1-oidc
JWT=$(kubectl --context $C -n openbao create token openbao-break-glass --duration=10m)
# bao CLI lives in the openbao pods (distroless: use `sh -c`, no cat/openssl):
TOK=$(kubectl --context $C -n openbao exec openbao-0 -- sh -c \
  'BAO_ADDR=http://127.0.0.1:8200 bao write -field=token auth/use1/login role=break-glass jwt='"$JWT")
# then run admin commands, e.g.:
kubectl --context $C -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$TOK bao <cmd>"
```

Shell state doesn't persist between separate exec calls; re-login (fresh 10m JWT) per batch of commands.

## Roles/policies reference
- ESO uses k8s auth: mount `use1`, role `external-secrets` → policy `use1`.
- Policies are files under `applications/openbao/config/policies/*.hcl`, applied **manually** by
  `bootstrap.sh` (NOT ArgoCD) — live edits don't self-heal-revert, but keep the repo in sync.
- `vault-global-admin` includes `sys/storage/raft/*` (added for break-glass raft/cluster ops).

## Cluster / raft ops
Raft node repair (diverged member, `tls: unrecognized name`, stale leader redirect causing ESO
`no route to host` flapping): see the memory note `openbao-raft-node-repair`.
Standard fix: break-glass login → `bao operator raft remove-peer <id>`
→ wipe that node's `data-openbao-N` PVC + delete pod → it rejoins fresh and auto-unseals.
