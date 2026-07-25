# FlashCards on the Bosman k3s cluster

Kubernetes manifests for the three subprojects in `source/`, targeting the
single-node k3s server described in [`../INFRASTRUCTURE.md`](../INFRASTRUCTURE.md).

| Workload | Source | Kind | Port | Public |
|---|---|---|---:|---|
| `frontend` | `source/FlashCardsGUI` (Next.js 15) | Deployment | 3000 | `moomento.pl` |
| `backend` | `source/FlashCardsBackend` (Spring Boot 3.5) | Deployment | 8080 | `api.moomento.pl/api` |
| `hosted` | `source/FlashCardsHostedServices` (Spring Boot 3.5) | Deployment | 8081 | no |

Everything lives in the `moomento` namespace. Nothing here provisions
PostgreSQL, Kafka, Vault or the monitoring stack — those are shared
infrastructure this deployment only consumes.

## Layout

```
k8s/
├── kustomization.yaml        # the only file you normally edit
├── namespace.yaml
├── serviceaccounts.yaml      # one per workload, bound to Vault auth roles
├── backend.yaml              # Deployment + ClusterIP Service
├── frontend.yaml
├── hosted.yaml
├── ingress.yaml              # Traefik + cert-manager + deny-public middleware
├── hpa.yaml
├── servicemonitors.yaml
├── networkpolicies.yaml      # default-deny model
├── db/bootstrap-flashcards-db.sql
└── vault/bootstrap-vault.example.sh
```

## External dependencies

| Dependency | Address | Provided by |
|---|---|---|
| PostgreSQL | `postgresql.database.svc.cluster.local:5432` | cluster, namespace `database` |
| Kafka | `kafka.kafka.svc.cluster.local:9092` | cluster, namespace `kafka` |
| Vault | `vault.vault.svc.cluster.local:8200` | cluster, namespace `vault` |
| Prometheus | scrapes via `ServiceMonitor` | namespace `monitoring` |
| Loki | Alloy collects pod stdout | namespace `monitoring` |
| SMTP relay | `SPRING_MAIL_HOST` in `kustomization.yaml` | external |

Kafka is expected as shared infrastructure in its own `kafka` namespace, the same
way PostgreSQL and Grafana are. If you place the broker somewhere else, update
both `SPRING_KAFKA_BOOTSTRAP_SERVERS` in `kustomization.yaml` **and** the
namespace selector in the `allow-kafka-egress` NetworkPolicy.

### Logging

Both Spring services write structured JSON to stdout via `logback-spring.xml`,
and the frontend does the same from `src/app/api/log-to-loki/route.ts`. Alloy
picks stdout up and ships it to Loki, so no application pushes to Loki directly
and `LOKI_PUSH_URL` is not configured anywhere.

```logql
{cluster="bosman-k3s", namespace="moomento"}
{cluster="bosman-k3s", namespace="moomento", app="backend"}
```

If Promtail is still running alongside Alloy, keep the `moomento` drop rule to
avoid double ingestion.

## First-time setup

Run these in order. Steps 1–4 are one-time.

### 1. DNS

Create Cloudflare records for both hostnames pointing at `57.129.66.163`
**before** applying, otherwise the ACME http01 challenge cannot complete.
Recommended SSL/TLS mode: `Full (strict)`.

```
moomento.pl        A  57.129.66.163
api.moomento.pl    A  57.129.66.163
```

### 2. Vault policies, roles and secrets

```bash
export VAULT_ADDR=https://vault.bosman.top
vault login -method=userpass username=bosman

export FLASHCARDS_MAIL_USERNAME='...'
export FLASHCARDS_MAIL_PASSWORD='...'
./vault/bootstrap-vault.example.sh
```

This creates the `moomento-backend` / `moomento-hosted` policies and Kubernetes
auth roles, and seeds:

```
secret/projects/moomento/production/backend   SPRING_DATASOURCE_PASSWORD, JWT_SECRET
secret/projects/moomento/production/hosted    MAIL_USERNAME, MAIL_PASSWORD
```

### 3. PostgreSQL database and role

```bash
FLASHCARDS_DB_PASSWORD=$(vault kv get -field=SPRING_DATASOURCE_PASSWORD \
  secret/projects/moomento/production/backend)

kubectl exec -i -n database postgresql-0 -- \
  psql -U postgres -d postgres \
       -v flashcards_password="$FLASHCARDS_DB_PASSWORD" \
  < db/bootstrap-flashcards-db.sql
```

Verify the application role can actually connect:

```bash
kubectl run pg-connectivity-test -n moomento --rm -it --restart=Never \
  --image=postgres:18.3-bookworm \
  --env="PGPASSWORD=$FLASHCARDS_DB_PASSWORD" \
  -- psql -h postgresql.database.svc.cluster.local \
          -U flashcards_user -d flashcards \
          -c 'select current_user, current_database();'
```

### 4. Image pull secret

GHCR packages are private by default, so the node needs credentials. Use a
classic PAT with only `read:packages`. This is a Secret — it is created
imperatively and never committed.

```bash
kubectl create namespace moomento --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry ghcr-pull -n moomento \
  --docker-server=ghcr.io \
  --docker-username='<github-user>' \
  --docker-password='<PAT with read:packages>'
```

Alternatively make the three GHCR packages public and delete the
`imagePullSecrets` blocks from the three workload manifests.

### 5. Build the images

Each subproject has a `Dockerfile` and a `docker-publish.yml` workflow that
pushes to GHCR on every push to `main`. Trigger it once per repository, then set
the tags:

```bash
kustomize edit set image flashcards-backend=*:sha-1a2b3c4
kustomize edit set image flashcards-frontend=*:sha-5d6e7f8
kustomize edit set image flashcards-hosted=*:sha-9a0b1c2
```

### 6. Apply

```bash
kubectl apply -k . --dry-run=server    # required by INFRASTRUCTURE.md rule 12
kubectl apply -k .
```

## Configuration

`kustomization.yaml` is the single place for non-secret values: hostnames, image
tags, database and Kafka addresses, connection pool sizes, mail endpoint. The
manifests read them from the generated `app-config` ConfigMap, and the Ingress
hostnames are injected with `replacements` so rules and TLS SANs cannot drift
apart.

The ConfigMap name suffix hash is disabled (the `replacements` need a stable
name), which means editing a value does **not** restart the pods:

```bash
kubectl apply -k .
kubectl rollout restart -n moomento deploy/backend deploy/frontend deploy/hosted
```

Two values are not in `kustomization.yaml` because kustomize cannot rewrite
them. If you rename the namespace, also update by hand:

- `traefik.ingress.kubernetes.io/router.middlewares: moomento-deny-public@kubernetescrd`
  in `ingress.yaml`
- `NAMESPACE` in `vault/bootstrap-vault.example.sh`, then re-run it

### Request routing

The browser only ever talks to `moomento.pl`. `apiClient.ts` uses the relative
base URL `/api`, and `next.config.ts` rewrites `/api/:path*` to
`http://${NEXT_PUBLIC_API_URL}/api/:path*` server-side — which is `backend:8080`,
a ClusterIP address. `api.moomento.pl` exists for external API clients only; the
frontend does not depend on it.

Because of that, `/actuator` is deliberately **not** routed on
`api.moomento.pl`. The backend exposes Prometheus metrics and detailed health
there with no authentication (`management.endpoint.prometheus.access=unrestricted`),
so publishing a bare `/` on that host would put them on the internet. Same for
the frontend: `frontend-metrics-deny` puts an `ipAllowList` middleware in front
of `/metrics`, which Traefik prefers over the `/` route because its rule is
longer. Prometheus is unaffected — it scrapes the ClusterIP Services directly.

## Routine deploy

```bash
cd k8s
kustomize edit set image flashcards-backend=*:sha-<new>
kubectl apply -k . --dry-run=server
kubectl apply -k .
kubectl rollout status -n moomento deploy/backend --timeout=5m
```

## Verification

```bash
kubectl get pods,svc,ingress,hpa -n moomento
kubectl get certificate -n moomento              # want READY=True on both
kubectl top pods -n moomento

# Vault injection worked (file present, and no secret printed)
kubectl exec -n moomento deploy/backend -c application -- \
  ls -l /vault/secrets/backend.properties

# Metrics are being scraped
kubectl exec -n moomento deploy/backend -c application -- \
  wget -qO- localhost:8080/actuator/health

# Public endpoints
curl -sI https://moomento.pl | head -1
curl -s  https://api.moomento.pl/api/... | head
# these two must NOT return metrics:
curl -s https://moomento.pl/metrics | head -1
curl -sI https://api.moomento.pl/actuator/prometheus | head -1
```

In Grafana, the targets appear as `serviceMonitor/moomento/{backend,frontend,hosted}/0`.

## Rollback

```bash
# fastest: previous ReplicaSet
kubectl rollout undo -n moomento deploy/backend
kubectl rollout status -n moomento deploy/backend

# or pin the previous image tag and re-apply
kustomize edit set image flashcards-backend=*:sha-<previous>
kubectl apply -k .
```

`revisionHistoryLimit: 3`, so the last three revisions are available.
`kubectl rollout history -n moomento deploy/backend` lists them.

A rollback does **not** revert database schema changes made by Hibernate — see
the schema note below.

## Backups

`local-path` volumes live on the single node and are not replicated. This
deployment owns no PVC of its own; all persistent state is the `flashcards`
database.

```bash
# dump
kubectl exec -n database postgresql-0 -- \
  pg_dump -U postgres -Fc flashcards > flashcards-$(date +%F).dump

# restore into an empty database
kubectl exec -i -n database postgresql-0 -- \
  pg_restore -U postgres -d flashcards --clean --if-exists < flashcards-<date>.dump
```

Copy the dumps off the server. Nothing about this cluster is a backup.

## Known deviations and follow-ups

Worth fixing, in rough priority order:

1. **The committed JWT secret is compromised.**
   `source/FlashCardsBackend/src/main/resources/application.properties` contains
   a real `jwt.secret` value in git history. Vault overrides it at runtime, so
   production is fine, but the committed value must be treated as public — any
   token signed with it elsewhere is forgeable. Replace it with a placeholder.

2. **Schema management is `ddl-auto=update`, not migrations.**
   INFRASTRUCTURE.md section 4 requires explicit migration jobs. Hibernate
   auto-DDL also races when several backend replicas start at once, and it gives
   you no way to roll a schema change back. `SPRING_JPA_HIBERNATE_DDL_AUTO` is a
   ConfigMap key so you can switch it to `validate` the moment Flyway or
   Liquibase lands; until then treat `maxReplicas: 3` scale-ups as safe only
   because the schema rarely changes.

3. **No PodDisruptionBudgets.** On a single node they would only block drains
   without buying availability. Add them if a second node ever appears.

4. **`hosted` HPA is capped at 2.** Scaling a Kafka consumer group past the
   partition count only adds idle consumers. Raise `maxReplicas` together with
   the topic partition count.

5. **Read-only root filesystem.** All three containers run with
   `readOnlyRootFilesystem: true`, non-root uid 10001 and all capabilities
   dropped. Writable paths are explicit emptyDirs (`/tmp`, and
   `/app/.next/cache` for the frontend). If a new library needs to write
   somewhere, add an emptyDir rather than disabling the flag.

6. **Resource limits are estimates, not load-test results.** The node has 4 vCPU
   and 8Gi shared with PostgreSQL, Vault, Traefik and kube-prometheus-stack.
   Sum of requests at full HPA scale-out is roughly 3.1Gi. Check `k top nodes`
   before raising anything.

## Troubleshooting

**Pods stuck in `Init:0/1`** — the `vault-agent-init` container cannot render
secrets. Check the Vault role binding and that Vault is unsealed:

```bash
kubectl logs -n moomento deploy/backend -c vault-agent-init
kubectl exec -n vault vault-0 -- vault status
```

**`ImagePullBackOff`** — the `ghcr-pull` secret is missing, expired, or the PAT
lacks `read:packages` (step 4).

**Certificate stuck in `False`** — DNS record missing, or Traefik cannot reach
the ACME solver pod. The `allow-ingress-from-traefik` NetworkPolicy selects all
pods in the namespace precisely so the solver is reachable.

```bash
kubectl describe certificate -n moomento frontend-tls
kubectl get challenge,order -n moomento
```

**A pod cannot reach a dependency** — almost always a missing egress rule.
`networkpolicies.yaml` is default-deny; there is one rule per allowed
destination. To rule it out quickly, comment `networkpolicies.yaml` out of
`kustomization.yaml`, re-apply, and confirm the traffic works before adding the
proper rule.

**Config change had no effect** — the ConfigMap has no name hash, so pods are
not restarted automatically. `kubectl rollout restart` them.
