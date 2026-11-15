# smtp-relay

Outbound-only mail relay for everything we run. Apps log in to this Postfix relay,
and the relay hands the mail to the Google Workspace SMTP relay service, which
delivers it. No app holds a Google credential and no app needs a Google license.

```
 Grafana, Pocket ID, ...  (pods)  ─┐
 Proxmox, Docker hosts    (LAN)   ─┼─ 587 STARTTLS + per-app login ─► smtp-relay.vngenterprise.com
 NetBird peers                    ─┘                                        │
                                                                            ▼
                                         smtp-relay (Postfix StatefulSet x2, queue on Longhorn)
                                           - each login may only send as its own address
                                           - Google 5.7.x refusals are queued, not bounced
                                           - metrics -> Mimir, JSON logs -> Loki, alerts -> Slack
                                                                            │ 587, TLS verified
                                                                            ▼ from our public IP
                                         smtp-relay.gmail.com (authorizes us by that IP)
                                                                            ▼
                                         recipients and Google Groups (alerts@ ...)
```

| Piece | Where |
|---|---|
| Postfix (bokysan `mail` chart 5.2.1) | `overlays/use1/values.yaml` |
| Logins (one per app) | OpenBao `kv/smtp-relay/use1`, `overlays/use1/external-secret.yaml` |
| Which login may send as which address | `overlays/use1/policy.configmap.yaml` |
| Who may connect | `overlays/use1/networkpolicy.yaml` |
| TLS certificate (`smtp-relay.vngenterprise.com`) | `overlays/use1/certificate.yaml` |
| In-cluster name | CoreDNS rewrite in `applications/coredns-config` |
| LAN / NetBird name | NetBird DNS zone record `smtp-relay.vngenterprise.com` -> `10.1.50.177` |
| Alerts | `applications/grafana/overlays/use1/vanguard/alerts/rules-smtp-relay.configmap.yaml` |

## Connection settings for any app

| Setting | Value |
|---|---|
| Host | `smtp-relay.vngenterprise.com` |
| Port | `587` |
| Encryption | STARTTLS, required (the relay refuses to authenticate without it) |
| Certificate | Let's Encrypt, verify it normally (no "skip verify") |
| Username | the app's address, e.g. `grafana@vngenterprise.com` |
| Password | OpenBao `kv/smtp-relay/use1`, the app's property |
| From address | exactly the username address. Any other envelope sender is refused. |

The From address does not need a mailbox or a Google license. Google accepts any
`@vngenterprise.com` sender from our IP ("Only addresses in my domains").

## Prerequisite: OpenBao policy

External Secrets reads `kv/smtp-relay/*` with the `use1` policy
(`applications/openbao/config/policies/use1.hcl`, path `kv/data/smtp-relay/*`).
Policies are not applied by Argo CD. Before the first deploy, or after changing
the file, apply it with `bao policy write use1 applications/openbao/config/policies/use1.hcl`
(or rerun `applications/openbao/config/bootstrap.sh`). Without it
`smtp-relay-users` and `grafana-smtp` stay unsynced and the relay has no logins.

## Adding an app

1. Pick its address, e.g. `pelican@vngenterprise.com`.
2. Add a random password to OpenBao (no `:` or `,` in it):
   ```bash
   bao kv patch kv/smtp-relay/use1 pelican="$(openssl rand -hex 24)"
   ```
3. In this directory:
   - `policy.configmap.yaml`: add `pelican@vngenterprise.com  pelican@vngenterprise.com`.
   - `external-secret.yaml`: add the `pelican` property under `data` and
     `,pelican@vngenterprise.com:{{ .pelican }}` to `SMTPD_SASL_USERS`.
   - `networkpolicy.yaml`: add the app's namespace to the 587 ingress rule
     (not needed for LAN or NetBird hosts).
4. If the app's namespace has a default-deny CiliumNetworkPolicy, allow egress to
   `io.kubernetes.pod.namespace: smtp-relay` on 587 (see pocket-id's policy).
5. Give the app its password with its own ExternalSecret that reads only its
   property, in sync wave -1 so it exists before the app starts (see
   `applications/grafana/overlays/use1/vanguard/external-secret-smtp.yaml`).
   Apps read the password at start, so restart the app after changing it.
6. Merge, then restart the relay so it loads the new login:
   `kubectl -n smtp-relay rollout restart statefulset smtp-relay`.

## App recipes

### Grafana (done in this repo)

`applications/grafana/overlays/use1/vanguard/values.yaml` sets `[smtp]`
(host, user, `startTLS_policy: MandatoryStartTLS`), and `GF_SMTP_PASSWORD` comes from
the `grafana-smtp` ExternalSecret. The `email-alerts` contact point sends to the
`alerts@` Google Group. Test it from Alerting > Contact points > email-alerts > Test.

### Pocket ID

Pocket ID keeps its email settings in its database (they are only read from env
vars when `UI_CONFIG_DISABLED=true`, which would move every UI setting to env vars).
Its network policy already allows the relay. In Pocket ID, Admin >
Application Configuration > Email:

| Field | Value |
|---|---|
| SMTP Host | `smtp-relay.vngenterprise.com` |
| SMTP Port | `587` |
| SMTP From | `identity@vngenterprise.com` |
| SMTP User | `identity@vngenterprise.com` |
| SMTP Password | OpenBao `kv/smtp-relay/use1` -> `pocket_id` |
| SMTP TLS Option | StartTLS |
| Skip certificate verification | off |

Then send the test email from the same page, and turn on the emails you want
(sign-in notifications, one-time login codes, API key expiry).

### Proxmox VE (Datacenter > Notifications > Add > SMTP)

Server `smtp-relay.vngenterprise.com`, Encryption `STARTTLS`, Port `587`, Authenticate
on, Username `proxmox@vngenterprise.com`, Password from OpenBao, From Address
`proxmox@vngenterprise.com`. Add the login first (see "Adding an app"). The host must
resolve `smtp-relay.vngenterprise.com` to `10.1.50.177` (NetBird DNS, a UniFi local DNS
record, or `/etc/hosts`).

### Docker Compose (standalone hosts)

Most images take the same five settings. For example:

```yaml
services:
  app:
    image: example/app
    environment:
      SMTP_HOST: smtp-relay.vngenterprise.com
      SMTP_PORT: "587"
      SMTP_SECURITY: starttls
      SMTP_USERNAME: app@vngenterprise.com
      SMTP_FROM: app@vngenterprise.com
      SMTP_PASSWORD_FILE: /run/secrets/smtp_password
    secrets: [smtp_password]
    # Only if the host cannot resolve the name itself:
    extra_hosts:
      - "smtp-relay.vngenterprise.com:10.1.50.177"
secrets:
  smtp_password:
    file: ./smtp_password   # chmod 600, not committed
```

### Anything that only speaks `sendmail` (cron, scripts)

Install msmtp and point it at the relay:

```
# /etc/msmtprc
account default
host smtp-relay.vngenterprise.com
port 587
tls on
tls_starttls on
auth on
user host-x@vngenterprise.com
passwordeval cat /etc/msmtp.pass
from host-x@vngenterprise.com
```

## Google Workspace side

Admin console, all at the top-level org:

- Apps > Google Workspace > Gmail > Routing > **SMTP relay service**: one rule,
  allowed senders "Only addresses in my domains", "Only accept mail from the
  specified IP addresses" with our current public IP, "Require TLS encryption" on,
  "Require SMTP Authentication" off.
- Apps > Google Workspace > Gmail > **Authenticate email**: DKIM on (2048-bit,
  selector `google`), TXT record published in Cloudflare.
- DNS: SPF includes `_spf.google.com`; DMARC record at `_dmarc.vngenterprise.com`.
- Groups (e.g. `alerts@`): "Who can post" must include **Entire Organization**.
  Tested: mail from `grafana@` (not a Workspace user) through the relay is accepted
  by a group with Owners, Managers, Members and Entire Organization posting, and
  External posting off.

Verified on 2026-11-15 with a message through `smtp-relay.gmail.com`:
`spf=pass smtp.mailfrom=grafana@vngenterprise.com` (aligned, so DMARC passes on
SPF). Until the `google._domainkey` record is published and "Start
authentication" is clicked, Google signs relayed mail with its default key
(`d=vngenterprise-com.<date>.gappssmtp.com`), which does not align.

### When our public IP changes

Mail waits in the queue (Google's refusal is turned into a temporary error), and
`SmtpRelayDeferredQueue` fires in Slack after 20 minutes.

1. https://admin.google.com/ac/apps/gmail/routing > SMTP relay service > edit the
   rule: add the new IP **and remove the old one** (Verizon will give the old IP to
   someone else, who could then send as `@vngenterprise.com`).
2. Flush (otherwise it retries within 15 minutes on its own):
   ```bash
   for p in smtp-relay-0 smtp-relay-1; do kubectl -n smtp-relay exec $p -c mail -- postqueue -f; done
   ```

Mail is kept for 5 days, then bounced.

## Rotating a password

Apps and the relay read passwords at start, and External Secrets only refreshes
hourly, so do it in this order:

```bash
bao kv patch kv/smtp-relay/use1 grafana="$(openssl rand -hex 24)"
# Pull the new value now instead of waiting for the hourly refresh.
kubectl -n smtp-relay annotate externalsecret smtp-relay-users force-sync="$(date +%s)" --overwrite
kubectl -n grafana annotate externalsecret grafana-smtp force-sync="$(date +%s)" --overwrite
# Wait until both report a new refreshTime (and Ready=True) before restarting.
kubectl -n smtp-relay get externalsecret smtp-relay-users -o jsonpath='{.status.refreshTime}{"\n"}'
kubectl -n grafana get externalsecret grafana-smtp -o jsonpath='{.status.refreshTime}{"\n"}'
kubectl -n smtp-relay rollout restart statefulset smtp-relay
kubectl -n smtp-relay rollout status statefulset smtp-relay
kubectl -n grafana rollout restart deployment grafana
kubectl -n grafana rollout status deployment grafana
```

Restarting before the secrets refresh leaves the old password in place, and the
app fails to log in until it is restarted again.

Expect a short window (the two rollouts, about a minute) where the app and some
relay replicas hold different passwords. Submissions in that window are refused
at login, not queued. Grafana retries a failed notification only while its
process keeps running, and it restarts last in this order, so a refused alert can
wait for its next repeat interval or be lost if it resolves first. Other apps may
not retry at all. Rotate when nothing important is due to send, and check the
app's logs afterwards.

## Operating

```bash
kubectl -n smtp-relay get pods,svc,certificate,externalsecret
kubectl -n smtp-relay exec smtp-relay-0 -c mail -- mailq             # queue + reason
kubectl -n smtp-relay exec smtp-relay-0 -c mail -- postqueue -f      # retry now
kubectl -n smtp-relay exec smtp-relay-0 -c mail -- postsuper -d ID   # drop one message
```

Loki: `{namespace="smtp-relay", container="mail"} | json` (one line per message
with `status=sent|deferred|bounced`).

## Limits and known gaps

- Google relay limits: 10,000 messages and 10,000 recipients per sender per day
  (not applied to senders that are not Workspace users), 4.6M per day per org, 100
  recipients per SMTP transaction. The relay also rate limits each client to 120
  messages a minute.
- Only the envelope sender is tied to the login. An app could still put a different
  address in the message's `From:` header.
- The relay has no Google-side failover. If Google is down or refuses us, mail
  waits up to 5 days.
- Postfix runs as root inside its container (it drops privileges itself), so the
  namespace is at the baseline Pod Security level, not restricted.

## Testing procedure

After any change to the relay or the Google rule. `./smtp-test.py` works from any
host that resolves smtp-relay.vngenterprise.com; it prompts for the password (or reads
`SMTP_PASSWORD`, set from `bao kv get -field=<app> kv/smtp-relay/use1`).

| # | Case | Expect |
|---|---|---|
| 1 | Login `grafana@`, from `grafana@`, to a real address | accepted, `status=sent` in Loki, mail arrives with SPF pass (and DKIM pass once Google signs) |
| 2 | No login | `554 5.7.1 Client host rejected` |
| 3 | Wrong password | `535 5.7.8 authentication failed`; SmtpRelayAuthFailures after several |
| 4 | Login `grafana@`, from `identity@` or `ceo@` | `553 5.7.1 Sender address rejected: not owned by user` |
| 5 | Login without STARTTLS | AUTH not offered |
| 6 | Google refusing (remove our IP from the rule) | accepted, then `status=deferred dsn=4.7.x` and SmtpRelayDeferredQueue; restore the IP, flush, `status=sent` |
| 7 | Mail to `alerts@` | arrives for every group member (needs "Entire Organization" posting) |
| 8 | Delete one relay pod | the other keeps accepting; the deleted pod's queue is delivered when it returns |
