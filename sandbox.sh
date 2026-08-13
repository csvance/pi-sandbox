#!/usr/bin/env bash
#
# sandbox.sh: bubblewrap policy for herdr (terminal workspace manager) + pi
#
# Deny-by-default on three independent axes. All three matter: a leak on any
# one of them defeats the other two.
#
#   FILESYSTEM   There is NO read-only bind of /. Only the paths listed in
#                ROOT_READONLY / ROOT_WRITE_DIRS (outside $HOME) and the three
#                $HOME allowlists are visible. Everything else (/var, /opt,
#                /srv, /mnt, /media, mounted network shares, other users'
#                homes) is INVISIBLE, not merely read-only.
#   RUNTIME      /run is a private tmpfs. The host session bus, the keyring
#                ssh/control sockets, the gpg agent socket and (if ever
#                installed) the docker socket are not reachable by path.
#                A read-only bind does NOT block connect() to a unix socket
#                beneath it, verified on this kernel, so masking /run is a
#                real fix, not defense in depth.
#   ENVIRONMENT  --clearenv: only names in ENV_PASS survive. A credential
#                exported in the launching shell (GITHUB_TOKEN, AWS_*,
#                ANTHROPIC_API_KEY, anything a direnv put there) never enters
#                the sandbox, regardless of the mount policy.
#
# $HOME is masked with a private tmpfs and rebound one path at a time:
#   - WRITE_DIRS         read-write: Julia depot, projects, agent credentials
#   - HOME_READONLY      read-only: installed CLIs + configs (pi, herdr, julia…)
#   - PRIVATE_DATA_DIRS  the sandbox's OWN persistent copies of a path
# (plus /tmp, a fresh private tmpfs). herdr runs inside the sandbox, so every
# pane it spawns, including all pi sessions, inherits the same boundary.
#
# Usage:
#   ./sandbox.sh                # launch herdr inside the sandbox (attach to
#                               # the sandbox-private session)
#   ./sandbox-project.sh        # same, but hide ~/Git except the project you
#                               #   launch from (per-project agent isolation)
#   ./sandbox.sh --session X    # any herdr CLI args pass through
#   ./sandbox.sh --check        # policy probe: mounts, visible $HOME, tools
#                               # on PATH, surviving env. Run after ANY edit.
#   ./sandbox.sh --print-policy # print the assembled bwrap command
#
# Adding a path is a one-line change: append it to WRITE_DIRS below.
# (Optional extras for GPU, Wayland and the SSH agent are right after.)
#
# Requires: bubblewrap on a kernel with unprivileged user namespaces enabled
# (check: cat /proc/sys/kernel/unprivileged_userns_clone  -> 1).

set -euo pipefail

# ===========================================================================
# POLICY TOGGLES
# ===========================================================================

# Bind /sys read-only. Kept ON by default: libdrm/DRI device enumeration
# (GLMakie), hwloc topology and CUDA device discovery read it, and it holds
# kernel/device state rather than user credentials, so the cost of keeping it
# is low and the cost of guessing wrong is a hard-to-attribute breakage.
# Set to 0 and run --check + a real GLMakie/CUDA job to confirm before relying
# on it being unnecessary.
BIND_SYS="${BIND_SYS:-1}"

# --new-session blocks TIOCSTI terminal injection, but it also removes job
# control, which a TUI like herdr needs. Left OFF: modern kernels default
# dev.tty.legacy_tiocsti=0, which closes the same hole without breaking the
# TUI. --check prints the live sysctl so you can confirm. Only set this to 1
# for non-interactive use where the sysctl reads 1 and cannot be changed.
NEW_SESSION="${NEW_SESSION:-0}"

# ===========================================================================
# ROOT-LEVEL FILESYSTEM: everything visible OUTSIDE $HOME.
#
# /usr, /etc, /proc, /dev and /tmp are unconditional (assembled in ARGS
# below). This list is for everything else, and it is deliberately short: a
# path that is not here is invisible, not read-only. Entries that do not exist
# are skipped silently, so the list stays portable across hosts.
#
# Before adding: is this path shared with other users? A read-only bind still
# lets the agent READ every byte under it, and still lets it connect() to any
# unix socket under it.
# ===========================================================================
ROOT_READONLY=(
  "/var/lib/sss"          # NSS client sockets, for hosts where accounts come
                          #   from a directory service rather than /etc/passwd
                          #   (nsswitch.conf lists `sss`). Without it `id`,
                          #   `whoami`, git author lookup and every getpwuid()
                          #   inside the sandbox fail. Skipped silently when
                          #   absent, which is the usual case on a single-user
                          #   machine. Read-only is enough: connect() to a unix
                          #   socket works through a read-only bind.
                          #   `--check` prints the resolved user name, so you
                          #   find out immediately if this is needed.
  "/run/systemd/resolve"  # DNS. /etc/resolv.conf is a symlink into here, so
                          #   without it name resolution fails inside. Only
                          #   needed on systemd-resolved hosts; skipped
                          #   silently elsewhere.
  "/run/nvidia-persistenced"  # nvidia-persistenced control socket (device
                          #   adjacent; harmless without the /dev/nvidia*
                          #   binds in the GPU extras below).

  # Toolchain state that lives OUTSIDE $HOME is the thing most easily missed
  # now that / is not bound wholesale, such as a per-user cache dir at the root that
  # JULIA_DEPOT_PATH / UV_PYTHON_INSTALL_DIR / MPLCONFIGDIR point into, for
  # example. `--check` is what tells you: if a tool reports MISSING or BROKEN,
  # or Julia can't find its depot, add the directory here.
  # "/cache/$(id -un)"

  # NOTE: /var (logs, /var/lib service state), /opt, /srv, /mnt, /media, any
  # mounted volume or network share, and any other user's home are deliberately
  # absent. Under the old `--ro-bind / /` every one of them was fully readable
  # from inside the sandbox. That is the difference between "the agent cannot
  # read my home" and "the agent cannot read the machine".
)

# Root-level paths the sandbox may WRITE. Keep this as close to empty as you
# can; prefer $HOME/WRITE_DIRS. Every entry here is shared with the host and,
# unlike $HOME, is not covered by the home mask.
ROOT_WRITE_DIRS=(
  # "/cache/$(id -un)"    # promote the per-user cache above to read-write if
                          #   Julia Pkg operations or `uv python install`
                          #   need to write the depot / interpreter store.
)

# ===========================================================================
# PROJECT SCOPING (opt-in blast-radius reduction).
# By default the sandbox binds ALL of $HOME/Git read-write. Set
# SANDBOX_PROJECTS to a comma-separated list of project dirs (each must live
# under $HOME/Git) to bind ONLY those instead of the whole tree — an agent in
# such a sandbox never even sees sibling repos. The wrapper sandbox-project.sh
# sets this from the directory the user launches in. Leave unset for the
# default behaviour.
# ===========================================================================
SANDBOX_PROJECTS="${SANDBOX_PROJECTS:-}"
if [[ -n "$SANDBOX_PROJECTS" ]]; then
  IFS=',' read -r -a GIT_BIND_DIRS <<< "$SANDBOX_PROJECTS"
else
  GIT_BIND_DIRS=("$HOME/Git")
fi

# ===========================================================================
# THE POLICY: paths herdr/pi may READ + WRITE inside $HOME.
# Add entries freely; the script mkdirs them on the host if they don't exist.
# Use absolute paths with $HOME expanded.
#
# !! NEVER bind a whole parent subtree (~/.config, ~/.local/share, ~/.cache)
# !! without re-masking the credential directories underneath it: add a
# !! `--tmpfs "$path"` for each one immediately after the new bind. Binding
# !! ~/.config wholesale re-exposes every credential store under it and
# !! silently undoes the entire home mask. Bind the leaf, not the parent.
# ===========================================================================
WRITE_DIRS=(
  "$HOME/.julia"          # Julia depot: packages, registries, dev'd packages
  "$HOME/.herdr"          # herdr session/data directory
  "$HOME/.local/state/herdr"  # herdr's agent-detection manifest cache
                          #   (the host herdr shares this dir too). The sandbox
                          #   runs without it, but then herdr can't cache
                          #   updated detection profiles and logs a WARN at
                          #   server start. Detection profiles, not personal
                          #   data.
  "${GIT_BIND_DIRS[@]}"   # projects (SANDBOX_PROJECTS-scoped; default: all of ~/Git)
  "$HOME/.config/herdr"   # herdr config.toml + server log
  # ~/.config/mcp is deliberately NOT here. MCP registrations are a read-only
  # seed from the private store (see the mcp.json seed block below), never the
  # host's dir: an rw bind would let a sandboxed agent read AND rewrite host
  # MCP configs, and mcp.json entries can spawn processes.
  "$HOME/.pi/agent"       # pi auth (auth.json), sessions, mcp config
                          #   Without this, pi has no API keys and can't
                          #   persist sessions. Drop it only if you plan to
                          #   provision credentials inside the sandbox.
  "$HOME/.config/kaimon"  # Kaimon config: projects.json, extensions.json,
                          #   config.json (the TUI writes these)
                          # Kaimon's CACHE (~/.cache/kaimon: ZMQ IPC sockets,
                          #   kaimon.db, agent logs) is deliberately NOT bound.
                          #   XDG_CACHE_HOME is redirected to the private
                          #   /tmp/xdg-cache below, so the sandboxed kaimon can
                          #   never collide with or attach to a kaimon/gate on
                          #   the host. Kaimon binds FIXED socket names with
                          #   rm-first semantics, so sharing them would be an
                          #   escape hatch (same reasoning as HERDR_SOCKET_PATH).
  "$HOME/.config/fish"    # fish shell config + fish_variables (universal
                          #   vars / abbreviations; fish needs to WRITE
                          #   these; read-only makes `set -U` error out).
                          #   Want full isolation? Move it to PRIVATE_DATA_DIRS.
  # ~/.local/share/fish is intentionally NOT here; the sandbox fish gets its
  # own persistent history copy instead (see PRIVATE_DATA_DIRS below).
  "$HOME/.cache/huggingface"  # HF model/dataset cache, shared read-write with
                          #   the host, so downloads persist across launches
                          #   (HF_HOME points here; see the env section below).
  "$HOME/.local/share/uv" # uv-managed Python toolchains, shared read-write
                          #   with the host, so sandboxed uv sees (and installs)
                          #   the same interpreters as host uv; .venv symlinks
                          #   into this dir keep resolving
  "$HOME/.cache/uv"       # uv's package cache, persistent across launches
                          #   (avoids re-downloading torch/timm every relaunch;
                          #   UV_CACHE_DIR is pinned to it below)
)

# /tmp is a PRIVATE tmpfs: writable, but contents vanish when the sandbox
# exits and nothing from the host /tmp is visible. To share the HOST /tmp
# instead, replace "--tmpfs /tmp" in ARGS below with "--bind /tmp /tmp".
#
# Because $HOME is a tmpfs rather than a read-only bind, a write to an
# UNLISTED path inside $HOME now SUCCEEDS, lands in the tmpfs, and is
# discarded when the sandbox exits. Under a read-only home the same write
# failed loudly. If an output file "disappeared", it was written outside the
# allowlist. Add its directory to WRITE_DIRS.

# ===========================================================================
# HOME READ-ONLY ALLOWLIST: installed tooling and configs that must be
# visible inside the sandbox but never written. Everything else under $HOME
# is invisible (see the --tmpfs $HOME mask in ARGS). Absent paths are skipped
# silently. Uncomment lines as you need them.
#
# !! Same rule as WRITE_DIRS, and it is easier to violate here because a
# !! read-only bind feels safe: read-only still means the agent can READ every
# !! credential under the path. Never list ~/.config or ~/.local/share
# !! wholesale. List the leaf that holds the binary or config you need.
#
# A dangling PATH entry is the characteristic failure of a masked home: a
# symlink in ~/.local/bin whose target lives somewhere unlisted resolves fine
# on PATH and then fails to exec. `--check` lists every tool it cannot
# resolve, including this case. Run it after editing.
# ===========================================================================
HOME_READONLY=(
  "$HOME/.local/bin"                  # CLI symlinks: pi, herdr, claude, uv...
  "$HOME/.local/lib/node_modules"     # pi's install (npm global @earendil-works)
  "$HOME/.juliaup"                    # julia binary + toolchains (read-only:
                                      #   juliaup self-update fails, by design)
  "$HOME/.gitconfig"                  # git identity/signing config
  # The three below cover the dangling-PATH case: a wrapper in ~/.local/bin
  # whose real payload lives elsewhere under $HOME. Each is skipped silently
  # when absent, so they are safe to leave listed on a host that installs
  # these tools differently; `--check` is the authority on whether they are
  # doing anything. Each is bound at the LEAF that holds the binaries.
  "$HOME/.config/nvm"                 # nvm-managed node: the interpreter lives
                                      #   at versions/node/<v>/bin, which PATH
                                      #   and NVM_BIN point at, and pi is a
                                      #   node app. A public git checkout; no
                                      #   credentials under it.
  "$HOME/.local/share/claude/versions"  # claude's real binaries when
                                      #   ~/.local/bin/claude is a symlink into
                                      #   here. The `versions` leaf, not the
                                      #   parent.
  "$HOME/.cargo/bin"                  # cargo-installed CLIs. The `bin` leaf
                                      #   ONLY, because ~/.cargo also holds
                                      #   credentials.toml (registry tokens).
)

# ===========================================================================
# SANDBOX-PRIVATE PERSISTENT DATA: the host version is REPLACED inside the
# sandbox by a private copy that persists across launches.
# The sandboxed fish shell reads/writes ONLY this copy: it can neither read
# nor write the host's ~/.local/share/fish/fish_history. The private copy is
# stored on the host under $PRIVATE_DATA_ROOT (mirrored path), so it survives
# sandbox restarts; unlike /tmp, it is NOT wiped each launch.
# ===========================================================================
PRIVATE_DATA_DIRS=(
  "$HOME/.local/share/fish"   # fish shell history + state (your $SHELL in herdr panes)
)
PRIVATE_DATA_ROOT="$HOME/.local/share/pi-sandbox"

# ===========================================================================
# ENVIRONMENT ALLOWLIST.
# bwrap passes the parent environment through untouched, so a token exported
# in the launching shell walks straight past every mount decision. --clearenv
# drops everything; only the NAMES below are re-set from the parent, and only
# when non-empty. This is deny-by-default: a new credential variable is
# excluded because it is not listed, not because someone remembered to add it
# to a scrub list.
#
# Deliberately NOT passed: every *TOKEN/*KEY/*SECRET (GH_TOKEN, GITHUB_TOKEN,
# ANTHROPIC_API_KEY, OPENAI_API_KEY, AWS_*), DBUS_SESSION_BUS_ADDRESS and
# SSH_AUTH_SOCK (both would dangle once /run is masked; SSH_AUTH_SOCK is
# re-set below only if the agent socket is actually bound in), XDG_RUNTIME_DIR
# / XDG_CACHE_HOME (re-set to private locations), SSH_CLIENT / SSH_CONNECTION
# / SSH_TTY, and any HERDR_* from the parent (re-pinned below).
# ===========================================================================
ENV_PASS=(
  HOME USER LOGNAME SHELL TERM COLORTERM LANG TZ
  EDITOR VISUAL PAGER GIT_EDITOR
  PATH                    # references home paths that the allowlists bind
  # TLS trust: custom CA bundle, if set. Values point into /etc, which is bound.
  SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE REQUESTS_CA_BUNDLE
  NODE_EXTRA_CA_CERTS
  # toolchains
  NVM_DIR NVM_BIN NVM_INC
  JULIA_DEPOT_PATH JULIA_PKG_SERVER JULIA_NUM_THREADS JULIA_CPU_TARGET
  UV_NATIVE_TLS UV_SYSTEM_CERTS UV_PYTHON_INSTALL_DIR
  MPLCONFIGDIR
  CUDA_VISIBLE_DEVICES
)
# LC_* is passed by prefix (locale only, never credential-bearing).
ENV_PASS_PREFIXES=(LC_)
# Refuse to pass a credential-shaped NAME even if it is added to ENV_PASS
# above. Cheap guard against the obvious footgun.
ENV_DENY_REGEX='(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|CREDENTIAL|_KEY$|^AWS_)'

# Tools --check verifies are still resolvable on PATH inside the sandbox.
# Under a masked home "my toolchain is intact" is NOT obvious from the mount
# list, because half of it arrives through paths like
# ~/.local/share/<tool>/versions/<n> that nobody thinks to check.
CHECK_TOOLS=(herdr pi claude julia node npm uv git python3 fish)

# ===========================================================================
# OPTIONAL EXTRA MOUNTS: uncomment as needed
# ===========================================================================
EXTRA_ARGS=()

# GPU access (for GLMakie / GPU work in Julia sessions). /dev is a fresh
# devtmpfs, so the nvidia device nodes must be bound explicitly:
# EXTRA_ARGS+=(--dev-bind-try /dev/dri /dev/dri)
# EXTRA_ARGS+=(--dev-bind-try /dev/nvidiactl /dev/nvidiactl)
# EXTRA_ARGS+=(--dev-bind-try /dev/nvidia-uvm /dev/nvidia-uvm)
# EXTRA_ARGS+=(--dev-bind-try /dev/nvidia0 /dev/nvidia0)
# GPU broker leases (needs WRITE: it takes lock files under locks/):
# EXTRA_ARGS+=(--bind-try /run/gpu-broker /run/gpu-broker)

# Wayland socket for GUI apps (target is sandbox-side; XDG_RUNTIME_DIR is
# redirected to the private /tmp, so /tmp/wayland-0 is the right mount point):
# EXTRA_ARGS+=(--ro-bind-try "/run/user/$(id -u)/wayland-0" /tmp/wayland-0)

# X11 sockets (XWayland) for GUI apps:
# EXTRA_ARGS+=(--ro-bind-try /tmp/.X11-unix /tmp/.X11-unix)

# SSH agent, mounted automatically when the parent has one, and the target is
# recreated under the masked /run so the bind survives (see ARGS ordering).
# SSH_AUTH_SOCK is re-exported ONLY in this branch, so it never dangles.
#
# Understand what this grants: a forwarded agent is a live signing oracle for
# every host that trusts that key, usable by anything in the sandbox for as
# long as it is bound. It is the right tradeoff for `git push` convenience,
# it beats binding ~/.ssh, and the private key itself never enters the
# sandbox, but it is a deliberate credential exception, like ~/.pi/agent.
# Comment this block out if you do not need to push from inside.
SSH_AGENT_BOUND=0
if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK:-}" ]]; then
  EXTRA_ARGS+=(--ro-bind-try "$SSH_AUTH_SOCK" "$SSH_AUTH_SOCK")
  SSH_AGENT_BOUND=1
fi

# ===========================================================================
# Sandbox-private herdr runtime.
# HERDR_SOCKET_PATH / HERDR_CLIENT_SOCKET_PATH pin the server + client sockets
# to the private /tmp so the sandboxed herdr can NEVER attach to a herdr
# server running on the host (and the host herdr can't see the sandbox one).
# HERDR_SESSION namespaces session state under ~/.herdr (which is shared
# read-write with the host), so sandbox sessions can't collide with host ones.
# ===========================================================================
HERDR_SANDBOX_SESSION="sandbox"

# ===========================================================================
# PATH RESOLUTION + NESTED-GRANT REJECTION.
#
# Two bugs the allowlist model invites, both worth catching mechanically:
#
#  1. If an entry is a symlink, the thing actually bound is the TARGET, not
#     the name. Resolving first is what makes "is this entry inside a
#     credential directory" a question you can answer by looking at the list.
#  2. A read-only entry whose realpath lands strictly inside a read-write
#     entry gets layered on top by bwrap and silently makes that subtree
#     unwritable. A ~/.julia/bin symlink into an already-granted cache
#     turns the whole depot read-only, and the failure looks like a Julia bug,
#     not a policy bug. Such entries are dropped with a warning.
#
# Read-only binds are also applied BEFORE read-write ones (see ARGS assembly),
# so a read-write grant always wins over an overlapping read-only parent
# instead of depending on list order.
# ===========================================================================
resolved_path() { realpath -m -- "$1"; }

# is $1 strictly inside $2 ?
path_inside() {
  local child="$1" parent="$2"
  [[ "$child" != "$parent" && "$child" == "$parent"/* ]]
}

warn() { printf 'sandbox.sh: %s\n' "$*" >&2; }

# Resolve a list into REPLY_PATHS as "listed<TAB>realpath" pairs, skipping
# absent entries (when $2 = skip-absent) and de-duplicating by realpath.
declare -a REPLY_PATHS
resolve_list() {
  local -n _src="$1"; local mode="${2:-skip-absent}"
  local -A seen=(); local p rp
  REPLY_PATHS=()
  for p in "${_src[@]}"; do
    [[ -z "$p" ]] && continue
    [[ "$mode" == skip-absent && ! -e "$p" ]] && continue
    rp="$(resolved_path "$p")"
    [[ -n "${seen[$rp]:-}" ]] && continue
    seen[$rp]=1
    REPLY_PATHS+=("$p"$'\t'"$rp")
  done
}

# ===========================================================================
# ASSEMBLE THE BWRAP COMMAND
# ===========================================================================
RUNTIME_DIR="/run/user/$(id -u)"

ARGS=(
  --unshare-all                    # pid, ipc, uts, cgroup, user, net…
  --share-net                      # …then hand network back
  --cap-drop ALL
  --die-with-parent
  # No `--ro-bind / /`. The root filesystem is enumerated, not inherited.
  --ro-bind /usr /usr
  --symlink usr/lib /lib
  --symlink usr/lib64 /lib64
  --symlink usr/bin /bin
  --symlink usr/sbin /sbin
  --ro-bind /etc /etc              # TLS certs, nsswitch.conf, resolv.conf
  --proc /proc
  --dev /dev
  --tmpfs /dev/shm
  --tmpfs /tmp                     # private, writable /tmp
  # Mask ALL of /run, not just the session runtime dir: the host system bus,
  # the keyring ssh/control sockets, the gpg agent socket and a docker socket
  # all live under /run, and a read-only bind does not stop connect() to them.
  # ROOT_READONLY rebinds only the few that must come back (DNS, GPU).
  --tmpfs /run
  --perms 0700 --dir "$RUNTIME_DIR"
  --dir /tmp/herdr                 # sandbox-private herdr socket dir
  --dir /tmp/xdg-runtime
  --dir /tmp/xdg-cache
)

[[ "$NEW_SESSION" == 1 ]] && ARGS+=(--new-session)
[[ "$BIND_SYS" == 1 && -d /sys ]] && ARGS+=(--ro-bind /sys /sys)

# --- root-level read-only entries -----------------------------------------
resolve_list ROOT_READONLY
ROOT_RO_RESOLVED=("${REPLY_PATHS[@]}")
resolve_list ROOT_WRITE_DIRS
ROOT_RW_RESOLVED=("${REPLY_PATHS[@]}")

for entry in "${ROOT_RO_RESOLVED[@]}"; do
  listed="${entry%%$'\t'*}"; real="${entry##*$'\t'}"
  skip=0
  for w in "${ROOT_RW_RESOLVED[@]}"; do
    if path_inside "$real" "${w##*$'\t'}"; then
      warn "dropping read-only '$listed' -> '$real': nested inside read-write '${w%%$'\t'*}' (would make that subtree unwritable)"
      skip=1; break
    fi
  done
  [[ $skip == 1 ]] && continue
  ARGS+=(--ro-bind "$real" "$real")
  [[ "$listed" != "$real" ]] && ARGS+=(--ro-bind "$real" "$listed")
done

for entry in "${ROOT_RW_RESOLVED[@]}"; do
  listed="${entry%%$'\t'*}"; real="${entry##*$'\t'}"
  ARGS+=(--bind "$real" "$real")
  [[ "$listed" != "$real" ]] && ARGS+=(--bind "$real" "$listed")
done

# --- environment ----------------------------------------------------------
# --clearenv first, then re-set the allowlist. Order matters: bwrap applies
# these sequentially, so a --setenv before --clearenv would be discarded.
ARGS+=(--clearenv)

env_pass_var() {
  local name="$1" val="${!1:-}"
  [[ -z "$val" ]] && return 0
  if [[ "$name" =~ $ENV_DENY_REGEX ]]; then
    warn "refusing to pass credential-shaped variable '$name' through to the sandbox"
    return 0
  fi
  ARGS+=(--setenv "$name" "$val")
}

for _var in "${ENV_PASS[@]}"; do env_pass_var "$_var"; done
for _prefix in "${ENV_PASS_PREFIXES[@]}"; do
  while IFS='=' read -r _name _; do
    [[ "$_name" == "$_prefix"* ]] && env_pass_var "$_name"
  done < <(env)
done

# Display env vars: the TUI doesn't need them; GUI apps launched from panes do.
[[ -n "${WAYLAND_DISPLAY:-}" ]] && ARGS+=(--setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY")
[[ -n "${DISPLAY:-}" ]] && ARGS+=(--setenv DISPLAY "$DISPLAY")

# SSH_AUTH_SOCK is re-exported only when the socket was actually bound above,
# so it never points at a path the /run mask removed.
[[ "$SSH_AGENT_BOUND" == 1 ]] && ARGS+=(--setenv SSH_AUTH_SOCK "$SSH_AUTH_SOCK")

ARGS+=(
  --setenv XDG_RUNTIME_DIR /tmp/xdg-runtime
  --setenv XDG_CACHE_HOME /tmp/xdg-cache  # private kaimon cache: IPC sockets,
                                         #   kaimon.db, agent/extension logs
  --setenv HF_HOME "$HOME/.cache/huggingface"  # HF hub cache -> shared,
                                         #   persistent dir (bound read-write
                                         #   above), so downloads survive
                                         #   relaunches and are visible to
                                         #   host-side HF tools
  --setenv UV_CACHE_DIR "$HOME/.cache/uv"  # uv package cache -> shared,
                                         #   persistent dir (bound read-write
                                         #   above); without this the
                                         #   XDG_CACHE_HOME redirect would
                                         #   make uv's cache ephemeral
  --setenv HERDR_SOCKET_PATH /tmp/herdr/herdr.sock
  --setenv HERDR_CLIENT_SOCKET_PATH /tmp/herdr/herdr-client.sock
  --setenv HERDR_SESSION "$HERDR_SANDBOX_SESSION"
)

# uv: FORCE excluding package releases newer than 7 days (uv accepts "7 days").
# Set unconditionally AFTER the ENV_PASS loop so it wins over any value
# exported in the launching shell — the sandbox is secure by default and the
# window cannot be widened from outside. (Processes inside the sandbox can
# still override their own env, as with every other policy pin.) Tune the age
# by editing the "7 days" string here.
ARGS+=(--setenv UV_EXCLUDE_NEWER "7 days")

# --- $HOME ----------------------------------------------------------------
# Mask $HOME entirely: a private, writable, EPHEMERAL tmpfs. Nothing from the
# host home directory is visible until bound back in. Must come BEFORE every
# $HOME subtree bind. Writes to unlisted paths here vanish on exit.
ARGS+=(--tmpfs "$HOME")

# Resolve the three home lists, then apply READ-ONLY before READ-WRITE so a
# read-write grant always wins over an overlapping read-only parent.
resolve_list HOME_READONLY
HOME_RO_RESOLVED=("${REPLY_PATHS[@]}")

# WRITE_DIRS are mkdir'd on the host first, so new paths work with no setup.
# A path that can't be created is warned about and skipped rather than fatal:
# that happens when the script is run from INSIDE an existing sandbox, where
# the parent of a not-yet-created entry is read-only, and aborting there would
# make --check unusable in exactly the situation you want to debug.
for dir in "${WRITE_DIRS[@]}"; do
  [[ -z "$dir" ]] && continue
  [[ -e "$dir" ]] && continue
  mkdir -p "$dir" 2>/dev/null || warn "cannot create WRITE_DIRS entry '$dir', skipping (it will be absent inside the sandbox)"
done
resolve_list WRITE_DIRS
HOME_RW_RESOLVED=("${REPLY_PATHS[@]}")

for dir in "${PRIVATE_DATA_DIRS[@]}"; do
  [[ -z "$dir" ]] && continue
  private="$PRIVATE_DATA_ROOT${dir#"$HOME"}"
  # mkdir is a no-op once the store exists. If it can't be created (e.g. the
  # script is run inside an existing sandbox where ~/.local/share is read-only),
  # don't abort: bwrap's --bind will fail below with a clear source-path error.
  # The store is normally created by the host-side launch of this script.
  mkdir -p "$private" "$dir" 2>/dev/null || true
done

# Read-only home allowlist, minus any entry nested inside a read-write grant.
for entry in "${HOME_RO_RESOLVED[@]}"; do
  listed="${entry%%$'\t'*}"; real="${entry##*$'\t'}"
  skip=0
  for w in "${HOME_RW_RESOLVED[@]}" "${ROOT_RW_RESOLVED[@]}"; do
    if path_inside "$real" "${w##*$'\t'}"; then
      warn "dropping read-only '$listed' -> '$real': nested inside read-write '${w%%$'\t'*}' (would make that subtree unwritable)"
      skip=1; break
    fi
  done
  [[ $skip == 1 ]] && continue
  ARGS+=(--ro-bind "$real" "$real")
  # If the listed name is a symlink, make the NAME resolve too, not just the
  # target: PATH entries and configs refer to the name.
  [[ "$listed" != "$real" ]] && ARGS+=(--ro-bind "$real" "$listed")
done

# Writable policy paths. Applied after the read-only set, so these win.
for entry in "${HOME_RW_RESOLVED[@]}"; do
  listed="${entry%%$'\t'*}"; real="${entry##*$'\t'}"
  ARGS+=(--bind "$real" "$real")
  [[ "$listed" != "$real" ]] && ARGS+=(--bind "$real" "$listed")
done

# Sandbox-private persistent copies win over everything above: inside the
# sandbox the path points at the private store, not the host dir. The store
# path mirrors the original under PRIVATE_DATA_ROOT
# (e.g. ~/.local/share/fish -> <root>/.local/share/fish).
for dir in "${PRIVATE_DATA_DIRS[@]}"; do
  [[ -z "$dir" ]] && continue
  private="$PRIVATE_DATA_ROOT${dir#"$HOME"}"
  ARGS+=(--bind "$private" "$dir")
done

# --- ~/.npmrc: enforced secure default; the host's config is NEVER bound -----
# The host's ~/.npmrc is deliberately not mounted: the sandbox always gets its
# own persistent copy under PRIVATE_DATA_ROOT, seeded on first launch with
# NPMRC_DEFAULT, bound READ-ONLY so the sandbox can never weaken it (npm
# config set / npm login inside the sandbox fail with EROFS). To change the
# enforced default: edit NPMRC_DEFAULT and delete the private copy once; it
# will be re-seeded on the next launch.
NPMRC_DEFAULT=$'ignore-scripts=true\nmin-release-age=7'
NPMRC_PRIVATE="$PRIVATE_DATA_ROOT/.npmrc"
if [[ ! -f "$NPMRC_PRIVATE" ]]; then
  printf '%s\n' "$NPMRC_DEFAULT" > "$NPMRC_PRIVATE" 2>/dev/null || \
    warn "cannot seed sandbox .npmrc at '$NPMRC_PRIVATE' (it will be absent inside the sandbox)"
fi
[[ -f "$NPMRC_PRIVATE" ]] && ARGS+=(--ro-bind "$NPMRC_PRIVATE" "$HOME/.npmrc")

# --- ~/.config/mcp/mcp.json: sandbox-private seed; host's dir NEVER bound ----
# Same pattern as ~/.npmrc above, with an extra edge: mcp.json entries can
# spawn processes or carry OAuth secrets, so the host's ~/.config/mcp is
# deliberately NOT mounted -- a sandboxed agent must be able to neither READ
# host MCP registrations nor EDIT the ones pi loads (pi would happily connect
# to a swapped URL or run a planted stdio server with full system access on
# the next reload). The sandbox gets its own copy in the private store,
# seeded on first launch with the Kaimon registration and bound READ-ONLY;
# the adapter only ever READS the shared config (its overrides go to
# .pi/mcp.json / the agent dir), so nothing breaks. To change the seed: edit
# MCP_DEFAULT and delete the private copy once; it re-seeds next launch.
MCP_DEFAULT=$'{\n  "mcpServers": {\n    "kaimon": {\n      "transport": "streamable-http",\n      "url": "http://localhost:2828/mcp",\n      "lifecycle": "eager"\n    }\n  }\n}'
MCP_PRIVATE="$PRIVATE_DATA_ROOT/.config/mcp/mcp.json"
if [[ ! -f "$MCP_PRIVATE" ]]; then
  mkdir -p "$(dirname "$MCP_PRIVATE")" 2>/dev/null
  printf '%s\n' "$MCP_DEFAULT" > "$MCP_PRIVATE" 2>/dev/null || \
    warn "cannot seed '$MCP_PRIVATE' (kaimon will not be registered; --check will show it absent)"
fi
[[ -f "$MCP_PRIVATE" ]] && ARGS+=(--ro-bind "$MCP_PRIVATE" "$HOME/.config/mcp/mcp.json")

ARGS+=("${EXTRA_ARGS[@]}")

# Dropping `--ro-bind / /` leaves bwrap's own root tmpfs WRITABLE, so an agent
# could mkdir /whatever (ephemeral, host-invisible, but a behaviour change from
# the old read-only root). Remount it read-only. This must be the LAST mount
# argument: nested mounts keep their own flags, so /tmp, $HOME and every
# read-write grant above stay writable. Verified.
ARGS+=(--remount-ro /)

# ===========================================================================
# ENTRY POINTS
# ===========================================================================
case "${1:-}" in
  --print-policy)
    printf 'bwrap %s -- herdr %s\n' "${ARGS[*]}" "${*:2}"
    exit 0
    ;;

  --check)
    # Policy probe: launch the REAL sandbox on a script that reports what the
    # policy actually produced. Run it after any policy edit. It turns "run
    # it and see what explodes over the next week" into a ten second answer.
    printf '=== host-side facts (outside the sandbox) ===\n'
    printf '  bubblewrap:            %s\n' "$(bwrap --version 2>&1)"
    printf '  dev.tty.legacy_tiocsti: %s (0 = TIOCSTI injection already blocked; --new-session=%s)\n' \
      "$(sysctl -n dev.tty.legacy_tiocsti 2>/dev/null || echo unknown)" "$NEW_SESSION"
    printf '  BIND_SYS:              %s\n' "$BIND_SYS"
    printf '  ssh agent forwarded:   %s\n' "$([[ "$SSH_AGENT_BOUND" == 1 ]] && echo "yes, live signing oracle inside" || echo no)"
    printf '\n'

    # Report each read-write grant once, by the name it has inside the sandbox
    # (both the listed path and its realpath are bound, and for a non-symlink
    # entry those are the same string).
    declare -A _seen_w=()
    _wlist=()
    for entry in "${HOME_RW_RESOLVED[@]}" "${ROOT_RW_RESOLVED[@]}"; do
      for _p in "${entry%%$'\t'*}" "${entry##*$'\t'}"; do
        [[ -n "${_seen_w[$_p]:-}" ]] && continue
        _seen_w[$_p]=1; _wlist+=("$_p")
      done
    done

    probe_pre=""
    probe_pre+="P_WRITE='${_wlist[*]}'"$'\n'
    probe_pre+="P_PRIVATE='${PRIVATE_DATA_DIRS[*]}'"$'\n'
    probe_pre+="P_TOOLS='${CHECK_TOOLS[*]}'"$'\n'
    probe_pre+="P_RUNTIME='$RUNTIME_DIR'"$'\n'

    probe_body=$(cat <<'PROBE'
echo "=== inside the sandbox ==="
echo "uid=$(id -u) user=$(id -un 2>/dev/null || echo '(getpwuid FAILED, check ROOT_READONLY)')"

echo
echo "--- effective mount table ---"
awk '{ split($6, o, ","); printf "  %-3s %s\n", o[1], $5 }' /proc/self/mountinfo

echo
echo "--- / (top level: everything else on the host is invisible) ---"
ls -A / | sed 's/^/  /'

echo
echo "--- /run (host session bus, keyring and gpg sockets must be absent) ---"
ls -A /run | sed 's/^/  /'
printf '  %s: %s entries, mode %s\n' "$P_RUNTIME" \
  "$(ls -A "$P_RUNTIME" 2>/dev/null | wc -l)" "$(stat -c %a "$P_RUNTIME" 2>/dev/null)"
for s in "$P_RUNTIME/bus" "$P_RUNTIME/keyring/ssh" "$P_RUNTIME/keyring/control" \
         "$P_RUNTIME/gnupg" /run/dbus/system_bus_socket /run/docker.sock; do
  [ -e "$s" ] && echo "  LEAK      $s" || echo "  absent    $s"
done

echo
echo "--- \$HOME (everything else in your home is invisible) ---"
ls -A "$HOME" | sed 's/^/  /'

echo
echo "--- writable policy paths ---"
for d in $P_WRITE /tmp "$HOME"; do
  if [ ! -e "$d" ]; then echo "  ABSENT        $d"
  elif [ -w "$d" ]; then echo "  ok            $d"
  else echo "  NOT WRITABLE  $d"; fi
done
for p in $P_PRIVATE; do echo "  private   $p (sandbox's own persistent copy)"; done

echo
echo "--- tools on PATH ---"
for t in $P_TOOLS; do
  p=$(command -v "$t" 2>/dev/null) || p=""
  if [ -z "$p" ]; then
    printf '  %-8s %s\n' MISSING "$t"
  else
    r=$(readlink -f "$p" 2>/dev/null || echo "$p")
    if [ -e "$r" ]; then
      printf '  %-8s %-10s %s\n' ok "$t" "$p"
    else
      printf '  %-8s %-10s %s -> %s (symlink target not bound in)\n' BROKEN "$t" "$p" "$r"
    fi
  fi
done

echo
echo "--- credential channels ---"
# Leaf paths only. A PARENT of an allowlisted entry (~/.cache, ~/.config,
# ~/.local/share) always exists inside as an empty tmpfs directory holding just
# its allowlisted children, so testing one would be a guaranteed false alarm.
for s in "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.netrc" "$HOME/.git-credentials" \
         "$HOME/.aws" "$HOME/.config/gh" "$HOME/.docker" "$HOME/.kube" \
         "$HOME/.claude" "$HOME/.cache/kaimon" "$HOME/Documents" \
         "$HOME/.local/share/keyrings" /opt /srv /mnt /media /var/log; do
  [ -e "$s" ] && echo "  LEAK      $s" || echo "  invisible $s"
done
# Any home directory other than this user's should not be reachable at all.
_others=$(ls -A /home 2>/dev/null | grep -Fxv "$(basename "$HOME")" | tr '\n' ' ')
[ -n "$_others" ] && echo "  LEAK      other homes under /home: $_others" \
                  || echo "  invisible other users' homes"
if command -v gh >/dev/null 2>&1; then
  if gh auth token >/dev/null 2>&1; then echo "  LEAK      gh auth token is available"
  else echo "  ok        gh has no token"; fi
else
  echo "  n/a       gh not installed"
fi
if [ -w / ]; then echo "  WARNING   / is writable"; else echo "  ok        / is read-only"; fi

echo
echo "--- surviving environment (--clearenv + ENV_PASS) ---"
env | sort | sed 's/^/  /'

echo
echo "--- herdr ---"
herdr status 2>&1 | sed 's/^/  /' || echo "  herdr status failed"
PROBE
)
    exec bwrap "${ARGS[@]}" -- sh -c "$probe_pre$probe_body"
    ;;

  *)
    exec bwrap "${ARGS[@]}" -- herdr "$@"
    ;;
esac
