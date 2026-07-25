# FlashCards on Kubernetes

Manifests for the three subprojects in `source/`, deployed to two single-node k3s
servers. The production node is the one described in
[`../INFRASTRUCTURE.md`](../INFRASTRUCTURE.md).

| Environment | Branch | Server | SSH alias | Namespace | Public |
|---|---|---|---|---|---|
| production | `main` | `57.129.66.163` | `ovh` | `moomento` | `moomento.pl` |
| develop | `develop` | `57.128.251.9` | `ovh2` | `moomento-dev` | `dev.moomento.pl` |

| Workload | Source | Kind | Port | Public |
|---|---|---|---:|---|
| `frontend` | `source/FlashCardsGUI` (Next.js 15) | Deployment | 3000 | yes |
| `backend` | `source/FlashCardsBackend` (Spring Boot 3.5) | Deployment | 8080 | no |
| `hosted` | `source/FlashCardsHostedServices` (Spring Boot 3.5) | Deployment | 8081 | no |

**Only the frontend is reachable from the internet, in both environments.** The
backend and `hosted` are ClusterIP Services with no Ingress at all. Nothing about
this is environment-specific — there is no public API hostname anywhere.

The two namespaces differ on purpose. A develop manifest applied to the
production cluster by mistake creates `moomento-dev` rather than overwriting
production workloads.

Shared infrastructure is converged by
[`../ansible`](../ansible): k3s, Traefik, cert-manager, Vault, PostgreSQL, Kafka
and the application namespace. The old
[`provision/provision-dev-node.sh`](provision/provision-dev-node.sh) script is
kept as a readable legacy fallback for the develop node.

## Layout

```
k8s/
├── base/                       # environment-agnostic; no namespace, no tags, no hostnames
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── serviceaccounts.yaml    # one per workload, bound to Vault auth roles
│   ├── backend.yaml            # Deployment + ClusterIP Service
│   ├── frontend.yaml
│   ├── hosted.yaml
│   ├── ingress-frontend.yaml   # public host + deny-public middleware for /metrics
│   └── networkpolicies.yaml    # default-deny model
├── components/                 # opt-in add-ons, each with its own prerequisite
│   ├── autoscaling/            # HPAs; needs metrics-server and spare memory
│   └── monitoring/             # ServiceMonitors; needs the Prometheus CRDs
├── overlays/
│   ├── production/             # the only file you normally edit for prod
│   │   └── kustomization.yaml
│   └── develop/
│       ├── kustomization.yaml
│       └── patch-{backend,frontend,hosted}.yaml
├── provision/provision-dev-node.sh
├── db/bootstrap-flashcards-db.sql
└── vault/bootstrap-vault.example.sh
```

Components exist rather than plain file references because kustomize forbids an
overlay from referencing individual files outside its own directory. A directory
with `kind: Component` is the supported way to share optional resources.

Render either environment locally:

```bash
kustomize build k8s/overlays/production
kustomize build k8s/overlays/develop
```

## What develop leaves out, and why

| | production | develop |
|---|---|---|
| Node | 4 vCPU / 8Gi | 2 vCPU / 3.7Gi |
| `autoscaling` | yes | no — no headroom for a second replica |
| `monitoring` | yes | no — no Prometheus, no ServiceMonitor CRD |
| DB pool max | 5 | 3 |
| Vault path | `secret/projects/moomento/production/*` | `.../develop/*` |
| Vault role | `moomento-backend`, `moomento-hosted` | `moomento-dev-backend`, `moomento-dev-hosted` |

Public exposure is identical in both: one hostname, frontend only.

## External dependencies

| Dependency | Address | Provided by |
|---|---|---|
| PostgreSQL | `postgresql.database.svc.cluster.local:5432` | namespace `database` |
| Kafka | `kafka.kafka.svc.cluster.local:9092` | namespace `kafka` |
| Vault | `vault.vault.svc.cluster.local:8200` | namespace `vault` |
| Prometheus | scrapes via `ServiceMonitor` | namespace `monitoring` (production only) |
| Loki | Alloy collects pod stdout | namespace `monitoring` (production only) |
| SMTP relay | `SPRING_MAIL_HOST` in the overlay | external |

The in-cluster addresses are identical in both environments, so the manifests do
not vary — only the instances behind them do. If you move the broker, update both
`SPRING_KAFKA_BOOTSTRAP_SERVERS` in the overlay **and** the namespace selector in
the `allow-kafka-egress` NetworkPolicy.

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
avoid double ingestion. There is no log shipping on the develop node — use
`kubectl logs`.

## CI/CD

Pushing is the deploy. Nothing is applied from a workstation in normal operation.

```
                     push to develop
source/FlashCards*  ──────────────────►  docker-publish.yml
  (submodule repo)                         ├─ test
                                           ├─ publish  ghcr.io/…:sha-<short>
                                           └─ notify   repository_dispatch ─┐
                                                                            │
                                                                            ▼
FlashCards (root)   ──────────────────►  deploy.yml  ◄── push to main/develop
                     push to develop      ├─ resolve  branch → environment + tags
                                          ├─ provision Ansible over SSH
                                          ├─ render   kustomize + kubeconform + GHCR check
                                          └─ deploy   ssh → kubectl apply --server-side
```

### Which image tag gets deployed

The root repository pins each subproject to an exact commit through git
submodules, and each subproject publishes `sha-<short-sha>`. So the tag is
derivable from the submodule pointer — no manual version bookkeeping, and the
deployed state provably matches the root commit:

```bash
git ls-tree HEAD source/FlashCardsBackend | awk '{print $3}' | cut -c1-7
```

A `repository_dispatch` from a subproject overrides the one service it names and
leaves the other two on their pinned tags. `workflow_dispatch` lets an operator
choose both the target environment and a `source_ref` (branch, tag or SHA), and
also accepts an override per service for manual rollbacks.

Before anything touches a server, `render` confirms every resolved tag actually
exists in GHCR. A missing image fails the run with a clear message instead of an
`ImagePullBackOff` twenty seconds later.

Automatic runs (`push` and `repository_dispatch`) request all services, then
resolve the deployable subset from GHCR. On a fresh environment this means the
first published frontend image can deploy the frontend alone; when backend and
hosted images appear, the next automatic run includes them. Manual runs use the
operator's `deploy_services` input exactly.

### Repository configuration

Set once, on `Path-Of-Execution-Team/FlashCards`:

| Kind | Name | Value |
|---|---|---|
| secret | `SSH_PRIVATE_KEY` | deploy key accepted by both nodes |
| secret | `GHCR_PULL_TOKEN` | classic PAT, `read:packages` only, owned by `GHCR_PULL_USER` |
| variable | `SSH_KNOWN_HOSTS` | `ssh-keyscan` output for both hosts — public data, so a variable rather than a secret, which keeps it unmasked in logs |
| variable | `GHCR_PULL_USER` | GitHub username that owns `GHCR_PULL_TOKEN`; used as the Docker username in the in-cluster GHCR pull secret |

Then one [GitHub Environment](https://github.com/Path-Of-Execution-Team/FlashCards/settings/environments)
per target, each with four variables:

| Variable | `production` | `develop` |
|---|---|---|
| `SSH_HOST` | `57.129.66.163` | `57.128.251.9` |
| `SSH_USER` | `ubuntu` | `ubuntu` |
| `K8S_NAMESPACE` | `moomento` | `moomento-dev` |
| `PUBLIC_HOST` | `moomento.pl` | `dev.moomento.pl` |

Environments are what make a required reviewer on production possible later
without touching the workflow.

And in **each** of the three subproject repositories:

| Kind | Name | Value |
|---|---|---|
| secret | `DEPLOY_DISPATCH_TOKEN` | fine-grained PAT scoped to `Path-Of-Execution-Team/FlashCards`, `Contents: read and write` |

`GITHUB_TOKEN` cannot be used for the dispatch — it is scoped to the repository
it runs in. The `notify` job is separate from `publish` so a missing or expired
token shows up as its own red check while `publish` stays green, making it clear
the image was pushed and only the rollout trigger failed.

### How the deploy step works

`kubectl` runs **on the node**, over SSH. The kubeconfig never leaves the server
and CI never holds cluster-admin credentials — only one rendered YAML file is
shipped. The apply is server-side with a dedicated field manager:

```bash
kubectl apply --dry-run=server -f /tmp/flashcards-deploy.yaml   # rule 12
kubectl apply --server-side --force-conflicts \
  --field-manager=github-actions -f /tmp/flashcards-deploy.yaml
```

`--force-conflicts` is needed the first time a resource previously applied
client-side is taken over by this field manager.

On failure the workflow dumps pods, events, application logs and
`vault-agent-init` logs, then runs `kubectl rollout undo` on all three
Deployments.

## First-time setup

### Empty Server, Frontend First

For a brand-new environment where you want to see the frontend before the
backend and Vault secrets are ready:

1. Configure the GitHub repository secrets and environment variables with
   `.github/setup-repository.sh`.
2. Make sure the frontend image exists in GHCR. Usually that means pushing the
   frontend submodule branch so its `docker-publish.yml` finishes successfully.
3. Run the root **Deploy** workflow manually:

```text
environment     develop
source_ref      <root branch/tag/SHA to deploy>
deploy_services frontend
frontend_tag    <optional, only if you want to override the submodule tag>
```

That run still executes Ansible first, so k3s, Traefik, cert-manager, Vault,
PostgreSQL, Kafka and the app namespace are created. Because only `frontend` is
selected, the workflow does not require Vault to be unsealed and does not check
or deploy backend/hosted images.

When the backend is ready, initialise/unseal/configure Vault, seed the app
secrets, create the database role with `db/bootstrap-flashcards-db.sql`, then
run **Deploy** again with `deploy_services=backend` or `deploy_services=all`.
Use `hosted` the same way when the worker image is ready.

### Production (`57.129.66.163`)

Steps 1–4 are one-time.

**1. DNS.** Create the Cloudflare record **before** applying, or the ACME http01
challenge cannot complete. SSL/TLS mode `Full (strict)`. One record — there is no
public API hostname.

```
moomento.pl        A  57.129.66.163
```

**2. Vault policies, roles and secrets.**

```bash
export VAULT_ADDR=https://vault.bosman.top
vault login -method=userpass username=bosman

export FLASHCARDS_MAIL_USERNAME='...'
export FLASHCARDS_MAIL_PASSWORD='...'
ENVIRONMENT=production ./vault/bootstrap-vault.example.sh
```

This creates the `moomento-backend` / `moomento-hosted` policies and Kubernetes
auth roles, and seeds:

```
secret/projects/moomento/production/backend   SPRING_DATASOURCE_PASSWORD, JWT_SECRET
secret/projects/moomento/production/hosted    MAIL_USERNAME, MAIL_PASSWORD
```

Re-running the script never overwrites an existing path, so it cannot rotate a
live database password out from under running pods.

**3. PostgreSQL database and role.**

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

**4. Image pull secret.** The deploy workflow refreshes this on every run from
`GHCR_PULL_TOKEN`, so this is only needed if you apply by hand:

```bash
kubectl create secret docker-registry ghcr-pull -n moomento \
  --docker-server=ghcr.io \
  --docker-username='<github-user>' \
  --docker-password='<PAT with read:packages>'
```

**5. Push to `main`.** That is the deploy.

### Develop (`57.128.251.9`)

The node started empty — no k3s, no kubectl, no docker. Bootstrap it with the
Ansible playbook:

```bash
python -m pip install -r ansible/requirements.txt
ansible-playbook -i ansible/inventory.example.yml ansible/playbooks/provision.yml \
  --limit develop \
  -e vault_initialize=true \
  -e vault_unseal_from_node_file=true \
  -e vault_configure_kubernetes_auth=true
```

It installs k3s (Traefik from Helm, not the bundled manifest), cert-manager with
a `letsencrypt-production` ClusterIssuer, Vault in standalone mode with the Agent
Injector, and a dedicated in-cluster PostgreSQL and single-node KRaft Kafka. It
is idempotent — re-running it skips or reconciles whatever is already there.

The playbook generates the PostgreSQL superuser password and the Vault unseal key
**on the node**. Nothing is printed and nothing is written into this repository;
Vault's init output lands in `/root/vault-init.json` mode 0600. Copy it into a
password manager and shred it.

Then, still on the node:

```bash
kubectl -n vault port-forward svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
vault login                       # root token from /root/vault-init.json
export FLASHCARDS_MAIL_USERNAME='...' FLASHCARDS_MAIL_PASSWORD='...'
ENVIRONMENT=develop ./bootstrap-vault.example.sh
```

Vault on this node has a single unseal share, which is a deliberate trade for a
disposable environment. **It comes back sealed after every reboot** and pods will
hang in `Init:0/1` until you unseal it:

```bash
kubectl -n vault exec -it vault-0 -- vault operator unseal
```

Add DNS `dev.moomento.pl A 57.128.251.9`, then push to `develop`.

## Configuration

The overlay's `kustomization.yaml` is the single place for non-secret values:
hostnames, image tags, database and Kafka addresses, pool sizes, mail endpoint.
The manifests read them from the generated `app-config` ConfigMap, and the
Ingress hostnames are injected with `replacements` so rules and TLS SANs cannot
drift apart.

The ConfigMap keeps kustomize's name suffix hash, so editing any value changes
the ConfigMap name, which changes the pod template, which rolls the pods. No
`kubectl rollout restart` is needed. This works alongside `replacements` because
they resolve the source by its pre-hash name `app-config` while the
name-reference transformer rewrites every `configMapKeyRef` to the hashed name.

Two values are not derivable and must be edited by hand if you rename a
namespace:

- the `router.middlewares` JSON patch in the overlay
  (`moomento-deny-public@kubernetescrd`)
- `NAMESPACE` in `vault/bootstrap-vault.example.sh`, then re-run it

### Request routing

The browser only ever talks to the frontend host. `apiClient.ts` uses the
relative base URL `/api`, and `next.config.ts` rewrites `/api/:path*` to
`http://${NEXT_PUBLIC_API_URL}/api/:path*` server-side — which is `backend:8080`,
a ClusterIP address. So the API hop never leaves the cluster and the backend
needs no Ingress at all.

That is why there is no public API hostname in either environment. It is also the
safer default: the backend serves `/actuator` on the same port as `/api`, with
Prometheus metrics and detailed health exposed without authentication
(`management.endpoint.prometheus.access=unrestricted`). With no Ingress in front
of it, none of that is routable from outside.

If external, non-browser API clients are ever needed, add an Ingress that
publishes **only** `/api` — never a bare `/`, which would also expose
`/actuator`. Add `/swagger-ui` and `/v3/api-docs` explicitly if you want the docs
public.

The frontend does serve one sensitive path of its own, `/metrics`.
`frontend-metrics-deny` puts an `ipAllowList` middleware in front of it, which
Traefik prefers over the `/` route because its rule is longer. Prometheus is
unaffected — it scrapes the ClusterIP Services directly.

## Routine deploy

Push to `main` or `develop`. Automatic deploys keep the fixed mapping:
`develop` -> develop and `main` -> production.

The automatic path is bootstrap-aware: it verifies the branch's resolved image
tags in GHCR and deploys the newest available branch state for the services that
already have images. Once all three images exist, automatic deploys become full
`backend frontend hosted` rollouts again.

For a manual test deploy, run the **Deploy** workflow and choose:

- `environment`: target cluster, `develop` or `production`
- `source_ref`: branch, tag or SHA to check out; leave empty to use the branch
  selected in GitHub's **Run workflow** dropdown
- `deploy_services`: `all`, or a comma-separated subset such as `frontend` or
  `frontend,backend`
- optional image tag overrides for one-off rollback or smoke testing

`frontend` can be deployed before `backend`. The rendered manifest keeps the
`backend` Service so `backend:8080` resolves in-cluster, but it does not create
the backend Deployment or check the backend image tag. API calls will fail until
the backend is deployed, but the frontend rollout can complete.

By hand, if CI is unavailable — substitute `moomento-dev` and `overlays/develop`
for the develop node:

```bash
cd k8s/overlays/production
kustomize edit set image flashcards-backend=*:sha-<new>
kustomize build . > /tmp/rendered.yaml
kubectl apply --dry-run=server -f /tmp/rendered.yaml
kubectl apply --server-side --force-conflicts -f /tmp/rendered.yaml
kubectl rollout status -n moomento deploy/backend --timeout=5m
```

## Verification

```bash
kubectl get pods,svc,ingress,hpa -n moomento
kubectl get certificate -n moomento              # want READY=True
kubectl top pods -n moomento

# Vault injection worked (file present, and no secret printed)
kubectl exec -n moomento deploy/backend -c application -- \
  ls -l /vault/secrets/backend.properties

kubectl exec -n moomento deploy/backend -c application -- \
  wget -qO- localhost:8080/actuator/health

# Public endpoints - exactly one hostname per environment
curl -sI https://moomento.pl | head -1
curl -sI https://dev.moomento.pl | head -1

# Must NOT return metrics (ipAllowList middleware):
curl -s  https://moomento.pl/metrics | head -1

# Must NOT reach the backend at all - there is no Ingress for it. Expect a
# Traefik 404, and no `backend` row in:
kubectl get ingress -n moomento
```

In Grafana, the production targets appear as
`serviceMonitor/moomento/{backend,frontend,hosted}/0`.

## Rollback

CI does this automatically when a rollout fails. Manually:

```bash
kubectl rollout undo -n moomento deploy/backend
kubectl rollout status -n moomento deploy/backend
```

`revisionHistoryLimit: 3`, so the last three revisions are available;
`kubectl rollout history -n moomento deploy/backend` lists them. To pin a
specific older image instead, use the **Deploy** workflow's tag override.

A rollback does **not** revert database schema changes made by Hibernate — see
the schema note below.

## Backups

`local-path` volumes live on the single node and are not replicated. The
application owns no PVC of its own; all persistent state is the `flashcards`
database.

```bash
# dump
kubectl exec -n database postgresql-0 -- \
  pg_dump -U postgres -Fc flashcards > flashcards-$(date +%F).dump

# restore into an empty database
kubectl exec -i -n database postgresql-0 -- \
  pg_restore -U postgres -d flashcards --clean --if-exists < flashcards-<date>.dump
```

Copy the dumps off the server. Nothing about either cluster is a backup. The
develop node's PostgreSQL and Kafka PVCs are explicitly disposable.

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

3. **Develop Vault needs a manual unseal after every reboot.** One unseal share,
   stored in a password manager. Acceptable for a disposable environment,
   surprising if you have forgotten it — hence the note above and the explicit
   pre-flight check in the deploy workflow.

4. **No PodDisruptionBudgets.** On a single node they would only block drains
   without buying availability. Add them if a second node ever appears.

5. **`hosted` HPA is capped at 2.** Scaling a Kafka consumer group past the
   partition count only adds idle consumers. Raise `maxReplicas` together with
   the topic partition count.

6. **Read-only root filesystem.** All three containers run with
   `readOnlyRootFilesystem: true`, non-root uid 10001 and all capabilities
   dropped. Writable paths are explicit emptyDirs (`/tmp`, and
   `/app/.next/cache` for the frontend). If a new library needs to write
   somewhere, add an emptyDir rather than disabling the flag.

7. **Resource limits are estimates, not load-test results.** Production shares
   4 vCPU / 8Gi with PostgreSQL, Vault, Traefik and kube-prometheus-stack; sum of
   requests at full HPA scale-out is roughly 3.1Gi. Develop has 2 vCPU / 3.7Gi
   for everything, single replicas, no monitoring stack. Check `kubectl top
   nodes` before raising anything.

## Troubleshooting

**Pods stuck in `Init:0/1`** — the `vault-agent-init` container cannot render
secrets. Check the Vault role binding and that Vault is unsealed:

```bash
kubectl logs -n moomento deploy/backend -c vault-agent-init
kubectl exec -n vault vault-0 -- vault status
```

On develop this is most often just a sealed Vault after a reboot.

**`Permission denied` reading `/vault/secrets/*.properties`** — the
`vault.hashicorp.com/agent-run-as-same-user: "true"` annotation is missing. The
agent otherwise runs as uid 100 and renders the file 0640, which the
application's uid 10001 cannot read.

**`ImagePullBackOff`** — the `ghcr-pull` secret is missing or its PAT lacks
`read:packages`. The deploy workflow recreates it every run, so check
`GHCR_PULL_TOKEN` first.

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
`base/kustomization.yaml`, re-apply, and confirm the traffic works before adding
the proper rule.

**The deploy workflow says a tag is not in GHCR** — the subproject's
`docker-publish.yml` has not finished, or it never ran because the push went to a
branch other than `main`/`develop`.

**A subproject build is green but nothing deployed** — check its `Trigger
deployment` job. A missing `DEPLOY_DISPATCH_TOKEN` fails exactly there.
