# Cupboard NetworkPolicy rollout (Phase 7 PR6)

Default-deny **ingress and egress** across all eleven cupboard namespaces, with
explicit allows, per decision I of `Cupboard/docs/phase7-plan.md`. The CNI is Cilium
1.19.6 (migrated from flannel in PR5, runbook in `cluster/talos/use1/`), kube-proxy is
retained, pod CIDR is `10.245.0.0/16`.

These are **CiliumNetworkPolicy** (`cilium.io/v2`), not plain `NetworkPolicy`, because
the allow set needs two things upstream NetworkPolicy cannot express:

- `fromEntities: [host, remote-node]` for kubelet probes, and
- `toFQDNs` for the per-service internet allow-lists.

## The one rule that matters

**One namespace at a time. Watch. Then the next.**

Every policy file contains its namespace's default-deny *and* all of its allows, so a
single `kubectl apply` flips a namespace atomically and a single `kubectl delete`
reverts it. Never split a default-deny away from its allows, and never `kustomize
build ... | kubectl apply -f -` the whole cupboard tree in one go for the first
rollout: that flips eleven namespaces simultaneously and turns any single authoring
mistake into a full-platform outage.

## File locations

| Namespace | Policy file |
|---|---|
| cupboard-metrics | `applications/cupboard/overlays/metrics/networkpolicy.yaml` |
| cupboard-bot | `applications/cupboard/overlays/bot/networkpolicy.yaml` |
| cupboard-fleet | `applications/cupboard/overlays/fleet/networkpolicy.yaml` |
| cupboard-collector | `applications/cupboard/overlays/collector/networkpolicy.yaml` |
| cupboard-identity | `applications/cupboard/overlays/identity/networkpolicy.yaml` |
| cupboard-auth | `applications/cupboard/overlays/auth/networkpolicy.yaml` |
| cupboard-tenant | `applications/cupboard/overlays/tenant/networkpolicy.yaml` |
| cupboard-redis | `applications/redis-operator/overlays/cupboard/networkpolicy.yaml` |
| cupboard-web | `applications/cupboard/overlays/web/networkpolicy.yaml` |
| cupboard-gateway | `applications/cupboard/overlays/gateway/networkpolicy.yaml` |
| cupboard-db | `applications/cloudnative-postgres/overlays/cupboard/networkpolicy.yaml` |

`cupboard-db` and `cupboard-redis` are not under `applications/cupboard/` because
those namespaces are owned by the `cnpg-cupboard` and `cupboard-redis` ArgoCD
Applications. The policies live with the resources they protect.

## Ordered rollout

Least blast radius first, most last. Soak at least one full traffic cycle (10-15
minutes of real use, and long enough for the slowest periodic loop in that namespace)
before moving to the next step. Do not batch steps.

| # | Namespace | Why here | What must still work after apply |
|---|---|---|---|
| 1 | **cupboard-metrics** | Smallest surface in the fleet: Redis in, OTLP out, no DB, no internet, no service-to-service calls. If the authoring pattern is wrong, this is where it shows up cheaply. | `/perf/*` through the gateway; perf gauges still landing in Mimir. |
| 2 | **cupboard-bot** | Second smallest and fully self-contained. Also the first test of the `toFQDNs` + L7-DNS pattern, on the least critical consumer. | Discord gateway websocket stays connected; a `/ticket` command round-trips; ticket stream consumer keeps draining. |
| 3 | **cupboard-fleet** | Leaf service: three known callers in, Postgres and OTLP out, nothing else. | `/fleet/*` through the gateway; collector reconcile; identity BM import servers phase. |
| 4 | **cupboard-collector** | Adds the broad `toEntities: world` carve-out. Verify RCON and A2S still reach real game servers before locking down anything upstream of it. | RCON connects; A2S queries return; `/ingest/*` accepted; ingest stream still filling. |
| 5 | **cupboard-identity** | First namespace with four distinct ingress sources plus a `toFQDNs` rule under real load. | Ban lookups from the collector; `/players`, `/bans`, `/evasion` via gateway; a BattleMetrics import tick. |
| 6 | **cupboard-auth** | Public callback host plus two identity providers. Login is user-visible, so it wants a quiet window. | Operator login; Steam player login end to end (`cupboard-login.vngenterprise.com`); Discord OAuth; invite accept. |
| 7 | **cupboard-tenant** | Widest allow set of any app namespace: four ingress sources, four commerce FQDNs, and apiserver writes. | Storefront reads; a provider webhook delivery; a Stripe call; one `domains_loop` tick that writes a Certificate/IngressRoute. |
| 8 | **cupboard-redis** | Shared dependency: a mistake here degrades six services at once. Goes after all its clients so any drop is unambiguous. | All six client namespaces still reading/writing streams; `kubectl -n cupboard-redis get redisreplication cupboard-redis` healthy. |
| 9 | **cupboard-web** | User-facing SSR plus the cert-manager ACME solver pods that land in this namespace. | Dashboard and storefronts render; a custom-domain certificate can still be issued (this is the step most likely to surface an HTTP-01 problem). |
| 10 | **cupboard-gateway** | The single front door for every dashboard and API call. Everything downstream is already policed, so a drop here is isolated to the gateway's own allow set. | Every `/auth`, `/fleet`, `/players`, `/ingest`, `/perf`, `/sites`, `/store`, `/public` route. |
| 11 | **cupboard-db** | Riskiest. Every stateful service is behind it, and CNPG's own control traffic (operator, instance manager, pooler to primary, apiserver status writes) is easy to under-allow. Apply only against a healthy primary that is not mid-failover. | CNPG cluster stays `Cluster in healthy state`; all five DB clients keep their pools; the PodMonitor scrape keeps returning samples. |

## Watching for drops

Per namespace, live:

```sh
hubble observe --verdict DROPPED --namespace cupboard-metrics --follow
```

Whole cupboard fleet at once (useful while soaking a step, since a drop caused by
namespace A often shows up as a drop reported on namespace B):

```sh
hubble observe --verdict DROPPED --follow | grep cupboard
```

Recent history rather than a live tail, which is what you want immediately after an
apply:

```sh
hubble observe --verdict DROPPED --namespace cupboard-metrics --last 500
```

Both directions of a specific suspected pair:

```sh
hubble observe --from-namespace cupboard-gateway --to-namespace cupboard-db --last 200
hubble observe --verdict DROPPED --to-namespace cupboard-db --last 200
```

DNS specifically, which is the first thing to check when a namespace goes quiet
(especially in the four namespaces that use the L7 DNS proxy: auth, identity, tenant,
bot):

```sh
hubble observe --namespace cupboard-auth --protocol dns --last 100
```

Confirm which policies are actually loaded on an endpoint:

```sh
kubectl -n cupboard-metrics get cnp
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list | grep cupboard
```

## Rollback

Instant, per namespace, no side effects (Cilium removes the default-deny with the
policy, so the namespace returns to allow-all):

```sh
kubectl delete -f applications/cupboard/overlays/metrics/networkpolicy.yaml
```

Established connections are conntrack-tracked, so a rollback does not require
restarting pods. Long-lived connections that were killed by the enforcement (Redis
consumer groups, the Discord gateway websocket, sqlx pools) generally reconnect on
their own, but check the affected pods before declaring the rollback clean.

If several namespaces are already enforced and the platform is broken in a way that is
not obviously attributable, remove them all and start over rather than debugging under
outage:

```sh
kubectl delete cnp --all -n cupboard-metrics -n cupboard-bot   # etc, one per namespace
```

Because these files are also in the kustomizations, ArgoCD will re-create anything you
delete by hand on the next sync. For a rollback that sticks, either disable auto-sync
on that Application first, or revert the commit.

## Optional: audit mode before enforcement

Decision I calls for audit mode first. Cilium can log verdicts without enforcing them,
per endpoint, which lets a policy be validated against real traffic with zero risk:

```sh
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list | grep cupboard-metrics
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint config <endpoint-id> PolicyAuditMode=Enabled
```

Apply the policy, drive traffic, and read `hubble observe --verdict AUDIT --namespace
cupboard-metrics`. Anything that would have been dropped appears there. Turn it off
(`PolicyAuditMode=Disabled`) to enforce. Audit mode is per endpoint and does not
survive a pod restart, so treat it as a rehearsal tool rather than a rollout state.

## Known follow-ups

- **Linkerd (PR7) needs an additive allow block in every meshed namespace.** When the
  mesh lands, each injected cupboard namespace additionally needs egress to the
  linkerd control plane (`linkerd-destination`, `linkerd-identity`,
  `linkerd-policy-validator`) and ingress from the proxy-injector webhook path.
  Sidecars also change what the kubelet probe path looks like on the wire. This is an
  **additive block appended to each existing file**, not a rewrite: the pair matrix
  above stays the source of truth. Decision I explicitly carries this conditional
  block so PR7 does not retro-break PR6.
- **Non-cupboard namespaces stay unpoliced this phase.** Locking down rustlens,
  grafana, zitadel, openbao and the rest is deferred (see the phase 7 plan's
  "Deferred" section). The CNI makes it possible; it is not a Phase 7 deliverable.
- **Production (decision M).** The prod overlay tree gets its own copies of these
  files against `cupboard-prod-*` namespaces, plus one rule staging does not need:
  egress from the prod `cupboard-db` namespace to the `barmanObjectStore` S3 endpoint.
- **Talos apiserver identity.** The apiserver runs hostNetwork on the control planes,
  so its identity carries both `reserved:kube-apiserver` and the node identity. If
  `cupboard-db` or `cupboard-tenant` shows apiserver drops, add `remote-node` to the
  `toEntities` list on that one rule rather than widening anything else.
