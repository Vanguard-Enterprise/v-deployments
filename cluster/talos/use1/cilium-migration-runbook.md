# Cilium migration runbook (Phase 7 PR5)

> **Status: DRAFT, execution-gated.** Source of record for migrating `use1` from flannel
> to Cilium so `NetworkPolicy` becomes enforceable (Phase 7 PR6/PR7). This is a
> **live-cluster datapath change**: it runs ONLY inside an operator-approved maintenance
> window, and it should be rehearsed on a staging clone first. Nothing here is applied by
> ArgoCD.
>
> Grounded in the Cilium + Sidero/Talos docs (sources at the bottom) AND validated against
> the live cluster on 2026-07-24 (the concrete values below are read from use1, not
> assumed). Items still needing a same-day check are marked **[CONFIRM]**.

## Live cluster facts (read from use1 2026-07-24)

- **Talos v1.10.4, Kubernetes v1.33.1.** KubePrism is on by default (Talos >= 1.6), so
  Cilium's API endpoint is `localhost:7445`, NOT the VIP.
- **6 nodes, NOT converged:** control planes `use1-master-01/02/03`
  (10.1.50.31/.32/.33, VIP .30) are tainted `node-role.kubernetes.io/control-plane:NoSchedule`
  and run only kube-system pods; **all workloads (cupboard, longhorn, cnpg, metallb, redis)
  run on the 3 workers** `use1-worker-01/02/03` (10.1.50.41/.42/.43). This is far less
  dangerous than a converged cluster: worker drains carry the stateful risk, control-plane
  drains carry only etcd quorum.
- **CNI: flannel**, VXLAN backend on **port 4789** (`kube-flannel` DS, cm `kube-flannel-cfg`).
  `cluster.network.cni` is unset in the machine config (implicit flannel), so
  `cilium-cni.patch.yaml`'s `op: add` is correct (not `replace`).
- **Pod CIDR 10.244.0.0/16, service CIDR 10.96.0.0/12, node/MetalLB net 10.1.50.0/24.**
  Cilium's migration CIDR must avoid all three; **10.245.0.0/16** is clear.
- **CNPG clusters are SINGLE-instance** (`cupboard`, `grafana-db`, `rustlens` all
  `instances: 1`). There is NO replica to fail over to: draining a worker that hosts a
  CNPG pod takes that database DOWN until the pod reschedules and re-attaches its Longhorn
  volume. Plan for a short per-database outage (or temporarily scale to 2, memory permitting).
- **Longhorn:** `default-replica-count = 3`, `node-drain-policy = block-if-contains-last-replica`
  (already set). Draining one of three workers keeps 2/3 replicas. Volumes healthy at check
  time (a couple detached/unused PVCs, harmless).
- **MetalLB L2 mode**, pool `use1-pool` = 10.1.50.150-199, `speaker` DS on all nodes.
- **kube-proxy** DS runs on all 6 nodes; we KEEP it this window.

## Why, and the shape of the change

flannel does not enforce `NetworkPolicy` (objects apply but are silent no-ops), so Phase 7's
default-deny segmentation (PR6) needs a policy-capable CNI first. We adopt **Cilium** via the
documented **live per-node migration**: Cilium is installed alongside flannel on a separate
pod CIDR, then each node is drained, switched, and rebooted one at a time. The dual-CIDR
overlay keeps migrated-node and flannel-node pods talking throughout, so there is no
connectivity island. flannel stays installed as the rollback net until the finalize step.

This is NOT the OIDC-patch node-at-a-time canary (that was a stateless apiserver flag). We
reject the big-bang ("reboot everything") approach: it detaches every Longhorn volume and
kills every single-instance CNPG database at once, and risks etcd quorum.

## Decision table (resolve before the window)

| Decision | Value / recommendation | Why |
|---|---|---|
| Migration style | **Live per-node** (dual-overlay, separate CIDR) | Rolling worker drains keep 2/3 Longhorn replicas; control-plane drains keep etcd quorum; flannel stays as rollback. |
| kube-proxy | **Keep it this window** (patch = `cni.name: none` only) | Fewer simultaneous variables; MetalLB-L2 keeps working. Dropping kube-proxy (`proxy.disabled: true` + Cilium `kubeProxyReplacement`) is a SEPARATE later window. |
| MetalLB | **Keep MetalLB; leave Cilium L2/LB-IPAM OFF** | Two L2 announcers on one pool = ARP conflict; Cilium L2 also needs kube-proxy disabled, which we are not doing. MetalLB->Cilium is an optional later project. |
| Cilium version | **[CONFIRM]** latest stable that supports k8s 1.33 (1.17.x/1.18.x era; check `docs.cilium.io/en/stable` + the k8s-compat matrix on the day) | Pin a release, never `latest`/dev. |
| Cilium API endpoint | **`localhost:7445`** (KubePrism), not the VIP 10.1.50.30 | Draining the VIP-holder must not blind Cilium on other nodes. |
| Cilium pod CIDR | **10.245.0.0/16** (RESOLVED: clear of 10.244/16, 10.96/12, 10.1.50/24) | Live migration needs Cilium on a separate range from flannel. |
| Cilium tunnel port | **8472** (RESOLVED: flannel is on 4789, so 8472 is free) | Avoid VXLAN port collision during the dual-overlay window. |
| Node order | **Workers first (one at a time), then control planes (one at a time)**; the worker holding the `cupboard` CNPG pod gets the DB-downtime note; control planes never two at once | Stateful risk is worker-side; etcd quorum is control-plane-side. |
| CNPG single-instance outage | **[CONFIRM]** accept a short per-DB outage when its worker drains, OR pre-scale that cluster to `instances: 2` if memory allows | No replica exists to fail over to. |

## Pre-flight (before touching any node)

1. **Snapshot health**: `talosctl -n 10.1.50.30 health`; `kubectl get nodes -o wide` (all 6
   Ready); every namespace's pods Ready; Cilium not yet present.
2. **etcd**: `talosctl -n 10.1.50.31 etcd status` (and .32/.33) all healthy, 3 members, one
   leader, equal RAFT index, no errors, no learners.
3. **Longhorn**: every in-use volume `healthy` at 3 replicas; node-drain-policy is already
   `block-if-contains-last-replica` (verify it still is).
4. **CNPG**: note which worker hosts each single-instance primary (`cupboard-1`,
   `grafana-db-1`, `rustlens-*`); decide accept-outage vs pre-scale per the decision table.
5. **MetalLB**: note which node announces each LoadBalancer IP (Traefik 10.1.50.175/.176
   especially; pool 10.1.50.150-199).
6. **Access**: `~/.talos/config` os:admin cert valid (README break-glass), and you can reach
   every node by its own IP (the VIP node gets drained).

## Procedure

### Step 1 - install Cilium in migration mode (no node touched yet)

Helm install a migration values file. Load-bearing bits: `ipam.mode: cluster-pool` with
`clusterPoolIPv4PodCIDRList: ["10.245.0.0/16"]`; `tunnelProtocol: vxlan` + `tunnelPort: 8472`;
`policyEnforcementMode: never`; `cni.customConf: true` (do NOT write the CNI conf yet);
`operator.unmanagedPodWatcher.restart: false`; `bpf.hostLegacyRouting: true`; the
Talos-mandatory `securityContext.capabilities.*` sets and `cgroup.autoMount.enabled: false` +
`cgroup.hostRoot: /sys/fs/cgroup`; `k8sServiceHost: localhost` + `k8sServicePort: 7445`.
Keep `kubeProxyReplacement: false` (we keep kube-proxy). Verify `cilium status` operator up,
flannel still running, no node flipped.

### Step 2 - CiliumNodeConfig gated on a label that matches nothing yet

`CiliumNodeConfig` (kube-system) selecting `io.cilium.migration/cilium-default: "true"`,
writing `/host/etc/cni/net.d/05-cilium.conflist`, `cni-exclusive: true`,
`cni-chaining-mode: none`. No node carries the label, so nothing changes.

### Step 3 - migrate WORKERS first, one at a time (.41 -> .42 -> .43)

For each worker `$NODE` / IP `$IP`, waiting for full health between nodes:
1. If this worker hosts a CNPG pod, expect that DB to be down from drain until it reschedules
   and its Longhorn volume re-attaches (pre-scale first if you chose that path).
2. `kubectl cordon $NODE`
3. `kubectl drain --ignore-daemonsets --delete-emptydir-data $NODE` (respect Longhorn PDBs;
   do not force-delete Longhorn/CNPG pods; the drain policy blocks on a last replica).
4. `kubectl label node $NODE --overwrite io.cilium.migration/cilium-default=true`
5. `kubectl -n kube-system delete pod --field-selector spec.nodeName=$NODE -l k8s-app=cilium`
   then `kubectl -n kube-system rollout status ds/cilium -w`.
6. `talosctl -n $IP patch mc -p @cluster/talos/use1/cilium-cni.patch.yaml` then
   `talosctl -n $IP reboot`.
7. Wait: node `Ready`; `cilium status --wait` clean; the node's Longhorn instance-manager
   healthy and iSCSI re-attached; any CNPG pod that landed here back to Ready; CoreDNS serving.
8. `kubectl uncordon $NODE`; verify workloads rescheduled and healthy before the next worker.

### Step 4 - migrate CONTROL PLANES, one at a time (.31 -> .32 -> .33)

Same per-node steps, but the constraint is **etcd quorum**: after each control-plane reboot,
confirm the node is `Ready` AND `talosctl etcd status` on the other two shows quorum re-formed
(equal RAFT index, one leader) BEFORE touching the next. Never drain/reboot two control planes
at once. Do the node currently holding the **VIP last** (KubePrism keeps Cilium's API reachable
via localhost:7445 when the VIP moves). Control planes carry only kube-system pods, so no
Longhorn/CNPG concern here.

### Step 5 - finalize (after ALL 6 nodes are on Cilium)

Helm-upgrade Cilium out of migration mode: `operator.unmanagedPodWatcher.restart: true`,
`cni.customConf: false`, `policyEnforcementMode: default`, `bpf.hostLegacyRouting: false`.
Remove flannel (`kube-flannel` DS + `kube-flannel-cfg`) and the `CiliumNodeConfig` + migration
labels. Verify DNS, MetalLB IP reachability (Traefik LBs), and a cross-namespace pod-to-pod path.

### Step 6 - soak, THEN policy work (PR6)

Soak on Cilium (a day+) before any enforcement. PR6 stages default-deny with Cilium **policy
audit mode** (allow-all-but-log would-be drops via Hubble) per cupboard namespace, then flips
to enforce one namespace at a time. Non-cupboard namespaces stay unpoliced this phase.

## Rollback

Per node, before finalize (flannel still installed): remove the label
(`kubectl label node $NODE io.cilium.migration/cilium-default-`), cordon/drain, delete
Cilium's CNI conf on that node, re-apply a patch setting `/cluster/network/cni/name` back to
`flannel`, `talosctl apply-config`, reboot; the node rejoins on flannel. Un-migrated nodes were
never touched, so a mid-run abort's blast radius is only the flipped node(s). Full revert also
`helm uninstall cilium`. **[CONFIRM]** the full-revert path on a staging clone; the Cilium docs
give no explicit rollback.

## Interaction hazards (summary)

- **etcd quorum**: never drain/reboot two of three control planes at once.
- **Longhorn**: one worker at a time keeps 2/3 replicas; verify iSCSI re-attach post-reboot.
- **CNPG single-instance**: short per-DB outage on its worker's drain (no replica); pre-scale
  or accept it, per the decision table.
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
