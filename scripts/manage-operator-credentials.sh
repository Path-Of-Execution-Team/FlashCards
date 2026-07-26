#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/manage-operator-credentials.sh <credentials.csv>

CSV header:
  login,email,vault_password,kafka_ui_password,grafana_password,pgadmin_password,postgres_user,postgres_password,postgres_database

Empty password fields are skipped. If email is empty, login@bosman.top is used
unless login already contains "@". Vault is treated as the source of truth where
possible; runtime Kubernetes Secrets are synchronized from the same CSV values.

Expected to run on a node/operator machine with kubectl access to the cluster.
For Vault writes, set VAULT_TOKEN or keep the generated userpass password file
at /root/vault-userpass-bosman.txt.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[credentials] %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

decode_b64() {
  printf '%s' "$1" | base64 -d
}

csv_file="${1:-}"
if [[ -z "$csv_file" || "$csv_file" == "-h" || "$csv_file" == "--help" ]]; then
  usage
  exit 0
fi
[[ -r "$csv_file" ]] || die "CSV file is not readable: $csv_file"

require_cmd kubectl
require_cmd python3
require_cmd base64
require_cmd openssl

EMAIL_DOMAIN="${EMAIL_DOMAIN:-bosman.top}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_USERPASS_USERNAME="${VAULT_USERPASS_USERNAME:-bosman}"
VAULT_USERPASS_PASSWORD_FILE="${VAULT_USERPASS_PASSWORD_FILE:-/root/vault-userpass-bosman.txt}"
VAULT_USERPASS_POLICY="${VAULT_USERPASS_POLICY:-flashcards-admin}"

KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
KAFKA_UI_BASIC_AUTH_SECRET="${KAFKA_UI_BASIC_AUTH_SECRET:-kafka-ui-basic-auth}"

GRAFANA_NAMESPACE="${GRAFANA_NAMESPACE:-monitoring}"
GRAFANA_SECRET="${GRAFANA_SECRET:-grafana-admin-credentials}"
GRAFANA_STATEFULSET="${GRAFANA_STATEFULSET:-monitoring-grafana}"

PGADMIN_NAMESPACE="${PGADMIN_NAMESPACE:-database}"
PGADMIN_SECRET="${PGADMIN_SECRET:-pgadmin4-credentials}"
PGADMIN_DEPLOYMENT="${PGADMIN_DEPLOYMENT:-pgadmin4}"

POSTGRES_NAMESPACE="${POSTGRES_NAMESPACE:-database}"
POSTGRES_POD="${POSTGRES_POD:-postgresql-0}"
POSTGRES_SUPERUSER_SECRET="${POSTGRES_SUPERUSER_SECRET:-postgresql-superuser}"
POSTGRES_SUPERUSER_SECRET_KEY="${POSTGRES_SUPERUSER_SECRET_KEY:-password}"
POSTGRES_DEFAULT_DATABASE="${POSTGRES_DEFAULT_DATABASE:-applications}"

vault_token="${VAULT_TOKEN:-}"
if [[ -z "$vault_token" ]]; then
  [[ -r "$VAULT_USERPASS_PASSWORD_FILE" ]] || die "Set VAULT_TOKEN or make $VAULT_USERPASS_PASSWORD_FILE readable"
  vault_password="$(<"$VAULT_USERPASS_PASSWORD_FILE")"
  vault_token="$(
    kubectl -n "$VAULT_NAMESPACE" exec "$VAULT_POD" -- \
      vault login -method=userpass username="$VAULT_USERPASS_USERNAME" password="$vault_password" -format=json \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"]["client_token"])'
  )"
fi

vault() {
  kubectl -n "$VAULT_NAMESPACE" exec "$VAULT_POD" -- env "VAULT_TOKEN=$vault_token" vault "$@"
}

vault_stdin() {
  kubectl -n "$VAULT_NAMESPACE" exec -i "$VAULT_POD" -- env "VAULT_TOKEN=$vault_token" vault "$@"
}

vault_kv_put() {
  local path="$1"
  shift
  vault kv put "$path" "$@" >/dev/null
}

ensure_vault_userpass() {
  if vault auth list -format=json | grep -q '"userpass/"'; then
    return
  fi
  vault auth enable userpass >/dev/null
}

apply_literal_secret() {
  local namespace="$1"
  local name="$2"
  shift 2
  kubectl -n "$namespace" create secret generic "$name" "$@" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
}

postgres_admin_password() {
  if kubectl -n "$POSTGRES_NAMESPACE" get secret "$POSTGRES_SUPERUSER_SECRET" >/dev/null 2>&1; then
    kubectl -n "$POSTGRES_NAMESPACE" get secret "$POSTGRES_SUPERUSER_SECRET" \
      -o "jsonpath={.data.${POSTGRES_SUPERUSER_SECRET_KEY}}" | base64 -d
    return
  fi
  kubectl -n "$POSTGRES_NAMESPACE" get secret postgresql-credentials \
    -o "jsonpath={.data['postgres-password']}" | base64 -d
}

set_postgres_secret_password() {
  local password="$1"
  apply_literal_secret "$POSTGRES_NAMESPACE" "$POSTGRES_SUPERUSER_SECRET" \
    --from-literal="$POSTGRES_SUPERUSER_SECRET_KEY=$password"

  if kubectl -n "$POSTGRES_NAMESPACE" get secret postgresql-credentials >/dev/null 2>&1; then
    apply_literal_secret "$POSTGRES_NAMESPACE" postgresql-credentials \
      --from-literal="postgres-password=$password" \
      --from-literal="password=$password"
  fi
}

run_postgres_sql() {
  local role="$1"
  local password="$2"
  local database="$3"
  local admin_password="$4"

  kubectl -n "$POSTGRES_NAMESPACE" exec -i "$POSTGRES_POD" -- \
    env "PGPASSWORD=$admin_password" psql -U postgres -d postgres \
      -v ON_ERROR_STOP=1 \
      -v role="$role" \
      -v role_password="$password" \
      -v db="$database" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')
\gexec

ALTER ROLE :"role" WITH LOGIN PASSWORD :'role_password';

SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8'' TEMPLATE template0', :'db', :'role')
WHERE :'db' <> '' AND NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db')
\gexec

SELECT format('ALTER DATABASE %I OWNER TO %I', :'db', :'role')
WHERE :'db' <> ''
\gexec
SQL
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
kafka_users_file="$tmp_dir/kafka-ui-users"
: > "$kafka_users_file"

grafana_login=""
grafana_email=""
grafana_password=""
pgadmin_login=""
pgadmin_email=""
pgadmin_password=""
postgres_admin_password_cache=""
postgres_changed=0
kafka_changed=0
grafana_changed=0
pgadmin_changed=0
vault_changed=0

while IFS=$'\t' read -r login64 email64 vault64 kafka64 grafana64 pgadmin64 pguser64 pgpass64 pgdb64; do
  login="$(decode_b64 "$login64")"
  email="$(decode_b64 "$email64")"
  vault_password="$(decode_b64 "$vault64")"
  kafka_password="$(decode_b64 "$kafka64")"
  row_grafana_password="$(decode_b64 "$grafana64")"
  row_pgadmin_password="$(decode_b64 "$pgadmin64")"
  postgres_user="$(decode_b64 "$pguser64")"
  postgres_password="$(decode_b64 "$pgpass64")"
  postgres_database="$(decode_b64 "$pgdb64")"

  [[ -n "$login" ]] || continue
  if [[ -z "$email" ]]; then
    if [[ "$login" == *@* ]]; then
      email="$login"
    else
      email="${login}@${EMAIL_DOMAIN}"
    fi
  fi
  [[ -n "$postgres_user" ]] || postgres_user="$login"
  [[ -n "$postgres_database" ]] || postgres_database="$POSTGRES_DEFAULT_DATABASE"

  if [[ -n "$vault_password" ]]; then
    ensure_vault_userpass
    vault write "auth/userpass/users/${login}" password="$vault_password" policies="$VAULT_USERPASS_POLICY" >/dev/null
    vault_kv_put "secret/infrastructure/vault/users/${login}" \
      username="$login" email="$email" password="$vault_password" policy="$VAULT_USERPASS_POLICY"
    vault_changed=1
    log "Vault userpass updated for ${login}"
  fi

  if [[ -n "$kafka_password" ]]; then
    hash="$(openssl passwd -apr1 "$kafka_password")"
    printf '%s:%s\n' "$login" "$hash" >> "$kafka_users_file"
    vault_kv_put "secret/infrastructure/kafka-ui/users/${login}" \
      username="$login" email="$email" password="$kafka_password"
    kafka_changed=1
    log "Kafka UI credentials staged for ${login}"
  fi

  if [[ -n "$row_grafana_password" ]]; then
    vault_kv_put "secret/infrastructure/grafana/users/${login}" \
      username="$login" email="$email" password="$row_grafana_password"
    if [[ -z "$grafana_login" ]]; then
      grafana_login="$login"
      grafana_email="$email"
      grafana_password="$row_grafana_password"
    fi
    grafana_changed=1
    log "Grafana credentials stored in Vault for ${login}"
  fi

  if [[ -n "$row_pgadmin_password" ]]; then
    vault_kv_put "secret/infrastructure/pgadmin4/users/${login}" \
      username="$login" email="$email" password="$row_pgadmin_password"
    if [[ -z "$pgadmin_login" ]]; then
      pgadmin_login="$login"
      pgadmin_email="$email"
      pgadmin_password="$row_pgadmin_password"
    fi
    pgadmin_changed=1
    log "pgAdmin credentials stored in Vault for ${email}"
  fi

  if [[ -n "$postgres_password" ]]; then
    [[ -n "$postgres_admin_password_cache" ]] || postgres_admin_password_cache="$(postgres_admin_password)"
    vault_kv_put "secret/infrastructure/postgresql/users/${postgres_user}" \
      username="$postgres_user" password="$postgres_password" database="$postgres_database" \
      host="postgresql.database.svc.cluster.local" port="5432"
    run_postgres_sql "$postgres_user" "$postgres_password" "$postgres_database" "$postgres_admin_password_cache"
    if [[ "$postgres_user" == "postgres" ]]; then
      set_postgres_secret_password "$postgres_password"
      postgres_admin_password_cache="$postgres_password"
    fi
    postgres_changed=1
    log "PostgreSQL role synchronized for ${postgres_user}"
  fi
done < <(
  python3 - "$csv_file" "$EMAIL_DOMAIN" <<'PY'
import base64
import csv
import sys

path = sys.argv[1]
email_domain = sys.argv[2]
aliases = {
    "login": ("login", "username", "user"),
    "email": ("email", "mail"),
    "vault_password": ("vault_password", "vault"),
    "kafka_ui_password": ("kafka_ui_password", "kafka_password", "kafka_ui", "kafka"),
    "grafana_password": ("grafana_password", "grafana"),
    "pgadmin_password": ("pgadmin_password", "pgadmin", "pgadmin4_password", "pgadmin4"),
    "postgres_user": ("postgres_user", "postgres_login", "postgres_username", "db_user"),
    "postgres_password": ("postgres_password", "postgres", "db_password"),
    "postgres_database": ("postgres_database", "postgres_db", "db_name", "database"),
}

def norm(name):
    return (name or "").strip().lower().replace("-", "_").replace(" ", "_")

def b64(value):
    return base64.b64encode((value or "").encode("utf-8")).decode("ascii")

with open(path, newline="", encoding="utf-8-sig") as handle:
    reader = csv.DictReader(handle)
    if not reader.fieldnames:
        raise SystemExit("CSV must include a header")
    field_map = {norm(name): name for name in reader.fieldnames}
    for row in reader:
        clean = {}
        for target, names in aliases.items():
            value = ""
            for alias in names:
                source = field_map.get(alias)
                if source is not None:
                    value = (row.get(source) or "").strip()
                    break
            clean[target] = value
        if not clean["login"]:
            continue
        if not clean["email"]:
            clean["email"] = clean["login"] if "@" in clean["login"] else f"{clean['login']}@{email_domain}"
        values = [
            clean["login"],
            clean["email"],
            clean["vault_password"],
            clean["kafka_ui_password"],
            clean["grafana_password"],
            clean["pgadmin_password"],
            clean["postgres_user"],
            clean["postgres_password"],
            clean["postgres_database"],
        ]
        print("\t".join(b64(value) for value in values))
PY
)

if [[ "$kafka_changed" -eq 1 ]]; then
  kubectl -n "$KAFKA_NAMESPACE" create secret generic "$KAFKA_UI_BASIC_AUTH_SECRET" \
    --from-file=users="$kafka_users_file" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "Kafka UI BasicAuth secret synchronized from CSV users"
fi

if [[ "$grafana_changed" -eq 1 && -n "$grafana_login" ]]; then
  vault_kv_put "secret/infrastructure/grafana/config" \
    username="$grafana_login" email="$grafana_email" password="$grafana_password"
  apply_literal_secret "$GRAFANA_NAMESPACE" "$GRAFANA_SECRET" \
    --from-literal="admin-user=$grafana_login" \
    --from-literal="admin-password=$grafana_password"

  grafana_pod="$(kubectl -n "$GRAFANA_NAMESPACE" get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$grafana_pod" ]]; then
    kubectl -n "$GRAFANA_NAMESPACE" exec "$grafana_pod" -c grafana -- \
      sh -lc '/usr/share/grafana/bin/grafana cli admin reset-admin-password "$1" >/dev/null' sh "$grafana_password" \
      || log "Grafana CLI password reset failed; secret was still updated"
  fi
  kubectl -n "$GRAFANA_NAMESPACE" rollout restart "statefulset/${GRAFANA_STATEFULSET}" >/dev/null
  log "Grafana admin secret synchronized and statefulset restarted"
fi

if [[ "$pgadmin_changed" -eq 1 && -n "$pgadmin_email" ]]; then
  vault_kv_put "secret/infrastructure/pgadmin4/config" \
    username="$pgadmin_login" email="$pgadmin_email" password="$pgadmin_password"
  apply_literal_secret "$PGADMIN_NAMESPACE" "$PGADMIN_SECRET" \
    --from-literal="password=$pgadmin_password"
  kubectl -n "$PGADMIN_NAMESPACE" set env "deployment/${PGADMIN_DEPLOYMENT}" \
    "PGADMIN_DEFAULT_EMAIL=$pgadmin_email" >/dev/null
  kubectl -n "$PGADMIN_NAMESPACE" rollout restart "deployment/${PGADMIN_DEPLOYMENT}" >/dev/null
  log "pgAdmin default credentials synchronized; existing pgAdmin users may require app-level update"
fi

if [[ "$vault_changed" -eq 0 && "$kafka_changed" -eq 0 && "$grafana_changed" -eq 0 && "$pgadmin_changed" -eq 0 && "$postgres_changed" -eq 0 ]]; then
  log "No password fields were provided; nothing changed"
else
  log "Credential synchronization completed"
fi
