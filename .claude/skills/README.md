# Brainwave Skills

Project skills for the brainwave monorepo. Each lives in `.claude/skills/<name>/SKILL.md`
and is invocable as `/<name>` in Claude Code. They're committed to the root repo, so
anyone who clones brainwave gets the same shortcuts.

## Skills by taxonomy

| `/skill` | Taxonomy bucket | Use it to… |
|---|---|---|
| `/bump-submodule` | Project-Specific · Execution | Commit/push a submodule and bump its pointer in the root repo. |
| `/stack-up` | Execution · Tool | Boot the dev stack (`make dev-services`), check health, print URLs, tail logs. |
| `/new-feature` | Project-Specific · Reasoning | Scaffold a feature across the hexagonal layers of a hub. |
| `/kong-route` | Tool | Add/validate a route in `infra/kong/kong.yml` and apply it. |
| `/db-migrate` | Tool · Execution | Run the correct Prisma flow per hub (generate/migrate/push/seed). |
| `/agent-tune` | Domain-Specific · Tool | Live-tune agent-hub CRAG governance (loops, temps, rerank, prompts). |
| `/crag-trace` | Domain-Specific · Reasoning | Debug a CRAG chat turn from its run trajectory. |
| `/milestone-plan` | Reasoning · Communication | Decompose a TDD/milestone into a service-mapped checklist. |

**General** skills (search, summarize, code-review, verify, simplify, run, dataviz,
security-review) are already provided by Claude Code built-ins — not duplicated here.

## How skills work
- A skill = a folder with a `SKILL.md`. Frontmatter needs `name` (kebab-case → `/name`)
  and `description` (when-to-use; also drives auto-triggering). The Markdown body is the
  instructions Claude follows when the skill runs.
- No registration/config — Claude Code auto-discovers `.claude/skills/`.
- Optional frontmatter: `allowed-tools:` to restrict what a skill may call; `model:` to
  pin a model.

## Add a new skill
1. `mkdir .claude/skills/<name>` and create `SKILL.md` with the frontmatter above.
2. Keep the body concise and action-oriented; reference real paths/commands.
3. Commit it to the root repo so the team gets it.

## Sharing beyond this repo
These folders can later be packaged as a **Claude Code plugin** and published to a
plugin marketplace to reuse across other repos — not needed for in-repo use.
