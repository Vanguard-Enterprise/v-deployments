# v-deployments

GitOps manifests for the Vanguard Enterprise `use1` Kubernetes cluster. Argo CD
syncs `main` automatically.

- `argocd/`: the app-of-apps and every Argo CD `Application`.
- `applications/<app>/`: Kustomize bases and overlays for each app.
- `cluster/`: Talos and Cilium configuration applied by hand.

Documentation lives in the [wiki](https://github.com/Vanguard-Enterprise/v-deployments/wiki).

## Status

| App | Status |
|---|---|
| alloy-logs | ![alloy-logs](https://argocd.vngenterprise.com/api/badge?name=alloy-logs) |
| alloy-metrics | ![alloy-metrics](https://argocd.vngenterprise.com/api/badge?name=alloy-metrics) |
| alloy-receiver | ![alloy-receiver](https://argocd.vngenterprise.com/api/badge?name=alloy-receiver) |
| argocd-image-updater | ![argocd-image-updater](https://argocd.vngenterprise.com/api/badge?name=argocd-image-updater) |
| argocd-metrics | ![argocd-metrics](https://argocd.vngenterprise.com/api/badge?name=argocd-metrics) |
| cert-manager | ![cert-manager](https://argocd.vngenterprise.com/api/badge?name=cert-manager) |
| cloudflare-ddns | ![cloudflare-ddns](https://argocd.vngenterprise.com/api/badge?name=cloudflare-ddns) |
| cloudnative-postgres-operator | ![cloudnative-postgres-operator](https://argocd.vngenterprise.com/api/badge?name=cloudnative-postgres-operator) |
| cluster-rbac | ![cluster-rbac](https://argocd.vngenterprise.com/api/badge?name=cluster-rbac) |
| cnpg-grafana | ![cnpg-grafana](https://argocd.vngenterprise.com/api/badge?name=cnpg-grafana) |
| cnpg-vanguard-portal | ![cnpg-vanguard-portal](https://argocd.vngenterprise.com/api/badge?name=cnpg-vanguard-portal) |
| coredns-config | ![coredns-config](https://argocd.vngenterprise.com/api/badge?name=coredns-config) |
| cupboard-rebuild | ![cupboard-rebuild](https://argocd.vngenterprise.com/api/badge?name=cupboard-rebuild) |
| external-secrets | ![external-secrets](https://argocd.vngenterprise.com/api/badge?name=external-secrets) |
| grafana | ![grafana](https://argocd.vngenterprise.com/api/badge?name=grafana) |
| kube-state-metrics | ![kube-state-metrics](https://argocd.vngenterprise.com/api/badge?name=kube-state-metrics) |
| loki | ![loki](https://argocd.vngenterprise.com/api/badge?name=loki) |
| longhorn | ![longhorn](https://argocd.vngenterprise.com/api/badge?name=longhorn) |
| mcp-grafana | ![mcp-grafana](https://argocd.vngenterprise.com/api/badge?name=mcp-grafana) |
| mcp-hub | ![mcp-hub](https://argocd.vngenterprise.com/api/badge?name=mcp-hub) |
| metallb | ![metallb](https://argocd.vngenterprise.com/api/badge?name=metallb) |
| metrics-server | ![metrics-server](https://argocd.vngenterprise.com/api/badge?name=metrics-server) |
| mimir | ![mimir](https://argocd.vngenterprise.com/api/badge?name=mimir) |
| n8n | ![n8n](https://argocd.vngenterprise.com/api/badge?name=n8n) |
| netbird | ![netbird](https://argocd.vngenterprise.com/api/badge?name=netbird) |
| netbird-clients | ![netbird-clients](https://argocd.vngenterprise.com/api/badge?name=netbird-clients) |
| node-exporter | ![node-exporter](https://argocd.vngenterprise.com/api/badge?name=node-exporter) |
| openbao | ![openbao](https://argocd.vngenterprise.com/api/badge?name=openbao) |
| pelican | ![pelican](https://argocd.vngenterprise.com/api/badge?name=pelican) |
| pocket-id | ![pocket-id](https://argocd.vngenterprise.com/api/badge?name=pocket-id) |
| rooted-in-pages | ![rooted-in-pages](https://argocd.vngenterprise.com/api/badge?name=rooted-in-pages) |
| routeguard | ![routeguard](https://argocd.vngenterprise.com/api/badge?name=routeguard) |
| smtp-relay | ![smtp-relay](https://argocd.vngenterprise.com/api/badge?name=smtp-relay) |
| traefik | ![traefik](https://argocd.vngenterprise.com/api/badge?name=traefik) |
| traefik-internal | ![traefik-internal](https://argocd.vngenterprise.com/api/badge?name=traefik-internal) |
| use1 | ![use1](https://argocd.vngenterprise.com/api/badge?name=use1) |
| vanguard-nexus | ![vanguard-nexus](https://argocd.vngenterprise.com/api/badge?name=vanguard-nexus) |
| vanguard-portal | ![vanguard-portal](https://argocd.vngenterprise.com/api/badge?name=vanguard-portal) |
