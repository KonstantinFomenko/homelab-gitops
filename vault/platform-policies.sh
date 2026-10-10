#!/bin/sh
# Vault configuration for the showcase services of this repository (platform/platform-secrets).
# Idempotent: run after every change of the namespace list and after re-initialising Vault — always
# after vault/policies.sh of the private repository (personal apps), which enables Kubernetes auth.
# Prints only what it changes.
#
# Needs: kubectl access to the cluster and a Vault admin token inside the pod (vault/admin.sh login
# of the private repository, or the new root token right after `vault operator init`).
#
# For every <namespace> below:
#   policy platform-<namespace>: read platform/<namespace> and platform/<namespace>/* (KV v2)
#   role   platform-<namespace>: Kubernetes auth, service account "default" of namespace <namespace>,
#          token audience "vault" (SecretStore: serviceAccountRef.audiences: [vault])
# Values are never here: they are put by hand from the password manager (README, Secrets).
set -eu

# Namespaces with a SecretStore in platform/platform-secrets/templates/.
namespaces="tailscale monitoring"

v() { kubectl exec -n vault vault-0 -- vault "$@"; }
vin() { kubectl exec -i -n vault vault-0 -- vault "$@"; }

if ! v auth list -format=json | grep -q '"kubernetes/"'; then
  echo "Kubernetes auth is not enabled: run vault/policies.sh of the private repository first" >&2
  exit 1
fi

if ! v secrets list -format=json | grep -q '"platform/"'; then
  v secrets enable -path=platform -version=2 kv
fi

for ns in $namespaces; do
  name="platform-$ns"
  policy=$(cat <<POLICY
path "platform/data/$ns" {
  capabilities = ["read"]
}
path "platform/data/$ns/*" {
  capabilities = ["read"]
}
POLICY
)
  current=$(v policy read "$name" 2>/dev/null || true)
  if [ "$current" != "$policy" ]; then
    printf '%s\n' "$policy" | vin policy write "$name" -
  fi

  want="default|$ns|$name|600|vault"
  have=$(v read -format=json "auth/kubernetes/role/$name" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)["data"]
except Exception:
    sys.exit(0)
print("|".join([",".join(d["bound_service_account_names"]), ",".join(d["bound_service_account_namespaces"]),
                ",".join(d["token_policies"]), str(d["token_ttl"]), d.get("audience", "")]))' || true)
  if [ "$have" != "$want" ]; then
    v write "auth/kubernetes/role/$name" \
      bound_service_account_names=default \
      bound_service_account_namespaces="$ns" \
      token_policies="$name" \
      token_ttl=10m \
      audience=vault
  fi
done
echo "vault: platform configured for: $namespaces"
