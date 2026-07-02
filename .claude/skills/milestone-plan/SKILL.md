---
name: milestone-plan
description: Decompose a brainwave TDD or milestone (from docs/tdd) into an ordered, service-mapped implementation plan — tasks grouped by hub, with the submodule bumps and cross-service touchpoints called out. Use when starting a new milestone/phase and you want a clear checklist before writing code.
---

# milestone-plan — Reasoning · Communication

Turn a design doc into an executable, review-ready plan that respects brainwave's
service boundaries and submodule workflow.

## When to use
- Kicking off a milestone (e.g. an "M6" ingestion phase) or a feature spanning services.

## Procedure
1. **Read the source of truth:** the relevant `docs/tdd/*` (docs is its own submodule),
   plus `CLAUDE.md` for current architecture. Note the milestone's acceptance criteria.
2. **Map to services:** for each requirement, identify which hub(s) own it
   (auth/user/know/audit/agent-hub), the core library changes, infra/Kong/env changes,
   and UI feature modules affected.
3. **Order by dependency:** contracts first (proto, Kafka topics, Prisma schema, core
   exports) → producers → consumers → gateway/UI. Flag cross-service handshakes
   (gRPC contracts, `DOCUMENT_UPLOADED` consumers, `SEMANTIC_WORKER_ENABLED` toggles).
4. **Emit the plan** as a Markdown checklist, grouped by service, each task with:
   - the files/layers it touches (use the hexagonal layering),
   - the verification step (build/lint/health/manual),
   - the `bump-submodule` action to land it.
5. **Call out risks / env changes** (new vars in `infra/env/services/<svc>.dev.env`,
   new Kong routes, new Postgres schema/migrations).

## Output style
- Concise, scannable, phased. Prefer `- [ ]` tasks over prose.
- Reference existing patterns/utilities rather than inventing new ones.
- End with an ordered "first 3 steps to start" so work can begin immediately.

## Guardrails
- This skill **plans**; it doesn't implement. Hand off tasks to `new-feature`,
  `db-migrate`, `kong-route`, etc.
- Convert any relative dates in the TDD to absolute ones in the plan.
