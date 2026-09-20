# Self-hosted Grafana OnCall

This overlay deploys the Grafana OnCall OSS engine and its bundled MariaDB,
RabbitMQ, and Redis dependencies in the `oncall` namespace. Grafana itself is
provided by the existing `grafana` application.

Before syncing the Argo CD application:

1. Create `monitoring/grafana-oncall` in OpenBao with these properties:
   `SECRET_KEY`, `MIRAGE_SECRET_KEY`, `mariadb-root-password`,
   `mariadb-password`, `mariadb-replication-password`, `rabbitmq-password`,
   `rabbitmq-erlang-cookie`, and `redis-password`.
2. Add internal DNS for `oncall.vngenterprise.com` pointing at the internal
   Traefik entry point. The Traefik `IngressRoute` is already included.
3. Sync the `oncall` Argo CD application, then open the OnCall app from
   Grafana at `https://grafana.vngenterprise.com`.

The service is self-hosted, but the official Grafana mobile push relay is not.
The web UI and alerting engine can run locally; mobile push notifications need
an independently operated notification path if they are required.
