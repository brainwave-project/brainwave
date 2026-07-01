# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Monorepo Layout

```
brainwave/
├── infra/          # Docker Compose, Kong, Keycloak, Postgres, Kafka, observability
├── core/           # @brainwave-project/core — shared library (ESM, published to npm)
├── auth-hub/       # Identity facade — Keycloak wrapper + JWT issuance
├── user-hub/       # User lifecycle, account state machine, role management
├── know-hub/       # Document management — triple store + semantic search
├── audit-hub/      # Audit trail — Kafka consumer only, no write path
├── agent-hub/      # Agentic RAG + multi-agent ingestion (Phase 3, Python · LangGraph · Ollama)
├── ui/             # React/Vite frontend (not in Docker; run separately)
└── docs/           # TDDs and architecture docs (separate git submodule)
```

Each directory above (except `ui/`) is its own git repository managed as a git submodule. When updating a service, bump its submodule pointer with a commit in the root repo.

## Commands

### Infrastructure

Run all commands from `infra/`:

```bash
make dev            # Infra + observability only (no app services)
make dev-services   # Full dev stack: infra + auth/user/know/audit hubs
make down           # Stop containers, preserve volumes
make dev-down       # Alias for down
make reset          # ⚠ Destroy all volumes (drops all data)
make ps             # Service status
make logs           # Tail all logs
make logs s=kong    # Tail a single service
make urls           # Print all management UI URLs
make lint           # Validate all compose files + Kong config
```

### UI (run separately — not in Docker)

```bash
cd ui && npm run dev     # http://localhost:5173
cd ui && npm run build   # tsc --noEmit + vite build
cd ui && npm run lint
```

### Per-service (auth-hub, user-hub, know-hub, audit-hub)

```bash
npm run build       # tsc → dist/
npm run dev         # nodemon + tsx (hot-reload)
npm run lint
```

Prisma (user-hub, know-hub, and audit-hub):

```bash
npm run db:generate    # prisma generate
npm run db:migrate     # prisma migrate dev  (user-hub, know-hub only)
npm run db:push        # prisma db push      (user-hub, audit-hub only)
npm run db:seed        # prisma db seed      (user-hub only)
npm run db:studio      # prisma studio
```

### Core library

```bash
cd core && npm run build   # tsc → dist/
cd core && npm run dev     # tsc --watch
```

### agent-hub (Python · uv)

```bash
cd agent-hub
uv sync                                                              # create .venv + install deps
uv run python -m agent_hub.main                                      # serve on :3004
uv run uvicorn agent_hub.transport.http.app:app --reload --port 3004 # hot-reload alternative
uv run ruff check .                                                  # lint
uv run pytest                                                        # run tests
uv run pytest tests/test_crag_graph.py                              # run a single test file
python scripts/gen_proto.py                                          # regenerate gRPC stubs from proto/knowhub.proto
uv run python -m agent_hub.eval.ragas_eval                           # run RAGAS outcome evaluation (M8)
```

### Tests

TypeScript services (`auth-hub`, `user-hub`, `know-hub`, `audit-hub`, `core`) have no test suite yet — `npm test` exits with no output. `agent-hub` has `pytest` tests in `agent-hub/tests/` (`test_crag_graph.py`, `test_ingestion_crew.py`). Validation otherwise relies on TypeScript compilation and integration testing via the running stack.

## Architecture

### Request Flow

```
Browser → Kong :8000
  ├── JWT RS256 validation (Keycloak issuer, JWKS-based)
  ├── X-User-Id header injected via Kong post-function
  └── Routed to service (auth-hub:3000 / user-hub:3001 / know-hub:3002 / audit-hub:3003 / agent-hub:3004)
```

Kong is the **only** entry point. Services trust `X-User-Id` from Kong — they never re-validate JWTs. Auth-hub `/api/auth/*` routes are public (no JWT required); all other routes require a valid Keycloak token.

### Service Pattern (Hexagonal Architecture)

Each service follows the same layering:

```
src/
├── domain/         # Pure types + invariants (no dependencies)
├── application/    # Service classes depending on port interfaces only
│   └── ports/      # Repository / adapter interfaces
├── adapters/       # Implementations (Prisma, gRPC clients, Keycloak, MinIO, Mongo)
├── transport/
│   ├── http/       # Express routers + handlers
│   └── grpc/       # gRPC server (auth-hub: TokenValidation; know-hub: DocumentInternal)
├── events/         # Kafka emitter setup
├── observability/  # Pino logger + Prometheus metrics
└── health/         # /health/live + /health/ready handlers
```

### Cross-Service Communication

- **HTTP → auth-hub** for public auth operations
- **gRPC** from user-hub and know-hub to auth-hub for token validation (internal, zero-trust). Contract defined in `auth-hub/authhub.proto` (copied to `user-hub/proto/` and `know-hub/proto/`). Service: `TokenValidation.ValidateToken`.
- **gRPC** from agent-hub to know-hub for the ingestion write path (`PersistChunks`, `UpdateMetadata`, `GetPayload`, `SemanticSearch`). Contract: `know-hub/proto/knowhub.proto` (copied to `agent-hub/proto/`). Service: `DocumentInternal`. know-hub's gRPC server is gated by `GRPC_ENABLED=true` and listens on `GRPC_PORT` (default 50052, internal only — not exposed via Kong). Python stubs regenerated via `scripts/gen_proto.py`. CRAG retrieval (`SemanticSearch`) currently uses the HTTP path during early milestones; gRPC takes over from M6.
- **Kafka** for domain events → audit-hub consumes all events; know-hub semantic worker and agent-hub ingestion crew both consume `DOCUMENT_UPLOADED`. When agent-hub's ingestion crew is active (M6+), set `SEMANTIC_WORKER_ENABLED=false` in know-hub's env to avoid double-indexing.

### User Account State Machine

Defined in `user-hub/src/domain/user.ts`. Valid transitions enforced before every DB write:

```
pending_identity → active       (Keycloak webhook confirms identity)
active           → suspended    (admin action)
active           → disabled     (admin action / GDPR delete)
suspended        → active       (admin reinstates)
*                → failed       (system error during provisioning)
disabled / failed → (terminal, no transitions)
```

### Know-Hub Triple Store

Documents are persisted across three stores:
- **PostgreSQL** (`doc` schema via Prisma) — metadata, ownership, embedding status
- **MongoDB** — dynamic document payload (content, extracted text)
- **MinIO** — binary file storage

### Semantic Layer (Phase 1 — TypeScript, know-hub)

Runs entirely in-network — no external API:
- **Ollama** container serves `nomic-embed-text` (768-dim)
- Embeddings stored in **pgvector** (`sem` schema)
- Worker triggered by `DOCUMENT_UPLOADED` Kafka event (runs inside know-hub process at `src/ai/worker.ts`)
- Pipeline: extract text → chunk → embed (Ollama) → upsert chunks → mark `INDEXED`
- Terminal statuses: `INDEXED` (searchable), `SKIPPED` (no text layer, e.g. image), `FAILED` (error — admin can reindex)
- Gate: `SEMANTIC_WORKER_ENABLED=true` in know-hub env
- Documents stay in `embedding_status=PENDING` if Ollama is slow/down; never blocks uploads
- Reindex endpoint: `POST /api/semantic/reindex/:documentId` (requires ADMIN role)
- know-hub uses **Langfuse** (`langfuse` package) for LLM observability

### agent-hub (Phase 3 — Python · LangGraph)

Stateless reasoning service — reads and re-scores, never writes to the triple store:
- **CRAG** (Corrective RAG): `POST /api/agent/chat` (SSE) — retrieves from know-hub, grades relevance with Ollama, rewrites weak queries, abstains after `CRAG_MAX_LOOPS`, then ground-checks the answer before streaming
- **Ingestion crew**: multi-agent pipeline (supervisor → extractor → classifier → chunker → embedder) triggered by `DOCUMENT_UPLOADED` Kafka event; adapts chunk strategy per document type (`clause` / `slide` / `turn` / `fixed`)
- LangGraph checkpoint stored in Postgres (`agent` schema); run history queryable via `GET /api/agent/runs/:id`
- Observability via structured logging (`src/agent_hub/observability/logging.py`) + optional Langfuse callback (`langfuse_cb.py`, gated by `LANGFUSE_ENABLED`)
- The two domains (`application/crag` and `application/ingestion`) share only `adapters/` and are otherwise fully isolated — neither imports from the other
- RAGAS outcome evaluation lives in `src/agent_hub/eval/ragas_eval.py` (M8)

### @brainwave-project/core

Shared ESM library. Key exports:
- `AppError`, `ErrorCode` — structured error base classes
- `createLogger`, `childLogger` — Pino-based structured logging
- `correlationId`, `requestLogger`, `errorHandler` — Express middleware
- `initTelemetry` — OpenTelemetry SDK init
- `createGrpcClient`, `buildMetadata` — gRPC client helpers
- `KAFKA_TOPICS`, `CONSUMER_GROUPS`, `createEventProducer`, `emitEvent` — Kafka contracts
- `chunkText`, `embedWithOllama`, `embedQuery`, `toPgVector` — Semantic Layer primitives

### UI Tech Stack

React 18 + Vite + TypeScript. Key libraries:
- **Zustand** — client state (`src/store/`)
- **React Query** (`@tanstack/react-query`) — server state / data fetching
- **Radix UI** — unstyled accessible primitives
- **Tailwind CSS** + `class-variance-authority` — styling
- **React Hook Form** + **Zod** — form validation
- **React Router v6** — client-side routing

Feature modules live under `src/features/`: `auth`, `chat`, `documents`, `semantic`, `users`.

## Environment Variables

Two-tier config (see `infra/env/README.md`):

1. **`infra/env/.env.dev`** — shared infra values (DB creds, ports, Kafka brokers). Loaded via `--env-file` by `make` commands; used for `${VAR}` interpolation in compose YAML.
2. **`infra/env/services/<service>.dev.env`** — per-service literals (NODE_ENV, LOG_LEVEL, in-network hostnames). Loaded via `env_file:` in compose; no interpolation.

### Service env var contracts

- **auth-hub**: uses split `DB_HOST`, `DB_USER`, `DB_PASS` — no `DATABASE_URL`. No Prisma in production.
- **user-hub**: requires `DATABASE_URL` (full URL), `AUTH_HUB_GRPC_HOST` + `AUTH_HUB_GRPC_PORT` separately.
- **know-hub**: requires `DATABASE_URL`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` (not `MINIO_USER`/`MINIO_PASS`). `GRPC_ENABLED=true` and `GRPC_PORT=50052` activate the `DocumentInternal` gRPC server for agent-hub.
- **agent-hub**: `OLLAMA_BASE_URL`, `AGENT_REASONING_MODEL` (use the full pulled tag e.g. `llama3.1:8b-instruct-q4_K_M`, not a shorthand), `KNOW_HUB_URL`, `KNOW_HUB_GRPC_PORT`, `DATABASE_URL`, `KAFKA_BROKERS`, `CRAG_MAX_LOOPS` (default 2), `LANGFUSE_ENABLED` (default false). Config validated at startup by pydantic-settings (`src/agent_hub/config.py`).

## Dev vs. Production

| Aspect | Development | Production |
|--------|-------------|------------|
| Core dependency | `file:../core` | `@brainwave-project/core@^1.2.0` (npm) |
| Build context | Monorepo root | Service directory |
| TypeScript runtime | `tsx` | Compiled `node dist/` |
| Image source | Built locally | Pre-built from GHCR |
| Compose command | `make dev-services` | `make prod-services` |

Production images are built and pushed via `.github/workflows/publish-services.yml` (triggers on push to main/develop). See `DEPLOYMENT.md` for the full publish and deploy workflow.

## Key Service URLs (dev)

| Service | URL |
|---------|-----|
| UI | http://localhost:5173 |
| Kong (API gateway) | http://localhost:8000 |
| auth-hub Swagger | http://localhost:3000/api/docs |
| user-hub Swagger | http://localhost:3001/api/docs |
| know-hub Swagger | http://localhost:3002/api/docs |
| audit-hub Swagger | http://localhost:3003/api/docs |
| agent-hub | http://localhost:3004 |
| Keycloak Admin | http://localhost:8080/admin |
| Kong Admin API | http://localhost:8001 |
| Kong Manager (GUI) | http://localhost:8002 |
| MinIO Console | http://localhost:9001 |
| Grafana | http://localhost:3030 (admin/admin) |
| Prometheus | http://localhost:9090 |
| Alertmanager | http://localhost:9093 |
| Loki | http://localhost:3100 |
| Tempo | http://localhost:3200 |
| OTel zPages | http://localhost:5679 |
| cAdvisor | http://localhost:8181 |
| PostgreSQL | localhost:6632 (host port; internal: 5432) |

## Postgres Schemas

Postgres uses separate schemas, each owned by a dedicated role:

- `user_management` — users, roles (user-hub)
- `doc` — document metadata, embedding_status, doc_type, topic, chunk_strategy (know-hub)
- `sem` — vector chunks (pgvector, know-hub semantic layer)
- `audit` — event log (audit-hub)
- `agent` — agent_runs, agent_steps, LangGraph checkpoint tables (agent-hub; initialized from `infra/postgres/init/40-agent.sql`)

Fresh databases are initialized from `infra/postgres/init/*.sql` (runs once on container creation). For existing databases adding pgvector: `cd know-hub && npx prisma migrate deploy` (requires superuser for `CREATE EXTENSION vector`).

## Kong Configuration

Kong runs in DB-less declarative mode. Config lives at `infra/kong/kong.yml`. Edit this file and run `make dev-services` (or restart the kong container) to apply changes. Validate with `make lint`.

The JWT public key in `kong.yml` is the dev RSA-2048 key from `infra/keys/dev-signing-pub.pem`. Rotate in production using `infra/scripts/rotate-kong-jwt-key.sh`.
