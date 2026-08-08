# pi-sandbox — bwrap policy for herdr + pi

Launches [herdr](https://herdr.dev) inside a [bubblewrap](https://github.com/containers/bubblewrap)
sandbox. Every pane herdr spawns — including all pi sessions — runs inside
the same boundary, so a single policy covers the whole agent workspace.

## The policy

| Mount | Access | Why |
| --- | --- | --- |
| `/` (host root) | **read-only** | baseline: `/usr`, `/bin`, `/lib`, `/etc` (TLS certs), node — everything readable |
| `$HOME` | **private tmpfs** | home directory is masked entirely. Only the rows below are bound back in; everything else is **invisible** to the sandbox |
| `~/Git` | read/write | your projects |
| `~/.julia` | read/write | Julia depot (packages, registries, dev'd packages) + kaimon launcher |
| `~/.juliaup` | read-only | julia binary + toolchains |
| `~/.local/bin` | read-only | CLI symlinks: pi, herdr, claude, uv… |
| `~/.local/lib/node_modules` | read-only | pi's install |
| `~/.gitconfig` | read-only | git identity / signing config |
| `~/.config/fish` | read/write | fish config + `fish_variables` (universal vars — fish must write these) |
| `~/.config/herdr` | read/write | herdr `config.toml`, server log |
| `~/.herdr` | read/write | herdr session/data directory |
| `~/.local/state/herdr` | read/write | herdr's agent-detection manifest cache (shared with host herdr; detection profiles, not personal data) |
| `~/.pi/agent` | read/write | pi's agent state (auth, sessions, MCP config) — pi is useless without it |
| `~/.config/kaimon` | read/write | Kaimon config: `projects.json`, `extensions.json`, `config.json` |
| `~/.local/share/fish` | **private persistent copy** | fish history + state. Replaced by an isolated copy stored at `~/.local/share/pi-sandbox/…` — sandbox fish can neither read nor write the host's `fish_history`, and the copy survives restarts |
| `XDG_CACHE_HOME` | **private** (`/tmp/xdg-cache`) | Kaimon's cache — ZMQ IPC sockets, `kaimon.db`, agent logs — redirected here so the sandboxed kaimon can never attach to or stomp a kaimon/gate on the host (Kaimon binds fixed socket names with rm-first semantics) |
| `/tmp` | **private tmpfs** | writable, discarded when the sandbox exits; host `/tmp` is *not* visible |
| `/dev`, `/proc`, `/sys` | standard | fresh devtmpfs + procfs; `/dev/shm` is a private tmpfs |

Everything not in the table is invisible (for `$HOME`) or read-only (for the
rest of the host root). herdr, pi, Julia, git read fine from the ro root;
only the listed paths are bound in.

Read protection is the allowlist itself: `$HOME` is masked wholesale, and
only the rows above are bound back in — anything not listed is invisible.
There is no separate hide-list; see "Sensitive paths" below for what must
never be bound.

## Usage

```bash
./sandbox.sh                # attach to the sandbox-private herdr session
./sandbox.sh --session X    # any herdr CLI arg passes through
./sandbox.sh --check        # probe: prints the effective policy, exits
./sandbox.sh --print-policy # prints the assembled bwrap command
```

Optional: symlink it into your PATH.

```bash
ln -s "$PWD/sandbox.sh" ~/.local/bin/pi-sandbox
```

## Adding paths (the part you'll keep doing)

Three knobs, one line each — decide what you want the path to be:

| Want it to be… | Add it to | Notes |
| --- | --- | --- |
| read/write (host dir shared) | `WRITE_DIRS` | the script `mkdir -p`s it on the host first, so new paths work with no setup |
| read-only (visible, never written) | `HOME_READONLY` | installed CLIs, configs — e.g. `"$HOME/.config/<app>"` |
| invisible | *nothing* | default: any path not listed is invisible inside the sandbox |
| the sandbox's OWN persistent copy | `PRIVATE_DATA_DIRS` | host version replaced by a private store; survives restarts |

The script `mkdir -p`s each `WRITE_DIRS` entry on the host before binding, so
paths that don't exist yet (like `~/.herdr` did) work without extra setup.
Keep `HOME_READONLY` disjoint from `WRITE_DIRS` / `PRIVATE_DATA_DIRS` (those
bind the same paths read-write).

## Why herdr works in here (the isolation details)

1. **Socket pinning.** herdr's default socket is `~/.config/herdr/herdr.sock`.
   If the sandbox shared that, the sandboxed herdr client would attach to any
   herdr server already running on the host — silently escaping the sandbox.
   `HERDR_SOCKET_PATH` / `HERDR_CLIENT_SOCKET_PATH` are pinned to the private
   `/tmp/herdr/`, so sandboxed herdr and host herdr can never see each other.
2. **Session namespacing.** `~/.herdr` is shared read-write with the host, so
   `HERDR_SESSION=sandbox` namespaces session state and prevents collisions
   with host sessions. Change the name in the script if you want multiple
   sandboxes.
3. **Runtime dir redirection.** `XDG_RUNTIME_DIR` points at `/tmp/xdg-runtime`
   (private) instead of `/run/user/1000` (read-only in the sandbox).
4. **Whole-tree containment.** `--unshare-pid` makes herdr PID 1 of a new
   process namespace; when it exits (or `--die-with-parent` fires because the
   launching terminal closed), the kernel reaps every pane and pi session.

## Sensitive paths (never bind them)

Read protection comes from the allowlist alone: `$HOME` is masked wholesale,
so **any path not bound in is invisible** — there is no separate hide-list.

Rule for future edits: never bind a whole parent subtree (e.g. `~/.config` or
`~/.local/share`) without re-masking the credential directories it would
re-expose — add a `--tmpfs "$path"` for each one right after the new bind.
Credential locations (shell/agent secrets, git token stores, browser
profiles, password vaults, cloud/portability credentials, dotfile secrets)
are intentionally not enumerated in this document.

Notes:
- SSH remotes work without binding any host SSH state: the agent is
  auto-mounted read-only when the parent exports `SSH_AUTH_SOCK`, so
  `git push` just works.
- pi's agent state is bound read-write by design — it is pi's own
  credential store, so the allowlist entry must stay.

## Sandbox-private persistent data

`PRIVATE_DATA_DIRS` gives a path its own persistent copy *inside* the sandbox:
the host version is replaced by a private store under `~/.local/share/pi-sandbox/`
(mirrored path), and the copy survives sandbox restarts. Unlike `/tmp` (wiped
every launch), this is *persistent*; unlike `WRITE_DIRS`, it is *isolated* from
the host.

Currently: `~/.local/share/fish` — the sandboxed fish shell (your `$SHELL` in
herdr panes) has its own history and can neither read nor write the host's
`~/.local/share/fish/fish_history`. (Bash/zsh histories are invisible by
default — not bound; fish gets the stronger "own copy" treatment since it's
the shell you actually use in panes.) The store is created automatically by the first
host-side launch of the script.

## Optional extras (in the script, commented)

- **GPU** — `--dev-bind-try /dev/dri /dev/dri` (GLMakie / GPU Julia work)
- **Wayland** — bind `$XDG_RUNTIME_DIR/wayland-0` to `/tmp/wayland-0` (GUI apps)
- **X11** — `--ro-bind-try /tmp/.X11-unix /tmp/.X11-unix` (XWayland apps)
- **SSH agent** — mounted automatically when `SSH_AUTH_SOCK` is set; lets
  `git push` work inside pi sessions without binding any host SSH state
- **Shared host /tmp** — replace `--tmpfs /tmp` with `--bind /tmp /tmp`
- **Other runtime sockets** — bind `/run/user/1000` read-write if an app
  insists on the real runtime dir (weaker isolation; prefer redirection)

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `herdr update` fails | `~/.local/bin` is read-only by design. Update on the host, outside the sandbox. |
| `./sandbox.sh` prints `herdr: detached from server` | Normal — no server was running, so herdr started one headless and detached. Attach the TUI with `./sandbox.sh session attach sandbox` (from a plain terminal; inside a herdr pane a nested TUI detaches the same way). |
| `juliaup` self-update fails | `~/.juliaup` is read-only by design (same reason). Update on the host. |
| I can't see `~/Documents`, `~/Downloads`, `~/.cache`, … | By design — `$HOME` is masked wholesale; only allowlisted paths are visible. Add the path to `WRITE_DIRS`/`HOME_READONLY` if you need it. |
| `fish` errors on `set -U` (fish_variables) | `~/.config/fish` is bound read-write precisely so universal vars persist. If you still see it, the sandbox predates the change — relaunch. |
| `git push` fails | SSH remotes: rely on the auto-mounted SSH agent, or bind your SSH state explicitly. HTTPS remotes: token stores are invisible by default (not bound) — bind them explicitly or use SSH remotes. |
| `bwrap: setting up uid map: Invalid argument` | Unprivileged user namespaces disabled (`cat /proc/sys/kernel/unprivileged_userns_clone` → `0`). Enable it, or switch to a setuid bwrap install. |
| A herdr server is already running on the host | No conflict — different sockets, verified. The sandbox starts its own server. |
| `kaimon` fails with `ZMQ: Read-only file system` | Was: `~/.cache/kaimon` read-only. Fixed by redirecting `XDG_CACHE_HOME` to the private `/tmp/xdg-cache` (sockets, `kaimon.db`, logs). Consequence: kaimon session state is per-sandbox and resets each launch; config (`projects.json`) is still shared via `~/.config/kaimon`. |
| fish prints `Unable to create temporary file ... fish_history` | Was: `~/.local/share/fish` read-only. Now bound to a sandbox-private persistent copy (`PRIVATE_DATA_DIRS`): sandbox fish history is isolated from the host's and survives restarts. If sandbox history looks "empty", that's the point — it's a fresh, separate history. |
| pi has no credentials | pi's agent state directory missing from `WRITE_DIRS` or commented out — keep it bound. |
| GUI/GPU app fails in a pane | Uncomment the Wayland/X11/`/dev/dri` extras above. |
| Sandbox died when I closed the terminal | That's `--die-with-parent` working as intended: the sandbox lives exactly as long as its launcher. |

## Requirements

- bubblewrap (`pacman -S bubblewrap`, `apt install bubblewrap`, …)
- kernel with unprivileged user namespaces (the default on Arch, and on
  Ubuntu/Debian/Fedora unless explicitly restricted)

Verified against: herdr 0.8.0, bubblewrap 0.11.2, pi from
`~/.local/lib/node_modules/@earendil-works/pi-coding-agent`.
