# Agent instructions

## Commit completed work

Leaving completed work uncommitted is not acceptable in this project. A task that changes repository files is complete only after the changes are committed, unless the user explicitly requests otherwise.

- Inspect `git status --short` before editing so you can distinguish existing work from your changes. Preserve unrelated existing work and commit only the work within the authorized task.
- Run the checks appropriate to the change, inspect the diff and new files, and commit the implementation together with its tests, documentation, and required assets. Keep credentials, signing keys, local settings, and generated build outputs excluded.
- Before the final response, verify `git status --short`. Report the commit hash and verification results. Identify any remaining uncommitted files and explain why they remain.
- If a blocker prevents committing, report it explicitly and preserve the work. Never discard changes merely to obtain a clean status. Commit locally; push only when authorized by the user.
