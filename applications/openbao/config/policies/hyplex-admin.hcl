# Hyplex Admin Policy
# Read/write access to all Hyplex-related secrets

# Full access to hyplex secrets
path "kv/data/hyplex-*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "kv/metadata/hyplex-*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "kv/delete/hyplex-*" {
  capabilities = ["update"]
}

path "kv/undelete/hyplex-*" {
  capabilities = ["update"]
}

path "kv/destroy/hyplex-*" {
  capabilities = ["update"]
}

# List all secrets (to navigate to hyplex ones)
path "kv/metadata" {
  capabilities = ["list"]
}

# Basic self-service token capabilities
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
