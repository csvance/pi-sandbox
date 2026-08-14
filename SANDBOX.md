# SANDBOX — the bubblewrap policy

The containment layer of this project. `sandbox.sh` is a
[bubblewrap](https://github.com/containers/bubblewrap) policy that launches
[herdr](https://herdr.dev) inside a sandbox. Every pane herdr spawns — pi
sessions included — runs inside the same boundary, so a single policy covers
the whole agent workspace.

## The three axes

Deny-by-default on all three. A leak on any one of them defeats the other two.

| Axis | Mechanism |
| --- | --- |
| **Filesystem** | There is no read-only bind of `/`. The root filesystem is *enumerated*, not inherited: only `/usr`, `/etc`, `/proc`, `/dev`, `/tmp` and the short `ROOT_READONLY` list are visible. `$HOME` is masked with a private tmpfs and rebound one path at a time. |
| **Runtime** | `/run` is a private tmpfs, so the session bus, the keyring ssh/control sockets, the gpg agent socket and any docker socket are unreachable by path. |
| **Environment** | `--clearenv`, then only the names in `ENV_PASS` are re-set. A token exported in the launching shell never enters the sandbox. `ZAI_API_KEY` is the one exception: set unconditionally from the gitignored `secrets/.zai-api-key` file (see "Environment"). |

## The policy

| Mount | Access | Why |
| --- | --- | --- |
| `/usr`, `/etc` | read-only | binaries, libraries, TLS certs, `nsswitch.conf`, `resolv.conf`. `/lib`, `/lib64`, `/bin`, `/sbin` are symlinks into `usr/`. |
| `/proc`, `/dev` | standard | fresh procfs + devtmpfs. `/dev/shm` is a private tmpfs. |
| `/sys` | read-only, toggle | `BIND_SYS=1` by default. See "Why `/sys` is still bound" below. |
| `/run` | **private tmpfs** | host runtime dir masked. `/run/user/$UID` is recreated empty at mode 0700. |
| `ROOT_READONLY` | read-only | the few `/run` and `/var` paths that must come back: DNS (`/run/systemd/resolve`), directory-service NSS sockets, a GPU control socket. Entries that do not exist are skipped. |
| **everything else at `/`** | **invisible** | `/var` (logs, `/var/lib` service state), `/opt`, `/srv`, `/mnt`, `/media`, any mounted volume or network share, and any other user's home. |
| `$HOME` | **private tmpfs** | masked entirely. Only the rows below are bound back in. |
| `~/Git` | read/write | projects. By default the whole tree; see "Per-project agent scoping" for the opt-in narrowed form. |
| `~/.npmrc` | **private seeded copy, read-only** | never the host's file. See "Supply-chain hardening". |
| `~/.nanorc` | **injected fresh, every launch** (plain file in the private tmpfs — not a bind) | nano config, currently `include "/usr/share/nano/markdown.nanorc"`. Written from `NANORC_CONTENT` in `sandbox.sh` via bwrap `--file`; writable during a session, but the host's `~/.nanorc` is never bound or touched and edits vanish with the sandbox. |
| `~/.julia` | read/write | Julia depot (packages, registries, dev'd packages) |
| `~/.juliaup` | read-only | julia binary + toolchains |
| `~/.local/bin` | read-only | CLI symlinks: pi, herdr, claude, uv... |
| `~/.local/lib/node_modules` | read-only | pi's install |
| `~/.config/nvm` | read-only | nvm-managed node, when that is where node lives |
| `~/.local/share/claude/versions` | read-only | claude's real binaries, when `~/.local/bin/claude` is a symlink into it |
| `~/.cargo/bin` | read-only | cargo-installed CLIs. The `bin` leaf only; `~/.cargo` also holds registry tokens. |
| `~/.gitconfig` | read-only | git identity / signing config |
| `~/.config/fish` | read/write | fish config + `fish_variables` (universal vars, fish must write these). Home of the `pi-bwrap` function and the kaimon auto-start hook. |
| `~/.config/herdr` | read/write | herdr `config.toml`, server log |
| `~/.herdr` | read/write | herdr session/data directory |
| `~/.local/state/herdr` | read/write | herdr's agent-detection manifest cache (shared with host herdr; detection profiles, not personal data) |
| `~/.pi/agent` | read/write | pi's agent state (auth, sessions, MCP config, plugins). pi is useless without it. |
| `~/.pi/web-search.json` | **private seeded copy, read-only** | pi web-search provider API keys (openai, brave, exa, jina, ...). The host's file is **never bound**; seeded on every launch from the gitignored `secrets/.web-search.json` (same pattern as `~/.npmrc`). Read-only so the agent can't swap keys mid-session. |
| `~/.config/kaimon` | read/write | Kaimon config: `projects.json`, `extensions.json`, `config.json` |
| `~/.config/mcp` | **private seeded copy, read-only** | MCP server registrations (`mcp.json`) — the host's dir is **never bound**. Seeded from `MCP_DEFAULT` in `sandbox.sh` on first launch (same pattern as `~/.npmrc`; see "Sandbox-private persistent data"). A sandboxed agent can neither read host MCP configs (which may hold other tools' OAuth secrets or `command` entries) nor edit the registrations pi loads. |
| `~/.cache/huggingface`, `~/.cache/uv`, `~/.local/share/uv` | read/write | model and package caches, shared with the host so downloads persist |
| `~/.local/share/fish` | **private persistent copy** | fish history + state, stored at `~/.local/share/pi-sandbox/...`. Sandbox fish can neither read nor write the host's `fish_history`, and the copy survives restarts. |
| `~/.config/gh` | **private persistent copy** | gh CLI auth. The host's real `~/.config/gh` is **never bound** (it may hold a write-scoped token). Provisioned on **every launch** from the repo's gitignored `secrets/.gh-token`; read/write so gh can write `config.yml`, but `hosts.yml` is re-seeded each launch. |
| `XDG_CACHE_HOME` | **private** (`/tmp/xdg-cache`) | Kaimon's cache: ZMQ IPC sockets, `kaimon.db`, agent logs. Redirected so the sandboxed kaimon can never attach to or stomp a kaimon/gate on the host (Kaimon binds fixed socket names with rm-first semantics). |
| `/tmp` | **private tmpfs** | writable, discarded on exit. Host `/tmp` is not visible. Holds the sandbox-private herdr sockets and XDG dirs. |

Read protection is the allowlist itself. There is no separate hide-list.

## Supply-chain hardening

Beyond containment, the sandbox enforces secure defaults for the package
ecosystems agents install from:

- **npm** — the sandbox's `~/.npmrc` is *never* the host's file. It is the
  sandbox's own persistent copy under `~/.local/share/pi-sandbox/.npmrc`,
  seeded on first launch with:

  ```
  ignore-scripts=true
  min-release-age=7
  ```

  and bound **read-only**, so npm inside the sandbox can neither weaken the
  defaults nor write an auth token (`npm login` fails with `EROFS` — by
  design). To change the default: edit `NPMRC_DEFAULT` in `sandbox.sh` and
  delete the private copy once (it re-seeds on the next launch).

  Note on scope: a *project-level* `.npmrc` (npm precedence: CLI > env >
  project > user) can still override these for that project. The ro user file
  blocks drift and token writes; it is not a hard override-proof gate.

- **uv** — `UV_EXCLUDE_NEWER="7 days"` is set unconditionally *after* the
  `ENV_PASS` loop, so a value exported in the launching shell can neither
  widen nor disable it. It gates Python package installs to releases older
  than 7 days (the same 7-day window npm uses). uv's env var also outranks
  project `uv.toml`/`pyproject.toml` config.

- **Why 7 days** — the two classic registry attacks are freshly-published
  typosquats and account-takeover re-publishes. Both are stopped by an age
  gate. npm 12's `min-release-age` is **strict by default**: if no version of
  a dependency satisfies the window, the install hard-errors
  (`ENOVERSIONS`). The old warning-mode toggle (`strict-release-age`, npm
  ≤11) no longer exists in npm 12 — verified absent from both the CLI and the
  docs. uv's `exclude-newer` hard-filters the same way.

## Per-project agent scoping

The blast-radius reducer for agents. Two layers, both opt-in:

### `pi-bwrap` — one agent, one project (recommended)

herdr itself sees **all** of `~/Git` (it is a multiplexer; you want every
project). Each *agent* gets a **nested bwrap** that hides `~/Git` except the
project it was launched in. `pi-bwrap` is a fish function in
`~/.config/fish/config.fish`:

```fish
cd ~/Git/my-project
pi-bwrap          # pi now sees ONLY my-project under ~/Git
```

The nested bwrap re-establishes the base mounts and remasks only `~/Git`:

```
bwrap --unshare-all --share-net --cap-drop ALL --die-with-parent \
    --ro-bind /usr /usr \
    --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --symlink usr/bin /bin --symlink usr/sbin /sbin \
    --ro-bind /etc /etc \
    --ro-bind /sys /sys \
    --proc /proc \
    --bind /dev /dev \
    --bind /tmp /tmp \
    --bind /run /run \
    --bind "$HOME" "$HOME" \
    --tmpfs "$HOME/Git" \
    --bind "$proj" "$proj" \
    -- pi "$@"
```

Two non-obvious facts made this non-trivial:

1. **bwrap's root is a fresh empty tmpfs — the outer sandbox's mounts are
   *not* inherited.** The base mounts must be re-established explicitly or
   even `sh` fails to exec (`bwrap: execvp sh: No such file or directory`).
2. **`/tmp` and `/run` are bound through, not remasked.** The outer `/tmp`
   holds the herdr sockets and XDG dirs pi needs; binding them keeps
   pi↔herdr integration alive. `$HOME` is bound wholesale (it is already the
   sandboxed allowlist view); only `~/Git` is remasked, then the project
   re-exposed.

Guards: outside the sandbox (`HERDR_SESSION != sandbox`), not under `~/Git`,
or a missing project → warns and runs pi unwrapped rather than failing. The
project is the top-level `~/Git/<name>` containing the pane's cwd, so
`~/Git/foo/subdir` scopes to the whole `foo` repo.

### `sandbox-project.sh` — whole-sandbox scoping (optional)

For a stricter variant that scopes the **herdr-level** sandbox to one project
(an agent then can't even see sibling repos in the herdr file tree), set
`SANDBOX_PROJECTS` to a comma-separated list of project dirs:

```bash
./sandbox-project.sh ~/Git/pi-sandbox   # wrapper: hides ~/Git except the given project
```

Unset (the default), the sandbox binds all of `~/Git` as before. The wrapper
validates the project lives under `~/Git` and exists.

On launch the wrapper also **seeds the default `AGENTS.md`** into the project
(copy-if-absent, never overwrite) — the template is the `AGENTS.md` in the
sandbox root (`~/Git/pi-sandbox/AGENTS.md`), which pi auto-loads at startup
for sessions in that project. The template is currently an **empty starting
point**: projects get a file they can fill in with their own rules, and no
stale defaults. A project with its own `AGENTS.md` (or `AGENTS.override.md`,
which pi prefers) is left untouched; edit the sandbox root template to change
the default for future projects. The unscoped `./sandbox.sh` does **not**
seed — it binds all of `~/Git` and must not create files in repos that never
asked for them.

## Usage

```bash
./sandbox.sh                # attach to the sandbox-private herdr session
./sandbox.sh --session X    # any herdr CLI arg passes through
./sandbox.sh --check        # policy probe (run this after every edit)
./sandbox.sh --print-policy # prints the assembled bwrap command
./sandbox-project.sh [dir]  # same, but ~/Git scoped to one project
```

Optional: symlink it into your PATH.

```bash
ln -s "$PWD/sandbox.sh" ~/.local/bin/pi-sandbox
```

## `--check`

Launches the real sandbox on a probe script and reports what the policy
actually produced, rather than what it was meant to produce. It prints the
effective mount table, the top level of `/`, the contents of `/run`, every
entry visible in `$HOME`, the writability of each grant, the surviving
environment (credential-shaped values redacted), and:

```
--- tools on PATH ---
  ok       julia      /home/user/.juliaup/bin/julia
  ok       node       /home/user/.config/nvm/versions/node/v25.2.1/bin/node
  BROKEN   pi         /home/user/.local/bin/pi -> /home/user/.local/lib/... (symlink target not bound in)
  MISSING  gh
```

That section is the one that earns its keep. Under a masked home, "my
toolchain is still intact" is not obvious from the mount list, because half of
it arrives through paths like `~/.local/share/<tool>/versions/<n>` that nobody
thinks to check. `BROKEN` is the characteristic failure: a wrapper in
`~/.local/bin` resolves fine on `PATH` and then fails to exec, because its real
payload lives somewhere unlisted.

It also prints host-side facts that the policy depends on: the bubblewrap
version, `dev.tty.legacy_tiocsti`, and whether an ssh agent is being forwarded
in.

Run it after any policy edit. It turns "run it and see what explodes over the
next week" into a ten second answer.

## Adding paths (the part you'll keep doing)

Four knobs, one line each.

| Want it to be... | Add it to | Notes |
| --- | --- | --- |
| read/write inside `$HOME` | `WRITE_DIRS` | the script `mkdir -p`s it on the host first, so new paths work with no setup |
| read-only inside `$HOME` | `HOME_READONLY` | installed CLIs, configs. Bind the **leaf**, not the parent. |
| visible outside `$HOME` | `ROOT_READONLY` / `ROOT_WRITE_DIRS` | keep both as short as you can |
| invisible | *nothing* | the default: any path not listed is invisible |
| the sandbox's own persistent copy | `PRIVATE_DATA_DIRS` | host version replaced by a private store; survives restarts |

### The one rule

Never bind a whole parent subtree (`~/.config`, `~/.local/share`, `~/.cache`)
without re-masking the credential directories underneath it: add a
`--tmpfs "$path"` for each one immediately after the new bind. Binding
`~/.config` wholesale re-exposes every credential store under it and silently
undoes the entire home mask. Bind the leaf, not the parent.

This applies to read-only binds too, and it is easier to violate there because
read-only feels safe. Read-only still means the agent can read every credential
under the path, and it does not stop `connect()` to a unix socket under it
either (see below).

The rule is repeated as a comment directly above `WRITE_DIRS` and
`HOME_READONLY` in the script, where the edit actually happens.

## Symlinks and nested grants

Two bugs the allowlist model invites, both handled mechanically:

1. **Symlinked entries.** If a listed path is a symlink, the thing actually
   bound is the target, not the name. Every entry is resolved with `realpath`
   first, and both the target and the listed name are bound, so `PATH` entries
   and configs that refer to the name keep working. Resolving first is also
   what makes "is this entry inside a credential directory" a question you can
   answer by looking at the list.
2. **Nested grants.** A read-only entry whose realpath lands strictly inside a
   read-write entry gets layered on top by bwrap and silently makes that
   subtree unwritable. A `~/.julia/bin` symlink into an already-granted cache
   turns the whole depot read-only, and the failure looks like a Julia bug, not
   a policy bug. Such entries are dropped with a warning on stderr.

Read-only binds are also applied *before* read-write ones, so a read-write
grant always wins over an overlapping read-only parent instead of depending on
list order.

## Environment

bwrap passes the parent environment through untouched, so any credential
exported in the launching shell walks straight past the mount allowlist:
`GITHUB_TOKEN`, `ANTHROPIC_API_KEY`, `AWS_*`, `OPENAI_API_KEY`, whatever a
direnv or a sourced `.envrc` put there. No amount of home masking touches it.

`--clearenv` drops everything, then only the names in `ENV_PASS` are re-set
from the parent, and only when non-empty. This is deny-by-default: a new
credential variable is excluded because it is not listed, not because someone
remembered to add it to a scrub list. A name matching `ENV_DENY_REGEX` is
refused with a warning even if it is added to `ENV_PASS`.

One deliberate exception: **`ZAI_API_KEY`** is set unconditionally after the
`ENV_PASS` loop, provisioned from the repo's gitignored `secrets/.zai-api-key`
file (one line, raw key; same model as the other files in `secrets/`). It is
never taken from the parent environment — `ENV_DENY_REGEX` would refuse it
— so the launching shell cannot leak or override it; rotation is a one-line
file edit. `--check` redacts credential-shaped values in its environment
dump, so the provisioned key is not echoed back.

Deliberately not passed:

- every `*TOKEN` / `*KEY` / `*SECRET` / `AWS_*`
- `DBUS_SESSION_BUS_ADDRESS` and `SSH_AUTH_SOCK`. Both would otherwise be
  inherited pointing at paths that no longer exist once `/run` is masked, and a
  program that tries the session bus then gets a confusing connect error
  instead of cleanly concluding there is no bus. `SSH_AUTH_SOCK` is re-set only
  in the branch that actually binds the agent socket, so it never dangles.
- `XDG_RUNTIME_DIR` and `XDG_CACHE_HOME`, re-set to private locations
- `SSH_CLIENT`, `SSH_CONNECTION`, `SSH_TTY`, and any parent `HERDR_*`

If a tool breaks for want of a variable, `--check` prints the surviving
environment, so the missing name is a ten second diagnosis.

## Why a read-only bind is not enough

A read-only bind mount does **not** block `connect()` to a unix socket beneath
it. Verified directly: with `/var/lib/sss` bound read-only, a write into it
fails with `EROFS` and the mount reads `ro` in `mountinfo`, yet NSS lookups
through the socket under it still succeed.

So masking `/run` is a real fix rather than defense in depth. Under a
read-only root bind, everything under `/run` stayed reachable: the session bus,
the keyring ssh and control sockets, the gpg agent socket, and a docker socket
if one is ever installed. Masking `/run/user/$UID` alone closed the most
important door but left the rest of `/run` open.

The same fact means a socket you *do* need can be bound read-only rather than
read-write.

## Why `/sys` is still bound

`BIND_SYS=1` by default. libdrm/DRI device enumeration (GLMakie), hwloc
topology and CUDA device discovery read `/sys`, and it holds kernel and device
state rather than user credentials, so the cost of keeping it is low and the
cost of guessing wrong is a breakage that is hard to attribute. Set `BIND_SYS=0`
and run `--check` plus a real GLMakie or CUDA job before relying on it being
unnecessary.

## `--new-session` and the other cheap flags

Present: `--unshare-all` (pid, ipc, uts, cgroup, user, net, then `--share-net`
hands the network back), `--cap-drop ALL`, `--die-with-parent`, and
`--remount-ro /`.

`--remount-ro /` matters because dropping `--ro-bind / /` leaves bwrap's own
root tmpfs writable, so an agent could `mkdir /whatever`. It is ephemeral and
invisible to the host, but it is a behavior change from the old read-only root,
so the root mount is remounted read-only as the last mount argument. Nested
mounts keep their own flags, so `/tmp`, `$HOME` and every read-write grant stay
writable.

`--new-session` blocks TIOCSTI terminal injection, where a process inside
pushes characters into the launching terminal as if typed. It also removes job
control, which a TUI like herdr needs, so it is a policy toggle
(`NEW_SESSION`) defaulting to **off**. Modern kernels default
`dev.tty.legacy_tiocsti=0`, which closes the same hole without breaking the
TUI; `--check` prints the live sysctl. Only set `NEW_SESSION=1` for
non-interactive use on a host where that sysctl reads 1 and cannot be changed.

## Sensitive paths (never bind them)

Read protection comes from the allowlist alone, so any path not bound in is
invisible. Follow "the one rule" above for every edit. Credential locations
(shell and agent secrets, git token stores, browser profiles, password vaults,
cloud credentials, dotfile secrets) are intentionally not enumerated here.

Four deliberate credential exceptions:

- **pi's agent state** is bound read-write by design. It is pi's own credential
  store, so the allowlist entry must stay.
- **The gh CLI's token store** is provisioned from the repo's gitignored
  `secrets/.gh-token` (see "Sandbox-private persistent data"): the host's
  `~/.config/gh` is never bound, so a write-scoped host token can never leak
  into the sandbox and a sandboxed agent can never touch the host's gh auth.
  The sandbox sees only the read-only token you keep in `secrets/.gh-token`.
- **pi's web-search keys** (`~/.pi/web-search.json`) are a read-only seed
  from the repo's gitignored `secrets/.web-search.json` (see "Sandbox-
  private persistent data"): the host's file is never bound, so the agent
  can neither read host-side keys for other tools nor swap the provisioned
  ones.
- **The ssh agent** is auto-mounted read-only when the parent exports
  `SSH_AUTH_SOCK`, so `git push` works without binding any host SSH state and
  without the private key ever entering the sandbox. Understand what it grants:
  a forwarded agent is a live signing oracle for every host that trusts that
  key, usable by anything inside for as long as it is bound. That is the right
  tradeoff for push convenience, but it is a deliberate exception, not a free
  one. Comment the block out if you do not need to push from inside.

`~/.config/mcp` is **not bound at all** — the sandbox gets a read-only seed
from its private store instead (see "Sandbox-private persistent data"). The
host's file may hold other tools' registrations — including OAuth secrets and
`command` entries that spawn processes — so it is kept out of the sandbox
entirely, and the registrations pi loads cannot be tampered with.

The bind target is created under the masked `/run` by argument ordering, so the
agent socket survives the `/run` tmpfs.

## Writes to unlisted paths now vanish silently

Because `$HOME` is a tmpfs rather than a read-only bind, a write to an unlisted
path inside `$HOME` **succeeds**, lands in the tmpfs, and is discarded when the
sandbox exits. Under a read-only home the same write failed loudly.

"My output file disappeared" is a confusing symptom to debug from scratch. It
means the file was written outside the allowlist. Add its directory to
`WRITE_DIRS`.

## Sandbox-private persistent data

`PRIVATE_DATA_DIRS` gives a path its own persistent copy *inside* the sandbox:
the host version is replaced by a private store under
`~/.local/share/pi-sandbox/` (mirrored path), and the copy survives sandbox
restarts. Unlike `/tmp` (wiped every launch) it is persistent; unlike
`WRITE_DIRS` it is isolated from the host.

The provisioned credentials themselves live in the repo's gitignored
`secrets/` directory (next to `sandbox.sh`) — host-side only, never bound
into the sandbox: `secrets/.gh-token`, `secrets/.web-search.json`,
`secrets/.zai-api-key`.

Currently used for:

- **`~/.local/share/fish`** — the sandboxed fish shell has its own history and
  can neither read nor write the host's `fish_history`. Bash and zsh histories
  are invisible by default, not bound; fish gets the stronger "own copy"
  treatment since it is the shell actually used in panes.
- **`~/.config/gh`** — the gh CLI's auth store, provisioned on **every**
  launch from the repo's gitignored `secrets/.gh-token` (one line, raw
  token; rotation = edit the file and relaunch). The host's real
  `~/.config/gh` is never bound — it may hold a write-scoped token.
  Read/write (gh writes `config.yml`); `hosts.yml` is re-seeded each launch,
  so in-session token changes don't stick. No `secrets/.gh-token` (or an
  empty one) means gh has no token.
- **`~/.pi/web-search.json`** — pi's web-search provider API keys, seeded on
  every launch from the repo's gitignored `secrets/.web-search.json` and
  bound read-only (same pattern as `~/.npmrc`). The host's file is never
  bound.
- **`~/.npmrc`** — the enforced npm config (see "Supply-chain hardening"),
  seeded from `NPMRC_DEFAULT` on first launch and bound read-only.
- **`~/.config/mcp/mcp.json`** — MCP server registrations, seeded from
  `MCP_DEFAULT` on first launch and bound read-only. Same isolation as
  `~/.npmrc`, with an extra edge: mcp.json entries can spawn processes, and
  the host's `~/.config/mcp` may hold other tools' registrations (including
  OAuth secrets), so the sandbox must be able to neither read it nor modify
  the registrations pi loads. The adapter only ever reads this file (its
  overrides go to `.pi/mcp.json` / the agent dir), so read-only costs nothing.

The store is created automatically by the first host-side launch.

## Why herdr works in here

1. **Socket pinning.** herdr's default socket is `~/.config/herdr/herdr.sock`.
   If the sandbox shared that, the sandboxed herdr client would attach to any
   herdr server already running on the host, silently escaping the sandbox.
   `HERDR_SOCKET_PATH` / `HERDR_CLIENT_SOCKET_PATH` are pinned to the private
   `/tmp/herdr/`, so sandboxed herdr and host herdr can never see each other.
2. **Session namespacing.** `~/.herdr` is shared read-write with the host, so
   `HERDR_SESSION=sandbox` namespaces session state and prevents collisions
   with host sessions. Change the name in the script for multiple sandboxes.
3. **Runtime dir redirection.** `XDG_RUNTIME_DIR` points at `/tmp/xdg-runtime`,
   which is private, rather than at the masked host runtime dir.
4. **Whole-tree containment.** `--unshare-pid` makes herdr PID 1 of a new
   process namespace; when it exits, or `--die-with-parent` fires because the
   launching terminal closed, the kernel reaps every pane and pi session.

## Optional extras (in the script, commented)

- **GPU**: `/dev/dri` plus the `/dev/nvidia*` nodes. `/dev` is a fresh
  devtmpfs, so the device nodes must be bound explicitly.
- **GPU broker leases**: read-write bind on the broker's runtime dir, which
  takes lock files.
- **Wayland**: bind the host `wayland-0` socket to `/tmp/wayland-0`
- **X11**: `--ro-bind-try /tmp/.X11-unix /tmp/.X11-unix`
- **Shared host `/tmp`**: replace `--tmpfs /tmp` with `--bind /tmp /tmp`

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Anything unexpected after a policy edit | Run `./sandbox.sh --check` first. It answers most of the rows below directly. |
| `id` or `whoami` fails, git can't determine the author | The account is not in `/etc/passwd` and NSS needs a directory-service socket. Keep `/var/lib/sss` in `ROOT_READONLY`; `--check` prints the resolved user name. |
| DNS fails inside | `/etc/resolv.conf` is a symlink into `/run/systemd/resolve`, which the `/run` mask removes. Keep that entry in `ROOT_READONLY`. |
| A tool is `MISSING` or `BROKEN` in `--check` | Its real payload lives outside the allowlist. Add the leaf directory that holds the binaries to `HOME_READONLY`. |
| A tool cannot find its cache, depot or interpreters | That state may live outside `$HOME` (a per-user cache dir at the root, for instance), which is no longer visible now that `/` is not bound wholesale. Add it to `ROOT_READONLY`, or `ROOT_WRITE_DIRS` if it must be written. |
| An environment variable a tool needs is gone | `--clearenv` is deliberate. Add the name to `ENV_PASS`; `--check` prints what survived. |
| My output file disappeared | It was written to an unlisted path inside the masked `$HOME`, so it landed in the tmpfs and was discarded. Add its directory to `WRITE_DIRS`. |
| `sandbox.sh: dropping read-only 'X': nested inside read-write 'Y'` | Working as intended. `X` resolves inside `Y`, and binding it read-only would have made `Y` unwritable. Remove `X` from `HOME_READONLY`. |
| A herdr pane cannot start a job control TUI | Check `NEW_SESSION`. It must be `0` for interactive use. |
| `herdr update` or `juliaup` self-update fails | `~/.local/bin` and `~/.juliaup` are read-only by design. Update on the host. |
| `./sandbox.sh` prints `herdr: detached from server` | Normal. No server was running, so herdr started one headless and detached. Attach with `./sandbox.sh session attach sandbox` from a plain terminal. |
| `pi-bwrap` says "not inside the sandbox" | `HERDR_SESSION` is not `sandbox`. The function is meant for panes of the sandboxed herdr; outside it runs pi unwrapped by design. |
| `bwrap: execvp <cmd>: No such file or directory` inside `pi-bwrap` | The nested bwrap's root is a fresh empty tmpfs — base mounts are not inherited. The function re-establishes `/usr` + symlinks, `/etc`, `/sys`, `/proc`, `/dev`; if you edit it, keep those lines. |
| `pi-bwrap` can't reach herdr | The nested bwrap must **bind** `/tmp` (and `/run`), not remask them — the herdr sockets live there. |
| I can't see `~/Documents`, `~/Downloads`, `~/.cache`, ... | By design. `$HOME` is masked wholesale; only allowlisted paths are visible. |
| `fish` errors on `set -U` | `~/.config/fish` is bound read-write precisely so universal vars persist. If you still see it, relaunch. |
| `git push` fails | SSH remotes: rely on the auto-mounted agent. HTTPS remotes: token stores are invisible by default, so use SSH remotes or bind the store explicitly. |
| `bwrap: setting up uid map: Invalid argument` | Unprivileged user namespaces disabled (`cat /proc/sys/kernel/unprivileged_userns_clone` reads `0`). Enable it, or switch to a setuid bwrap install. |
| `bwrap: Can't find source path .../pi-sandbox/...` | The `PRIVATE_DATA_DIRS` store does not exist and could not be created. This happens when launching from inside another sandbox where the parent directory is read-only. Launch from the host. |
| A herdr server is already running on the host | No conflict. Different sockets; the sandbox starts its own server. |
| `kaimon` fails with `ZMQ: Read-only file system` | Was `~/.cache/kaimon` read-only. Fixed by redirecting `XDG_CACHE_HOME` to the private `/tmp/xdg-cache`. Consequence: kaimon session state is per-sandbox and resets each launch; config is still shared via `~/.config/kaimon`. |
| GUI or GPU app fails in a pane | Uncomment the Wayland, X11 or `/dev/nvidia*` extras. |
| Sandbox died when I closed the terminal | `--die-with-parent` working as intended. The sandbox lives exactly as long as its launcher. |

## Requirements

- bubblewrap (`pacman -S bubblewrap`, `apt install bubblewrap`, ...)
- kernel with unprivileged user namespaces (the default on Arch, and on
  Ubuntu/Debian/Fedora unless explicitly restricted)

Verified against: herdr 0.8.0, bubblewrap 0.9.0 and 0.11.2, pi from
`~/.local/lib/node_modules/@earendil-works/pi-coding-agent`.
