#!/usr/bin/env bash
#
# sandbox.sh — bubblewrap policy for herdr (terminal workspace manager) + pi
#
# The entire host root is mounted READ-ONLY inside the sandbox, and $HOME is
# masked entirely (a private, ephemeral tmpfs) — nothing from your home
# directory is visible until it is bound back in explicitly:
#   - WRITE_DIRS       read-write: Julia depot, projects, agent credentials
#   - HOME_READONLY    read-only: installed CLIs + configs (pi, herdr, julia…)
#   - PRIVATE_DATA_DIRS: the sandbox's OWN persistent copies of a path
# (plus /tmp, a fresh private tmpfs). herdr runs inside the sandbox, so every
# pane it spawns — including all pi sessions — inherits the same boundary.
#
# Usage:
#   ./sandbox.sh                # launch herdr inside the sandbox (attach to
#                               # the sandbox-private session)
#   ./sandbox.sh --session X    # any herdr CLI args pass through
#   ./sandbox.sh --check        # run a policy probe instead of herdr
#   ./sandbox.sh --print-policy # print the assembled bwrap command
#
# Adding a path is a one-line change: append it to WRITE_DIRS below.
# (Optional extras — GPU, Wayland, SSH agent — are right after.)
#
# Requires: bubblewrap on a kernel with unprivileged user namespaces enabled
# (check: cat /proc/sys/kernel/unprivileged_userns_clone  -> 1).

set -euo pipefail

# ===========================================================================
# THE POLICY — paths herdr/pi may READ + WRITE.
# Everything else on the host is mounted read-only. Add entries freely;
# the script mkdirs them on the host if they don't exist yet.
# Use absolute paths with $HOME expanded.
# ===========================================================================
WRITE_DIRS=(
  "$HOME/.julia"          # Julia depot: packages, registries, dev'd packages
  "$HOME/.herdr"          # herdr session/data directory
  "$HOME/.local/state/herdr"  # herdr's agent-detection manifest cache
                          #   (the host herdr shares this dir too). The sandbox
                          #   runs without it, but then herdr can't cache
                          #   updated detection profiles and logs a WARN at
                          #   server start. Detection profiles — not personal
                          #   data.
  "$HOME/Git"             # your projects
  "$HOME/.config/herdr"   # herdr config.toml + server log
  "$HOME/.pi/agent"       # pi auth (auth.json), sessions, mcp config
                          #   — without this, pi has no API keys and can't
                          #   persist sessions. Drop it only if you plan to
                          #   provision credentials inside the sandbox.
  "$HOME/.config/kaimon"  # Kaimon config: projects.json, extensions.json,
                          #   config.json — the TUI writes these
                          # Kaimon's CACHE (~/.cache/kaimon: ZMQ IPC sockets,
                          #   kaimon.db, agent logs) is deliberately NOT bound.
                          #   XDG_CACHE_HOME is redirected to the private
                          #   /tmp/xdg-cache below, so the sandboxed kaimon can
                          #   never collide with or attach to a kaimon/gate on
                          #   the host — Kaimon binds FIXED socket names with
                          #   rm-first semantics, so sharing them would be an
                          #   escape hatch (same reasoning as HERDR_SOCKET_PATH).
  "$HOME/.config/fish"    # fish shell config + fish_variables (universal
                          #   vars / abbreviations — fish needs to WRITE
                          #   these; read-only makes `set -U` error out).
                          #   Want full isolation? Move it to PRIVATE_DATA_DIRS.
  # ~/.local/share/fish is intentionally NOT here — the sandbox fish gets its
  # own persistent history copy instead (see PRIVATE_DATA_DIRS below).
)

# /tmp is a PRIVATE tmpfs: writable, but contents vanish when the sandbox
# exits and nothing from the host /tmp is visible. To share the HOST /tmp
# instead, replace "--tmpfs /tmp" in ARGS below with "--bind /tmp /tmp".

# ===========================================================================
# HOME READ-ONLY ALLOWLIST — installed tooling and configs that must be
# visible inside the sandbox but never written. Everything else under $HOME
# is invisible (see the --tmpfs $HOME mask in ARGS). Keep these disjoint from
# WRITE_DIRS / PRIVATE_DATA_DIRS, which bind the same paths read-write.
# Absent paths are skipped silently — uncomment lines as you need them.
# ===========================================================================
HOME_READONLY=(
  "$HOME/.local/bin"                  # CLI symlinks: pi, herdr, claude, uv...
  "$HOME/.local/lib/node_modules"     # pi's install (npm global @earendil-works)
  "$HOME/.juliaup"                    # julia binary + toolchains (read-only:
                                      #   juliaup self-update fails, by design)
  "$HOME/.gitconfig"                  # git identity/signing config
)

# ===========================================================================
# SANDBOX-PRIVATE PERSISTENT DATA — the host version is REPLACED inside the
# sandbox by a private copy that persists across launches.
# The sandboxed fish shell reads/writes ONLY this copy: it can neither read
# nor write the host's ~/.local/share/fish/fish_history. The private copy is
# stored on the host under $PRIVATE_DATA_ROOT (mirrored path), so it survives
# sandbox restarts — unlike /tmp, it is NOT wiped each launch.
# ===========================================================================
PRIVATE_DATA_DIRS=(
  "$HOME/.local/share/fish"   # fish shell history + state (your $SHELL in herdr panes)
)
PRIVATE_DATA_ROOT="$HOME/.local/share/pi-sandbox"

# ===========================================================================
# OPTIONAL EXTRA MOUNTS — uncomment as needed
# ===========================================================================
EXTRA_ARGS=()

# GPU access (for GLMakie / GPU work in Julia sessions):
# EXTRA_ARGS+=(--dev-bind-try /dev/dri /dev/dri)

# Wayland socket for GUI apps (target is sandbox-side; XDG_RUNTIME_DIR is
# redirected to the private /tmp, so /tmp/wayland-0 is the right mount point):
# EXTRA_ARGS+=(--ro-bind-try "/run/user/$(id -u)/wayland-0" /tmp/wayland-0)

# X11 sockets (XWayland) for GUI apps:
# EXTRA_ARGS+=(--ro-bind-try /tmp/.X11-unix /tmp/.X11-unix)

# SSH agent — mounted automatically when the parent has one. This lets
# `git push` inside pi sessions authenticate, without exposing ~/.ssh itself.
if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK:-}" ]]; then
  EXTRA_ARGS+=(--ro-bind-try "$SSH_AUTH_SOCK" "$SSH_AUTH_SOCK")
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

ARGS=(
  --unshare-all
  --share-net
  --die-with-parent
  --ro-bind / /                    # entire host root, read-only (baseline)
  --dev /dev
  --tmpfs /dev/shm
  --proc /proc
  --ro-bind /sys /sys
  --tmpfs /tmp                     # private, writable /tmp
  --dir /tmp/herdr                 # sandbox-private herdr socket dir
  --dir /tmp/xdg-runtime
  --setenv XDG_RUNTIME_DIR /tmp/xdg-runtime
  --dir /tmp/xdg-cache
  --setenv XDG_CACHE_HOME /tmp/xdg-cache  # private kaimon cache: IPC sockets,
                                         #   kaimon.db, agent/extension logs
  --setenv HERDR_SOCKET_PATH /tmp/herdr/herdr.sock
  --setenv HERDR_CLIENT_SOCKET_PATH /tmp/herdr/herdr-client.sock
  --setenv HERDR_SESSION "$HERDR_SANDBOX_SESSION"
)

# ===========================================================================
# CLOSE HOST CREDENTIAL CHANNELS.
# The host root is ro-bound, so the REAL /run/user/<uid> (the host session
# runtime dir — D-Bus bus, kwallet/keyring sockets, p11-kit, X auth, …) was
# visible by path; gh found its OAuth token through the host secret service
# behind it. Mask the dir with a private tmpfs and drop the env vars that
# name it, so nothing from the host desktop session leaks into the sandbox
# (same reasoning as the XDG_RUNTIME_DIR/XDG_CACHE_HOME redirects). The SSH
# agent, when the parent has one, is still bound explicitly by EXTRA_ARGS.
# ===========================================================================
ARGS+=(--dir "/run/user/$(id -u)")
ARGS+=(--tmpfs "/run/user/$(id -u)")

# Scrub credential env vars the host launcher might carry, by name.
for _var in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_PAT GH_ENTERPRISE_PAT; do
  ARGS+=(--unsetenv "$_var")
done
ARGS+=(--unsetenv DBUS_SESSION_BUS_ADDRESS)

# Carry display env vars through (the TUI doesn't need them; GUI apps
# launched from panes do).
[[ -n "${WAYLAND_DISPLAY:-}" ]] && ARGS+=(--setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY")
[[ -n "${DISPLAY:-}" ]] && ARGS+=(--setenv DISPLAY "$DISPLAY")

# Mask $HOME entirely: a private, writable, EPHEMERAL tmpfs. Nothing from the
# host home directory is visible until bound back in (WRITE_DIRS below, plus
# HOME_READONLY and PRIVATE_DATA_DIRS). Must come AFTER --ro-bind / / and
# BEFORE every $HOME subtree bind. Writes here vanish when the sandbox exits.
ARGS+=(--tmpfs "$HOME")

# Bind the writable policy paths over the masked root. Order matters: bwrap
# applies mounts sequentially, so these override --ro-bind / / and the tmpfs.
for dir in "${WRITE_DIRS[@]}"; do
  [[ -z "$dir" ]] && continue
  mkdir -p "$dir"
  ARGS+=(--bind "$dir" "$dir")
done

# Read-only home allowlist: installed CLIs + configs that must be visible but
# never written. Disjoint from WRITE_DIRS / PRIVATE_DATA_DIRS by design.
for path in "${HOME_READONLY[@]}"; do
  [[ -z "$path" ]] && continue
  [[ -e "$path" ]] || continue    # absent path → stays invisible
  ARGS+=(--ro-bind "$path" "$path")
done

# Bind sandbox-private persistent copies over the listed paths. This comes
# AFTER the WRITE_DIRS loop, so these win: inside the sandbox the path points
# at the private store, not the host dir. The store path mirrors the original
# under PRIVATE_DATA_ROOT (e.g. ~/.local/share/fish -> <root>/.local/share/fish).
for dir in "${PRIVATE_DATA_DIRS[@]}"; do
  [[ -z "$dir" ]] && continue
  private="$PRIVATE_DATA_ROOT${dir#$HOME}"
  # mkdir is a no-op once the store exists. If it can't be created (e.g. the
  # script is run inside an existing sandbox where ~/.local/share is read-only),
  # don't abort: bwrap's --bind will fail below with a clear source-path error.
  # The store is normally created by the host-side launch of this script.
  mkdir -p "$private" "$dir" 2>/dev/null || true
  ARGS+=(--bind "$private" "$dir")
done

ARGS+=("${EXTRA_ARGS[@]}")

case "${1:-}" in
  --print-policy)
    printf 'bwrap %s -- herdr %s\n' "${ARGS[*]}" "${*:2}"
    exit 0
    ;;
  --check)
    # Probe: verify the sandbox is up and the policy is actually applied.
    probe_body='echo "== sandbox probe =="; echo "uid=$(id -u) hostname=$(hostname)";'
    probe_body+='echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR XDG_CACHE_HOME=$XDG_CACHE_HOME";'
    probe_body+='echo "HERDR_SOCKET_PATH=$HERDR_SOCKET_PATH HERDR_SESSION=$HERDR_SESSION";'
    probe_body+='for d in'
    for d in "${WRITE_DIRS[@]}" "${PRIVATE_DATA_DIRS[@]}" /tmp; do probe_body+=" $(printf %q "$d")"; done
    probe_body+='; do if [ -w "$d" ]; then echo "writable:    $d"; else echo "NOT WRITABLE: $d"; fi; done;'
    probe_body+='echo "home: $HOME is a private tmpfs — visible entries:"; ls -A "$HOME" | sed "s/^/  /";'
    if [[ ${#PRIVATE_DATA_DIRS[@]} -gt 0 ]]; then
      probe_body+='for p in'
      for d in "${PRIVATE_DATA_DIRS[@]}"; do probe_body+=" $(printf %q "$d")"; done
      probe_body+="; do echo \"sandbox-private: \$p -> ${PRIVATE_DATA_ROOT}\${p#\$HOME}\"; done;"
    fi
    probe_body+='for s in "$HOME/.ssh" "$HOME/.claude" "$HOME/.cache" "$HOME/Documents" "$HOME/.local/share/TelegramDesktop"; do [ -e "$s" ] && echo "LEAK: $s" || echo "invisible: $s"; done;'
    probe_body+='echo "runtime dir: $(ls -A "/run/user/$(id -u)" 2>/dev/null | wc -l) entries (0 = host session masked)";'
    probe_body+='if gh auth token >/dev/null 2>&1; then echo "gh token: AVAILABLE (leak!)"; else echo "gh token: none (credential channels closed)"; fi;'
    probe_body+='if [ -w / ]; then echo "WARNING: / is writable!"; else echo "read-only:   / (baseline)"; fi;'
    probe_body+='echo "readable:    /etc/resolv.conf, herdr binary"; herdr status'
    exec bwrap "${ARGS[@]}" -- sh -c "$probe_body"
    ;;
  *)
    exec bwrap "${ARGS[@]}" -- herdr "$@"
    ;;
esac
