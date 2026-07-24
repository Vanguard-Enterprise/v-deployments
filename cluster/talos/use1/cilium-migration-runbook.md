# Cilium migration runbook (Phase 7 PR5)

> **Status: DRAFT, execution-gated.** This is the source of record for migrating `use1`
> from flannel to Cilium so that `NetworkPolicy` becomes enforceable (Phase 7 PR6/PR7).
> It is a **live-cluster datapath change** and runs ONLY inside an operator-approved
> maintenance window, on the operator's `talosctl` access. Nothing here is applied by
> ArgoCD. Rehearse on a staging clone before the live run.
>
> Grounded in the Cilium and Sidero/Talos docs (sources at the bottom). Every value the
> operator must confirm against the live cluster on execution day is marked **[CONFIRM]**.

## Why, and the shape of the change

The cluster runs Talos's default CNI, **flannel**, which does not enforce
`NetworkPolicy` (objects apply but are silent no-ops). Phase 7's default-deny segmentation
(PR6) and any policy-layer work need a policy-capable CNI first. We adopt **Cilium**.

This is NOT the OIDC-patch node-at-a-time canary shape (that was a stateless apiserver
flag). A CNI swap re-IPs pods, so we use Cilium's documented **live per-node migration**:
Cilium is installed alongside flannel on a **separate pod CIDR**, then each node is drained,
switched, and rebooted one at a time. The dual-CIDR overlay keeps migrated-node and
flannel-node pods talking throughout, so there is no connectivity island. flannel stays
installed as the rollback safety net until the final "finalize" step.

We deliberately reject the big-bang ("reboot everything") approach: it detaches every
Longhorn volume and bounces both CNPG members at once, and it risks etcd quorum on a
3-node all-control-plane cluster. See the tradeoff table below.

## Decision table (resolve before the window)

| Decision | Recommendation | Why |
|---|---|---|
| Migration style | **Live per-node** (dual-overlay, separate CIDR) | Rolling drain keeps 2/3 Longhorn replicas + a live CNPG member + etcd quorum; flannel stays as rollback. Big-bang has none of these. |
| kube-proxy | **Keep it for this window** (`cni.name: none` only) | Fewer simultaneous variables; MetalLB-L2 keeps working. Dropping kube-proxy (`proxy.disabled: true` + Cilium `kubeProxyReplacement`) is a SEPARATE later window. |
| MetalLB | **Keep MetalLB owning LoadBalancer IPs; leave Cilium L2/LB-IPAM OFF** | Two L2 announcers on the same pool = ARP conflict. Cilium L2 also requires kube-proxy disabled, which we are not doing here. MetalLB->Cilium is an optional later project. |
| Cilium version | **[CONFIRM]** latest stable (1.19.x at research time; check `docs.cilium.io/en/stable` on the day) against k8s 1.34 | Pin a release, never `latest`/dev. |
| Cilium API endpoint | **`localhost:7445`** (Talos KubePrism), NOT the VIP 10.1.50.30 | KubePrism is a per-node local HA proxy; pointing at the VIP would blind Cilium on other nodes while the VIP-holder is drained. |
| Cilium pod CIDR | **[CONFIRM]** a NEW /16 that does not overlap the flannel pod CIDR or 10.1.50.0/24 (e.g. 10.245.0.0/16) | Live migration requires Cilium on a separate range from flannel. |
| Cilium tunnel port | **[CONFIRM]** distinct from flannel's VXLAN port (flannel default 8472; use e.g. 8473) | Avoid VXLAN port collision during the dual-overlay window. |
| Node order | VIP-holder + CNPG primary node **LAST**; CNPG primary switched off its node first | Controlled failover, and Cilium keeps its API via KubePrism when the VIP moves. |

## Pre-flight (before touching any node)

1. **Snapshot health** so "different after" is detectable: `talosctl -n 10.1.50.30 health`;
   `kubectl get nodes -o wide`; every namespace's pods Ready; `cilium` not yet present.
2. **etcd**: `talosctl -n 10.1.50.31 etcd status` (and .32/.33) all healthy, 3 members.
3. **Longhorn**: every volume `healthy` and at 3 replicas; set the Longhorn **Node Drain
   Policy** to `block-if-contains-last-replica`. **[CONFIRM]** against Longhorn docs.
4. **CNPG**: `cupboard` cluster (and rustlens/grafana CNPG) primary + replica in sync;
   know which node holds each primary. **[CONFIRM]** the controlled-switchover command
   (`kubectl cnpg promote` / switchover) before draining a primary's node.
5. **MetalLB**: note which node announces each LoadBalancer IP (the external/internal
   Traefik IPs 10.1.50.175/.176 especially).
6. **Backups / break-glass**: confirm the `~/.talos/config` os:admin cert is valid (the
   README break-glass steps), and that you can reach all three nodes directly by IP
   (not only via the VIP), since the VIP node will be drained.

## Procedure

### Step 1 - install Cilium in migration mode (no node touched yet)

Helm install with a migration values file. The load-bearing bits (full Talos value set in
the sources): separate CIDR via `ipam.mode: cluster-pool`, a distinct `tunnelPort`,
`policyEnforcementMode: never`, `cni.customConf: true` (do NOT write the CNI conf yet),
`operator.unmanagedPodWatcher.restart: false`, `bpf.hostLegacyRouting: true`, plus the
Talos-mandatory `securityContext.capabilities.*` sets and `cgroup.autoMount.enabled: false`
+ `cgroup.hostRoot: /sys/fs/cgroup`, and `k8sServiceHost: localhost` / `k8sServicePort: 7445`.

Verify: `cilium status` shows the operator up; flannel still runs; no node has flipped
(the `CiliumNodeConfig` in step 2 matches no nodes yet).

### Step 2 - apply the CiliumNodeConfig gated on a label that matches nothing

`CiliumNodeConfig` (namespace kube-system) with `nodeSelector` on
`io.cilium.migration/cilium-default: "true"`, writing `/host/etc/cni/net.d/05-cilium.conflist`
with `cni-exclusive: true`, `cni-chaining-mode: none`. No node carries the label yet, so
nothing changes.

### Step 3 - migrate nodes one at a time (VIP/CNPG-primary node LAST)

For each `$NODE` (IP `$IP`), waiting for full health between nodes:

1. If this node holds a CNPG primary, **switch the primary to another node first**.
2. `kubectl cordon $NODE`
3. `kubectl drain --ignore-daemonsets --delete-emptydir-data $NODE` (respect Longhorn PDBs;
   do not force-delete Longhorn/CNPG pods).
4. `kubectl label node $NODE --overwrite io.cilium.migration/cilium-default=true`
5. `kubectl -n kube-system delete pod --field-selector spec.nodeName=$NODE -l k8s-app=cilium`
   then `kubectl -n kube-system rollout status ds/cilium -w`.
6. Apply the machine-config patch and reboot the node onto Cilium networking:
   `talosctl -n $IP patch mc -p @cluster/talos/use1/cilium-cni.patch.yaml`
   then `talosctl -n $IP reboot`.
7. Wait: node returns `Ready`; **etcd quorum re-formed** (`talosctl etcd status` on the
   other two); `cilium status --wait` clean; the node's Longhorn instance-manager healthy
   and iSCSI sessions re-established; CoreDNS still serving.
8. `kubectl uncordon $NODE`.
9. Only now move to the next node.

### Step 4 - finalize (after ALL nodes are on Cilium)

Helm-upgrade Cilium out of migration mode: `operator.unmanagedPodWatcher.restart: true`,
`cni.customConf: false`, `policyEnforcementMode: default`, `bpf.hostLegacyRouting: false`.
Remove flannel (delete its DaemonSet/config) and the `CiliumNodeConfig` + migration labels.
Verify DNS, MetalLB IP reachability, and a cross-namespace pod-to-pod path.

### Step 5 - soak, THEN policy work (PR6)

Let the cluster run on Cilium for a soak period (a day+) before any `NetworkPolicy`
enforcement. PR6 stages default-deny using Cilium **policy audit mode** (`policyAuditMode`,
which allows-all-but-logs would-be drops via Hubble) per cupboard namespace, then flips to
enforce one namespace at a time. Non-cupboard namespaces stay unpoliced this phase.

## Rollback

Per node, before finalize (flannel is still installed): remove the label
(`kubectl label node $NODE io.cilium.migration/cilium-default-`), cordon/drain, delete
Cilium's CNI conf on that node, re-apply a patch setting `/cluster/network/cni/name` back
to `flannel`, `talosctl apply-config`, reboot; the node rejoins on flannel. Un-migrated
nodes were never touched, so a mid-run abort's blast radius is only the flipped node(s).
Full revert also `helm uninstall cilium`. **[CONFIRM]** the full-revert path on a staging
clone; the Cilium docs give no explicit rollback.

## Interaction hazards (summary; detail in the pre-flight)

- **etcd quorum**: never drain/reboot two of three control planes at once.
- **Longhorn**: one-at-a-time keeps 2/3 replicas; verify iSCSI re-attach post-reboot.
- **CNPG**: controlled switchover before draining a primary's node; primary node last.
- **MetalLB**: single announcer only; Cilium L2 stays off this window.
- **CoreDNS**: keep >=1 replica Ready; the dual-overlay keeps it reachable across the split.

## Sources

- Sidero (Talos) - Deploy Cilium CNI: https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium
- Sidero (Talos) - KubePrism (localhost:7445): https://docs.siderolabs.com/kubernetes-guides/advanced-guides/kubeprism
- Cilium - Migrating a cluster to Cilium: https://docs.cilium.io/en/stable/installation/k8s-install-migration/
- Cilium - Install using Helm: https://docs.cilium.io/en/stable/installation/k8s-install-helm/
- Cilium - Without kube-proxy: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Cilium - LB-IPAM / L2 announcements: https://docs.cilium.io/en/stable/network/lb-ipam/ , https://docs.cilium.io/en/latest/network/l2-announcements/
- Cilium - Policy audit mode: https://docs.cilium.io/en/stable/security/policy-creation/
- MetalLB->Cilium (ARP window): https://blog.stonegarden.dev/articles/2023/12/migrating-from-metallb-to-cilium/
