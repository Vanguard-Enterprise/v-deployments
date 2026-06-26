# cluster/talos/use1

Source-of-record for **node-level Talos machine config** that is applied **out-of-band**
with `talosctl` (NOT by ArgoCD — this directory is not referenced by any Application).

The cluster's full Talos config (`controlplane.yaml`/`secrets.yaml`) is **not** stored in
git. Only targeted, reviewed patches are recorded here so changes are not lost.

## Files

- `oidc-apiserver.patch.yaml` — adds kube-apiserver OIDC flags so humans authenticate via
  the in-cluster Zitadel IdP. See the header in that file for the canary apply procedure.
  Replace `<KUBECTL_CLIENT_ID>` with the Zitadel `kubectl` OIDC app Client ID before applying.

## Break-glass

Admin access is a client cert in `~/.kube/config` (and `~/.talos/config` for Talos),
both 1-year certs. Renew before the annual expiry with:

```
talosctl config new <out> --nodes 10.1.50.30   # mint fresh os:admin talosconfig
talosctl kubeconfig --force                     # regenerate admin kubeconfig
```

Control planes: 10.1.50.31 / .32 / .33  (VIP/endpoint 10.1.50.30).
