# Bosman Kubernetes Infrastructure Context

> Canonical, AI-readable context for building and deploying projects on this server.
> Last verified: 2026-07-25 (UTC).
>
> Never place passwords, Vault tokens, unseal keys, Kubernetes Secret values, or
> `vault-init.json` contents in source control, prompts, manifests, or application logs.

## 1. Platform summary

```yaml
platform:
  environment: single-node-vps
  public_ipv4: 57.129.66.163
  operating_system: Ubuntu 26.04 LTS
  architecture: linux/amd64
  cpu: 4
  memory: 8Gi
  root_disk: 72Gi
  swap: disabled

kubernetes:
  distribution: k3s
  version: v1.36.2+k3s1
  node: vps-65fdc653
  role: control-plane
  container_runtime: containerd 2.3.2-k3s2
  cluster_domain: cluster.local
  pod_cidr: 10.42.0.0/16
  service_cidr: 10.43.0.0/16
  kubeconfig: /home/ubuntu/.kube/config
  kubectl_alias: k

storage:
  default_storage_class: local-path
  access_mode: ReadWriteOnce
  high_availability: false
  volume_expansion: false

ingress:
  controller: Traefik
  version: 3.7.6
  ingress_class: traefik
  public_ip: 57.129.66.163
  ports: [80, 443]

tls:
  controller: cert-manager
  version: 1.21.0
  cluster_issuer: letsencrypt-production
  dns_proxy: Cloudflare
```

## 2. Public endpoints

| Component | Public URL | Login identifier | Credentials |
|---|---|---|---|
| Vault UI | https://vault.bosman.top/ui/ | `bosman` via `userpass` | Managed separately; do not store in project files |
| Grafana | https://grafana.bosman.top | `bosman` | Vault: `secret/infrastructure/grafana/config` |
| pgAdmin4 | https://pgadmin4.bosman.top | `bosman@bosman.top` | Vault: `secret/infrastructure/pgadmin4/users/bosman` |

All public endpoints use Traefik and valid Let's Encrypt certificates. HTTP is
redirected to HTTPS. PostgreSQL, Prometheus, Loki, Alertmanager, and Vault API
ports are not exposed directly to the internet.

## 3. Namespaces

```yaml
namespaces:
  cert-manager: TLS certificate automation
  database: PostgreSQL and pgAdmin4
  monitoring: Grafana, Prometheus, Alertmanager, Loki, Alloy
  traefik: public ingress controller
  vault: Vault server and Vault Agent Injector
  kube-system: k3s system services and Metrics Server
```

Create a dedicated namespace for every new project. Do not deploy applications
to `default`, `database`, `monitoring`, `vault`, or `kube-system`.

## 4. PostgreSQL

```yaml
postgresql:
  version: "18.3"
  image: postgres:18.3-bookworm
  namespace: database
  workload: StatefulSet/postgresql
  replicas: 1
  service: postgresql
  internal_host: postgresql.database.svc.cluster.local
  port: 5432
  application_database: applications
  application_user: app_user
  admin_user: postgres
  public_access: false
  persistent_volume:
    claim: data-postgresql-0
    size: 20Gi
    storage_class: local-path
  authentication: scram-sha-256
  data_checksums: enabled
```

Application connection template:

```text
postgresql://app_user:${POSTGRES_PASSWORD}@postgresql.database.svc.cluster.local:5432/applications
```

Vault paths:

```text
secret/infrastructure/postgresql/admin
secret/infrastructure/postgresql/applications
```

Expected fields under `secret/infrastructure/postgresql/applications`:

```yaml
host: postgresql.database.svc.cluster.local
port: 5432
database: applications
username: app_user
password: <managed by Vault>
```

Rules for projects:

1. Prefer a separate PostgreSQL role and database per production application.
2. Never use the `postgres` superuser from application code.
3. Do not expose port 5432 with Ingress, LoadBalancer, or NodePort.
4. Read credentials from Vault or a Kubernetes Secret generated from Vault.
5. Use connection pooling and bounded pool sizes; this is a single PostgreSQL instance.
6. Schema migrations must be explicit jobs or release steps.

In-cluster connectivity test:

```bash
kubectl run pg-connectivity-test \
  --rm -it --restart=Never \
  --image=postgres:18.3-bookworm \
  --env="PGPASSWORD=${POSTGRES_PASSWORD}" \
  -- psql \
  -h postgresql.database.svc.cluster.local \
  -U app_user \
  -d applications \
  -c 'select current_user, current_database();'
```

## 5. Vault and secrets

```yaml
vault:
  version: 2.0.3
  chart: vault-0.34.0
  namespace: vault
  mode: standalone
  storage_backend: file
  high_availability: false
  initialized: true
  seal: shamir
  key_shares: 5
  unseal_threshold: 3
  external_url: https://vault.bosman.top
  internal_url: http://vault.vault.svc.cluster.local:8200
  kv_engine:
    mount: secret/
    version: 2
  auth_methods:
    - token
    - userpass
    - kubernetes
  injector: enabled
  audit_log: enabled
  persistent_storage:
    data: 10Gi
    audit: 5Gi
```

Current infrastructure secret hierarchy:

```text
secret/infrastructure/
├── grafana/
│   └── config
├── pgadmin4/
│   ├── config
│   └── users/
│       └── bosman
└── postgresql/
    ├── admin
    └── applications
```

Recommended application hierarchy:

```text
secret/projects/<project-name>/<environment>/<secret-name>
```

Example:

```text
secret/projects/orders-api/production/database
secret/projects/orders-api/production/jwt
```

### Vault Agent Injector pattern

Kubernetes Auth and the injector are installed, but each project must receive
its own ServiceAccount, Vault policy, and Kubernetes auth role.

Minimal pod annotations:

```yaml
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "PROJECT_NAME"
    vault.hashicorp.com/agent-inject-secret-config: "secret/data/projects/PROJECT_NAME/production/config"
    vault.hashicorp.com/agent-inject-template-config: |
      {{- with secret "secret/data/projects/PROJECT_NAME/production/config" -}}
      DATABASE_URL={{ .Data.data.database_url }}
      {{- end }}
spec:
  serviceAccountName: PROJECT_NAME
```

Injected files are available in `/vault/secrets/`. Never bind a project role to
the `default` ServiceAccount and never assign the `grand-admin` policy to an
application.

Example least-privilege policy:

```hcl
path "secret/data/projects/PROJECT_NAME/production/*" {
  capabilities = ["read"]
}

path "secret/metadata/projects/PROJECT_NAME/production/*" {
  capabilities = ["read", "list"]
}
```

## 6. Monitoring and logs

```yaml
grafana:
  image: grafana/grafana:13.1.1
  namespace: monitoring
  external_url: https://grafana.bosman.top
  storage: 5Gi
  sign_up: disabled
  datasources:
    - Prometheus
    - Loki
    - Alertmanager

prometheus:
  image: prometheus:v3.13.1
  namespace: monitoring
  internal_url: http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
  retention: 7d
  retention_size: 12GB
  storage: 15Gi

loki:
  version: 3.7.4
  namespace: monitoring
  mode: Monolithic
  internal_url: http://loki-gateway.monitoring.svc.cluster.local
  retention: 7d
  storage: 10Gi

alloy:
  version: 1.18.0
  namespace: monitoring
  controller: Deployment
  replicas: 1
  purpose:
    - collect Kubernetes pod logs
    - collect Kubernetes events
    - forward logs to Loki
  static_log_label:
    cluster: bosman-k3s

alertmanager:
  image: alertmanager:v0.33.1
  namespace: monitoring
  storage: 2Gi

metrics_server:
  version: 0.8.1
  purpose: current CPU and memory metrics for kubectl top and HPA
  historical_storage: false
```

Useful LogQL selectors:

```logql
{cluster="bosman-k3s"}
{cluster="bosman-k3s", namespace="PROJECT_NAMESPACE"}
{cluster="bosman-k3s", namespace="PROJECT_NAMESPACE", app="PROJECT_NAME"}
```

### Exposing application metrics

Applications should expose Prometheus metrics on a named port such as
`metrics`, normally at `/metrics`, and provide a `ServiceMonitor`.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: PROJECT_NAME
  namespace: PROJECT_NAMESPACE
spec:
  selector:
    matchLabels:
      app: PROJECT_NAME
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
```

Prometheus is configured to discover ServiceMonitor and PodMonitor resources
outside the monitoring Helm release.

## 7. Autoscaling

Metrics Server and the Kubernetes HPA controller are operational. HPA scales
pods only; it cannot add nodes or increase VPS CPU/RAM.

Every autoscaled container must define resource requests:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

Recommended HPA baseline:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: PROJECT_NAME
  namespace: PROJECT_NAMESPACE
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: PROJECT_NAME
  minReplicas: 1
  maxReplicas: 5
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
  metrics:
    - type: ContainerResource
      containerResource:
        name: cpu
        container: application
        target:
          type: Utilization
          averageUtilization: 60
```

Set limits according to actual load tests and the remaining capacity of this
single node.

## 8. Publishing a project

DNS is managed through Cloudflare. Before requesting a certificate, create a
proxied or DNS-only record for the project hostname resolving to:

```text
57.129.66.163
```

Ingress template:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: PROJECT_NAME
  namespace: PROJECT_NAMESPACE
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - PROJECT_HOST.bosman.top
      secretName: PROJECT_NAME-tls
  rules:
    - host: PROJECT_HOST.bosman.top
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: PROJECT_NAME
                port:
                  number: 80
```

Recommended Cloudflare SSL/TLS mode: `Full (strict)`.

## 9. Local source-of-truth files

```text
/home/ubuntu/
├── INFRASTRUCTURE.md
├── db/
│   └── postgresql-pgadmin.yaml
├── monitoring/
│   ├── alloy-values.yaml
│   ├── kube-prometheus-stack-values.yaml
│   └── loki-values.yaml
├── traefik/
│   └── traefik-values.yaml
└── vault/
    ├── vault-values.yaml
    ├── vault-public-ingress.yaml
    └── vault-init.json          # secret, mode 0600, never commit
```

These files contain the intended configuration. The live Kubernetes cluster
remains the source for generated objects, Secrets, runtime status, and Helm
release metadata.

## 10. Installed Helm releases

| Release | Namespace | Chart | App version |
|---|---|---|---|
| `vault` | `vault` | `vault-0.34.0` | `2.0.3` |
| `traefik` | `traefik` | `traefik-41.0.2` | `3.7.6` |
| `cert-manager` | `cert-manager` | `cert-manager-v1.21.0` | `v1.21.0` |
| `monitoring` | `monitoring` | `kube-prometheus-stack-87.19.1` | `v0.92.1` |
| `loki` | `monitoring` | `loki-18.5.4` | `3.7.4` |
| `alloy` | `monitoring` | `alloy-1.11.0` | `v1.18.0` |

PostgreSQL and pgAdmin4 are managed by a plain Kubernetes manifest, not Helm.

## 11. Persistent volumes

| Component | Namespace | Size | Storage class |
|---|---|---:|---|
| PostgreSQL | `database` | 20Gi | `local-path` |
| pgAdmin4 | `database` | 2Gi | `local-path` |
| Prometheus | `monitoring` | 15Gi | `local-path` |
| Loki | `monitoring` | 10Gi | `local-path` |
| Grafana | `monitoring` | 5Gi | `local-path` |
| Alertmanager | `monitoring` | 2Gi | `local-path` |
| Vault data | `vault` | 10Gi | `local-path` |
| Vault audit | `vault` | 5Gi | `local-path` |

`local-path` volumes live on this node. They are not replicated and do not
constitute a backup.

## 12. Operational commands

```bash
# Cluster
k get nodes
k get pods -A
k top nodes
k top pods -A
k9s

# Database
k get pods,pvc -n database
k logs -n database postgresql-0

# Monitoring
k get pods,pvc -n monitoring
k logs -n monitoring deployment/alloy -c alloy

# Certificates
k get certificate -A
k get challenge,order -A

# Helm
helm list -A

# Vault status
k exec -n vault vault-0 -- vault status
```

## 13. Constraints and non-negotiable safety rules

1. This is a single-node cluster. Node failure causes downtime for everything.
2. PostgreSQL, Vault, Prometheus, Loki, and Grafana are single-replica services.
3. Storage is local and non-replicated. Configure off-server backups before
   treating workloads as production-critical.
4. There is no swap. Avoid aggregate memory limits that can exhaust 8 GiB.
5. Do not delete PVCs during routine workload or Helm changes.
6. Do not commit Kubernetes Secret manifests, `vault-init.json`, kubeconfig, or
   expanded Helm Secrets.
7. Do not expose PostgreSQL, Loki, Prometheus, Alertmanager, or the Vault API
   directly to the public internet.
8. Use per-project ServiceAccounts, Vault policies, database users, and databases.
9. Use readiness, liveness, and startup probes for production workloads.
10. Set CPU and memory requests/limits before enabling HPA.
11. Use pinned image versions, not `latest`.
12. Validate manifests with server-side dry-run before applying:

```bash
kubectl apply --dry-run=server -f manifest.yaml
```

## 14. AI agent project checklist

An AI agent preparing a new project for this cluster should produce:

- a dedicated namespace;
- a Deployment or StatefulSet with pinned images;
- a ClusterIP Service;
- resource requests and limits;
- readiness, liveness, and startup probes;
- a non-root security context when supported by the image;
- a dedicated ServiceAccount;
- a least-privilege Vault policy and Kubernetes auth role;
- PostgreSQL database migrations and a dedicated database role when needed;
- a ServiceMonitor when the app exposes metrics;
- an HPA only after requests are defined and load behavior is known;
- a Traefik Ingress with cert-manager annotation when public access is required;
- NetworkPolicies appropriate for the app;
- a backup and restore procedure for persistent data;
- verification commands and rollback instructions.

The agent must ask before deleting namespaces, PVCs, Vault metadata, databases,
database roles, or production secrets.
