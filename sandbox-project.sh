#!/usr/bin/env bash
#
# sandbox-project.sh: launch the sandbox scoped to ONE project.
#
# Hides $HOME/Git except the given project (default: the current directory),
# so an agent started in a project can only read/write THAT project — it never
# even sees sibling repos under ~/Git. Blast-radius reduction: a rogue agent
# can only poison the project it was launched in, not the whole tree.
#
# Usage:
#   ./sandbox-project.sh [project-path] [sandbox.sh args...]
#
#   project-path  default: $PWD; must be an existing directory under $HOME/Git
#   remaining args (flags starting with '-') pass through to sandbox.sh:
#                 --check, --session X, --print-policy, ...
#
# One sandbox/herdr instance per project: start a new one from each project
# you want to work in. The default ./sandbox.sh (no scoping) is unchanged.
#
# On launch it also seeds the default AGENTS.md (agent-instructions template,
# currently empty) into the project — copy-if-absent, never overwrite.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBOX="$HERE/sandbox.sh"

PROJECT="$PWD"
if [[ $# -gt 0 && "$1" != -* ]]; then
  PROJECT="$1"
  shift
fi

PROJECT="$(realpath -m -- "$PROJECT")"
if [[ "$PROJECT" != "$HOME/Git" && "$PROJECT" != "$HOME/Git"/* ]]; then
  echo "sandbox-project.sh: '$PROJECT' must live under \$HOME/Git" >&2
  exit 1
fi
if [[ ! -d "$PROJECT" ]]; then
  echo "sandbox-project.sh: '$PROJECT' is not a directory" >&2
  exit 1
fi

# Seed the default AGENTS.md (the agent-instructions template next to this
# script — currently empty) into the project on its first scoped launch.
# Copy-if-absent, never overwrite: a project that already has its own
# AGENTS.md (or AGENTS.override.md) keeps it untouched. Edit the template to
# change the default for every future project.
if [[ ! -e "$PROJECT/AGENTS.md" && -f "$HERE/AGENTS.md" ]]; then
  cp "$HERE/AGENTS.md" "$PROJECT/AGENTS.md"
  echo "sandbox-project.sh: seeded AGENTS.md (default agent instructions) into $PROJECT"
fi

export SANDBOX_PROJECTS="$PROJECT"
cd "$PROJECT"   # sandbox processes (herdr, pi panes) start inside the project
exec "$SBOX" "$@"
