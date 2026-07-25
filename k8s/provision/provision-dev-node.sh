#!/usr/bin/env bash
# =============================================================================
#  Provisions the develop node (57.128.251.9 / ssh ovh2) so that
#  k8s/overlays/develop can be applied to it.
#
#  Mirrors the production node (57.129.66.163) component by component and
#  version by version, with resource requests cut to fit 2 vCPU / 3.7Gi:
#
#    k3s v1.36.2+k3s1        --disable=traefik   (Traefik comes from Helm)
#    traefik        chart 41.0.2   (v3.7.6)
#    cert-manager   chart v1.21.0  + ClusterIssuer letsencrypt-production
#    vault          chart 0.34.0   (2.0.3) standalone + Agent Injector
#    postgres       18.3-bookworm  StatefulSet in namespace `database`
#    kafka          4.3.1 KRaft    StatefulSet in namespace `kafka`
#
#  Run ON the node, as a user with sudo:
#
#    scp k8s/provision/provision-dev-node.sh ovh2:/tmp/
#    ssh ovh2 'bash /tmp/provision-dev-node.sh'
#
#  Every step is idempotent and skips itself if already done, so re-running
#  after a failure is safe.
#
#  SECRETS: this script generates the PostgreSQL superuser password and the
#  Vault unseal key/root token ON THE NODE. Nothing is printed to stdout and
#  nothing is written into this repository. Vault's init output lands in
#  /root/vault-init.json (mode 0600) - copy it into a password manager and then
#  delete it. See INFRASTRUCTURE.md.
# =============================================================================
set -euo pipefail

K3S_VERSION="v1.36.2+k3s1"
TRAEFIK_CHART_VERSION="41.0.2"
CERT_MANAGER_VERSION="v1.21.0"
VAULT_CHART_VERSION="0.34.0"
POSTGRES_IMAGE="postgres:18.3-bookworm"
KAFKA_IMAGE="apache/kafka:4.3.1"
ACME_EMAIL="${ACME_EMAIL:-admin@bosman.top}"

# The develop app namespace. Must match `namespace:` in
# k8s/overlays/develop/kustomization.yaml.
APP_NAMESPACE="${APP_NAMESPACE:-moomento-dev}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
skip() { printf '    \033[0;90m--- %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
log "Preflight"
# -----------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "run as a normal user with sudo, not as root - k3s writes its kubeconfig group to \$USER"
sudo -n true 2>/dev/null || sudo true || die "passwordless or interactive sudo is required"

mem_mib=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
[ "$mem_mib" -ge 3000 ] || die "only ${mem_mib}Mi of RAM; this stack needs ~2.6Gi of requests plus headroom"
printf '    RAM %sMi, %s vCPU, %s free on /\n' "$mem_mib" "$(nproc)" "$(df -h --output=avail / | tail -1 | tr -d ' ')"

if [ "$(swapon --show --noheadings | wc -l)" -ne 0 ]; then
  die "swap is enabled; kubelet requires it off (swapoff -a and remove the fstab entry)"
fi

# -----------------------------------------------------------------------------
log "k3s ${K3S_VERSION}"
# -----------------------------------------------------------------------------
if command -v k3s >/dev/null 2>&1; then
  skip "already installed: $(k3s --version | head -1)"
else
  # --disable=traefik so Traefik is managed by Helm at the same chart version as
  # production. metrics-server is kept: on a node this tight, `kubectl top` is
  # the tool you need most.
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_EXEC="server --disable=traefik --write-kubeconfig-mode=640 --write-kubeconfig-group=$(id -gn)" \
    sh -
fi

sudo systemctl is-active --quiet k3s || die "k3s is installed but not active: journalctl -u k3s -n50"

# Make kubectl work for this user without sudo, matching the production node.
mkdir -p "$HOME/.kube"
if ! [ -f "$HOME/.kube/config" ] || ! diff -q <(sudo cat /etc/rancher/k3s/k3s.yaml) "$HOME/.kube/config" >/dev/null 2>&1; then
  sudo install -m 600 -o "$(id -u)" -g "$(id -g)" /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
fi
export KUBECONFIG="$HOME/.kube/config"

log "Waiting for the node to become Ready"
kubectl wait --for=condition=Ready node --all --timeout=300s

# -----------------------------------------------------------------------------
log "Helm"
# -----------------------------------------------------------------------------
if command -v helm >/dev/null 2>&1; then
  skip "already installed: $(helm version --short)"
else
  curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update >/dev/null

# -----------------------------------------------------------------------------
log "Traefik ${TRAEFIK_CHART_VERSION}"
# -----------------------------------------------------------------------------
# Same arguments as production, including the permanent 80 -> 443 redirect, so
# the request path under test is the same one production serves.
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --version "${TRAEFIK_CHART_VERSION}" \
  --wait --timeout 10m \
  -f - <<'YAML'
deployment:
  replicas: 1
ingressClass:
  enabled: true
  isDefaultClass: true
providers:
  kubernetesIngress:
    enabled: true
service:
  type: LoadBalancer
ports:
  web:
    port: 80
    exposedPort: 80
    expose:
      default: true
  websecure:
    port: 443
    exposedPort: 443
    expose:
      default: true
additionalArguments:
  - --entryPoints.web.http.redirections.entryPoint.to=websecure
  - --entryPoints.web.http.redirections.entryPoint.scheme=https
  - --entryPoints.web.http.redirections.entryPoint.permanent=true
resources:
  requests:
    cpu: 25m
    memory: 48Mi
  limits:
    cpu: 300m
    memory: 256Mi
YAML

# -----------------------------------------------------------------------------
log "cert-manager ${CERT_MANAGER_VERSION}"
# -----------------------------------------------------------------------------
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --set resources.requests.cpu=10m \
  --set resources.requests.memory=32Mi \
  --set webhook.resources.requests.cpu=10m \
  --set webhook.resources.requests.memory=32Mi \
  --set cainjector.resources.requests.cpu=10m \
  --set cainjector.resources.requests.memory=48Mi \
  --wait --timeout 10m

log "ClusterIssuer letsencrypt-production"
# The name matches production so base/ingress-frontend.yaml needs no patching.
kubectl apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    email: ${ACME_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-production-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
YAML

# -----------------------------------------------------------------------------
log "Vault ${VAULT_CHART_VERSION} (standalone + Agent Injector)"
# -----------------------------------------------------------------------------
# Audit storage is disabled here (it is on in production) to save a PVC and the
# write amplification on a 38G disk.
helm upgrade --install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --version "${VAULT_CHART_VERSION}" \
  --timeout 10m \
  -f - <<'YAML'
global:
  enabled: true
  tlsDisable: true
injector:
  enabled: true
  replicas: 1
  resources:
    requests:
      cpu: 25m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 128Mi
server:
  standalone:
    enabled: true
    config: |
      ui = true

      listener "tcp" {
        address = "0.0.0.0:8200"
        cluster_address = "0.0.0.0:8201"
        tls_disable = 1
      }

      storage "file" {
        path = "/vault/data"
      }
  dataStorage:
    enabled: true
    size: 4Gi
    storageClass: local-path
  auditStorage:
    enabled: false
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 384Mi
ui:
  enabled: true
  serviceType: ClusterIP
YAML

log "Waiting for the vault-0 pod to exist (it stays 0/1 until unsealed)"
for _ in $(seq 60); do
  kubectl -n vault get pod vault-0 >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n vault get pod vault-0 >/dev/null 2>&1 || die "vault-0 never appeared: kubectl -n vault describe pod vault-0"

# --- init ---------------------------------------------------------------------
# 1 key share is deliberate for a develop box: a 5/3 split you cannot assemble
# alone is worse than one key stored properly. Production keeps its own split.
if sudo test -s /root/vault-init.json; then
  skip "/root/vault-init.json exists - Vault was already initialised"
else
  log "Initialising Vault (output -> /root/vault-init.json, mode 0600, not echoed)"
  kubectl -n vault exec vault-0 -- vault operator init \
      -key-shares=1 -key-threshold=1 -format=json \
    | sudo tee /root/vault-init.json >/dev/null
  sudo chmod 600 /root/vault-init.json
fi

# --- unseal -------------------------------------------------------------------
sealed=$(kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null | grep -o '"sealed": *[a-z]*' | awk '{print $2}' || echo true)
if [ "$sealed" = "false" ]; then
  skip "already unsealed"
else
  log "Unsealing"
  # The key is piped straight from root-owned storage into the pod; it never
  # becomes a shell argument, so it stays out of the process list and history.
  sudo grep -o '"unseal_keys_b64":\["[^"]*' /root/vault-init.json \
    | sed 's/.*\["//' \
    | kubectl -n vault exec -i vault-0 -- vault operator unseal - >/dev/null
fi

# --- kv v2 + kubernetes auth --------------------------------------------------
run_vault() {
  # Runs `vault <args>` inside vault-0 authenticated with the root token, which
  # is read from root-owned storage and passed as an env var, not an argument.
  local token
  token=$(sudo grep -o '"root_token":"[^"]*' /root/vault-init.json | cut -d'"' -f4)
  kubectl -n vault exec -i vault-0 -- env "VAULT_TOKEN=${token}" "$@"
}

if run_vault vault secrets list -format=json | grep -q '"secret/"'; then
  skip "kv secrets engine already mounted at secret/"
else
  log "Enabling kv v2 at secret/"
  run_vault vault secrets enable -path=secret -version=2 kv
fi

if run_vault vault auth list -format=json | grep -q '"kubernetes/"'; then
  skip "kubernetes auth already enabled"
else
  log "Enabling Kubernetes auth"
  run_vault vault auth enable kubernetes
  # shellcheck disable=SC2016
  run_vault sh -c 'vault write auth/kubernetes/config \
      kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
      token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
      kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
fi

# -----------------------------------------------------------------------------
log "PostgreSQL ${POSTGRES_IMAGE}"
# -----------------------------------------------------------------------------
kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -

# Superuser password: generated on the node, never printed, never in git.
if kubectl -n database get secret postgresql-superuser >/dev/null 2>&1; then
  skip "secret postgresql-superuser already exists"
else
  log "Generating the PostgreSQL superuser password"
  kubectl -n database create secret generic postgresql-superuser \
    --from-literal=password="$(openssl rand -base64 24)"
fi

kubectl apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: database
spec:
  clusterIP: None
  selector:
    app: postgresql
  ports:
    - name: postgresql
      port: 5432
      targetPort: postgresql
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql
  namespace: database
spec:
  serviceName: postgresql
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      securityContext:
        fsGroup: 999
      containers:
        - name: postgresql
          image: ${POSTGRES_IMAGE}
          ports:
            - name: postgresql
              containerPort: 5432
          env:
            - name: POSTGRES_USER
              value: postgres
            - name: POSTGRES_DB
              value: postgres
            - name: POSTGRES_INITDB_ARGS
              value: --auth-host=scram-sha-256 --data-checksums
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgresql-superuser
                  key: password
          resources:
            requests:
              cpu: 100m
              memory: 192Mi
            limits:
              cpu: 1
              memory: 768Mi
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "postgres", "-d", "postgres"]
            initialDelaySeconds: 10
            periodSeconds: 10
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 8Gi
YAML

# -----------------------------------------------------------------------------
log "Kafka ${KAFKA_IMAGE} (single-node KRaft)"
# -----------------------------------------------------------------------------
kubectl create namespace kafka --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: kafka
spec:
  selector:
    app: kafka
  ports:
    - name: plaintext
      port: 9092
      targetPort: plaintext
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-headless
  namespace: kafka
spec:
  clusterIP: None
  selector:
    app: kafka
  ports:
    - name: plaintext
      port: 9092
      targetPort: plaintext
    - name: controller
      port: 9093
      targetPort: controller
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: kafka
spec:
  serviceName: kafka-headless
  replicas: 1
  selector:
    matchLabels:
      app: kafka
  template:
    metadata:
      labels:
        app: kafka
    spec:
      containers:
        - name: kafka
          image: ${KAFKA_IMAGE}
          ports:
            - name: plaintext
              containerPort: 9092
            - name: controller
              containerPort: 9093
          env:
            # Same CLUSTER_ID as production is fine - it only has to be stable
            # within one cluster, and reusing it keeps the two comparable.
            - name: CLUSTER_ID
              value: MkU3OEVBNTcwNTJENDM2Qk
            - name: KAFKA_NODE_ID
              value: "1"
            - name: KAFKA_PROCESS_ROLES
              value: broker,controller
            - name: KAFKA_LISTENERS
              value: PLAINTEXT://:9092,CONTROLLER://:9093
            - name: KAFKA_ADVERTISED_LISTENERS
              value: PLAINTEXT://kafka.kafka.svc.cluster.local:9092
            - name: KAFKA_CONTROLLER_LISTENER_NAMES
              value: CONTROLLER
            - name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP
              value: CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
            - name: KAFKA_CONTROLLER_QUORUM_VOTERS
              value: 1@kafka-0.kafka-headless.kafka.svc.cluster.local:9093
            - name: KAFKA_INTER_BROKER_LISTENER_NAME
              value: PLAINTEXT
            - name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR
              value: "1"
            - name: KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR
              value: "1"
            - name: KAFKA_TRANSACTION_STATE_LOG_MIN_ISR
              value: "1"
            - name: KAFKA_DEFAULT_REPLICATION_FACTOR
              value: "1"
            - name: KAFKA_MIN_INSYNC_REPLICAS
              value: "1"
            - name: KAFKA_NUM_PARTITIONS
              value: "3"
            # Shorter retention and a smaller cap than production: 38G disk.
            - name: KAFKA_LOG_RETENTION_HOURS
              value: "24"
            - name: KAFKA_LOG_RETENTION_BYTES
              value: "1073741824"
            - name: KAFKA_LOG_SEGMENT_BYTES
              value: "134217728"
            - name: KAFKA_LOG_DIRS
              value: /var/lib/kafka/data
            # Half of production's heap; enough for a single-partition-per-topic
            # develop workload.
            - name: KAFKA_HEAP_OPTS
              value: -Xms256m -Xmx256m
          resources:
            requests:
              cpu: 100m
              memory: 384Mi
            limits:
              cpu: 1
              memory: 640Mi
          readinessProbe:
            tcpSocket:
              port: plaintext
            initialDelaySeconds: 20
            periodSeconds: 10
          volumeMounts:
            - name: data
              mountPath: /var/lib/kafka
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 6Gi
YAML

# -----------------------------------------------------------------------------
log "Waiting for PostgreSQL and Kafka"
# -----------------------------------------------------------------------------
kubectl -n database rollout status statefulset/postgresql --timeout=300s
kubectl -n kafka    rollout status statefulset/kafka      --timeout=300s

# -----------------------------------------------------------------------------
log "Done"
# -----------------------------------------------------------------------------
cat <<EOF

Cluster components:
$(kubectl get nodes -o wide --no-headers)

Traefik external address (this is what dev.moomento.pl must resolve to):
$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

Remaining manual steps
----------------------
1. Move /root/vault-init.json into a password manager, then:
       sudo shred -u /root/vault-init.json
   Vault is standalone, so after every node reboot it comes back SEALED and the
   backend/hosted pods will hang in Init until you unseal it:
       kubectl -n vault exec -it vault-0 -- vault operator unseal

2. Create the database and role, and store the develop secrets in Vault:
       ENVIRONMENT=develop bash bootstrap-vault.example.sh
       psql ... -f bootstrap-flashcards-db.sql
   (see k8s/README.md - "First-time setup")

3. Point DNS at this node:
       dev.moomento.pl  A  57.128.251.9   (Cloudflare proxy: on, SSL: Full (strict))

4. Push to the develop branch, or run the deploy workflow manually.

Memory budget on this node (requests, not limits):
$(kubectl get pods -A -o custom-columns=':spec.containers[*].resources.requests.memory' --no-headers 2>/dev/null | tr ',' '\n' | grep -o '[0-9]*Mi' | awk -F'Mi' '{s+=$1} END {printf "  infrastructure so far: %dMi of %dMi total\n", s, '"$mem_mib"'}')
  the three application pods will add ~704Mi of requests on top
EOF
