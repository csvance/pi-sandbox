# AGENTS.md — project agent instructions

This file was seeded by `sandbox-project.sh` from the pi-sandbox default
(`~/Git/pi-sandbox/AGENTS.md`). It is a starting point, not a straitjacket:
extend or replace it with project-specific rules. The seed only runs when
this file is absent, so edits here are never overwritten.

## Environment

You run inside the pi-sandbox (bubblewrap): this project under `~/Git` is
the only repository you can read or write, and everything outside the
sandbox allowlist is invisible. A missing path is the boundary working as
designed — do not try to "fix" it by loosening sandbox policy. The sandbox
policy, pi wiring, and herdr integration are documented in `~/Git/pi-sandbox`
(SANDBOX.md, PI.md, HERDR.md), readable from a session launched there.

## Workflow failures

If any agent workflow fails (/workflow, saved workflow script, or a dispatched fix/review run):

1. Salvage what you can first — the run journal survives at ~/.pi/workflows/projects/<project>/runs/<runId>.json (every agent's full output is in journal[]).
2. Dispatch a new pi session in herdr to ~/Git/pi-sandbox to improve the workflow skill there (~/Git/pi-sandbox/skills/workflow-orchestration/, mirrored from ~/.pi/agent/skills/workflow-orchestration/). See the herdr skill (~/.pi/agent/skills/herdr.md) for pane/agent mechanics and WORKFLOWS.md for the workflow contract and failure-mode table.
