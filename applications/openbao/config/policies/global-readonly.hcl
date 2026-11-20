# Global Read-Only Policy
# Allows reading all secrets but no modifications

# Read access to all KV secrets
path "kv/data/*" {
  capabilities = ["read", "list"]
}

path "kv/metadata/*" {
  capabilities = ["read", "list"]
}

# CI signing keys (kv/ci/*) are for their workflows only. Read-only humans can
# still see that they exist through metadata, but never read their values.
path "kv/data/ci/*" {
  capabilities = ["deny"]
}

# List secret engines
path "sys/mounts" {
  capabilities = ["read"]
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
