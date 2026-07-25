#!/usr/bin/env bash
#
# One-time Vault bootstrap for the FlashCards project, per environment.
#
# Creates a least-privilege policy and a Kubernetes auth role per workload, then
# seeds the secret values the Vault Agent Injector renders into the pods.
#
# This file contains NO secret values. Passwords are generated locally or taken
# from your environment and never written to disk. Do not commit any variant of
# this script that has values filled in.
#
# Prerequisites:
#   - Vault is initialised and unsealed
#   - the `kubernetes` auth method is enabled
#   - the KV v2 engine is mounted at secret/
#   - you are logged in with a token that may write policies and auth roles
#
# Usage - production (57.129.66.163, ssh ovh):
#   export VAULT_ADDR=https://vault.bosman.top
#   vault login -method=userpass username=bosman
#   ENVIRONMENT=production ./bootstrap-vault.example.sh
#
# Usage - develop (57.128.251.9, ssh ovh2). Vault there is not published on the
# internet, so run it from the node itself against the in-cluster address:
#   ssh ovh2
#   kubectl -n vault port-forward svc/vault 8200:8200 &
#   export VAULT_ADDR=http://127.0.0.1:8200
#   vault login   # root token from /root/vault-init.json
#   ENVIRONMENT=develop ./bootstrap-vault.example.sh
#
set -euo pipefail

PROJECT="moomento"

# production -> namespace moomento      (k8s/overlays/production)
# develop    -> namespace moomento-dev  (k8s/overlays/develop)
ENVIRONMENT="${ENVIRONMENT:-production}"
case "${ENVIRONMENT}" in
  production) DEFAULT_NAMESPACE="moomento" ;;
  develop)    DEFAULT_NAMESPACE="moomento-dev" ;;
  *) echo "ENVIRONMENT must be 'production' or 'develop', got '${ENVIRONMENT}'" >&2; exit 1 ;;
esac

# Must match `namespace:` in the corresponding overlay's kustomization.yaml.
NAMESPACE="${NAMESPACE:-${DEFAULT_NAMESPACE}}"

# Policy and role names are prefixed with the namespace, which is exactly what
# the vault.hashicorp.com/role annotations expect:
#   moomento-backend      / moomento-hosted      (production)
#   moomento-dev-backend  / moomento-dev-hosted  (develop)
PREFIX="${NAMESPACE}"
BASE="secret/projects/${PROJECT}/${ENVIRONMENT}"

command -v vault >/dev/null || { echo "vault CLI not found" >&2; exit 1; }
: "${VAULT_ADDR:?set VAULT_ADDR, e.g. https://vault.bosman.top}"

vault status >/dev/null || { echo "Vault unreachable or sealed" >&2; exit 1; }

echo "environment : ${ENVIRONMENT}"
echo "namespace   : ${NAMESPACE}"
echo "secret path : ${BASE}"
echo

# -----------------------------------------------------------------------------
# Policies - read-only, scoped to this project and environment only.
# Never attach grand-admin or any infrastructure policy to an application.
# -----------------------------------------------------------------------------
for svc in backend hosted; do
  echo ">> policy ${PREFIX}-${svc}"
  vault policy write "${PREFIX}-${svc}" - <<EOF
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
# bound_service_account_names must match base/serviceaccounts.yaml and the
# vault.hashicorp.com/role annotations in base/backend.yaml, base/hosted.yaml
# and the develop overlay's patch-*.yaml.
# The `default` service account is deliberately never bound.
# -----------------------------------------------------------------------------
for svc in backend hosted; do
  echo ">> auth/kubernetes/role/${PREFIX}-${svc}"
  vault write "auth/kubernetes/role/${PREFIX}-${svc}" \
    bound_service_account_names="${svc}" \
    bound_service_account_namespaces="${NAMESPACE}" \
    token_policies="${PREFIX}-${svc}" \
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
    cat >&2 <<MSG

    A database password was generated. Read it back and apply it to PostgreSQL:

      FLASHCARDS_DB_PASSWORD=\$(vault kv get -field=SPRING_DATASOURCE_PASSWORD \\
        ${BASE}/backend)

      kubectl exec -i -n database postgresql-0 -- \\
        psql -U postgres -d postgres \\
             -v flashcards_password="\$FLASHCARDS_DB_PASSWORD" \\
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
echo "  vault read auth/kubernetes/role/${PREFIX}-backend"
