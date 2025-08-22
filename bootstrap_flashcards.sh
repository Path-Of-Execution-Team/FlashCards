#!/usr/bin/env bash
set -euo pipefail

# ========= sanity =========
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing tool: $1"; exit 1; }; }
need kubectl
command -v openssl >/dev/null 2>&1 || echo "WARN: openssl not found – random passwords will use a simple fallback."

# ========= defaults =========
OUT_DIR="${OUT_DIR:-./out}"

DEV_NS="${DEV_NS:-flashcards-dev}"
PROD_NS="${PROD_NS:-flashcards}"

MON_NS_DEV="${MON_NS_DEV:-dev-flashcards-monitoring}"
MON_NS_PROD="${MON_NS_PROD:-flashcards-monitoring}"

DEFAULT_DOMAIN="flashcards.bosman.top"
DEFAULT_DEV_TAG="dev-latest"
DEFAULT_PROD_TAG="latest"

# NodePorts (DEV vs PROD must be different)
FRONTEND_NODEPORT_DEV=30000
BACKEND_NODEPORT_DEV=30180
HOSTED_NODEPORT_DEV=30181

FRONTEND_NODEPORT_PROD=32000
BACKEND_NODEPORT_PROD=32180
HOSTED_NODEPORT_PROD=32181

# Monitoring NodePorts
PROM_NODEPORT_DEV=30900
GRAFANA_NODEPORT_DEV=30300
PROM_NODEPORT_PROD=30910
GRAFANA_NODEPORT_PROD=30310

genpw(){
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 12
  else
    date +%s | sha256sum | head -c 24
  fi
}

# ========= prompts =========
read -rp "Primary domain (default: ${DEFAULT_DOMAIN}): " BASE_DOMAIN
BASE_DOMAIN=${BASE_DOMAIN:-$DEFAULT_DOMAIN}

read -rp "Use separate DEV subdomains (dev., dev-api., dev-hosted.)? [y/N] (default: y): " DEV_SUBD
DEV_SUBD=${DEV_SUBD:-y}

FRONTEND_HOST_PROD="$BASE_DOMAIN"
BACKEND_HOST_PROD="api.${BASE_DOMAIN}"
HOSTED_HOST_PROD="hosted.${BASE_DOMAIN}"

if [[ "$DEV_SUBD" =~ ^[Yy]$ ]]; then
  FRONTEND_HOST_DEV="dev.${BASE_DOMAIN}"
  BACKEND_HOST_DEV="dev-api.${BASE_DOMAIN}"
  HOSTED_HOST_DEV="dev-hosted.${BASE_DOMAIN}"
else
  FRONTEND_HOST_DEV="$FRONTEND_HOST_PROD"
  BACKEND_HOST_DEV="$BACKEND_HOST_PROD"
  HOSTED_HOST_DEV="$HOSTED_HOST_PROD"
fi

echo
echo "== GHCR image paths =="
read -rp "Backend image (default: ghcr.io/Path-Of-Execution-Team/flashcardsbackend): " IMG_BACKEND
IMG_BACKEND=${IMG_BACKEND:-ghcr.io/Path-Of-Execution-Team/flashcardsbackend}
read -rp "Hosted  image (default: ghcr.io/Path-Of-Execution-Team/flashcardshostedservices): " IMG_HOSTED
IMG_HOSTED=${IMG_HOSTED:-ghcr.io/Path-Of-Execution-Team/flashcardshostedservices}
read -rp "Frontend image (default: ghcr.io/Path-Of-Execution-Team/flashcardsgui): " IMG_FRONTEND
IMG_FRONTEND=${IMG_FRONTEND:-ghcr.io/Path-Of-Execution-Team/flashcardsgui}

read -rp "Are GHCR images PRIVATE (create imagePullSecret)? [y/N] (default: N): " GHCR_PRIVATE
GHCR_PRIVATE=${GHCR_PRIVATE:-N}
if [[ "$GHCR_PRIVATE" =~ ^[Yy]$ ]]; then
  read -rp "GHCR username (default: ${GITHUB_ACTOR:-your-gh-username}): " GHCR_USER
  GHCR_USER=${GHCR_USER:-${GITHUB_ACTOR:-your-gh-username}}
  read -rp "GHCR token (read:packages) (default: empty – paste if private): " GHCR_TOKEN
  GHCR_TOKEN=${GHCR_TOKEN:-}
fi

read -rp "DEV tag for initial run (default: ${DEFAULT_DEV_TAG}): " DEV_TAG
DEV_TAG=${DEV_TAG:-$DEFAULT_DEV_TAG}
read -rp "PROD tag for initial run (default: ${DEFAULT_PROD_TAG}): " PROD_TAG
PROD_TAG=${PROD_TAG:-$DEFAULT_PROD_TAG}

echo
echo "== Postgres =="
read -rp "DB name (default: flashcards): " PG_DB; PG_DB=${PG_DB:-flashcards}
read -rp "DB user (default: flashcards_user): " PG_USER; PG_USER=${PG_USER:-flashcards_user}
read -rp "DB password DEV (default: random): " PG_PASS_DEV; PG_PASS_DEV=${PG_PASS_DEV:-$(genpw)}
read -rp "DB password PROD (default: random): " PG_PASS_PROD; PG_PASS_PROD=${PG_PASS_PROD:-$(genpw)}

echo
read -rp "Use Vault (Inject backend DB password via Vault Agent)? [y/N] (default: N): " USE_VAULT
USE_VAULT=${USE_VAULT:-N}
if [[ "$USE_VAULT" =~ ^[Yy]$ ]]; then
  read -rp "VAULT_ADDR (default: ${VAULT_ADDR:-none}): " IN_VAULT_ADDR
  VAULT_ADDR="${IN_VAULT_ADDR:-${VAULT_ADDR:-}}"
  read -rp "VAULT_TOKEN (default: ${VAULT_TOKEN:+***}): " IN_VAULT_TOKEN
  VAULT_TOKEN="${IN_VAULT_TOKEN:-${VAULT_TOKEN:-}}"
  export VAULT_ADDR VAULT_TOKEN
fi

# ========= layout =========
mkdir -p "$OUT_DIR"/caddy \
         "$OUT_DIR"/{dev,prod}/k8s \
         "$OUT_DIR"/{dev,prod}/monitoring

# ========= namespaces =========
cat > "$OUT_DIR/k8s-namespaces.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata: { name: ${DEV_NS} }
---
apiVersion: v1
kind: Namespace
metadata: { name: ${PROD_NS} }
---
apiVersion: v1
kind: Namespace
metadata: { name: ${MON_NS_DEV} }
---
apiVersion: v1
kind: Namespace
metadata: { name: ${MON_NS_PROD} }
YAML

# ========= generators =========
gen_db_yaml() {
  local env="$1" ns="$2" pass="$3"
  cat > "$OUT_DIR/${env}/k8s/postgres.yaml" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: ${ns}
type: Opaque
stringData:
  POSTGRES_DB: ${PG_DB}
  POSTGRES_USER: ${PG_USER}
  POSTGRES_PASSWORD: ${pass}
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: ${ns}
spec:
  selector: { app: postgres }
  ports: [{ name: db, port: 5432, targetPort: 5432 }]
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: ${ns}
spec:
  serviceName: postgres
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      containers:
        - name: postgres
          image: postgres:16
          envFrom: [{ secretRef: { name: postgres-secret } }]
          ports: [{ containerPort: 5432 }]
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: pgdata
          emptyDir: {}   # PROD: change to PVC for persistence
YAML
}

gen_kafka_yaml() {
  local env="$1" ns="$2"
  cat > "$OUT_DIR/${env}/k8s/kafka.yaml" <<YAML
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: ${ns}
spec:
  selector: { app: kafka }
  ports:
    - { name: internal, port: 9092, targetPort: 9092 }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: ${ns}
spec:
  serviceName: kafka
  replicas: 1
  selector: { matchLabels: { app: kafka } }
  template:
    metadata: { labels: { app: kafka } }
    spec:
      containers:
        - name: kafka
          image: bitnami/kafka:3.7
          env:
            - { name: KAFKA_ENABLE_KRAFT, value: "yes" }
            - { name: KAFKA_CFG_NODE_ID, value: "1" }
            - { name: KAFKA_CFG_PROCESS_ROLES, value: "broker,controller" }
            - { name: KAFKA_CFG_CONTROLLER_LISTENER_NAMES, value: "CONTROLLER" }
            - { name: KAFKA_CFG_LISTENERS, value: "INTERNAL://:9092,CONTROLLER://:9093" }
            - { name: KAFKA_CFG_ADVERTISED_LISTENERS, value: "INTERNAL://kafka.${ns}.svc.cluster.local:9092" }
            - { name: KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP, value: "INTERNAL:PLAINTEXT,CONTROLLER:PLAINTEXT" }
            - { name: KAFKA_CFG_INTER_BROKER_LISTENER_NAME, value: "INTERNAL" }
            - { name: KAFKA_CFG_CONTROLLER_QUORUM_VOTERS, value: "1@kafka:9093" }
            - { name: ALLOW_PLAINTEXT_LISTENER, value: "yes" }
            - { name: KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE, value: "true" }
          ports:
            - { containerPort: 9092 }
            - { containerPort: 9093 }
          volumeMounts:
            - { name: kafkadata, mountPath: /bitnami/kafka }
      volumes:
        - name: kafkadata
          emptyDir: {}
YAML
}

gen_apps_yaml() {
  local env="$1" ns="$2" fe_host="$3" be_host="$4" ho_host="$5" fe_np="$6" be_np="$7" ho_np="$8" backend_tag="$9" hosted_tag="${10}" front_tag="${11}"
  cat > "$OUT_DIR/${env}/k8s/apps.yaml" <<YAML
# === Backend ===
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: ${ns}
spec:
  type: NodePort
  selector: { app: backend }
  ports:
    - { name: http, port: 8080, targetPort: 8080, nodePort: ${be_np} }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: ${ns}
spec:
  replicas: 1
  selector: { matchLabels: { app: backend } }
  template:
    metadata: { labels: { app: backend } }
    spec:
      serviceAccountName: backend-sa
      containers:
        - name: backend
          image: ${IMG_BACKEND}:${backend_tag}
          imagePullPolicy: IfNotPresent
          env:
            - { name: SPRING_PROFILES_ACTIVE, value: "${env}" }
            - { name: SPRING_DATASOURCE_URL, value: "jdbc:postgresql://postgres.${ns}.svc.cluster.local:5432/${PG_DB}" }
            - { name: SPRING_DATASOURCE_USERNAME, value: "${PG_USER}" }
            - { name: SPRING_DATASOURCE_PASSWORD, valueFrom: { secretKeyRef: { name: postgres-secret, key: POSTGRES_PASSWORD } } }
            - { name: SPRING_KAFKA_BOOTSTRAP_SERVERS, value: "kafka.${ns}.svc.cluster.local:9092" }
            - { name: ALLOWED_ORIGINS, value: "https://${fe_host}-https://${be_host}" }
          ports: [{ containerPort: 8080 }]
          readinessProbe: { httpGet: { path: /actuator/health/readiness, port: 8080 }, initialDelaySeconds: 10, periodSeconds: 5 }
          livenessProbe:  { httpGet: { path: /actuator/health/liveness,  port: 8080 }, initialDelaySeconds: 30, periodSeconds: 10 }

# === Hosted ===
---
apiVersion: v1
kind: Service
metadata:
  name: hosted
  namespace: ${ns}
spec:
  type: NodePort
  selector: { app: hosted }
  ports:
    - { name: http, port: 8081, targetPort: 8081, nodePort: ${ho_np} }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hosted
  namespace: ${ns}
spec:
  replicas: 1
  selector: { matchLabels: { app: hosted } }
  template:
    metadata: { labels: { app: hosted } }
    spec:
      containers:
        - name: hosted
          image: ${IMG_HOSTED}:${hosted_tag}
          imagePullPolicy: IfNotPresent
          env:
            - { name: SPRING_PROFILES_ACTIVE, value: "${env}" }
            - { name: SPRING_APPLICATION_JSON, value: '{"server":{"port":8081}}' }
            - { name: SPRING_KAFKA_BOOTSTRAP_SERVERS, value: "kafka.${ns}.svc.cluster.local:9092" }
          ports: [{ containerPort: 8081 }]
          readinessProbe: { httpGet: { path: /actuator/health/readiness, port: 8081 }, initialDelaySeconds: 10, periodSeconds: 5 }
          livenessProbe:  { httpGet: { path: /actuator/health/liveness,  port: 8081 }, initialDelaySeconds: 30, periodSeconds: 10 }

# === Frontend ===
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: ${ns}
spec:
  type: NodePort
  selector: { app: frontend }
  ports:
    - { name: http, port: 3000, targetPort: 3000, nodePort: ${fe_np} }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: ${ns}
spec:
  replicas: 1
  selector: { matchLabels: { app: frontend } }
  template:
    metadata: { labels: { app: frontend } }
    spec:
      containers:
        - name: frontend
          image: ${IMG_FRONTEND}:${front_tag}
          imagePullPolicy: IfNotPresent
          env:
            - { name: NEXT_TELEMETRY_DISABLED, value: "1" }
            - { name: NEXT_PUBLIC_API_BASE_URL, value: "https://${be_host}" }
            - { name: PORT, value: "3000" }
          ports: [{ containerPort: 3000 }]
          readinessProbe: { httpGet: { path: /api/health, port: 3000 }, initialDelaySeconds: 5, periodSeconds: 5 }
          livenessProbe:  { httpGet: { path: /api/health, port: 3000 }, initialDelaySeconds: 20, periodSeconds: 10 }
YAML
}

# create ServiceAccount for backend (always present; harmless if Vault off)
gen_sa_backend() {
  local env="$1"
  cat > "$OUT_DIR/${env}/k8s/sa-backend.yaml" <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend-sa
YAML
}

# write kustomization.yaml for apps (include patches conditionally)
write_kust_apps() {
  local env="$1" ns="$2"
  local KUST="$OUT_DIR/${env}/k8s/kustomization.yaml"
  cat > "$KUST" <<YAML
# yaml-language-server: \$schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${ns}

resources:
  - postgres.yaml
  - kafka.yaml
  - apps.yaml
  - sa-backend.yaml
YAML

  # patches (append if files exist)
  if [[ -f "$OUT_DIR/${env}/k8s/backend-vault-patch.yaml" ]]; then
    cat >> "$KUST" <<YAML
patches:
  - target: { kind: Deployment, name: backend }
    path: backend-vault-patch.yaml
YAML
  fi

  if [[ -f "$OUT_DIR/${env}/k8s/deploy-pullsecret-patch.yaml" ]]; then
    if ! grep -q '^patches:' "$KUST"; then echo "patches:" >> "$KUST"; fi
    cat >> "$KUST" <<YAML
  - target: { kind: Deployment, name: backend }
    path: deploy-pullsecret-patch.yaml
  - target: { kind: Deployment, name: hosted }
    path: deploy-pullsecret-patch.yaml
  - target: { kind: Deployment, name: frontend }
    path: deploy-pullsecret-patch.yaml
YAML
  fi
}

# monitoring stack (plus its kustomization)
gen_monitoring_stack() {
  local env="$1" mon_ns="$2" app_ns="$3" prom_np="$4" graf_np="$5" job_name="$6"

  cat > "$OUT_DIR/${env}/monitoring/monitoring-stack.yaml" <<YAML
# === Prometheus ===
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: ${mon_ns}
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: '${job_name}'
        metrics_path: /actuator/prometheus
        static_configs:
          - targets:
              - backend.${app_ns}.svc.cluster.local:8080
              - hosted.${app_ns}.svc.cluster.local:8081
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: ${mon_ns}
spec:
  type: NodePort
  selector: { app: prometheus }
  ports:
    - { name: http, port: 9090, targetPort: 9090, nodePort: ${prom_np} }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: ${mon_ns}
spec:
  replicas: 1
  selector: { matchLabels: { app: prometheus } }
  template:
    metadata: { labels: { app: prometheus } }
    spec:
      containers:
        - name: prometheus
          image: prom/prometheus:latest
          args: ["--config.file=/etc/prometheus/prometheus.yml","--storage.tsdb.path=/prometheus"]
          ports: [{ containerPort: 9090 }]
          resources:
            requests: { cpu: "250m", memory: "512Mi" }
            limits:   { cpu: "1",    memory: "2Gi" }
          volumeMounts:
            - { name: conf, mountPath: /etc/prometheus }
            - { name: data, mountPath: /prometheus }
      volumes:
        - name: conf
          configMap: { name: prometheus-config }
        - name: data
          emptyDir: {}

# === Loki ===
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: ${mon_ns}
data:
  loki.yaml: |
    auth_enabled: false
    server:
      http_listen_port: 3100
    common:
      path_prefix: /loki
      storage:
        filesystem:
          chunks_directory: /loki/chunks
          rules_directory: /loki/rules
      replication_factor: 1
      ring:
        instance_addr: 127.0.0.1
        kvstore: { store: inmemory }
    schema_config:
      configs:
        - from: 2022-01-01
          store: boltdb-shipper
          object_store: filesystem
          schema: v12
          index: { prefix: index_, period: 24h }
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: ${mon_ns}
spec:
  selector: { app: loki }
  ports:
    - { name: http, port: 3100, targetPort: 3100 }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: loki
  namespace: ${mon_ns}
spec:
  serviceName: loki
  replicas: 1
  selector: { matchLabels: { app: loki } }
  template:
    metadata: { labels: { app: loki } }
    spec:
      containers:
        - name: loki
          image: grafana/loki:2.9.4
          args: ["-config.file=/etc/loki/loki.yaml"]
          ports: [{ containerPort: 3100 }]
          resources:
            requests: { cpu: "100m", memory: "256Mi" }
            limits:   { cpu: "500m", memory: "1Gi" }
          volumeMounts:
            - { name: conf, mountPath: /etc/loki }
            - { name: data, mountPath: /loki }
      volumes:
        - name: conf
          configMap: { name: loki-config }
        - name: data
          emptyDir: {}

# === Promtail ===
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: ${mon_ns}
data:
  promtail.yaml: |
    server:
      http_listen_port: 9080
      grpc_listen_port: 0
    positions:
      filename: /run/promtail/positions.yaml
    clients:
      - url: http://loki.${mon_ns}.svc.cluster.local:3100/loki/api/v1/push
    scrape_configs:
      - job_name: kubernetes-logs
        static_configs:
          - targets: ['localhost']
            labels:
              job: kubernetes
              __path__: /var/log/containers/*.log
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail
  namespace: ${mon_ns}
spec:
  selector: { matchLabels: { app: promtail } }
  template:
    metadata: { labels: { app: promtail } }
    spec:
      serviceAccountName: default
      containers:
        - name: promtail
          image: grafana/promtail:2.9.4
          args: ["-config.file=/etc/promtail/promtail.yaml"]
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits:   { cpu: "200m", memory: "200Mi" }
          volumeMounts:
            - { name: conf,       mountPath: /etc/promtail }
            - { name: positions,  mountPath: /run/promtail }
            - { name: varlog,     mountPath: /var/log }
            - { name: containers, mountPath: /var/log/containers }
            - { name: pods,       mountPath: /var/log/pods }
      volumes:
        - name: conf
          configMap: { name: promtail-config }
        - name: positions
          emptyDir: {}
        - name: varlog
          hostPath: { path: /var/log }
        - name: containers
          hostPath: { path: /var/log/containers }
        - name: pods
          hostPath: { path: /var/log/pods }

# === Grafana ===
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: ${mon_ns}
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus.${mon_ns}.svc.cluster.local:9090
        isDefault: true
      - name: Loki
        type: loki
        access: proxy
        url: http://loki.${mon_ns}.svc.cluster.local:3100
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: ${mon_ns}
spec:
  type: NodePort
  selector: { app: grafana }
  ports:
    - { name: http, port: 3000, targetPort: 3000, nodePort: ${graf_np} }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: ${mon_ns}
spec:
  replicas: 1
  selector: { matchLabels: { app: grafana } }
  template:
    metadata: { labels: { app: grafana } }
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:10.4.2
          ports: [{ containerPort: 3000 }]
          env:
            - { name: GF_SECURITY_ADMIN_USER,     value: "admin" }
            - { name: GF_SECURITY_ADMIN_PASSWORD, value: "changeMeGrafana123" }
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "512Mi" }
          volumeMounts:
            - { name: ds, mountPath: /etc/grafana/provisioning/datasources }
      volumes:
        - name: ds
          configMap: { name: grafana-datasources }
YAML

  # kustomization for monitoring
  cat > "$OUT_DIR/${env}/monitoring/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${mon_ns}
resources:
  - monitoring-stack.yaml
YAML
}

# ========= generate apps/manifests =========
# DEV
gen_db_yaml "dev"  "$DEV_NS"  "$PG_PASS_DEV"
gen_kafka_yaml "dev"  "$DEV_NS"
gen_apps_yaml "dev"  "$DEV_NS"  "$FRONTEND_HOST_DEV" "$BACKEND_HOST_DEV" "$HOSTED_HOST_DEV" \
  "$FRONTEND_NODEPORT_DEV" "$BACKEND_NODEPORT_DEV" "$HOSTED_NODEPORT_DEV" \
  "$DEV_TAG" "$DEV_TAG" "$DEV_TAG"
gen_sa_backend "dev"

# PROD
gen_db_yaml "prod" "$PROD_NS" "$PG_PASS_PROD"
gen_kafka_yaml "prod" "$PROD_NS"
gen_apps_yaml "prod" "$PROD_NS" "$FRONTEND_HOST_PROD" "$BACKEND_HOST_PROD" "$HOSTED_HOST_PROD" \
  "$FRONTEND_NODEPORT_PROD" "$BACKEND_NODEPORT_PROD" "$HOSTED_NODEPORT_PROD" \
  "$PROD_TAG" "$PROD_TAG" "$PROD_TAG"
gen_sa_backend "prod"

# optional GHCR pull secrets
if [[ "$GHCR_PRIVATE" =~ ^[Yy]$ ]]; then
  cat > "$OUT_DIR/k8s-ghcr-secrets.sh" <<EOS
#!/usr/bin/env bash
set -euo pipefail
: "\${GHCR_USER:?GHCR_USER not set}"
: "\${GHCR_TOKEN:?GHCR_TOKEN not set}"
: "\${DEV_NS:?DEV_NS not set}"
: "\${PROD_NS:?PROD_NS not set}"

kubectl create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username="\$GHCR_USER" \
  --docker-password="\$GHCR_TOKEN" \
  -n "\$DEV_NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username="\$GHCR_USER" \
  --docker-password="\$GHCR_TOKEN" \
  -n "\$PROD_NS" --dry-run=client -o yaml | kubectl apply -f -

echo "ghcr-creds created in \$DEV_NS and \$PROD_NS."
EOS
  chmod +x "$OUT_DIR/k8s-ghcr-secrets.sh"

  for env in dev prod; do
    cat > "$OUT_DIR/${env}/k8s/deploy-pullsecret-patch.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  template:
    spec:
      imagePullSecrets: [{ name: ghcr-creds }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hosted
spec:
  template:
    spec:
      imagePullSecrets: [{ name: ghcr-creds }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  template:
    spec:
      imagePullSecrets: [{ name: ghcr-creds }]
YAML
  done
fi

# optional Vault patches + helper
if [[ "$USE_VAULT" =~ ^[Yy]$ ]]; then
  # DEV patch
  cat > "$OUT_DIR/dev/k8s/backend-vault-patch.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "flashcards-dev-backend"
        vault.hashicorp.com/agent-pre-populate: "true"
        vault.hashicorp.com/agent-inject-secret-backend.env: "kv/flashcards/dev/backend"
        vault.hashicorp.com/agent-inject-template-backend.env: |
          {{- with secret "kv/flashcards/dev/backend" -}}
          SPRING_DATASOURCE_PASSWORD={{ .Data.data.SPRING_DATASOURCE_PASSWORD }}
          {{- end }}
    spec:
      serviceAccountName: backend-sa
      containers:
        - name: backend
          command: ["/bin/sh","-lc"]
          args: [ "set -e; . /vault/secrets/backend.env; exec java -jar app.jar" ]
YAML

  # PROD patch
  cat > "$OUT_DIR/prod/k8s/backend-vault-patch.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "flashcards-prod-backend"
        vault.hashicorp.com/agent-pre-populate: "true"
        vault.hashicorp.com/agent-inject-secret-backend.env: "kv/flashcards/prod/backend"
        vault.hashicorp.com/agent-inject-template-backend.env: |
          {{- with secret "kv/flashcards/prod/backend" -}}
          SPRING_DATASOURCE_PASSWORD={{ .Data.data.SPRING_DATASOURCE_PASSWORD }}
          {{- end }}
    spec:
      serviceAccountName: backend-sa
      containers:
        - name: backend
          command: ["/bin/sh","-lc"]
          args: [ "set -e; . /vault/secrets/backend.env; exec java -jar app.jar" ]
YAML

  # helper to configure Vault (+ prompt to self-delete)
  cat > "$OUT_DIR/vault-setup.sh" <<EOS
#!/usr/bin/env bash
set -euo pipefail
: "\${VAULT_ADDR:?VAULT_ADDR not set}"
: "\${VAULT_TOKEN:?VAULT_TOKEN not set}"

cat > policies.hcl <<HCL
path "kv/data/flashcards/dev/backend"  { capabilities = ["read"] }
path "kv/data/flashcards/prod/backend" { capabilities = ["read"] }
HCL

vault policy write flashcards-dev-backend policies.hcl
vault policy write flashcards-prod-backend policies.hcl

vault write auth/kubernetes/role/flashcards-dev-backend  \
  bound_service_account_names=backend-sa                 \
  bound_service_account_namespaces=${DEV_NS}             \
  policies=flashcards-dev-backend                        \
  ttl=24h

vault write auth/kubernetes/role/flashcards-prod-backend \
  bound_service_account_names=backend-sa                 \
  bound_service_account_namespaces=${PROD_NS}            \
  policies=flashcards-prod-backend                       \
  ttl=24h

vault kv put kv/flashcards/dev/backend  SPRING_DATASOURCE_PASSWORD='${PG_PASS_DEV}'
vault kv put kv/flashcards/prod/backend SPRING_DATASOURCE_PASSWORD='${PG_PASS_PROD}'

echo
echo "Vault roles/policies/secrets prepared."
read -rp "Delete this script (vault-setup.sh) now? [Y/n] (default: Y): " DEL
DEL=\${DEL:-Y}
if [[ "\$DEL" =~ ^[Yy]$ ]]; then
  rm -f "\$0"
  echo "Removed \$(basename "\$0")."
else
  echo "Left \$(basename "\$0") in place."
fi
EOS
  chmod +x "$OUT_DIR/vault-setup.sh"
fi

# write kustomizations for apps
write_kust_apps "dev"  "$DEV_NS"
write_kust_apps "prod" "$PROD_NS"

# monitoring manifests + kustomizations
gen_monitoring_stack "dev"  "$MON_NS_DEV"  "$DEV_NS"  "$PROM_NODEPORT_DEV"  "$GRAFANA_NODEPORT_DEV"  "dev-flashcards-metrics"
gen_monitoring_stack "prod" "$MON_NS_PROD" "$PROD_NS" "$PROM_NODEPORT_PROD" "$GRAFANA_NODEPORT_PROD" "flashcards-metrics"

# Caddyfile
cat > "$OUT_DIR/caddy/Caddyfile" <<CADDY
{
  email you@example.com
}

# ===== PROD =====
${FRONTEND_HOST_PROD} {
  encode zstd gzip
  reverse_proxy 127.0.0.1:${FRONTEND_NODEPORT_PROD}
}

${BACKEND_HOST_PROD} {
  encode zstd gzip
  reverse_proxy 127.0.0.1:${BACKEND_NODEPORT_PROD}
}

${HOSTED_HOST_PROD} {
  encode zstd gzip
  reverse_proxy 127.0.0.1:${HOSTED_NODEPORT_PROD}
}

# ===== DEV =====
${FRONTEND_HOST_DEV} {
  encode zstd gzip
  reverse_proxy 127.0.0.1:${FRONTEND_NODEPORT_DEV}
}

${BACKEND_HOST_DEV} {
  encode zstd gzip
  reverse_proxy 127.0.0.1:${BACKEND_NODEPORT_DEV}
}

${HOSTED_HOST_DEV} {
  encode zstd gzip
  reverse_proxy 127.0.0.1:${HOSTED_NODEPORT_DEV}
}
CADDY

# summary
cat <<INFO

== Generated into: $OUT_DIR ==

Namespaces:
  - $OUT_DIR/k8s-namespaces.yaml
    (creates: ${DEV_NS}, ${PROD_NS}, ${MON_NS_DEV}, ${MON_NS_PROD})

DEV apps (kustomize):
  - $OUT_DIR/dev/k8s/{postgres.yaml,kafka.yaml,apps.yaml,sa-backend.yaml,kustomization.yaml}

PROD apps (kustomize):
  - $OUT_DIR/prod/k8s/{postgres.yaml,kafka.yaml,apps.yaml,sa-backend.yaml,kustomization.yaml}

Monitoring:
  - $OUT_DIR/dev/monitoring/{monitoring-stack.yaml,kustomization.yaml}     (ns: ${MON_NS_DEV})
  - $OUT_DIR/prod/monitoring/{monitoring-stack.yaml,kustomization.yaml}    (ns: ${MON_NS_PROD})

Caddy:
  - $OUT_DIR/caddy/Caddyfile

== Apply order ==
kubectl apply -f "$OUT_DIR/k8s-namespaces.yaml"

# If GHCR is private:
$( [[ "$GHCR_PRIVATE" =~ ^[Yy]$ ]] && echo "export GHCR_USER='$GHCR_USER' GHCR_TOKEN='${GHCR_TOKEN:-paste-token}' DEV_NS='$DEV_NS' PROD_NS='$PROD_NS'" )
$( [[ "$GHCR_PRIVATE" =~ ^[Yy]$ ]] && echo "\"$OUT_DIR/k8s-ghcr-secrets.sh\"" )

# DEV
kubectl apply -k "$OUT_DIR/dev/k8s"
kubectl apply -k "$OUT_DIR/dev/monitoring"

# PROD
kubectl apply -k "$OUT_DIR/prod/k8s"
kubectl apply -k "$OUT_DIR/prod/monitoring"

# Caddy on VPS
sudo cp "$OUT_DIR/caddy/Caddyfile" /etc/caddy/Caddyfile
sudo caddy fmt --overwrite /etc/caddy/Caddyfile
sudo systemctl reload caddy

INFO