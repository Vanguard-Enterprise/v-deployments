# Cupboard's main-branch Check workflow reads the machine-agent release signing
# key (field signing_key, Ed25519 PEM), and nothing else. The key lives outside
# kv/cupboard/* so External Secrets (policy use1) can never sync it into the
# cluster. Its public half is agent/release-key.pub in the Cupboard repository;
# rotating the key means shipping agents that trust the new public key first.
path "kv/data/ci/cupboard/agent-release" {
  capabilities = ["read"]
}
