---
name: bump-submodule
description: Commit and push changes inside a brainwave git submodule (infra, core, auth-hub, user-hub, know-hub, audit-hub, agent-hub, ui, docs), then bump its pointer in the root repo with a chore commit. Use whenever work in a submodule is done and the root repo needs to record the new commit — the standard brainwave "bump the pointer" workflow.
---

# bump-submodule — Project-Specific · Execution

Each top-level directory (except `ui/`... which is also a submodule here) is its own
git repo tracked as a submodule. After changing a service you must commit **inside**
the submodule and then record its new SHA in the **root** repo.

## When to use
- You (or the user) finished edits in `<sub>/` and want them landed + the root pointer updated.
- The root `git status` shows a submodule as "new commits" / modified.

## Guardrails
- **Only commit or push when the user has asked.** If they only asked to make changes, stop before committing and report.
- If the submodule (or root) is on `main`/`master`, branch first unless the user said to commit on main.
- Never `--no-verify` or skip hooks unless explicitly requested.
- Commit messages end with the required trailer:
  `Co-Authored-By: Codex Opus 4.8 <noreply@anthropic.com>`

## Procedure
1. Enter the submodule and inspect: `cd <sub> && git status && git branch --show-current`.
2. Stage + commit the real change (descriptive message, not "wip"):
   `git add -A && git commit -m "<type>: <what changed>"`.
3. Push the submodule branch: `git push` (or `git push -u origin <branch>` if new).
4. Return to root: `cd ..` (root = `C:\Users\ALIEN WARE\repo\brainwave`).
5. Stage the pointer + commit in root:
   `git add <sub> && git commit -m "chore: bump <sub> pointer — <one-line reason>"`.
6. Report the new submodule SHA and the root commit SHA. Push root only if asked.

## Notes
- Bumping multiple submodules at once: repeat steps 1–3 per submodule, then one root
  commit `chore: bump submodule pointers — <reason>` staging all of them.
- `.gitmodules` already lists all URLs; you never need to re-add a submodule.
