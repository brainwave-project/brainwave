---
name: new-feature
description: Scaffold a new feature or endpoint inside a TypeScript hub (auth-hub, user-hub, know-hub, audit-hub) following brainwave's hexagonal architecture — domain types/invariants, application service + port interface, adapter implementation, and transport wiring. Use when adding capability to a service and you want it to match the established layering.
---

# new-feature — Project-Specific · Reasoning

Every hub follows the same hexagonal layering. Build inward-out: pure core first,
side-effects last, dependencies always pointing toward `domain/`.

```
src/
├── domain/        # pure types + invariants, zero dependencies
├── application/   # service classes depending ONLY on port interfaces
│   └── ports/     # repository / adapter interfaces
├── adapters/      # implementations (Prisma, gRPC, Keycloak, MinIO, Mongo)
├── transport/http # Express routers + handlers   (and grpc/ where present)
├── events/        # Kafka emitter setup
├── observability/ # Pino logger + Prometheus metrics
└── health/        # /health/live + /health/ready
```

## When to use
- Adding a new endpoint, use-case, or persisted concept to a hub.

## Procedure (reason through each layer)
1. **Domain** — add the type + any invariant to `src/domain/`. If it's a state change,
   check for an existing state machine (e.g. user-hub `domain/user.ts`) and extend its
   allowed transitions rather than bypassing it. No imports from outer layers.
2. **Port** — declare the interface the use-case needs in `src/application/ports/`
   (e.g. `SomethingRepository`). The application layer depends on this, never on the adapter.
3. **Application** — write/extend the service class in `src/application/`; inject ports
   via the constructor. Keep it framework-free and side-effect-free beyond the ports.
4. **Adapter** — implement the port in `src/adapters/` (Prisma client, gRPC client, etc.).
   For DB work, update the Prisma schema and run the `db-migrate` skill.
5. **Transport** — add the Express handler/route in `src/transport/http/`; validate input,
   call the service, map `AppError` → HTTP. Services trust `X-User-Id` from Kong — do **not**
   re-validate JWTs.
6. **Cross-cutting** — emit a Kafka domain event if state changed (audit-hub consumes all);
   add a metric/log via `observability/`; expose the route through Kong (`kong-route` skill).

## Guardrails
- Reuse `@brainwave-project/core` (`AppError`, `ErrorCode`, `createLogger`, gRPC/Kafka helpers) — don't reinvent.
- Keep the dependency direction strict: `transport → application → domain`, adapters implement ports.
- Validate: `npm run build` (tsc) in the hub; there is no unit-test suite yet.
