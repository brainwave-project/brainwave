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
make staging        # Start staging stack
make staging-services
make prod           # Start prod stack
make prod-services  # Full prod stack (used by "Dev vs. Production" below)
make no-restart     # Clear the restart policy on existing brainwave containers
```

Dev and observability containers use `restart: "no"` so they do **not** start with
Docker Desktop. A restart policy is only applied at container *creation*, so
containers created before that change keep their old policy — `make no-restart`
rewrites them in place (`docker update --restart=no`). Prod (`on-failure:3`) and
staging (`always`) keep auto-restart deliberately.

### Evaluation stack

```bash
make evals          # Full flow: up → seed corpus → score → report
make evals-up       # Lean eval stack only
make evals-seed     # Ingest the eval corpus, wait for INDEXED
make evals-run      # Retrieval suite only (fast — no LLM judge)
make evals-ragas    # Generation suite only (slow — local 8B judge)
make evals-gate     # Compare newest report to baseline; non-zero on regression
make evals-promote  # Adopt the newest report as the baseline
make evals-shell    # Interactive shell in the eval runner
make evals-down     # Stop the eval stack
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
uv sync --extra rerank                                               # + cross-encoder deps (sentence-transformers, CPU torch — heavy, optional)
uv run python -m agent_hub.main                                      # serve on :3004
uv run uvicorn agent_hub.transport.http.app:app --reload --port 3004 # hot-reload alternative
uv run ruff check .                                                  # lint
uv run pytest                                                        # run tests
uv run pytest tests/test_crag_graph.py                              # run a single test file
python scripts/gen_proto.py                                          # regenerate gRPC stubs from proto/knowhub.proto
python scripts/seed_langfuse.py                                      # push DEFAULT_PROMPTS into Langfuse (seed a fresh project)
uv run python -m agent_hub.eval.ragas_eval                           # run RAGAS outcome evaluation (M8)
```

### Tests

TypeScript services (`auth-hub`, `user-hub`, `know-hub`, `audit-hub`, `core`) have no test suite yet — `npm test` exits with no output. `agent-hub` has `pytest` tests in `agent-hub/tests/` (`test_crag_graph.py`, `test_ingestion_crew.py`, `test_governance.py`). Validation otherwise relies on TypeScript compilation and integration testing via the running stack.

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

**Runtime governance (§13.5) — hot-tunable config without redeploy.** CRAG's guardrails (loops, top-k, temperatures, graph-shape toggles, rerank settings) ship as `Settings` defaults but are overlaid at runtime by a single JSONB row in `agent.agent_governance` (`adapters/governance_repo.py`). The row is cached in memory so the hot path never touches the DB; ADMIN-only writes are re-validated through the `GovernanceSettings` pydantic model before persisting. Managed via `GET/PUT /api/agent/governance` and `POST /api/agent/governance/reset`; the UI exposes this in the **KnowOps / Retrieval Lab** page. Other agent routes: `GET /api/agent/models` (LLM catalog), `GET /api/agent/metrics`, `GET /api/agent/ping`.

**Cross-encoder reranking (two-stage retrieval).** When `CROSS_ENCODER_ENABLED=true`, stage 1 (pgvector bi-encoder) fetches a wide candidate pool (`RERANK_CANDIDATE_K`) and stage 2 (`adapters/reranker.py`, a sentence-transformers `CrossEncoder`) re-scores each (query, chunk) pair jointly, keeping the top `RERANK_TOP_N`. **Fail-open**: the model is lazy-loaded from the optional `rerank` extra; any missing-package / download / inference error logs and falls back to stage-1 order (`NullReranker`), never breaking a chat turn. Inference runs off the event loop via `asyncio.to_thread`.

**Langfuse-managed prompts (§13.5).** Every reasoning system prompt is authored/versioned in Langfuse under a stable key (`crag/grade`, `crag/rewrite-query`, `crag/generate`, `crag/check-grounded`, `ingestion/classify`) and fetched by name at call time via `adapters/prompts.py` (`PromptRegistry`, cached per process). The bundled `DEFAULT_PROMPTS` are only a fallback for when Langfuse is disabled/unreachable, and are the seed source for `scripts/seed_langfuse.py`. Edit a prompt in the Langfuse UI, publish the `PROMPT_LABEL` (`production`) label, and the next run picks it up — no redeploy.

### Evaluation harness (`agent-hub/src/agent_hub/eval/`)

Offline measurement for the RAG pipeline — retrieval metrics, Arabic
normalisation, RAGAS generation scoring, and a regression gate. Full detail in
`agent-hub/src/agent_hub/eval/README.md`.

Runs on a **lean stack** (`infra/docker/compose.evals.yml`): postgres, mongodb,
minio, kafka, ollama, know-hub, plus a one-shot `eval-runner` container. No Kong,
Keycloak, auth-hub, user-hub, audit-hub, or observability stack. Two constraints
drive that shape:

- **Kong/Keycloak are skippable** because know-hub's `requirePermission` reads
  `X-User-Roles` only — it never validates a JWT. The eval client supplies the
  headers Kong would have injected (`X-User-Id` + `X-User-Roles`).
- **agent-hub's service is deliberately NOT started.** Its Kafka consumer
  subscribes to `DOCUMENT_UPLOADED` unconditionally, so running it beside
  know-hub's semantic worker double-indexes the corpus. The harness runs as
  `eval-runner` and builds the CRAG graph in-process — it needs agent-hub's
  *code*, not its HTTP server.
- The overlay forces `SEMANTIC_WORKER_ENABLED=true` (dev default is `false`) and
  `SIMILARITY_THRESHOLD=0.0` — know-hub's 0.60 default would truncate rankings
  before the metrics saw them.

Modules that need no stack: `retrieval_metrics.py` (hit rate, recall@k,
precision@k, MRR, NDCG@k, MAP — hand-written, each docstring naming when the
metric misleads), `stats.py` (bootstrap CIs, paired deltas, sample-size),
`arabic/normalize.py` (per-transform normalisation), `datasets.py`. Stack-bound:
`seed.py`, `retrieval.py`, `ragas_eval.py`.

`ragas_eval.py` drives CRAG via `build_crag_graph(...).ainvoke()` with
`checkpointer=None` and a `NullRecorder` — no Postgres needed — and pins the
RAGAS judge to local Ollama so no document text leaves the network.

The Arabic corpus is seeded with deliberate orthographic traps (alef/hamza,
taa marbuta, tatweel, diacritics, alef-maqsura, Arabic-Indic digits) plus
untrapped controls. `tests/test_eval_corpus.py` asserts every trap still responds
to normalisation — an eval that cannot detect the effect it was built to detect
reports a confident number instead of an error.

Known finding the harness measures (does not fix): `sem.document_chunks.content_tsv`
is `GENERATED ALWAYS AS (to_tsvector('english', content)) STORED`
(`infra/postgres/init/05-semantic.sql`), so the lexical half of hybrid RRF search
is close to inert on Arabic.

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

Feature modules live under `src/features/`: `auth`, `chat`, `dashboard`, `documents`, `governance`, `knowops`, `semantic`, `users`. `governance` + `knowops` drive the agent-hub governance store and Retrieval Lab (`src/pages/knowops/RetrievalLabPage.tsx`, `GovernancePage.tsx`); the governance API client is `src/api/governance.api.ts`.

## Environment Variables

Two-tier config (see `infra/env/README.md`):

1. **`infra/env/.env.dev`** — shared infra values (DB creds, ports, Kafka brokers). Loaded via `--env-file` by `make` commands; used for `${VAR}` interpolation in compose YAML.
2. **`infra/env/services/<service>.dev.env`** — per-service literals (NODE_ENV, LOG_LEVEL, in-network hostnames). Loaded via `env_file:` in compose; no interpolation.

### Service env var contracts

- **auth-hub**: uses split `DB_HOST`, `DB_USER`, `DB_PASS` — no `DATABASE_URL`. No Prisma in production.
- **user-hub**: requires `DATABASE_URL` (full URL), `AUTH_HUB_GRPC_HOST` + `AUTH_HUB_GRPC_PORT` separately.
- **know-hub**: requires `DATABASE_URL`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` (not `MINIO_USER`/`MINIO_PASS`). `GRPC_ENABLED=true` and `GRPC_PORT=50052` activate the `DocumentInternal` gRPC server for agent-hub.
- **agent-hub**: `OLLAMA_BASE_URL`, `AGENT_REASONING_MODEL` (use the full pulled tag e.g. `llama3.1:8b-instruct-q4_K_M`, not a shorthand), `KNOW_HUB_URL`, `KNOW_HUB_GRPC_PORT`, `DATABASE_URL`, `KAFKA_BROKERS`, `CRAG_MAX_LOOPS` (default 2), `LANGFUSE_ENABLED` (default false). CRAG guardrails (`CRAG_TOP_K`, `CRAG_MIN_SCORE`, `CRAG_MAX_REGEN`, per-node `CRAG_*_TEMPERATURE`, `CRAG_QUERY_REWRITE_ENABLED`, `CRAG_GROUNDING_ENABLED`) are the **shipped defaults** — the governance store overrides them at runtime. Reranking: `CROSS_ENCODER_ENABLED` (default false), `RERANK_MODEL`, `RERANK_CANDIDATE_K`, `RERANK_TOP_N`. Prompts: `PROMPT_LABEL` (default `production`), plus `LANGFUSE_HOST` / `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY`. All validated at startup by pydantic-settings (`src/agent_hub/config.py`).

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
| Langfuse (LLM prompts/traces) | http://localhost:3060 |
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
- `doc` — document metadata, embedding_status, doc_type, topic, chunk_strategy (know-hub; agent columns added by `41-doc-agent-columns.sql`)
- `sem` — vector chunks (pgvector, know-hub semantic layer)
- `chat` — chat_sessions, chat messages (know-hub, owned by `knowhub_app`; `infra/postgres/init/06-chat.sql`)
- `audit` — event log (audit-hub)
- `agent` — agent_runs, agent_steps, agent_governance (single-row JSONB runtime config), LangGraph checkpoint tables (agent-hub; initialized from `infra/postgres/init/40-agent.sql`)

Langfuse is self-hosted as an infra container and gets its **own database** (not just a schema), bootstrapped by `infra/postgres/init/07-langfuse.sh` with a dedicated role. It manages its own migrations.

Fresh databases are initialized from `infra/postgres/init/*.sql` (runs once on container creation). For existing databases adding pgvector: `cd know-hub && npx prisma migrate deploy` (requires superuser for `CREATE EXTENSION vector`).

## Kong Configuration

Kong runs in DB-less declarative mode. Config lives at `infra/kong/kong.yml`. Edit this file and run `make dev-services` (or restart the kong container) to apply changes. Validate with `make lint`.

The JWT public key in `kong.yml` is the dev RSA-2048 key from `infra/keys/dev-signing-pub.pem`. Rotate in production using `infra/scripts/rotate-kong-jwt-key.sh`.
