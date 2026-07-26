#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/manage-operator-credentials.sh <credentials.csv>

CSV header:
  login,email,vault_password,kafka_ui_password,grafana_password,pgadmin_password,postgres_user,postgres_password,postgres_database

Empty password fields are skipped. If email is empty, login@bosman.top is used
unless login already contains "@". Each non-empty service password creates or
updates that user in the matching service. Vault is kept as the source of truth
where possible; runtime Kubernetes Secrets are synchronized from the same CSV
values.

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

encode_b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
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
GRAFANA_SERVICE="${GRAFANA_SERVICE:-monitoring-grafana}"
GRAFANA_STATEFULSET="${GRAFANA_STATEFULSET:-monitoring-grafana}"
GRAFANA_URL="${GRAFANA_URL:-}"
GRAFANA_LOCAL_PORT="${GRAFANA_LOCAL_PORT:-30080}"
GRAFANA_ORG_ROLE="${GRAFANA_ORG_ROLE:-Admin}"

PGADMIN_NAMESPACE="${PGADMIN_NAMESPACE:-database}"
PGADMIN_SECRET="${PGADMIN_SECRET:-pgadmin4-credentials}"
PGADMIN_DEPLOYMENT="${PGADMIN_DEPLOYMENT:-pgadmin4}"
PGADMIN_POD_SELECTOR="${PGADMIN_POD_SELECTOR:-app=pgadmin4}"
PGADMIN_PYTHON="${PGADMIN_PYTHON:-/venv/bin/python}"
PGADMIN_SETUP="${PGADMIN_SETUP:-/pgadmin4/setup.py}"
PGADMIN_SQLITE_PATH="${PGADMIN_SQLITE_PATH:-}"
PGADMIN_ADMIN="${PGADMIN_ADMIN:-true}"
PGADMIN_ROLE="${PGADMIN_ROLE:-Administrator}"

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

k8s_secret_value() {
  local namespace="$1"
  local name="$2"
  local key="$3"
  local encoded

  kubectl -n "$namespace" get secret "$name" >/dev/null 2>&1 || return 1
  encoded="$(kubectl -n "$namespace" get secret "$name" -o "jsonpath={.data.${key}}" 2>/dev/null || true)"
  [[ -n "$encoded" ]] || return 1
  printf '%s' "$encoded" | base64 -d
}

wait_for_tcp() {
  local host="$1"
  local port="$2"
  python3 - "$host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
with socket.create_connection((host, port), timeout=1):
    pass
PY
}

start_grafana_port_forward() {
  if [[ -n "$GRAFANA_URL" ]]; then
    return
  fi

  kubectl -n "$GRAFANA_NAMESPACE" port-forward "svc/${GRAFANA_SERVICE}" \
    "127.0.0.1:${GRAFANA_LOCAL_PORT}:80" >"$tmp_dir/grafana-port-forward.log" 2>&1 &
  grafana_port_forward_pid="$!"

  for _ in $(seq 1 30); do
    if wait_for_tcp 127.0.0.1 "$GRAFANA_LOCAL_PORT" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done

  cat "$tmp_dir/grafana-port-forward.log" >&2 || true
  die "Grafana port-forward did not become ready"
}

sync_grafana_users() {
  local users_file="$1"
  local admin_login="$2"
  local admin_password="$3"
  local grafana_url="${GRAFANA_URL:-http://127.0.0.1:${GRAFANA_LOCAL_PORT}}"

  python3 - "$users_file" "$grafana_url" "$admin_login" "$admin_password" "$GRAFANA_ORG_ROLE" <<'PY'
import base64
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

users_file, base_url, admin_login, admin_password, org_role = sys.argv[1:6]
base_url = base_url.rstrip("/")

auth = base64.b64encode(f"{admin_login}:{admin_password}".encode()).decode()

def decode(value):
    return base64.b64decode(value.encode()).decode()

def request(method, path, payload=None, ok=(200,)):
    body = None
    headers = {
        "Authorization": f"Basic {auth}",
        "Accept": "application/json",
    }
    if payload is not None:
        body = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base_url + path, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode()
            if resp.status not in ok:
                raise RuntimeError(f"{method} {path} returned HTTP {resp.status}: {raw}")
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode()
        if exc.code in ok:
            try:
                return exc.code, json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                return exc.code, raw
        raise RuntimeError(f"{method} {path} returned HTTP {exc.code}: {raw}") from exc

def lookup(login, email):
    for value in (login, email):
        encoded = urllib.parse.quote(value, safe="")
        status, data = request("GET", f"/api/users/lookup?loginOrEmail={encoded}", ok=(200, 404))
        if status == 200:
            return data
    return None

def ensure_org_role(user_id, login, email):
    if not org_role:
        return
    status, _ = request("PATCH", f"/api/org/users/{user_id}", {"role": org_role}, ok=(200, 404))
    if status == 404:
        request("POST", "/api/org/users", {"loginOrEmail": email or login, "role": org_role}, ok=(200, 409, 412))

with open(users_file, encoding="utf-8") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if not line:
            continue
        login64, email64, password64 = line.split("\t", 2)
        login = decode(login64)
        email = decode(email64)
        password = decode(password64)

        user = lookup(login, email)
        if user is None:
            _, created = request(
                "POST",
                "/api/admin/users",
                {"name": login, "email": email, "login": login, "password": password},
                ok=(200, 409, 412),
            )
            user = lookup(login, email)
            if user is None:
                raise RuntimeError(f"Grafana user {login} was not created: {created}")
            print(f"Grafana user created: {login}")
        else:
            request("PUT", f"/api/admin/users/{user['id']}/password", {"password": password}, ok=(200,))
            print(f"Grafana user updated: {login}")

        ensure_org_role(user["id"], login, email)
PY
}

pgadmin_sqlite_args() {
  if [[ -n "$PGADMIN_SQLITE_PATH" ]]; then
    printf '%s\n' --sqlite-path "$PGADMIN_SQLITE_PATH"
  fi
}

pgadmin_role_args() {
  if [[ "$PGADMIN_ADMIN" == "true" ]]; then
    printf '%s\n' --admin
  elif [[ -n "$PGADMIN_ROLE" ]]; then
    printf '%s\n' --role "$PGADMIN_ROLE"
  fi
}

sync_pgadmin_users() {
  local users_file="$1"
  local pgadmin_pod

  pgadmin_pod="$(kubectl -n "$PGADMIN_NAMESPACE" get pod -l "$PGADMIN_POD_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pgadmin_pod" ]] || die "Could not find pgAdmin pod with selector: $PGADMIN_POD_SELECTOR"

  while IFS=$'\t' read -r login64 email64 password64; do
    [[ -n "$email64" ]] || continue
    email="$(decode_b64 "$email64")"
    password="$(decode_b64 "$password64")"

    mapfile -t sqlite_args < <(pgadmin_sqlite_args)
    mapfile -t role_args < <(pgadmin_role_args)

    if kubectl -n "$PGADMIN_NAMESPACE" exec "$pgadmin_pod" -- \
      "$PGADMIN_PYTHON" "$PGADMIN_SETUP" get-users --username "$email" --json "${sqlite_args[@]}" 2>/dev/null \
      | grep -Fq "\"username\": \"$email\""; then
      kubectl -n "$PGADMIN_NAMESPACE" exec "$pgadmin_pod" -- \
        "$PGADMIN_PYTHON" "$PGADMIN_SETUP" update-user "$email" \
        --password "$password" "${role_args[@]}" --active --no-console "${sqlite_args[@]}" >/dev/null
      log "pgAdmin user updated for ${email}"
    else
      kubectl -n "$PGADMIN_NAMESPACE" exec "$pgadmin_pod" -- \
        "$PGADMIN_PYTHON" "$PGADMIN_SETUP" add-user "$email" "$password" \
        "${role_args[@]}" --active --no-console "${sqlite_args[@]}" >/dev/null
      log "pgAdmin user created for ${email}"
    fi
  done < "$users_file"
}

postgres_admin_password() {
  if kubectl -n "$POSTGRES_NAMESPACE" get secret "$POSTGRES_SUPERUSER_SECRET" >/dev/null 2>&1; then
    kubectl -n "$POSTGRES_NAMESPACE" get secret "$POSTGRES_SUPERUSER_SECRET" \
      -o "jsonpath={.data.${POSTGRES_SUPERUSER_SECRET_KEY}}" | base64 -d
    return
  fi
  kubectl -n "$POSTGRES_NAMESPACE" get secret postgresql-credentials \
    -o "jsonpath={.data.postgres-password}" | base64 -d
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
grafana_port_forward_pid=""
cleanup() {
  if [[ -n "$grafana_port_forward_pid" ]]; then
    kill "$grafana_port_forward_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
kafka_users_file="$tmp_dir/kafka-ui-users"
grafana_users_file="$tmp_dir/grafana-users.tsv"
pgadmin_users_file="$tmp_dir/pgadmin-users.tsv"
: > "$kafka_users_file"
: > "$grafana_users_file"
: > "$pgadmin_users_file"

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
    printf '%s\t%s\t%s\n' "$(encode_b64 "$login")" "$(encode_b64 "$email")" "$(encode_b64 "$row_grafana_password")" \
      >> "$grafana_users_file"
    if [[ -z "$grafana_login" ]]; then
      grafana_login="$login"
      grafana_email="$email"
      grafana_password="$row_grafana_password"
    fi
    grafana_changed=1
    log "Grafana credentials staged for ${login}"
  fi

  if [[ -n "$row_pgadmin_password" ]]; then
    vault_kv_put "secret/infrastructure/pgadmin4/users/${login}" \
      login="$login" username="$email" email="$email" password="$row_pgadmin_password"
    printf '%s\t%s\t%s\n' "$(encode_b64 "$login")" "$(encode_b64 "$email")" "$(encode_b64 "$row_pgadmin_password")" \
      >> "$pgadmin_users_file"
    if [[ -z "$pgadmin_login" ]]; then
      pgadmin_login="$login"
      pgadmin_email="$email"
      pgadmin_password="$row_pgadmin_password"
    fi
    pgadmin_changed=1
    log "pgAdmin credentials staged for ${email}"
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
  grafana_api_login="$(k8s_secret_value "$GRAFANA_NAMESPACE" "$GRAFANA_SECRET" "admin-user" 2>/dev/null || true)"
  grafana_api_password="$(k8s_secret_value "$GRAFANA_NAMESPACE" "$GRAFANA_SECRET" "admin-password" 2>/dev/null || true)"
  [[ -n "$grafana_api_login" ]] || grafana_api_login="admin"
  [[ -n "$grafana_api_password" ]] || grafana_api_password="$grafana_password"

  vault_kv_put "secret/infrastructure/grafana/config" \
    username="$grafana_login" email="$grafana_email" password="$grafana_password"
  apply_literal_secret "$GRAFANA_NAMESPACE" "$GRAFANA_SECRET" \
    --from-literal="admin-user=$grafana_login" \
    --from-literal="admin-password=$grafana_password"

  grafana_pod="$(kubectl -n "$GRAFANA_NAMESPACE" get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$grafana_pod" ]]; then
    if kubectl -n "$GRAFANA_NAMESPACE" exec "$grafana_pod" -c grafana -- \
      sh -lc '/usr/share/grafana/bin/grafana cli admin reset-admin-password "$1" >/dev/null' sh "$grafana_password" \
      ; then
      grafana_api_password="$grafana_password"
    else
      log "Grafana CLI password reset failed; trying API sync with the previous admin secret"
    fi
  fi

  start_grafana_port_forward
  sync_grafana_users "$grafana_users_file" "$grafana_api_login" "$grafana_api_password"
  kubectl -n "$GRAFANA_NAMESPACE" rollout restart "statefulset/${GRAFANA_STATEFULSET}" >/dev/null
  log "Grafana users, admin secret, and statefulset synchronized"
fi

if [[ "$pgadmin_changed" -eq 1 && -n "$pgadmin_email" ]]; then
  vault_kv_put "secret/infrastructure/pgadmin4/config" \
    login="$pgadmin_login" username="$pgadmin_email" email="$pgadmin_email" password="$pgadmin_password"
  apply_literal_secret "$PGADMIN_NAMESPACE" "$PGADMIN_SECRET" \
    --from-literal="password=$pgadmin_password"

  sync_pgadmin_users "$pgadmin_users_file"

  kubectl -n "$PGADMIN_NAMESPACE" set env "deployment/${PGADMIN_DEPLOYMENT}" \
    "PGADMIN_DEFAULT_EMAIL=$pgadmin_email" >/dev/null
  kubectl -n "$PGADMIN_NAMESPACE" rollout restart "deployment/${PGADMIN_DEPLOYMENT}" >/dev/null
  log "pgAdmin users, default secret, and deployment synchronized"
fi

if [[ "$vault_changed" -eq 0 && "$kafka_changed" -eq 0 && "$grafana_changed" -eq 0 && "$pgadmin_changed" -eq 0 && "$postgres_changed" -eq 0 ]]; then
  log "No password fields were provided; nothing changed"
else
  log "Credential synchronization completed"
fi
