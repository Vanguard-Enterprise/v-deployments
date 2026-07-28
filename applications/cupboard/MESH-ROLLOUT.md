# Linkerd mesh rollout (Phase 7 PR7)

Companion to `NETWORKPOLICY-ROLLOUT.md`. That document covers PR6's L3/L4
default-deny; this one covers the mTLS layer on top of it and, importantly, how
the two interact.

## State

All 9 cupboard app namespaces are meshed. `cupboard-db` and `cupboard-redis` are
deliberately NOT meshed: they are operator-managed stateful workloads (CNPG,
redis-operator) and mTLS on the internal APIs does not need them.

| Namespace | Meshed | Inbound policy | Enforced mTLS on :8080 |
|---|---|---|---|
| cupboard-identity | yes | audit | **yes**, 4 identities |
| cupboard-fleet | yes | audit | **yes**, 3 identities |
| cupboard-collector | yes | audit | **yes**, 1 identity |
| cupboard-metrics | yes | audit | **yes**, 1 identity |
| cupboard-gateway | yes | audit | no, see below |
| cupboard-web | yes | audit | no, see below |
| cupboard-auth | yes | audit | no, see below |
| cupboard-tenant | yes | audit | no, see below |
| cupboard-bot | yes | audit | n/a, no inbound traffic |
| cupboard-db, cupboard-redis | no | n/a | n/a |

## Why only four services are enforced

`cupboard-gateway`, `web`, `auth` and `tenant` each terminate a Traefik
IngressRoute, and **Traefik is not meshed**. A mesh-identity-only
AuthorizationPolicy on their :8080 would reject real user traffic outright.

Closing that gap needs a decision, not just more YAML. The options:

1. **Mesh Traefik.** Cleanest end state: every hop gets an identity and those
   four services enforce exactly like the internal four. But Traefik is shared
   cluster ingress, not a cupboard component, so this is a blast radius well
   beyond Phase 7.
2. **Add a NetworkAuthentication for Traefik** alongside the
   MeshTLSAuthentication. Works today, but it authorizes by IP/CIDR, which is
   materially weaker than workload identity and re-introduces the pinning
   problem that broke netbird when the pod CIDR changed in PR5.
3. **Leave them in audit.** What is shipped. Those services keep PR6's L4
   controls plus mesh encryption, without identity-based inbound authorization.

Recommendation is (1), scheduled as its own change with its own window.

## Two things that will bite you

**1. Meshed-to-meshed traffic does not use the app's port.** Once both ends are
meshed the outbound proxy dials the peer's inbound proxy on **:4143**, carrying
the original port in Linkerd's transport header. Every PR6 rule scoped to :8080
stopped matching the moment the second namespace was meshed. This was caught
live: a meshed pod got 503 to `cupboard-identity:8080/healthz` while an unmeshed
pod in the same namespace got 200, and a Hubble capture showed
`... <> cupboard-identity/...:4143 Policy denied DROPPED`.

The proxy's own log is actively misleading here. It reports the LOGICAL endpoint
(`endpoint{addr=10.245.1.115:8080}`) and says `connect timed out`, which reads
like a dead backend rather than a policy drop. **Trust the Hubble capture, not
the proxy log**, when diagnosing this.

Consequence: for meshed pairs the L4 port distinction is gone, since all ports
multiplex onto 4143. Linkerd's Server/AuthorizationPolicy is what restores
per-port control, and it does so per workload identity rather than per IP.

**2. Probe paths are always authorized.** Linkerd auto-authorizes `/healthz`,
`/ready` and `/live` on a Server from any network regardless of identity. This
is why we create no HTTPRoute: the instant an HTTPRoute selects a Server, that
auto-authorization stops and you must hand-author a NetworkAuthentication for
probes. It also means **health endpoints are not protected by these policies**.
Measured, not assumed: an unauthorized identity got 200 on `/healthz` and 403 on
`/perf/summary` against the same Server.

## Verifying, and how not to fool yourself

Hubble's relay ring buffer rolls in seconds on this cluster, so a retrospective
`hubble observe --last N` quietly returns nothing and looks like "zero drops".
Capture live instead, always with a hard timeout and a bounded file:

```bash
kubectl -n kube-system port-forward svc/hubble-relay 4245:80 &
timeout 45 hubble observe --server localhost:4245 --follow \
  --namespace cupboard-identity > /tmp/cap.txt
grep DROPPED /tmp/cap.txt
```

Never leave a follow-mode capture running unbounded; one filled /tmp to 74%
during PR6.

Prove an AuthorizationPolicy actually denies before believing it. A positive
test alone is worthless, and a probe path will pass no matter what:

```bash
# point the MeshTLSAuthentication at the WRONG identity, expect 403 on a
# NON-probe path, then restore and expect the app's own response
kubectl -n cupboard-metrics patch meshtlsauthentication cupboard-metrics-clients \
  --type=merge -p '{"spec":{"identityRefs":[{"kind":"ServiceAccount","name":"default","namespace":"cupboard-auth"}]}}'
```

Confirm traffic is genuinely mTLS'd rather than merely working:

```bash
linkerd diagnostics proxy-metrics -n cupboard-gateway po/<pod> \
  | grep 'direction="outbound"' | grep -oE 'tls="[^"]*"|server_id="[^"]*"'
# want: tls="true"  server_id="default.cupboard-metrics.serviceaccount.identity.linkerd.cluster.local"
```

## Meshing a new namespace

1. Add the linkerd allows to its `networkpolicy.yaml`: egress to ns `linkerd` on
   8080/8086/8090, ingress from host/remote-node on **4191** (the proxy's own
   probe port, separate from the app's), and 4143 to/from any meshed peer.
2. Annotate its `namespace.yaml` with `linkerd.io/inject: enabled` and
   `config.linkerd.io/default-inbound-policy: audit`.
3. Commit and push. ArgoCD selfHeal+prune is on for every cupboard app, so a
   hand-applied change WILL be reverted; git is the only durable path. Sync
   takes ~3-4 minutes, and the Application's `Synced` status goes stale before
   it updates, so check the live resource, not the status field.
4. Restart the workload (injection happens at admission, so nothing meshes until
   a pod is recreated) and gate on: pod 2/2 Ready, `Certified identity` in the
   proxy log, and a live Hubble capture showing zero drops.
