# HERDR — session layout & the kaimon auto-start

Notes on the herdr terminal setup in this project: how the session is laid out,
and why kaimon starts itself.

## Topology

- **Launcher:** `./sandbox.sh` — a bubblewrap policy. It masks `$HOME` with an
  ephemeral tmpfs, binds back a small allowlist (read-write, read-only, and
  sandbox-private copies), and launches `herdr` inside the boundary. Every
  pane herdr spawns — pi sessions included — inherits the same policy.
- **Session:** herdr session named `sandbox` (`HERDR_SESSION=sandbox`), set by
  `sandbox.sh` and pinned to sandbox-private sockets under `/tmp/herdr`.
  Session state persists in `~/.config/herdr/sessions/sandbox/` (layout in
  `session.json`).
- **Workspaces** (IDs are stable — persisted in `session.json`, reused on restore):

  | id  | label       | contents                                            |
  |-----|-------------|-----------------------------------------------------|
  | `w1`| `pi-sandbox`| pi agent panes (tabs for sessions/worktrees)        |
  | `w2`| `kaimon`    | one pane, tab 1 — the Kaimon MCP server TUI         |

- **Kaimon:** `/home/csvance/.julia/bin/kaimon` (a Julia package shim) — the
  MCP server pi's agents talk to (port 2828). Running it spawns
  `julia … -m Kaimon`.

## Why the auto-start hook exists

When a herdr session starts (e.g. `./sandbox.sh`), herdr **restores the saved
layout but panes come back as plain shells** — the kaimon pane's shell at the
workspace's identity cwd (`~/Git/pi-sandbox`), with nothing running in it. Previously kaimon had to
be launched by hand in that pane; **pi hangs at startup if kaimon isn't
running**, so the manual step was load-bearing and easy to forget.

Fix: a hook in `~/.config/fish/config.fish` (the pane shell) that starts kaimon
whenever a shell appears in the kaimon workspace.

## The hook

In `~/.config/fish/config.fish`:

```fish
if test "$HERDR_WORKSPACE_ID" = "w2"
    and not pgrep -f 'julia.*-m [K]aimon' >/dev/null 2>&1
    kaimon
end
```

### How it works

1. **Pane identity comes from herdr's env injection.** Every pane herdr spawns
   gets `HERDR_ENV`, `HERDR_SESSION`, `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`,
   `HERDR_PANE_ID` in its environment (the server sets these at spawn; the
   ids reflect the pane it lands in). A shell in the kaimon space therefore
   sees `HERDR_WORKSPACE_ID=w2`.
2. **`config.fish` runs on interactive shell start**, which is exactly when
   herdr restores a pane — so session restore, or herdr respawning a pane's
   shell, both re-trigger the hook.
3. **The guard prevents double-starts.** kaimon runs as `julia … -m Kaimon`,
   so `pgrep -f 'julia.*-m [K]aimon'` finds the server. The `[K]` bracket is
   the standard trick so the guard's own command line can't match the pattern.
   If a kaimon server is already up (e.g. a second pane opened in the space,
   or a leftover), the hook skips.
4. **Order in the file matters:** the hook sits after `fish_add_path …/.julia/bin`,
   so `kaimon` is on `PATH` when it runs.

Result: restore the session → the kaimon pane's shell boots and launches
kaimon automatically; pi starts clean.

## Verifying / testing

- **Next session start** exercises it end-to-end: `./sandbox.sh` (or
  `./sandbox.sh --session sandbox`), then check the kaimon space has the
  kaimon TUI up.
- **Without restarting the session:** close the kaimon pane — herdr respawns
  its shell, the hook fires, kaimon comes up. (`pgrep` guard means an already
  running kaimon is left alone.)
- **Sanity-check the guard:** `pgrep -af 'julia.*-m [K]aimon'` should print the
  kaimon server's PID.
- **Confirm pane env:** in any pane, `env | grep HERDR` shows the injected
  context (workspace/tab/pane ids).

## Maintenance

- **Workspace id changes.** The hook keys on `w2`. Workspace ids are persisted
  and reused across restarts, but if the kaimon space is ever **closed and
  recreated** it gets a new id (`herdr workspace list` to see it) — update the
  hook or autostart silently stops (harmlessly).
- **Scoping to this session only.** `HERDR_SESSION=sandbox` is set in every
  pane, so the hook can be narrowed with an extra condition, e.g.
  `test "$HERDR_SESSION" = "sandbox"`. Useful if other herdr sessions on this
  machine happen to use workspace id `w2` for something else.
- **Disabling.** Comment out the three-line block (or drop the `and not pgrep`
  guard if you ever want to force a restart on pane respawn).
- **The `julia.*-m [K]aimon` pattern** assumes kaimon runs through the standard
  Julia shim. If the launch command ever changes, update the pattern to match
  the new process's command line (and keep the bracket trick).
