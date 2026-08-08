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
| `mcp.json` | MCP server registrations (see below) |
| `settings.json` | theme, default provider/model, thinking level, installed packages |
| `auth.json` | API credentials (currently: DeepSeek key). **Never commit or paste this.** |
| `models-store.json` | model catalog: ids, cost, context window, thinking maps |
| `extensions/` | local extensions — currently only herdr's integration |
| `skills/` | local skills — currently `herdr.md` |
| `npm/` | installed plugin packages (user scope) + their node_modules |
| `sessions/` | persisted pi sessions |

## MCP setup

The MCP layer is: **pi** (client, via the `pi-mcp-extension` plugin) ←→
**Kaimon** (server, a Julia process). There is one registered server.

`~/.pi/agent/mcp.json`:

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
  eager`) over `streamable-http`.
- **What Kaimon exposes to agents** — the `mcp_kaimon_*` tool suite: a
  persistent Julia REPL (`ex`), package management, semantic + exact code
  search over indexed projects, reflection/introspection (types, methods,
  definitions), test running with coverage, `@infiltrate`-based debugging,
  spawned subagents, and Qdrant project indexing. It is the reason agents
  inside this sandbox can drive Julia projects end-to-end.
- The **`pi-mcp-extension`** plugin (below) is the client half of this — it is
  what lets pi talk to any MCP server, including Kaimon.

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
| `npm:pi-mcp-extension` | 1.5.0 | MCP client extension — connects pi to any MCP server (this is what talks to Kaimon) |
| `npm:pi-subagents` | 0.44.0 | Single-agent delegation and scripted multi-agent workflows (also ships skills + prompts) |
| `npm:@piex-dev/plan` | 0.2.0 | Plan Mode: read-only exploration, plan creation, step-by-step execution with progress tracking |
| `npm:pi-deepseek-search` | 1.0.15 | Zero-config web search for pi via DeepSeek's server-side search (`web_search_20260209`); DeepSeek models only |

### Management

```bash
pi list                      # show installed packages
pi install npm:@scope/pkg    # add one (user scope by default; -l for project)
pi remove npm:@scope/pkg
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

## Skills

| Skill | Source | Purpose |
| --- | --- | --- |
| `herdr` | `~/.pi/agent/skills/herdr.md` | Control the herdr terminal multiplexer (panes, tabs, workspaces, commands, other agents). Activated only when the user mentions herdr; requires `HERDR_ENV=1` |
| `pi-subagents` | bundled with the pi-subagents plugin (`skills/pi-subagents/SKILL.md`) | Delegation workflows: single-agent, parallel, scripted, compatibility-chain, async, forked-context, coordinated |

The pi-subagents plugin also ships prompt templates (`prompts/`):
`gather-context-and-clarify`, `parallel-cleanup`, `parallel-research`,
`parallel-review`, `review-loop`.

## Settings summary (`settings.json`)

```json
{
  "theme": "dark",
  "defaultProvider": "deepseek",
  "defaultModel": "deepseek-v4-flash",
  "defaultThinkingLevel": "high",
  "hideThinkingBlock": true,
  "packages": ["npm:pi-mcp-extension", "npm:pi-subagents",
               "npm:@piex-dev/plan", "npm:pi-deepseek-search"]
}
```

## How this fits the sandbox

- `~/.pi/agent` is bound **read/write** into the sandbox — a deliberate
  credential exception (pi's auth lives there). See SANDBOX.md → *Sensitive
  paths*.
- The pi install (`~/.local/lib/node_modules`) and CLI (`~/.local/bin`) are
  bound **read-only**; updating pi happens on the host.
- Agents get per-project containment via `pi-bwrap` (SANDBOX.md), which hides
  `~/Git` except the project an agent was launched in — the MCP/REPL/search
  tools still work, but only against the scoped project.
