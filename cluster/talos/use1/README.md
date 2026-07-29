# cluster/talos/use1

Source-of-record for **node-level Talos machine config** that is applied **out-of-band**
with `talosctl` (NOT by ArgoCD — this directory is not referenced by any Application).

The cluster's full Talos config (`controlplane.yaml`/`secrets.yaml`) is **not** stored in
git. Only targeted, reviewed patches are recorded here so changes are not lost.

## Files

- `oidc-apiserver.patch.yaml` — adds kube-apiserver OIDC flags so humans authenticate via
  the in-cluster Zitadel IdP. See the header in that file for the canary apply procedure.
  Replace `<KUBECTL_CLIENT_ID>` with the Zitadel `kubectl` OIDC app Client ID before applying.
- `cilium-cni.patch.yaml` + `cilium-migration-runbook.md`: Phase 7 PR5, hand the CNI from
  flannel to Cilium so NetworkPolicy becomes enforceable. DRAFT, execution-gated: a live
  datapath change run only inside an operator-approved maintenance window. Read the runbook
  first; the patch is one step of a multi-step per-node live migration, not a standalone apply.
- `cilium-values-final.yaml`: the helm values that reproduce the live Cilium release.
  Includes `cni.exclusive=false`, which is a hard prerequisite for linkerd-cni below.
- `linkerd-cni-values.yaml` + `linkerd-control-plane-values.yaml`: Phase 7 PR7, the
  Linkerd service mesh (installed with helm, out-of-band, like Cilium). Both files carry
  the install command in their header. The identity certs are NOT in git; see below.
- `linkerd-cert-rotation.md`: where the mesh's trust anchor and issuer live (OpenBao,
  `kv/linkerd/use1/identity`) and how to rotate them. The issuer expires **2027-07-28**;
  rotation is manual because the anchor's private key is deliberately never given to the
  cluster. Alerted on at 30 and 7 days by the `linkerd` rule group.

## Break-glass

Admin access is a client cert in `~/.kube/config` (and `~/.talos/config` for Talos),
both 1-year certs. Renew before the annual expiry with:

```
talosctl config new <out> --nodes 10.1.50.30   # mint fresh os:admin talosconfig
talosctl kubeconfig --force                     # regenerate admin kubeconfig
```

Control planes: 10.1.50.31 / .32 / .33  (VIP/endpoint 10.1.50.30).
