# Fleet (use1)

Fleet device management (https://fleetdm.com), Premium license, at
https://fleet.vngenterprise.com.

| Piece | Where |
|---|---|
| Fleet server (2 replicas) and migrations | Helm chart `fleet` (values.yaml), patched for Argo CD and restricted Pod Security |
| MySQL 8.4 | mysql.yaml, 10 Gi Longhorn volume |
| Redis (Valkey, no persistence) | redis.yaml |
| Pocket ID gate for the console | oauth2-proxy.yaml, Pocket ID client "Fleet", group `fleet_admins` |
| Routing | ingress.yaml (external Traefik) |
| Secrets | OpenBao `kv/fleet/use1`, `kv/fleet/s3`, `kv/fleet/oauth2-proxy` |
| Object storage | Wasabi bucket `fleet-use1` (us-east-2): `software-installers/`, `carves/`, `mysql-backups/` |

## Access

- **Agents and MDM** reach the server from anywhere through Cloudflare, but only on
  the paths Fleet documents as public (ingress.yaml lists them).
- **The console and API** answer only from the LAN and NetBird. A browser first signs
  in through Pocket ID (group `fleet_admins`), then logs in to Fleet. Fleet's SSO is
  SAML-only and Pocket ID is OIDC-only, so the two logins cannot be merged.
- **fleetctl** works from the LAN or NetBird with a Fleet API token
  (`fleetctl config set --address https://fleet.vngenterprise.com`, then
  `fleetctl login` or `--token`).

## Backups and restore

- Longhorn backs up the MySQL volume (default recurring group: hourly to monthly).
- `fleet-mysql-backup` writes a nightly `mysqldump` to `s3://fleet-use1/mysql-backups/`
  and keeps 30 days. The header of mysql-backup.yaml has the restore command.
- `server_private_key` in `kv/fleet/use1` encrypts the MDM certificates and keys in
  the database. A restore with a different key loses them and forces every MDM
  device to re-enroll.

## MDM setup (in the console)

- Apple: Settings > Integrations > MDM > Apple. Upload the APNs certificate
  (renew it yearly with the same Apple ID), and optionally connect Apple Business
  Manager for automatic enrollment.
- Windows: Settings > Integrations > MDM > Windows, then turn on Windows MDM.
