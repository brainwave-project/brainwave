# Brainwave Deployment Guide

This guide explains how the `@brainwave-project/core` library and the three service containers are published and deployed.

## Architecture Overview

The Brainwave monorepo consists of:

1. **@brainwave-project/core** — Shared library (TypeScript domain types, utilities, ports)
   - Published to npm registry as `@brainwave-project/core@1.2.0`
   - Services consume it as a published package, not a local file dependency

2. **Three service containers** — Built from individual service directories
   - `auth-hub` — Identity management with Keycloak facade
   - `user-hub` — User lifecycle and role management
   - `know-hub` — Document lifecycle with dual-store persistence

## Development vs. Production

### Development Setup

**Services are built from source with local dependencies:**
- `package.json`: Uses local workspace file references (e.g., `"file:../core"`)
- Docker: `compose.dev.yml` mounts source code as volumes and runs `ts-node` for hot-reload
- Build context: Full monorepo with `COPY core/ /core/` for npm to resolve `file:../core`

**Usage:**
```bash
cd brainwave
docker compose -f docker/compose.yml -f docker/compose.dev.yml \
  --env-file env/.env.dev --profile services up -d
```

### Production Setup

**Services use published artifacts:**
- `package.json`: Published version (e.g., `"@brainwave-project/core": "^1.2.0"`)
- Docker: Build from service directory (e.g., `cd auth-hub/ && docker build .`)
- Container Registry: Images pulled from GitHub Container Registry (ghcr.io)
- Compose: `compose.prod.yml` pulls pre-built images instead of building

**Usage:**
```bash
cd brainwave
# Build and push to GitHub Container Registry (via GitHub Actions)
# Then pull and deploy:
docker compose -f docker/compose.yml -f docker/compose.prod.yml \
  --env-file env/.env.prod --profile services up -d
```

## Publishing Flow

### Step 1: Publish @brainwave-project/core

Publish the shared library to your npm registry:

```bash
cd core/
npm version patch  # or minor, major
npm publish --registry <your-npm-registry-url>
```

Update `package.json` version tag in all services to match the published version:

```bash
# In auth-hub/, user-hub/, know-hub/
npm install @brainwave-project/core@^1.2.0
```

### Step 2: Prepare Service Dockerfiles

Service Dockerfiles are automatically simplified when using published core:

**Before (monorepo root build):**
```dockerfile
WORKDIR /app
COPY core/ /core/
COPY auth-hub/package*.json ./
RUN npm ci --omit=dev
```

**After (service directory build):**
```dockerfile
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
```

All three service Dockerfiles have already been updated to use the new pattern.

### Step 3: Build and Push Service Images

#### Manual Build and Push

Build from each service directory:

```bash
# Auth Hub
cd auth-hub/
docker build -t ghcr.io/brainwave-project/brainwave-auth-hub:latest .
docker push ghcr.io/brainwave-project/brainwave-auth-hub:latest

# User Hub
cd ../user-hub/
docker build -t ghcr.io/brainwave-project/brainwave-user-hub:latest .
docker push ghcr.io/brainwave-project/brainwave-user-hub:latest

# Know Hub
cd ../know-hub/
docker build -t ghcr.io/brainwave-project/brainwave-know-hub:latest .
docker push ghcr.io/brainwave-project/brainwave-know-hub:latest
```

#### Automated Build and Push (GitHub Actions)

The workflow `.github/workflows/publish-services.yml` automatically:
1. Triggers on `push` to `main` or `develop` branches (or manually via `workflow_dispatch`)
2. Filters by service directory changes
3. Builds each service from its directory
4. Tags images with semantic versioning and commit SHA
5. Pushes to `ghcr.io/<owner>/brainwave-<service>:latest`

**Setup GitHub Container Registry credentials:**

1. Create a Personal Access Token (PAT) with `write:packages` scope
2. Store it as `GITHUB_TOKEN` (automatically available in GitHub Actions)
3. Make image repository public or configure private access if needed

**Trigger the workflow:**
```bash
# Push commits to main/develop — workflow runs automatically
git push origin main

# Or manually trigger from GitHub UI
# Actions → Publish Services to GitHub Container Registry → Run workflow
```

### Step 4: Deploy to Production

Create `.env.prod` with production settings:

```env
# Database
POSTGRES_USER=prod_user
POSTGRES_PASSWORD=<secure-password>
POSTGRES_DB=brainwave
MONGO_USER=mongo_user
MONGO_PASSWORD=<secure-password>
MONGO_DB=brainwave

# MinIO / Object Storage
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=<secure-password>

# Keycloak
KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=<secure-password>
KEYCLOAK_AUTH_HUB_SECRET=<keycloak-client-secret>

# GitHub Container Registry
GHCR_REGISTRY=ghcr.io
GHCR_OWNER=brainwave-project
GHCR_REPO=brainwave
GHCR_TAG=latest

# Service Ports
AUTH_HUB_PORT=3000
AUTH_HUB_GRPC_PORT=50051
USER_HUB_PORT=3001
KNOW_HUB_PORT=3002
```

Deploy with production compose:

```bash
docker compose -f docker/compose.yml -f docker/compose.prod.yml \
  --env-file env/.env.prod --profile services up -d
```

## Semantic Layer (Phase 1)

KnowHub's semantic search runs entirely in-network: a local **Ollama** container
serves the `nomic-embed-text` embedding model (768-dim), and embeddings are
stored in **pgvector**. There is **no external API and no API key** — document
text never leaves the Docker network.

### Infrastructure additions

| Component | Change |
|-----------|--------|
| `postgres` | Image swapped to `pgvector/pgvector:pg16` (drop-in superset of `postgres:16`). |
| `ollama` | New service serving the embedding model. Data persisted in the `brainwave-ollama-data` volume. |
| `ollama-init` | One-shot container that pulls `${OLLAMA_MODEL}` on first boot, then exits. |

### First-run model pull

On a fresh stack, `ollama-init` pulls the model (~274 MB) before KnowHub's
worker can embed anything. This is a **one-time** download cached in the
`brainwave-ollama-data` volume; subsequent boots reuse it.

```bash
# Bring up infra (ollama-init pulls the model automatically on first run)
docker compose -f docker/compose.yml -f docker/compose.dev.yml \
  --env-file env/.env.dev --profile services up -d

# Watch the (one-time) model download
docker compose logs -f ollama-init

# Verify the model is available
curl http://localhost:11434/api/tags
```

KnowHub tolerates a not-yet-ready model: documents stay in `embedding_status =
PENDING` and the worker indexes them once Ollama responds. No uploads are
blocked by embedding.

### Existing databases — pgvector migration

Fresh dev databases are bootstrapped from `infra/postgres/init/*.sql` (which now
includes `05-semantic.sql`). For an **existing** database, after swapping to the
`pgvector/pgvector:pg16` image, apply the Prisma migration (the connection must
have superuser to run `CREATE EXTENSION vector`):

```bash
cd know-hub/
npx prisma migrate deploy
```

### Configuration

Non-secret defaults live in `infra/env/services/know-hub.dev.env`:

```env
OLLAMA_BASE_URL=http://ollama:11434
OLLAMA_MODEL=nomic-embed-text
OLLAMA_BATCH_SIZE=8
OLLAMA_TIMEOUT_MS=30000
SEMANTIC_WORKER_ENABLED=true   # set false to disable in-process indexing
SIMILARITY_THRESHOLD=0.60      # default minScore for search
QUERY_CACHE_SIZE=500
QUERY_CACHE_TTL_MS=300000
```

Search is exposed through Kong at `/api/semantic/*` (same JWT validation as the
rest of KnowHub). Reindexing (`POST /api/semantic/reindex/:documentId`) requires
the `ADMIN` role.

## Key Differences

| Aspect | Development | Production |
|--------|-------------|-----------|
| **Core Library** | `file:../core` (local) | `@brainwave-project/core@^1.2.0` (npm registry) |
| **Build Context** | Monorepo root | Service directory |
| **Volume Mounts** | Yes (source code) | No |
| **Runtime** | `tsx` (TypeScript) | `node` (compiled JavaScript) |
| **Image Source** | Built locally | Pre-built in GHCR |
| **ENV File** | `.env.dev` | `.env.prod` |
| **Log Level** | `debug` | `info` |
| **Restart Policy** | `unless-stopped` | `always` |

## Troubleshooting

### "Cannot find module @brainwave-project/core"

**Cause:** Service `package.json` still references `file:../core` but is being built from service directory.

**Fix:** Update all `package.json` files to use published version:
```json
"@brainwave-project/core": "^1.2.0"
```

Then rebuild images.

### "Failed to authenticate with GitHub Container Registry"

**Cause:** Missing GITHUB_TOKEN or incorrect credentials.

**Fix:** 
1. Ensure `GITHUB_TOKEN` is available in GitHub Actions
2. For manual push from local machine:
   ```bash
   echo $GITHUB_TOKEN | docker login ghcr.io -u <username> --password-stdin
   ```

### Service fails to start: "curl: command not found"

**Cause:** Healthcheck uses curl but it's not in the image.

**Fix:** Services are built with alpine, which doesn't include curl by default. Either:
1. Implement healthcheck in the service itself (preferred)
2. Or add curl to the Dockerfile: `RUN apk add --no-cache curl`

## References

- [GitHub Container Registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [Docker Build Context](https://docs.docker.com/build/building/context/)
- [Multi-stage Dockerfile](https://docs.docker.com/build/building/multi-stage/)
