path "kv/metadata/*" {
  capabilities = ["read", "list"]
}

path "kv/data/cert-manager/cloudflare-token" {
  capabilities = ["read"]
}
path "kv/data/netbird/*" {
  capabilities = ["read"]
}
path "kv/data/dockerconfig/aliencord-github" {
  capabilities = ["read"]
}
path "kv/data/monitoring/*" {
  capabilities = ["read"]
}
path "kv/data/argocd-image-updater/*" {
  capabilities = ["read"]
}
path "kv/data/argocd/github-app" {
  capabilities = ["read"]
}
path "kv/data/longhorn/backup-storage" {
  capabilities = ["read"]
}
path "kv/data/cnpg/*" {
  capabilities = ["read"]
}
path "kv/data/cupboard/*" {
  capabilities = ["read"]
}
path "kv/data/pocket-id/*" {
  capabilities = ["read"]
}
path "kv/data/rooted-in-pages/*" {
  capabilities = ["read"]
}
path "kv/data/mcp-hub/*" {
  capabilities = ["read"]
}
path "kv/data/smtp-relay/*" {
  capabilities = ["read"]
}
