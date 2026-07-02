---
name: db-migrate
description: Run the correct Prisma workflow for a brainwave hub — generate client, create/apply migrations, push schema, or seed. Use after changing a Prisma schema in user-hub, know-hub, or audit-hub, or when setting up a database. Knows which commands each hub actually supports.
---

# db-migrate — Tool · Execution

Prisma is used by **user-hub, know-hub, and audit-hub** (auth-hub has no Prisma in
prod — it uses split `DB_HOST`/`DB_USER`/`DB_PASS`). Run these from the hub directory.

## Command matrix (only run what the hub supports)
| Command | npm script | Supported by |
|---|---|---|
| Generate client | `npm run db:generate` | user-hub, know-hub, audit-hub |
| Create + apply migration (dev) | `npm run db:migrate` | **user-hub, know-hub only** |
| Push schema (no migration file) | `npm run db:push` | **user-hub, audit-hub only** |
| Seed | `npm run db:seed` | **user-hub only** |
| Studio (inspect) | `npm run db:studio` | all three |

## Procedure
1. Edit `prisma/schema.prisma` in the hub.
2. `npm run db:generate` to refresh the typed client.
3. Apply: `npm run db:migrate` (user-hub/know-hub) **or** `npm run db:push`
   (audit-hub, or quick user-hub iterations).
4. If the hub seeds reference data: `npm run db:seed` (user-hub).
5. Confirm the running stack sees it (`stack-up` skill → check `/health/ready`).

## pgvector (know-hub semantic layer)
- The `sem` schema uses the pgvector extension. On an **existing** DB that lacks it:
  `cd know-hub && npx prisma migrate deploy` — this needs a **superuser** because it
  runs `CREATE EXTENSION vector`.
- Fresh databases get extensions/schemas from `infra/postgres/init/*.sql` automatically
  (runs once on container creation).

## Guardrails
- Postgres schemas are role-owned (`user_management`, `doc`, `sem`, `chat`, `audit`, `agent`);
  don't cross-write between hubs.
- Don't run `db:migrate` against a hub that only supports `db:push` — it will fail or drift.
