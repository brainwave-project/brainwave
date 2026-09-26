---
name: agent-tune
description: Inspect and adjust agent-hub's runtime CRAG governance — retrieval depth, corrective loops, per-node temperatures, cross-encoder reranking, and Langfuse prompt label — via the /api/agent/governance API without a redeploy. Use when tuning answer quality, enabling/disabling reranking, or explaining what a knob does.
---

# agent-tune — Domain-Specific · Tool

agent-hub ships `Settings` defaults (`src/agent_hub/config.py`) but overlays a single
hot-tunable JSONB row (`agent.agent_governance`) read on every CRAG run. Change it live
via the API — no restart. Writes are **ADMIN-only** and re-validated by the
`GovernanceSettings` pydantic model, so an out-of-range value is rejected (422).

## Endpoints (through Kong `:8000`, or agent-hub `:3004` direct)
- `GET  /api/agent/governance` — current live settings.
- `PUT  /api/agent/governance` — partial patch; only sent keys change. ADMIN role.
- `POST /api/agent/governance/reset` — drop overrides, revert to shipped defaults.
- `GET  /api/agent/models` — LLM catalog. `GET /api/agent/metrics`.

## Governable knobs (what each does)
- **Retrieval:** `top_k` (chunks fetched), `min_score` (0 → know-hub applies its own SIMILARITY_THRESHOLD).
- **Corrective loop:** `max_loops` (query-rewrite cap), `max_regen` (grounding-retry cap),
  `query_rewrite_enabled`, `grounding_enabled` (turn whole phases off).
- **Determinism:** per-node temps — `grade_temperature`, `rewrite_temperature`,
  `generate_temperature` (warmer for fluency), `grounding_temperature`. Judgement nodes
  are 0 by default.
- **Rerank (two-stage):** `cross_encoder_enabled`, `rerank_candidate_k` (stage-1 pool),
  `rerank_top_n` (kept after re-scoring). Needs the optional `rerank` extra
  (`uv sync --extra rerank`); fails open if the model is missing.

## Procedure
1. Read current: `curl -s http://localhost:8000/api/agent/governance | jq`.
2. Patch (example — turn on reranking, deepen recall):
   `curl -X PUT .../api/agent/governance -H 'Content-Type: application/json' \
      -d '{"cross_encoder_enabled": true, "rerank_candidate_k": 20, "rerank_top_n": 4}'`
   (requires an ADMIN token forwarded by Kong).
3. Re-run a chat to observe the effect (`crag-trace` skill to inspect the trajectory).
4. Revert if needed: `POST .../api/agent/governance/reset`.

## Prompts
Prompts are Langfuse-managed (`prompt_label`, default `production`). To change wording,
edit in the Langfuse UI (`:3060`) and publish the label — not via this API. Seed a fresh
project with `python scripts/seed_langfuse.py`.
