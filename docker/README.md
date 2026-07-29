# Local development stack

Everything in the project running on one machine: both Spring services, the
Next.js frontend, PostgreSQL, Kafka, an SMTP catcher, and the same observability
components the cluster uses. Source changes are pushed into the running
containers by `docker compose watch` — no bind mounts, no rebuilds on save.

This is a development stack only. Production runs on k3s from `k8s/overlays/*`
and never uses these images.

## Start

```bash
git submodule update --init --recursive   # first time only
cp .env.example .env                      # optional, every value has a default
docker compose watch
```

The first run builds three images and downloads the Maven and npm dependency
trees — expect several minutes. After that, `docker compose watch` starts in
under a minute.

`watch` streams logs and keeps syncing until you press Ctrl-C. To run detached
without file syncing, use `docker compose up -d`.

| Command | Effect |
|---|---|
| `docker compose watch` | Start everything, sync code on save |
| `docker compose logs -f backend` | Follow one service |
| `docker compose restart backend` | Restart without rebuilding |
| `docker compose down` | Stop, keep data |
| `docker compose down -v` | Stop and wipe every volume |

## Endpoints

| Service | URL | Notes |
|---|---|---|
| Frontend | http://localhost:3000 | `next dev`, Fast Refresh |
| Backend | http://localhost:8080 | Swagger at `/swagger-ui.html` |
| Hosted services | http://localhost:8081 | Kafka consumer + mail sender |
| Grafana | http://localhost:3001 | Anonymous admin, no login |
| Prometheus | http://localhost:9090 | |
| Loki | http://localhost:3100 | Query it through Grafana |
| Alloy | http://localhost:12345 | Log shipper UI |
| Kafka UI | http://localhost:8085 | |
| Mailpit | http://localhost:8025 | Every outgoing email lands here |
| PostgreSQL | `localhost:5432` | `flashcards_user` / `changeMeStrong123` |
| Kafka | `localhost:29092` | From the host; containers use `kafka:9092` |

Ports and credentials come from `.env` — see `.env.example` for the full list.

## How watch behaves per service

| Change | Action | What you wait for |
|---|---|---|
| `FlashCardsGUI/src`, `messages`, `public` | `sync` | Fast Refresh, ~instant |
| `FlashCardsGUI/next.config.ts` | `sync+restart` | ~10s |
| `FlashCardsGUI/package.json`, `package-lock.json` | `rebuild` | `npm ci`, ~1-2 min |
| `FlashCardsBackend/src`, `FlashCardsHostedServices/src` | `sync+restart` | Incremental `javac`, ~15-30s |
| `*/pom.xml` | `rebuild` | Dependency resolution, ~2-5 min |

Java gets `sync+restart` rather than `sync` because the source has to be
compiled before it means anything. `target/` lives inside the container and
survives the restart, so the recompile is incremental — only the files you
touched.

## Layout

```
docker/
├── backend/Dockerfile.dev      Maven + JDK, runs `mvn spring-boot:run`
├── hosted/Dockerfile.dev       same, port 8081
├── frontend/Dockerfile.dev     Node, runs `next dev`
├── prometheus/prometheus.yml   scrape targets   -> mounted read-only
├── loki/loki-config.yml        single-binary Loki
├── alloy/config.alloy          container logs -> Loki
└── grafana/
    ├── provisioning/           datasources + dashboard provider
    └── dashboards/             drop exported .json files here
```

The three dev Dockerfiles keep Maven, the JDK, and the full `node_modules` in the
final image, which is the opposite of what the shipped Dockerfiles in each
submodule do. That is intentional: a container has to be able to recompile
itself after a sync.

Every config file above is mounted read-only, so editing one and running
`docker compose restart <service>` applies it — no rebuild.

## Parity with the cluster

Image versions match `ansible/group_vars/all.yml` and `INFRASTRUCTURE.md`:
PostgreSQL 18.3, Kafka 4.3.1, Grafana 13.1.1, Prometheus v3.13.1, Loki 3.7.4,
Alloy v1.18.0. Alloy applies the same log labels it applies in Kubernetes, so a
LogQL query differs only in the cluster value:

```logql
{cluster="flashcards-compose", app="backend"} | json | level="ERROR"
```

Two things are deliberately different:

- **Secrets.** The cluster injects them from Vault. Here they are environment
  variables with defaults in `docker-compose.yml`. `JWT_SECRET` overrides the
  `jwt.secret` committed in `application.properties`, so the committed value
  never signs a token you run with.
- **Mail.** The cluster sends through a real SMTP relay. Here everything goes to
  Mailpit, which delivers nowhere.

## When something is wrong

**Editing a file under `src/` does nothing.** Some hosts do not deliver inotify
events for files compose syncs in. Set `WATCHPACK_POLLING=true` in `.env` and
restart the frontend.

**Frontend serves a stale build.** `docker compose down && docker volume rm
flashcards_frontend-next && docker compose watch`.

**Backend restart loops on a compile error.** `docker compose logs -f backend` —
the Maven error is in there. Fix the source; the next sync restarts it.

**A port is taken.** Change it in `.env`; every port in the compose file reads
from one.

**Kafka will not start after changing its config.** KRaft stores the cluster id
on disk. `docker compose down && docker volume rm flashcards_kafka-data`.
