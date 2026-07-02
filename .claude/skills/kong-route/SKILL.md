---
name: kong-route
description: Add or edit a route/service in Kong's DB-less declarative config (infra/kong/kong.yml), then validate and apply it. Use when exposing a new hub endpoint through the API gateway, changing path routing, or adjusting JWT vs public access. Kong is the only entry point for the stack.
---

# kong-route — Tool

Kong runs in **DB-less declarative** mode; the whole gateway config lives in
`infra/kong/kong.yml`. Editing the file + restarting kong applies changes.

## When to use
- A hub added an endpoint that must be reachable from the browser/UI through `:8000`.
- Changing a route path, or making a route public vs JWT-protected.

## Key conventions
- Every request enters via Kong `:8000` → JWT RS256 validated against Keycloak (JWKS) →
  `X-User-Id` injected via a Kong post-function → routed to the hub.
- **Public** (no JWT): `auth-hub` `/api/auth/*`. **Everything else requires a valid token.**
- Services are internal hostnames: `auth-hub:3000`, `user-hub:3001`, `know-hub:3002`,
  `audit-hub:3003`, `agent-hub:3004`. Existing pattern (agent-hub):
  ```yaml
  - name: agent-hub
    url: http://agent-hub:3004
    routes:
      - name: agent-hub-routes
        paths:
          - /api/agent
  ```

## Procedure
1. Edit `infra/kong/kong.yml` — add/modify the `services[].routes[]` entry; attach the
   JWT plugin unless the route is intentionally public.
2. Validate: `cd infra && make lint` (validates all compose files + Kong config).
3. Apply: re-run `make dev-services` or restart the kong container.
4. Smoke-test through the gateway: `curl -i http://localhost:8000/<path>` (expect 401
   without a token on protected routes).

## Guardrails
- The JWT public key in `kong.yml` is the dev RSA-2048 key from `infra/keys/dev-signing-pub.pem`.
  Rotate in prod via `infra/scripts/rotate-kong-jwt-key.sh` — never hand-edit keys for prod here.
- Don't expose internal-only gRPC ports (e.g. know-hub `:50052`) through Kong.
