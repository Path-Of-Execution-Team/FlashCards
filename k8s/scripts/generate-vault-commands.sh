#!/usr/bin/env bash
set -euo pipefail

echo "=== Generator komend Vault (policies + sekrety) ==="
echo

# 1. Środowisko
read -rp "Wybierz środowisko (prod/dev): " ENV

case "$ENV" in
  prod)
    KV_PREFIX="secret/flashcards"
    DATA_PREFIX="secret/data/flashcards"
    BACKEND_POLICY="flashcards-backend"
    POSTGRES_POLICY="flashcards-postgres"
    HOSTED_POLICY="flashcards-hosted"
    ;;
  dev)
    KV_PREFIX="secret/flashcards-dev"
    DATA_PREFIX="secret/data/flashcards-dev"
    BACKEND_POLICY="flashcards-backend-dev"
    POSTGRES_POLICY="flashcards-postgres-dev"
    HOSTED_POLICY="flashcards-hosted-dev"
    ;;
  *)
    echo "Nieznane środowisko: $ENV (dozwolone: prod, dev)"
    exit 1
    ;;
esac

echo
echo "Wybrane środowisko: $ENV"
echo "KV prefix:   $KV_PREFIX"
echo "DATA prefix: $DATA_PREFIX"
echo

# 2. Wartości sekretów

echo "=== Backend ==="
read -srp "SPRING_DATASOURCE_PASSWORD: " SPRING_DATASOURCE_PASSWORD
echo
read -srp "JWT_SECRET: " JWT_SECRET
echo
echo

echo "=== Hosted (mail) ==="
read -rp  "MAIL_USERNAME: " MAIL_USERNAME
read -srp "MAIL_PASSWORD: " MAIL_PASSWORD
echo
echo

# 3. Plik wynikowy

OUT_FILE="vault-secrets-${ENV}.sh"

# helper do bezpiecznego wstawiania do basha
esc() {
  printf "%q" "$1"
}

SPRING_DATASOURCE_PASSWORD_ESCAPED=$(esc "$SPRING_DATASOURCE_PASSWORD")
JWT_SECRET_ESCAPED=$(esc "$JWT_SECRET")
MAIL_USERNAME_ESCAPED=$(esc "$MAIL_USERNAME")
MAIL_PASSWORD_ESCAPED=$(esc "$MAIL_PASSWORD")

cat > "$OUT_FILE" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# UWAGA:
# - zakładam, że masz ustawione VAULT_ADDR i VAULT_TOKEN
# - NIE commituj tego pliku do gita

echo "Ustawiam POLICIES i SEKRETY dla środowiska: $ENV"

########################
# POLICIES
########################

echo "Tworzę policy: $BACKEND_POLICY"
vault policy write $BACKEND_POLICY - <<'POLICY_BACKEND'
path "$DATA_PREFIX/backend" {
  capabilities = ["read"]
}
POLICY_BACKEND

echo "Tworzę policy: $POSTGRES_POLICY"
vault policy write $POSTGRES_POLICY - <<'POLICY_POSTGRES'
path "$DATA_PREFIX/backend" {
  capabilities = ["read"]
}
POLICY_POSTGRES

echo "Tworzę policy: $HOSTED_POLICY"
vault policy write $HOSTED_POLICY - <<'POLICY_HOSTED'
path "$DATA_PREFIX/hosted" {
  capabilities = ["read"]
}
POLICY_HOSTED

########################
# SEKRETY
########################

echo "Ustawiam sekrety w KV"

# backend
vault kv put $KV_PREFIX/backend \\
  SPRING_DATASOURCE_PASSWORD=$SPRING_DATASOURCE_PASSWORD_ESCAPED \\
  JWT_SECRET=$JWT_SECRET_ESCAPED

# hosted
vault kv put $KV_PREFIX/hosted \\
  MAIL_USERNAME=$MAIL_USERNAME_ESCAPED \\
  MAIL_PASSWORD=$MAIL_PASSWORD_ESCAPED

echo "Gotowe."
EOF

chmod +x "$OUT_FILE"

echo "Wygenerowano plik: $OUT_FILE"
echo "Uruchom go później w środowisku z zainstalowanym Vaultem, np.:"
echo "  ./$(basename "$OUT_FILE")"
