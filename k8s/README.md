# Kubernetes Deployment Guide

This directory contains a single-namespace Kubernetes deployment for the application stack:
- `frontend`
- `backend`
- `hosted`

The manifests assume that supporting services already exist outside this repository:
- PostgreSQL
- Kafka
- Vault
- Loki
- optional external Prometheus / Grafana

This deployment does not provision those components. It only consumes them.

## Layout

- `kustomization.yaml` - entrypoint for deployment and environment values
- `namespace.yaml` - target namespace
- `serviceaccounts.yaml` - dedicated service accounts for application workloads
- `backend.yaml` - backend deployment and internal service
- `frontend.yaml` - frontend deployment and internal service
- `hosted.yaml` - hosted/background service StatefulSet and service
- `ingress.yaml` - public entrypoint routing frontend and API traffic
- `backend-hpa.yaml`, `frontend-hpa.yaml`, `hosted-hpa.yaml` - autoscaling
- `vault-config.yaml` - Vault role names and secret paths injected into pod annotations
- `monitoring/` - dashboards and PodMonitor manifests specific to this application
- `vault/bootstrap-vault.example.sh` - example Vault bootstrap script

## Target Model

- single namespace deployment
- no overlays
- external infrastructure dependencies
- Vault Agent Injector for secrets delivery
- Ingress in front of ClusterIP services

## Prerequisites

The cluster must have:
- a working Kubernetes API
- Vault deployed and reachable from workload pods
- Vault Agent Injector enabled
- PostgreSQL reachable from the application namespace
- Kafka reachable from the application namespace
- Loki reachable from the application namespace
- enough CPU and memory for all requested pods

Recommended operational prerequisites:
- `metrics-server` if HPA is enabled
- DNS records for public frontend / API hosts
- a working Ingress controller in the cluster

## Configuration Model

Non-secret runtime configuration is defined in `kustomization.yaml` via `configMapGenerator`.

Typical values to adjust:
- `INGRESS_APP_HOST`
- `INGRESS_API_HOST`
- `NEXT_PUBLIC_API_URL`
- `BACKEND_ALLOWED_ORIGINS`
- `SPRING_DATASOURCE_URL`
- `SPRING_DATASOURCE_USERNAME`
- `SPRING_KAFKA_BOOTSTRAP_SERVERS`
- `LOKI_PUSH_URL`
- `VAULT_ADDR`
- `SPRING_MAIL_HOST`
- `SPRING_MAIL_PORT`
- image names and tags

Ingress hostnames are defined in `kustomization.yaml` and injected into `ingress.yaml`.
These values should stay aligned with:
- `NEXT_PUBLIC_API_URL`
- `BACKEND_ALLOWED_ORIGINS`

Secret values are not stored in this repository.

## Vault Integration

Secrets are injected through Vault Agent Injector.

Expected secret engine:
- KV v2 mounted at `secret/`

Expected secret paths:
- `secret/data/flashcards/backend`
- `secret/data/flashcards/hosted`

Expected backend keys:
- `SPRING_DATASOURCE_PASSWORD`
- `JWT_SECRET`

Expected hosted keys:
- `MAIL_USERNAME`
- `MAIL_PASSWORD`

Expected Kubernetes auth roles:
- `flashcards-backend`
- `flashcards-hosted`

The workloads explicitly use:
- `vault.hashicorp.com/service: "http://vault.vault.svc:8200"`

This avoids relying on injector defaults that may differ between clusters.

## Vault Bootstrap

Use `vault/bootstrap-vault.example.sh` as a starting point.

Before running it, replace placeholder values such as:
- `VAULT_ADDR`
- `VAULT_TOKEN`
- `SPRING_DATASOURCE_PASSWORD`
- `JWT_SECRET`
- `MAIL_USERNAME`
- `MAIL_PASSWORD`

Suggested execution flow:

1. Enter the Vault pod:
   ```bash
   kubectl exec -it -n vault vault-0 -- sh
   ```
2. Authenticate:
   ```bash
   export VAULT_ADDR="http://127.0.0.1:8200"
   vault login
   ```
3. Run the bootstrap commands manually or copy the script into the pod:
   ```bash
   kubectl cp k8s/vault/bootstrap-vault.example.sh vault/vault-0:/tmp/bootstrap-vault.sh
   kubectl exec -it -n vault vault-0 -- sh -lc 'export VAULT_ADDR="http://127.0.0.1:8200" && sh /tmp/bootstrap-vault.sh'
   ```

## Kubernetes Auth Sanity Checks

If Vault Agent reports `permission denied` during `auth/kubernetes/login`, verify:

1. Vault pod service account:
   ```bash
   kubectl get pod vault-0 -n vault -o jsonpath='{.spec.serviceAccountName}'; echo
   ```

2. ClusterRoleBinding for token reviews:
   ```bash
   kubectl get clusterrolebinding vault-auth-delegator -o yaml
   ```

3. The binding must point to the Vault service account in the `vault` namespace.

If needed:
```bash
kubectl delete clusterrolebinding vault-auth-delegator
kubectl create clusterrolebinding vault-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault-sa
```

Then refresh `auth/kubernetes/config` from inside `vault-0`:
```bash
export VAULT_ADDR="http://127.0.0.1:8200"
vault login
export K8S_HOST="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}"
export TOKEN_REVIEWER_JWT="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
export K8S_CA_CERT_PATH="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

vault write auth/kubernetes/config \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert=@"$K8S_CA_CERT_PATH" \
  token_reviewer_jwt="$TOKEN_REVIEWER_JWT" \
  disable_iss_validation=true
```

Manual validation of workload login:
```bash
kubectl create token backend-sa -n moomento
```

Then in `vault-0`:
```bash
vault write auth/kubernetes/login role=flashcards-backend jwt="PASTE_TOKEN_HERE"
```

## PostgreSQL Preparation

Create a dedicated application user and database if they do not already exist.

Example:
```bash
kubectl exec -it -n postgres postgres-0 -- sh
PGPASSWORD='POSTGRES_ADMIN_PASSWORD' psql -U appuser -d postgres
```

Example SQL:
```sql
CREATE USER flashcards_user WITH PASSWORD 'REPLACE_ME_DB_PASSWORD';
CREATE DATABASE flashcards OWNER flashcards_user;
GRANT ALL PRIVILEGES ON DATABASE flashcards TO flashcards_user;
```

## Deploy

From this directory:
```bash
kubectl apply -k .
```

Public application exposure:
The default deployment already exposes:
- `INGRESS_APP_HOST` -> `frontend` service
- `INGRESS_API_HOST` -> `backend` service

If your cluster does not define a default ingress class, add `spec.ingressClassName`
to `ingress.yaml` before applying manifests.

Optional monitoring stack:
```bash
kubectl create namespace monitoring
kubectl create secret generic grafana-admin-credentials -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='REPLACE_ME_STRONG_PASSWORD'
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring -f monitoring/kube-prometheus-stack.values.yaml
helm upgrade --install loki grafana/loki -n monitoring -f monitoring/loki.values.yaml
helm upgrade --install promtail grafana/promtail -n monitoring -f monitoring/promtail.values.yaml
kubectl apply -k monitoring
```

If the cluster already runs Alloy or Grafana Agent and those collectors already
ship pod logs to Loki, install Promtail with the override below to avoid
duplicate log streams for the `moomento` namespace:
```bash
helm upgrade --install promtail grafana/promtail -n monitoring \
  -f monitoring/promtail.values.yaml \
  -f monitoring/promtail.values.exclude-moomento.yaml
```

If the cluster uses Alloy for pod log collection, keep its pipeline aligned with
the Grafana dashboards by deploying the values file below. It adds the `level`
label for both JSON application logs and plain-text framework logs:
```bash
helm upgrade --install alloy-logs grafana/alloy -n monitoring \
  -f monitoring/alloy-logs.values.yaml
```

Promtail is configured to normalize log levels from two sources:
- application JSON logs emitted by backend, hosted, and frontend server handlers
- plain text framework logs such as Next.js / Node.js runtime output

The pipeline first parses JSON `level` fields, then falls back to regex detection for text logs, and finally defaults to:
- `error` for `stderr`
- `info` for `stdout`

This avoids Grafana showing `detected_level=unknown` for common framework logs that do not emit structured level fields.

Optional FlashCards-specific dashboards and PodMonitors:
```bash
kubectl apply -k monitoring
```

## Post-Deploy Verification

Basic checks:
```bash
kubectl get pods -n moomento
kubectl get svc -n moomento
kubectl rollout status deployment/frontend -n moomento
kubectl rollout status deployment/backend -n moomento
kubectl rollout status statefulset/hosted -n moomento
```

Inspect Vault init:
```bash
kubectl logs -n moomento -l app=backend -c vault-agent-init --tail=200
kubectl logs -n moomento -l app=hosted -c vault-agent-init --tail=200
```

Inspect application containers:
```bash
kubectl logs -n moomento -l app=frontend -c frontend --tail=200
kubectl logs -n moomento -l app=backend -c backend --tail=200
kubectl logs -n moomento -l app=hosted -c hosted --tail=200
```

## Runtime Notes

- `frontend` is exposed through the `flashcards` Ingress
- `backend` is exposed through the `flashcards` Ingress on the API host
- `hosted` is modeled as a StatefulSet
- `backend` uses a `startupProbe` because application boot can take longer than a standard health probe window
- resource requests for `backend`, `hosted`, and Vault Agent have been reduced to fit smaller single-node clusters

## Ingress

The default public routing is:
- `INGRESS_APP_HOST` -> `frontend:3000`
- `INGRESS_API_HOST` -> `backend:8080`

Adjust for your environment:
- public hostnames
- TLS strategy
- ingress class
- DNS records pointing at the ingress controller

Grafana in `monitoring/kube-prometheus-stack.values.yaml` still uses a `NodePort`
by default because it is an operational/admin endpoint and not part of the main
application ingress.

## Sensitive Data Policy

This repository should not contain:
- real Vault tokens
- real database passwords
- real SMTP credentials
- private JWT secrets

Example files are intentionally sanitized and should use placeholders such as `xxxx` or `REPLACE_ME_*`.

## Known Failure Modes

`ImagePullBackOff`
- image name, tag, or registry permissions are wrong

`vault-agent-init` stuck or `permission denied`
- wrong Vault service address
- wrong secret path
- broken `auth/kubernetes/config`
- incorrect `vault-auth-delegator`

Backend restarts with failed health probes
- `/actuator/health` not publicly accessible in the backend build
- probes are too aggressive for current startup time

`Insufficient cpu`
- reduce replicas
- reduce requests
- increase node capacity
