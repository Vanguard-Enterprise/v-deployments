path "kv/metadata/*" {
  capabilities = ["read", "list"]
}

path "kv/data/zitadel/*" {
  capabilities = ["read"]
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
path "kv/data/rustlens/*" {
  capabilities = ["read"]
}
path "kv/data/argocd-image-updater/*" {
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
