---
name: crag-trace
description: Debug a CRAG (Corrective RAG) chat turn in agent-hub — pull the run trajectory, reason through the retrieve → grade → rewrite → generate → ground-check loop, and pinpoint why an answer was weak, wrong, or abstained. Use when a chat gave a bad/empty/hallucinated answer and you need to find which node failed.
---

# crag-trace — Domain-Specific · Reasoning

CRAG (`POST /api/agent/chat`, SSE) retrieves from know-hub, grades relevance with
Ollama, rewrites weak queries, abstains after `max_loops`, then ground-checks the
answer before streaming. Every run is checkpointed in the `agent` schema.

## When to use
- An answer was irrelevant, empty, hallucinated, or the agent abstained unexpectedly.

## Procedure
1. **Get the trajectory:** `GET /api/agent/runs/:id` (run id from the chat response /
   logs). This returns the durable step-by-step path.
2. **Walk the loop and locate the break:**
   - *Retrieve* — were chunks returned at all? Check `top_k`, `min_score`, and that the
     source doc is `INDEXED` in know-hub (not `PENDING`/`SKIPPED`/`FAILED`).
   - *Grade* — did the grader mark good context NOT relevant (too strict) or vice versa?
     Grader runs at `grade_temperature` (0 = deterministic).
   - *Rewrite* — how many corrective loops ran vs `max_loops`? Abstention after the cap
     is expected behavior, not a bug, when retrieval stays weak.
   - *Generate* — answer must cite `[doc:<id>]` from context only.
   - *Ground-check* — a "not grounded" verdict triggers up to `max_regen` regenerations.
3. **Form a hypothesis and act:**
   - Thin/irrelevant recall → raise `top_k`, lower `min_score`, or enable the
     **cross-encoder reranker** (`agent-tune` skill) for better precision.
   - Over-strict grading / clipped answers → adjust the relevant prompt in Langfuse
     (`crag/grade`, `crag/generate`) and republish the `production` label.
   - Missing source → the doc never indexed; check know-hub semantic worker / reindex.

## Notes
- The reranker is **fail-open**: if its model can't load it silently keeps stage-1 order,
  so "rerank looks like it did nothing" may mean the `rerank` extra isn't installed.
- Enable `LANGFUSE_ENABLED=true` for full traced spans of each node in Langfuse (`:3060`).
