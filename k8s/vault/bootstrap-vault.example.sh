#!/bin/sh
set -eu

# ============================================================
# Fill in these variables before running the script.
# ============================================================

export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="xxxx"

K8S_AUTH_MOUNT="kubernetes"
K8S_NAMESPACE="moomento"

BACKEND_SERVICE_ACCOUNT="backend-sa"
HOSTED_SERVICE_ACCOUNT="hosted-sa"

BACKEND_POLICY_NAME="flashcards-backend"
HOSTED_POLICY_NAME="flashcards-hosted"

BACKEND_ROLE_NAME="flashcards-backend"
HOSTED_ROLE_NAME="flashcards-hosted"

BACKEND_SECRET_PATH="secret/data/flashcards/backend"
HOSTED_SECRET_PATH="secret/data/flashcards/hosted"

SPRING_DATASOURCE_PASSWORD="xxxx"
JWT_SECRET="xxxx"

MAIL_USERNAME="xxxx"
MAIL_PASSWORD="xxxx"

# Optional: only if Kubernetes auth is not configured in Vault yet.
# K8S_HOST="https://REPLACE_ME_KUBERNETES_API:6443"
# K8S_CA_CERT_PATH="/path/to/ca.crt"
# TOKEN_REVIEWER_JWT="REPLACE_ME_TOKEN_REVIEWER_JWT"

echo "Using VAULT_ADDR=${VAULT_ADDR}"

# ============================================================
# Optional one-time Kubernetes auth setup in Vault.
# Skip this block if auth/kubernetes is already configured.
# ============================================================

# vault auth enable "${K8S_AUTH_MOUNT}" || true
# vault write "auth/${K8S_AUTH_MOUNT}/config" \
#   kubernetes_host="${K8S_HOST}" \
#   kubernetes_ca_cert=@"${K8S_CA_CERT_PATH}" \
#   token_reviewer_jwt="${TOKEN_REVIEWER_JWT}"

# ============================================================
# Policies
# ============================================================

vault policy write "${BACKEND_POLICY_NAME}" - <<EOF
path "${BACKEND_SECRET_PATH}" {
  capabilities = ["read"]
}
EOF

vault policy write "${HOSTED_POLICY_NAME}" - <<EOF
path "${HOSTED_SECRET_PATH}" {
  capabilities = ["read"]
}
EOF

# ============================================================
# Kubernetes roles
# ============================================================

vault write "auth/${K8S_AUTH_MOUNT}/role/${BACKEND_ROLE_NAME}" \
  bound_service_account_names="${BACKEND_SERVICE_ACCOUNT}" \
  bound_service_account_namespaces="${K8S_NAMESPACE}" \
  policies="${BACKEND_POLICY_NAME}" \
  ttl="24h"

vault write "auth/${K8S_AUTH_MOUNT}/role/${HOSTED_ROLE_NAME}" \
  bound_service_account_names="${HOSTED_SERVICE_ACCOUNT}" \
  bound_service_account_namespaces="${K8S_NAMESPACE}" \
  policies="${HOSTED_POLICY_NAME}" \
  ttl="24h"

# ============================================================
# KV secrets
# These commands target kv-v2 and map to:
# - secret/data/flashcards/backend
# - secret/data/flashcards/hosted
# ============================================================

vault kv put secret/flashcards/backend \
  SPRING_DATASOURCE_PASSWORD="${SPRING_DATASOURCE_PASSWORD}" \
  JWT_SECRET="${JWT_SECRET}"

vault kv put secret/flashcards/hosted \
  MAIL_USERNAME="${MAIL_USERNAME}" \
  MAIL_PASSWORD="${MAIL_PASSWORD}"

# ============================================================
# Helpful verification
# ============================================================

vault read "auth/${K8S_AUTH_MOUNT}/role/${BACKEND_ROLE_NAME}"
vault read "auth/${K8S_AUTH_MOUNT}/role/${HOSTED_ROLE_NAME}"
vault kv get secret/flashcards/backend
vault kv get secret/flashcards/hosted

echo "Vault bootstrap for moomento is ready."
