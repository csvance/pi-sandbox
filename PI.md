# PI — agent CLI, MCP setup, and plugins

Notes on the [pi.dev](https://pi.dev) coding-agent installation used in this
project: what is installed, where its config lives, how the MCP layer is wired,
and which plugins/extensions/skills are active.

## Installation

| | |
| --- | --- |
| **pi** | `0.84.1`, installed as a global npm package at `~/.local/lib/node_modules/@earendil-works/pi-coding-agent` (read-only inside the sandbox) |
| **Binary** | `~/.local/bin/pi` (symlink into the install; bound read-only) |
| **User config dir** | `~/.pi/agent/` (bound read/write into the sandbox — pi is useless without it; see SANDBOX.md) |

## Config files (`~/.pi/agent/`)

| File | Purpose |
| --- | --- |
| `mcp.json` | MCP server registrations — now lives at `~/.config/mcp/mcp.json`, not here (see below) |
| `settings.json` | theme, default provider/model, thinking level, installed packages |
| `auth.json` | API credentials (currently: DeepSeek key). **Never commit or paste this.** |
| `models-store.json` | model catalog: ids, cost, context window, thinking maps |
| `extensions/` | local extensions — currently only herdr's integration |
| `skills/` | local skills — `herdr.md` + `workflow-orchestration/` (see Skills below) |
| `npm/` | installed plugin packages (user scope) + their node_modules |
| `sessions/` | persisted pi sessions |

## MCP setup

The MCP layer is: **pi** (client, via the `pi-mcp-adapter` plugin) ←→
**Kaimon** (server, a Julia process). There is one registered server.

Since the move to `pi-mcp-adapter`, the registration lives at the
**user-global shared** path — `~/.config/mcp/mcp.json` — not in the pi agent
dir. It is the same tool-agnostic path Claude Code / Cursor-style hosts read,
and the adapter reads it **before** the pi-specific layers. Inside this
sandbox the file is a **read-only copy from the sandbox's private store** (the
host's `~/.config/mcp` is never bound — see below); path and precedence are
unchanged. Full precedence chain (sources are merged, higher wins):

| # | File | Role |
| --- | --- | --- |
| 1 | `~/.config/mcp/mcp.json` | **user-global shared config — used here** |
| 2 | `~/.agents/mcp.json` | user-global, tool-agnostic |
| 3 | `~/.agents/mcp/mcp.json` | user-global, tool-agnostic |
| 4 | `~/.pi/agent/mcp.json` | pi-global override / compatibility imports (currently absent) |
| 5 | `.mcp.json` | project-local shared config |
| 6 | `.pi/mcp.json` | pi project override — where `/mcp disable` / `/mcp enable` persist `disabled` |

`~/.config/mcp/mcp.json`:

```json
{
  "mcpServers": {
    "kaimon": {
      "transport": "streamable-http",
      "url": "http://localhost:2828/mcp",
      "lifecycle": "eager"
    }
  }
}
```

- **`kaimon`** — the Julia MCP server (`/home/csvance/.julia/bin/kaimon`,
  runs `julia … -m Kaimon`). Listens on **127.0.0.1:2828** only — loopback,
  never exposed. It is auto-started by the fish hook in herdr's `kaimon`
  workspace (see HERDR.md); pi connects eagerly at startup (`lifecycle:
  eager`) over `streamable-http`. (`transport` is legacy/tolerated — the
  adapter actually keys off `url`, which is StreamableHTTP with SSE fallback.)
- **What Kaimon exposes to agents** — the `mcp_kaimon_*` tool suite: a
  persistent Julia REPL (`ex`), package management, semantic + exact code
  search over indexed projects, reflection/introspection (types, methods,
  definitions), test running with coverage, `@infiltrate`-based debugging,
  spawned subagents, and Qdrant project indexing. It is the reason agents
  inside this sandbox can drive Julia projects end-to-end.
- The **`pi-mcp-adapter`** plugin (below) is the client half of this — it is
  what lets pi talk to any MCP server, including Kaimon. The old
  `~/.pi/agent/mcp.json` was removed in the move: the shared file is now the
  single source of truth.
- The adapter also adds the `/mcp` status panel and `/mcp setup`, which can
  scaffold a project `.mcp.json`, quick-add known servers, or *explicitly*
  import server configs found in host files (Cursor, Claude Code, Codex,
  Windsurf, VS Code). `pi-mcp-adapter init` does the equivalent from the
  terminal. Host-config discovery stays off by default — importing is always
  an explicit opt-in.
- The file is a **sandbox-private, read-only seed** (same pattern as the
  enforced `~/.npmrc`): the host's `~/.config/mcp` is deliberately **never
  bound**, and `sandbox.sh` writes the registration above into the sandbox's
  private store on first launch, bound read-only at `~/.config/mcp/mcp.json`.
  Security: a sandboxed agent can neither read host MCP configs (which may
  hold other tools' OAuth secrets or `command` entries) nor edit the
  registrations pi loads. The adapter only ever *reads* the shared config
  (its overrides go to `.pi/mcp.json` / the agent dir), so read-only costs
  nothing. To add servers: edit `MCP_DEFAULT` in `sandbox.sh` (delete the
  private copy to re-seed), or use a project-local `.mcp.json`.

## Provider & models

- **Default provider:** DeepSeek — `defaultProvider: "deepseek"`,
  `defaultModel: "deepseek-v4-flash"`, `defaultThinkingLevel: "high"`.
- **`models-store.json`** holds the catalog: DeepSeek V4 Flash (reasoning,
  openai-completions API at `https://api.deepseek.com`, 1M context, thinking
  maps for the deepseek format). Refreshed with `pi update --models`.
- **`auth.json`** holds the DeepSeek API key (auto-provisioned via
  `pi /login`). Value redacted here by design.

## Plugins (installed pi packages)

Declared in `settings.json` → `packages` (user scope, installed under
`~/.pi/agent/npm/`):

| Package | Version | What it does |
| --- | --- | --- |
| `npm:pi-mcp-adapter` | 2.20.1 | MCP client extension — connects pi to any MCP server (this is what talks to Kaimon). Replaces the older `pi-mcp-extension`; adds the `/mcp` panel, `/mcp setup`, OAuth flows, host-config discovery, and the `mcp-scripting` skill |
| `npm:pi-agent-extensions` | 0.5.2 | Meta package: **17 extensions + 4 themes** for pi in one install (see Extensions below) |
| `npm:pi-deepseek-search` | 1.0.15 | Zero-config web search for pi via DeepSeek's server-side search (`web_search_20260209`); DeepSeek models only |

Previously installed, now removed: `pi-mcp-extension` (superseded by
`pi-mcp-adapter`) and `pi-subagents` + `@piex-dev/plan` (their delegation /
plan-mode / todos surface is covered by `pi-agent-extensions`' `workflow` /
`loop` / `todos` extensions).

### Management

```bash
pi list                      # show installed packages
pi install npm:@scope/pkg    # add one (user scope by default; -l for project)
pi remove npm:@scope/pkg
pi update npm:pi-agent-extensions   # update one package
pi update --extensions       # update plugins only
pi update --models           # refresh model catalogs
pi update --all              # update pi + plugins + reconcile git refs
```

**Security note (from pi's docs):** pi packages run with **full system access**
— extensions execute arbitrary code and skills instruct the model to run
arbitrary actions. Review source before installing. Within this sandbox that
means a rogue plugin is contained to the sandbox boundary (see SANDBOX.md).

## Extensions

- `~/.pi/agent/extensions/herdr-agent-state.ts` — **installed and managed by
  herdr** (`HERDR_INTEGRATION_ID=pi`, v8). Streams pi agent state to herdr over
  the herdr socket (`HERDR_SOCKET_PATH` + `HERDR_PANE_ID`), which powers
  herdr's agent-aware panes/status. Header comment says it explicitly: *managed
  by herdr; reinstalling or updating the integration overwrites this file —
  add custom hooks/plugins beside it instead of editing it.*

### pi-agent-extensions (17 extensions, 4 themes)

A meta package: one `pi install npm:pi-agent-extensions` registers everything
below (the package's `pi.extensions` field declares them; each lives under the
package's `extensions/` dir). They show up in the `[Extensions]` startup
section as `pi-agent-extensions:*`:

| Extension | Type | What it does | Status |
| --- | --- | --- | --- |
| `sessions` | command | quick session picker (`/sessions`) | stable |
| `ask_user` | tool | LLM can ask structured questions | beta |
| `handoff` | command | goal-driven context transfer (`/handoff`) | stable |
| `whimsical` | UI | context-aware loading messages & exit | stable |
| `files` | tool | unified file browser + git integration | stable |
| `notify` | automatic | OSC 777 desktop notification after agent turns | stable |
| `context` | command | context breakdown dashboard (`/context-simple`) | stable |
| `review` | tool | interactive code review | stable |
| `loop` | tool | test / condition / self-driven iteration loops | stable |
| `todos` | tool | file-based todo list management | stable |
| `control` | RPC | inter-session communication & control | beta |
| `answer` | tool | structured Q&A for complex queries | beta |
| `cwd_history` | tracker | tracks directory changes in context | stable |
| `btw` | command | ephemeral side questions without session history | stable |
| `powerline-footer` | UI | powerline-style footer bar (git branch, dirty-file count, model, context, cost, timer) | stable |
| `session-breakdown` | command | session analytics dashboard | stable |
| `workflow` | tool/command | model-routed multi-agent workflows (`/workflow`) | beta |

**Themes** (declared in the package's `pi.themes` field; pick one with
`settings.json → theme` or `/theme`): `nightowl`, `p10k-inspired`,
`ghostty-dark`, `fzf-bat`.

## Skills

| Skill | Source | Purpose |
| --- | --- | --- |
| `herdr` | `~/.pi/agent/skills/herdr.md` | Control the herdr terminal multiplexer (panes, tabs, workspaces, commands, other agents). Activated only when the user mentions herdr; requires `HERDR_ENV=1` |
| `workflow-orchestration` | `~/.pi/agent/skills/workflow-orchestration/SKILL.md` (seeded on first launch from `skills/` in this repo) | Dispatching robust multi-agent workflows (`/workflow`): strict script-shape contract, tolerant strict-JSON agent handling, model tiers (`scout`/`worker`/`reviewer`/`synthesizer`), debugging + failed-run journal salvage |
| `mcp-scripting` | bundled with the pi-mcp-adapter plugin (`~/.pi/agent/npm/node_modules/pi-mcp-adapter/skills/mcp-scripting/SKILL.md`) | Writing `mcpScript` JavaScript that discovers, inspects, and batches MCP tool calls |

Skills are part of the **documented standard environment**: `sandbox.sh`
ensures every skill in its `SKILL_SEEDS` list exists in the shared
`~/.pi/agent/skills/` dir, copying from the repo bundle (`skills/<name>/`)
on first launch when absent. Because `~/.pi/agent` is bound **read/write**
(see below), the seeded files are visible inside the sandbox with **no extra
bind** — the copy fires only when the target is missing, so a skill updated
on the host is never overwritten. To change the seeded content, edit the
bundle under `skills/` in this repo and delete the target dir to re-seed.

(The `pi-subagents` skill and its prompt templates shipped with the old
`pi-subagents` plugin and were removed with it.)

## Settings summary (`settings.json`)

```json
{
  "theme": "dark",
  "defaultProvider": "deepseek",
  "defaultModel": "deepseek-v4-flash",
  "defaultThinkingLevel": "high",
  "hideThinkingBlock": true,
  "packages": ["npm:pi-deepseek-search", "npm:pi-agent-extensions",
               "npm:pi-mcp-adapter"]
}
```

## How this fits the sandbox

- `~/.pi/agent` is bound **read/write** into the sandbox — a deliberate
  credential exception (pi's auth lives there). See SANDBOX.md → *Sensitive
  paths*.
- `~/.config/mcp` is **not bound at all** — a security decision (SANDBOX.md →
  policy table). The adapter reads `mcp.json` from a sandbox-private,
  read-only seed that `sandbox.sh` generates on first launch: host MCP
  configs stay out of the sandbox, and registrations can't be tampered with.
  The API key remains in `~/.pi/agent/auth.json` (the one deliberate pi
  credential exception).
- The pi install (`~/.local/lib/node_modules`) and CLI (`~/.local/bin`) are
  bound **read-only**; updating pi happens on the host.
- Agents get per-project containment via `pi-bwrap` (SANDBOX.md), which hides
  `~/Git` except the project an agent was launched in — the MCP/REPL/search
  tools still work, but only against the scoped project.
