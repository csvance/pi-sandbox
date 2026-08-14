# Sandbox agent instructions (global)

These rules apply to **every pi session in the sandbox**, whatever the
project. This file is the canonical source: on every sandbox launch,
`sandbox.sh` copies it to `~/.pi/agent/AGENTS.md` (pi's global context
file, loaded at startup for every session). **Edit this file** — direct
edits to `~/.pi/agent/AGENTS.md` are overwritten on the next launch.
Project-specific rules belong in each project's own `AGENTS.md`.

## Scratch space (persistent across launches)

Use a scratch directory **inside the project you are working on** — not
`/tmp` (the sandbox gives it a fresh private tmpfs on every relaunch; its
contents vanish when the sandbox exits) and not unlisted `$HOME` paths (also
wiped). The project directory is bound read/write into the sandbox, so files
in it survive relaunches.

- Create and use `.scratch/` in the project root (e.g. `mkdir -p .scratch`
  in `~/Git/<project>`); create it if it is missing.
- Add `.scratch/` to the project's `.gitignore` when you create it (scratch
  is throwaway by definition — unless you intend to commit what you store).
- Use it for intermediate files, downloaded artifacts, build outputs,
  caches, notes-to-self, and anything you need to keep between launches.
- Treat it as throwaway: clean up stale files, don't rely on it as the
  permanent home of anything important (that belongs in tracked files).

## GitHub CLI (`gh`)

`gh` is installed and configured with a **read-only, public-repos-only**
personal access token. Use it to fetch GitHub information: repos, issues,
PRs, releases, search, gists, API calls, etc. Examples:

```bash
gh repo view owner/repo --json name,description,stargazerCount,updatedAt
gh issue list -R owner/repo --state open --limit 20
gh search code "pattern" --repo owner/repo
gh api repos/owner/repo/releases/latest
```

Rules for the token:

- The token is provisioned into the sandbox on **every launch** from the
  repo's gitignored `secrets/.gh-token` file (`~/Git/pi-sandbox/secrets/.gh-token`:
  one line, raw token). To rotate it, edit that file and relaunch the sandbox.
- **Never print, export, or commit the token.** Treat it as a credential even
  though it is read-only. The whole `secrets/` directory is gitignored;
  don't work around that.
- The token cannot write anything (no pushes, no issue/PR mutations) — don't
  attempt write operations; they fail with 403. Use SSH remotes for git push.
- If `gh` reports no auth inside the sandbox, `secrets/.gh-token` is missing
  or empty — check it on the host and relaunch.

## Web search API keys

pi's web-search provider keys (`~/.pi/web-search.json`: openai, brave, exa,
jina, ...) are provisioned the same way: the gitignored `secrets/.web-search.json`
file is copied into the sandbox-private store on every launch and bound
read-only. **Never print, export, or commit those keys** either; rotate by
editing `secrets/.web-search.json` and relaunching.

## `ZAI_API_KEY`

`ZAI_API_KEY` is set in the sandbox environment on every launch from the
gitignored `secrets/.zai-api-key` file (one line, raw key). It is
deliberately never taken from the parent shell's environment (the sandbox
refuses credential-shaped variables from there). **Never print, export, or
commit it**; rotate by editing `secrets/.zai-api-key` and relaunching.
