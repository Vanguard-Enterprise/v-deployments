# Linkerd identity certificates (use1)

Phase 7 PR7. Covers what the mesh's trust material is, where it lives, and how to
rotate it before it expires.

## What exists

| Cert | Subject | Key | Expires | Private key stored |
|---|---|---|---|---|
| Trust anchor | `CN=root.linkerd.cluster.local` | ECDSA P-256 | **2036-07-25** | OpenBao only, never in the cluster |
| Identity issuer | `CN=identity.linkerd.cluster.local` | ECDSA P-256 | **2027-07-28** | OpenBao + `linkerd-identity-issuer` Secret in ns `linkerd` |

Both are in OpenBao at `kv/linkerd/use1/identity`, base64 encoded, as
`trust_anchor_crt_b64`, `trust_anchor_key_b64`, `issuer_crt_b64`, `issuer_key_b64`.

The anchor's private key is deliberately withheld from the cluster. A cluster-admin
compromise therefore cannot mint a new issuer and impersonate arbitrary workloads.
The price of that choice is that issuer rotation is a manual job, which is what the
rest of this document is about.

## THE RISK: read this first

**The issuer expires 2027-07-28. When it does, every proxy fails to get a workload
certificate and all meshed traffic stops.** Renew it well before then; a month of
margin is sensible.

This IS now alerted on, as of Phase 7 PR7:

| Alert | Fires at | Severity |
|---|---|---|
| `LinkerdIssuerCertExpiring` | issuer TTL < 30 days | warning |
| `LinkerdIssuerCertExpiringCritical` | issuer TTL < 7 days | critical |
| `LinkerdIdentityDown` | linkerd-identity has 0 ready replicas | critical |

Defined in `applications/grafana/overlays/use1/vanguard/alerts/rules-linkerd.configmap.yaml`,
fed by `applications/alloy-metrics/overlays/use1/podmonitor-linkerd.yaml`.

The metric is **`issuer_cert_ttl_seconds`**, read from the identity controller's
admin port :9990. It is NOT `identity_cert_expiration_timestamp_seconds`; an
alert on that name would sit at noData forever.

Note how it is wired: a PodMonitor, NOT a change to the alloy-metrics
`config.alloy`. The collector already runs `prometheus.operator.podmonitors` with
selector `instance=primary`, so a plain CRD is picked up with no collector edit.
Keep it that way. In PR3 an Alloy ConfigMap that passed both `kustomize build`
and `yaml.safe_load` carried an invalid component reference, CrashLooped
alloy-receiver and silently killed cluster-wide OTLP ingestion. alloy-metrics is
the scrape path every other alert depends on.

`linkerd check` also fails inside the last 60 days, as a second line of defence.

## Check current expiry

```bash
export KUBECONFIG=/tmp/use1.kubeconfig
linkerd check                      # includes "issuer cert is valid for at least 60 days"

kubectl -n linkerd get secret linkerd-identity-issuer \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -dates
```

`linkerd check` fails loudly inside the last 60 days, which is a useful manual
cross-check on the alerts above.

## Rotate the issuer (routine, no data-plane restart)

The anchor is unchanged, so proxies already trust the new issuer. Nothing needs
restarting beyond the identity controller.

1. Pull the anchor out of OpenBao (break-glass path, see the `openbao` skill):

```bash
export KUBECONFIG=/tmp/use1.kubeconfig
JWT=$(kubectl -n openbao create token openbao-break-glass --duration=10m)
TOK=$(kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 bao write -field=token auth/use1/login role=break-glass jwt=$JWT")
mkdir -p ~/linkerd-rotate && cd ~/linkerd-rotate && chmod 700 .
for f in trust_anchor_crt trust_anchor_key; do
  kubectl -n openbao exec openbao-0 -- sh -c \
    "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$TOK bao kv get -mount=kv -field=${f}_b64 linkerd/use1/identity" \
    | base64 -d > ${f}.pem
done
mv trust_anchor_crt.pem ca.crt && mv trust_anchor_key.pem ca.key
```

2. Mint a fresh issuer signed by that anchor:

```bash
openssl ecparam -name prime256v1 -genkey -noout -out issuer.key
cat > issuer.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = identity.linkerd.cluster.local
[v3_int]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
extendedKeyUsage = serverAuth, clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
openssl req -new -key issuer.key -out issuer.csr -config issuer.cnf
openssl x509 -req -in issuer.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out issuer.crt -days 365 -sha256 -extfile issuer.cnf -extensions v3_int
openssl verify -CAfile ca.crt issuer.crt          # must print: issuer.crt: OK
```

3. Install it. The anchor is unchanged, so pass the same `ca.crt`:

```bash
helm upgrade linkerd-control-plane linkerd-edge/linkerd-control-plane \
  --version <the version currently deployed> -n linkerd \
  -f linkerd-control-plane-values.yaml \
  --set-file identityTrustAnchorsPEM=ca.crt \
  --set-file identity.issuer.tls.crtPEM=issuer.crt \
  --set-file identity.issuer.tls.keyPEM=issuer.key
kubectl -n linkerd rollout restart deploy/linkerd-identity
linkerd check
```

4. Write the new material back to OpenBao (same keys, bumps the kv version) and
   update the expiry dates in this file and in `linkerd-control-plane-values.yaml`.

5. Shred the working copy: `rm -rf ~/linkerd-rotate`. The anchor key must not be
   left on disk.

## Rotate the trust anchor (rare, disruptive, plan a window)

Only needed by 2036, or immediately if the anchor key is believed compromised.
It cannot be done with a single swap: proxies must trust the old and new anchors
simultaneously while the data plane rolls, or in-flight mTLS breaks.

Outline: mint the new anchor; install a **bundle** of old+new as
`identityTrustAnchorsPEM` and wait for every proxy to pick it up; issue a new issuer
from the new anchor and restart `linkerd-identity`; restart every meshed workload;
only then drop the old anchor from the bundle. See
<https://linkerd.io/2/tasks/manually-rotating-control-plane-tls-credentials/>.

If anchor rotation is ever going to be routine, switch to cert-manager plus
trust-manager instead, which automates the bundle distribution. That was considered
for PR7 and rejected: trust-manager is not installed, and the cert-manager setup
requires the anchor's private key to live in the cluster, which is the property we
were specifically trying to avoid.
