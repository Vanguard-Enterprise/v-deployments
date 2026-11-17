# v-deployments

GitOps manifests for the Vanguard Enterprise `use1` Kubernetes cluster. Argo CD
syncs `main` automatically.

- `argocd/`: the app-of-apps and every Argo CD `Application`.
- `applications/<app>/`: Kustomize bases and overlays for each app.
- `cluster/`: Talos and Cilium configuration applied by hand.

Documentation lives in the [wiki](https://github.com/Vanguard-Enterprise/v-deployments/wiki).
