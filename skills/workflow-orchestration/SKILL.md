---
name: workflow-orchestration
description: "Guidance for dispatching robust multi-agent workflows with the workflow tool or /workflow. Use whenever the user asks to dispatch agents, fan out or parallelize work, run a workflow, orchestrate sub-agents, or debug a failed workflow run."
---

# Workflow Orchestration

The workflow machinery is reliable — every failure we have seen was an
orchestration bug. Follow this contract exactly.

## 1. Script shape (strict — violations fail with "Unexpected token 'export'")

```js
export const meta = { name: "…", description: "…", phases: [{ title: "…" }] };

export default async function () {
  // ALL helpers, constants, and orchestration live here.
  // Nothing else may exist at top level.
}
```

- First statement must be `export const meta = {…}`; then **exactly one**
  top-level statement: the `export default async function`.
- Any top-level `const`, helper `function`, or second `export` breaks the
  parse (the runner extracts the function body verbatim). **Everything
  inside the function.**
- Alternative: top-level code ending with a bare `run()` call.

## 2. Agents never return valid JSON — assume it, design for it

- Prompt every agent: "Return STRICT JSON only: one line per field, no
  newlines inside strings, no markdown fences, no prose."
- Parse tolerantly: strip prose (first `{` → last `}`), escape literal
  newlines/tabs inside strings, and double invalid escapes (`\s` → `\\s`).
- On parse failure: **one** correction call ("Your previous output was not
  valid JSON. Return ONLY valid JSON now"), then fail loudly with context.
- Validate recon output early (must contain the expected array) — a
  malformed lead list should fail fast, not downstream.

## 3. Tiers are real model routes (`~/.pi/workflows/model-tiers.json`)

`scout` = flash:low · `worker` = flash:medium · `reviewer`/`synthesizer`
= pro:high. Match tier to job: recon/scanning on scout; deep adversarial
analysis on reviewer; merging on synthesizer. Agents burn tokens fast
(~250k+ per deep-dive agent) — set a `tokenBudget` when cost matters and
keep prompts tight.

## 4. Debugging and salvage

- Panel `0/N agents` = 0 **done**, N **running** — healthy. Check the
  owner PID's network connections to the API host to confirm activity.
- `/workflow status <runId>` — agents, journal, evidence, exports.
- **Failed runs keep everything**: `~/.pi/workflows/projects/<project>/runs/<runId>.json`
  holds every agent's full output in `journal[]`. Salvage it with the
  tolerant parser and continue (e.g. re-dispatch only the synthesizer
  with the salvaged data as `args`) instead of re-running the pipeline.

## 5. Reuse the hardened template

- `/workflow saved recon-review '{"target": "…", "focus": "…", "topN": 3}'`
  runs a proven recon → parallel hunters → synthesizer workflow with all
  of the above built in (source: `examples/workflow-recon-review.js` in
  pi-plan-ng; update via `cp` — saved workflows are plain copies).
- Full failure-mode table: `WORKFLOWS.md` in pi-plan-ng.
