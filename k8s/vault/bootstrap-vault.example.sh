#!/usr/bin/env bash
#
# One-time Vault bootstrap for the FlashCards project.
#
# Creates a least-privilege policy and a Kubernetes auth role per workload, then
# seeds the secret values the Vault Agent Injector renders into the pods.
#
# This file contains NO secret values. Passwords are generated locally or taken
# from your environment and never written to disk. Do not commit any variant of
# this script that has values filled in.
#
# Prerequisites (all already true on this cluster per INFRASTRUCTURE.md):
#   - Vault is initialised and unsealed
#   - the `kubernetes` auth method is enabled
#   - the KV v2 engine is mounted at secret/
#   - you are logged in with a token that may write policies and auth roles
#
# Usage:
#   export VAULT_ADDR=https://vault.bosman.top
#   vault login -method=userpass username=bosman
#   ./bootstrap-vault.example.sh
#
set -euo pipefail

PROJECT="moomento"
NAMESPACE="moomento"
ENVIRONMENT="production"
BASE="secret/projects/${PROJECT}/${ENVIRONMENT}"

command -v vault >/dev/null || { echo "vault CLI not found" >&2; exit 1; }
: "${VAULT_ADDR:?set VAULT_ADDR, e.g. https://vault.bosman.top}"

vault status >/dev/null || { echo "Vault unreachable or sealed" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Policies - read-only, scoped to this project and environment only.
# Never attach grand-admin or any infrastructure policy to an application.
# -----------------------------------------------------------------------------
for svc in backend hosted; do
  echo ">> policy ${PROJECT}-${svc}"
  vault policy write "${PROJECT}-${svc}" - <<EOF
path "secret/data/projects/${PROJECT}/${ENVIRONMENT}/${svc}" {
  capabilities = ["read"]
}

path "secret/metadata/projects/${PROJECT}/${ENVIRONMENT}/${svc}" {
  capabilities = ["read", "list"]
}
EOF
done

# -----------------------------------------------------------------------------
# Kubernetes auth roles.
#
# bound_service_account_names must match serviceaccounts.yaml and the
# vault.hashicorp.com/role annotations in backend.yaml / hosted.yaml.
# The `default` service account is deliberately never bound.
# -----------------------------------------------------------------------------
for svc in backend hosted; do
  echo ">> auth/kubernetes/role/${PROJECT}-${svc}"
  vault write "auth/kubernetes/role/${PROJECT}-${svc}" \
    bound_service_account_names="${svc}" \
    bound_service_account_namespaces="${NAMESPACE}" \
    token_policies="${PROJECT}-${svc}" \
    token_ttl=1h \
    token_max_ttl=24h
done

# -----------------------------------------------------------------------------
# Secret values.
#
# Existing values are left alone so re-running this script cannot silently
# rotate a live database password out from under the running pods.
# -----------------------------------------------------------------------------
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-40}"; }

if vault kv get "${BASE}/backend" >/dev/null 2>&1; then
  echo ">> ${BASE}/backend already exists, leaving it untouched"
else
  echo ">> writing ${BASE}/backend"
  # If you already created the PostgreSQL role, pass the same password in
  # FLASHCARDS_DB_PASSWORD; otherwise one is generated here and you must feed it
  # to db/bootstrap-flashcards-db.sql.
  DB_PASSWORD="${FLASHCARDS_DB_PASSWORD:-$(gen 40)}"
  # 256-bit key for HS256. Note: the value committed in
  # src/main/resources/application.properties is a publicly known default and is
  # overridden by this one at runtime - treat the committed one as compromised.
  JWT_SECRET="${FLASHCARDS_JWT_SECRET:-$(openssl rand -hex 32)}"

  vault kv put "${BASE}/backend" \
    SPRING_DATASOURCE_PASSWORD="${DB_PASSWORD}" \
    JWT_SECRET="${JWT_SECRET}"

  if [[ -z "${FLASHCARDS_DB_PASSWORD:-}" ]]; then
    cat >&2 <<'MSG'

    A database password was generated. Read it back and apply it to PostgreSQL:

      FLASHCARDS_DB_PASSWORD=$(vault kv get -field=SPRING_DATASOURCE_PASSWORD \
        secret/projects/moomento/production/backend)

      kubectl exec -i -n database postgresql-0 -- \
        psql -U postgres -d postgres \
             -v flashcards_password="$FLASHCARDS_DB_PASSWORD" \
        < k8s/db/bootstrap-flashcards-db.sql

MSG
  fi
fi

if vault kv get "${BASE}/hosted" >/dev/null 2>&1; then
  echo ">> ${BASE}/hosted already exists, leaving it untouched"
else
  echo ">> writing ${BASE}/hosted"
  : "${FLASHCARDS_MAIL_USERNAME:?set FLASHCARDS_MAIL_USERNAME for the SMTP relay}"
  : "${FLASHCARDS_MAIL_PASSWORD:?set FLASHCARDS_MAIL_PASSWORD for the SMTP relay}"

  vault kv put "${BASE}/hosted" \
    MAIL_USERNAME="${FLASHCARDS_MAIL_USERNAME}" \
    MAIL_PASSWORD="${FLASHCARDS_MAIL_PASSWORD}"
fi

echo
echo "Done. Verify with:"
echo "  vault kv metadata get ${BASE}/backend"
echo "  vault read auth/kubernetes/role/${PROJECT}-backend"
