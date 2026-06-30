# Global Read-Only Policy
# Allows reading all secrets but no modifications

# Read access to all KV secrets
path "kv/data/*" {
  capabilities = ["read", "list"]
}

path "kv/metadata/*" {
  capabilities = ["read", "list"]
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
