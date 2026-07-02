---
name: stack-up
description: Bring up the brainwave dev stack with Docker Compose (make dev / make dev-services), wait for services to become healthy, print the management URLs, and show container status. Use when asked to start, boot, run, or spin up the stack, or to check whether services are up. Also covers tailing logs and stopping the stack.
---

# stack-up — Execution · Tool

All infra commands run from `infra/`. Kong (`:8000`) is the only entry point; hubs
listen on 3000–3004 behind it.

## When to use
- "Start the stack", "bring services up", "is X running?", "tail kong logs", "shut it down".

## Guardrails
- `make reset` **destroys all volumes / drops all data** — never run it unless the user explicitly asks and confirms.
- The **UI is not in Docker** — it runs separately (`cd ui && npm run dev` → http://localhost:5173).
- If a hub stays unhealthy, tail its logs before retrying; don't loop `make dev-services`.

## Procedure
1. Choose the target:
   - Infra + observability only: `cd infra && make dev`
   - Full app stack (infra + auth/user/know/audit hubs): `cd infra && make dev-services`
2. Check status: `make ps`.
3. Verify readiness — each hub exposes `/health/live` and `/health/ready`:
   - auth-hub `:3000`, user-hub `:3001`, know-hub `:3002`, audit-hub `:3003`, agent-hub `:3004`
   - via gateway: `curl http://localhost:8000/...` (JWT required except `auth-hub /api/auth/*`).
4. Print all management UIs: `make urls`.
5. Tail logs when debugging: `make logs` (all) or `make logs s=kong` (one service).

## Stopping
- `make down` (alias `make dev-down`) — stops containers, **preserves** volumes.

## Handy URLs (dev)
Kong `:8000` · Keycloak `:8080/admin` · Kong Manager `:8002` · MinIO `:9001` ·
Grafana `:3030` (admin/admin) · Prometheus `:9090` · Langfuse `:3060` ·
Postgres host port `:6632`.
