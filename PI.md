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
| `skills/` | local skills — currently `herdr.md` |
| `npm/` | installed plugin packages (user scope) + their node_modules |
| `AGENTS.md` | sandbox-global agent instructions — synced from the repo's `AGENTS.sandbox.md` on every sandbox launch |
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

## Claude Code (claude CLI + pi-claude-bridge)

The sandbox is wired so **Claude Code runs alongside pi** with the host's
Claude auth, no setup prompt, and persistent sessions — this is what makes
pi-claude-bridge (or running `claude` in a herdr pane) work in here.

| Piece | How it's handled |
| --- | --- |
| `claude` binary | read-only bind, already in place: `~/.local/bin/claude` is a symlink into `~/.local/share/claude/versions/…` (both bound ro). |
| `~/.claude` | **read/write bind** (deliberate credential exception, same class as `~/.pi/agent`): `.credentials.json` (OAuth tokens), `projects/` + `sessions/` (session transcripts), settings, plugins. Claude refreshes tokens in place; sessions persist across launches. Shared with the host — authenticate once (`claude` → login) and both the CLI and the bridge use it in either world. |
| `~/.claude.json` | **not bound** — claude rewrites it every run (it snapshots `.claude.json.backup` first), and a live rw file bind onto a rewritten host file is a stale-handle trap on NFS. Instead `sandbox.sh` injects the host copy via bwrap `--file` at every launch (same mechanism as `~/.nanorc`): a fresh, writable copy in the sandbox's tmpfs home. Onboarding markers + per-project trust come along, so no setup/trust prompt; writes are ephemeral by design and the host file stays authoritative. |

Practical notes:

- **Authenticate once, anywhere**: `claude` inside the sandbox or on the host
  writes/refreshes `~/.claude/.credentials.json`; both worlds share it.
- **No setup prompt**: the seeded `~/.claude.json` carries `firstStartTime`,
  migration markers and (once you've trusted folders) per-project trust, so
  claude skips onboarding and folder-trust prompts. In-sandbox trust decisions
  are ephemeral (re-seeded next launch) — trust projects on the host, or
  accept the one prompt per launch for new work dirs.
- **Persistent sessions**: pi sessions persist in `~/.pi/agent/sessions` (rw
  bind); Claude Code sessions persist in `~/.claude/projects` + `sessions`
  (rw bind).
- **pi-claude-bridge** (`pi install npm:pi-claude-bridge`) is optional but
  makes Claude the pi provider (`claude-bridge/claude-*` models) with the same
  auth — install it if you want Claude-only pi sessions.

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
| `npm:pi-mcp-adapter` | 2.21.0 | MCP client extension — connects pi to any MCP server (this is what talks to Kaimon). Replaces the older `pi-mcp-extension`; adds the `/mcp` panel, `/mcp setup`, OAuth flows, host-config discovery, and the `mcp-scripting` skill |
| `npm:pi-subagents` | 0.42.1 | Subagent delegation: single-agent, parallel, scripted, async and coordinated subagent workflows; ships the `pi-subagents` skill + prompt templates |
| `git:github.com/csvance/pi-plan-ng` | 0.1.0 (tracks `origin/main`; cloned to `~/.pi/agent/git/`) | Safety-gated plan mode with the command-parsing gate (`pi.extensions: ["./index.ts"]`). Installed from GitHub **without a pin**, so it tracks `main`: after pushing, `pi update git:github.com/csvance/pi-plan-ng` (or `pi update --extensions` for all) fetches and hard-resets the clone to the branch tip. Add `@ref` only if you want a fixed tag/commit instead |
| `git:github.com/csvance/pi-handoff-ng` | 0.1.0 (tracks `origin/main`; cloned to `~/.pi/agent/git/`) | Handoff for pi: the agent writes a handoff document (stored outside the project), then a new pi session starts initialized with it. Same update model as pi-plan-ng: tracks `origin/main`, pulled by `pi update git:github.com/csvance/pi-handoff-ng` |
| `npm:@juicesharp/rpiv-todo` | 2.4.0 | Model todo list rendered as a live overlay; survives `/reload` and conversation compaction |
| `npm:@narumitw/pi-goal` | 0.49.6 | `/goal`-driven goal tracking: keep working until the goal is complete, with a fresh-turns blocker audit |
| `npm:pi-web-access` | 0.18.0 | Web tools for pi: search, source checks, and content fetching (backed by pi's web-search keys) |

Previously installed, now removed: `pi-mcp-extension` (superseded by
`pi-mcp-adapter`), `pi-agent-extensions` (removed 2026-08; its delegation /
plan / todos surface is now covered by `pi-subagents` + the local
`pi-plan-ng` plugin), and `@piex-dev/plan`.

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
| `pi-subagents` | bundled with the pi-subagents plugin (`~/.pi/agent/npm/node_modules/pi-subagents/skills/pi-subagents/SKILL.md`) | Delegating work to builtin or custom subagents: single-agent, parallel, scripted, async, forked-context and coordinated workflows |
| `mcp-scripting` | bundled with the pi-mcp-adapter plugin (`~/.pi/agent/npm/node_modules/pi-mcp-adapter/skills/mcp-scripting/SKILL.md`) | Writing `mcpScript` JavaScript that discovers, inspects, and batches MCP tool calls |

(The `pi-subagents` skill ships with the plugin again since it was reinstalled;
its prompt templates live under the package's `prompts/` dir.)

## Settings summary (`settings.json`)

```json
{
  "theme": "dark",
  "defaultProvider": "deepseek",
  "defaultModel": "deepseek-v4-flash",
  "defaultThinkingLevel": "high",
  "hideThinkingBlock": true,
  "packages": ["npm:pi-mcp-adapter", "npm:pi-subagents",
               "npm:@juicesharp/rpiv-todo",
               "git:github.com/csvance/pi-plan-ng",
               "git:github.com/csvance/pi-handoff-ng",
               "npm:@narumitw/pi-goal", "npm:pi-web-access"]
}
```

(The `whimsical` TUI block — enabled, F:50/G:50, `chevronFlow` — is also set;
keys like `lastChangelogVersion` are pi-managed.)

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
