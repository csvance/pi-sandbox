# Agent instructions

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
  repo's gitignored `.gh-token` file (`~/Git/pi-sandbox/.gh-token`: one line,
  raw token). To rotate it, edit that file and relaunch the sandbox.
- **Never print, export, or commit the token.** Treat it as a credential even
  though it is read-only. `.gh-token` is gitignored; don't work around that.
- The token cannot write anything (no pushes, no issue/PR mutations) — don't
  attempt write operations; they fail with 403. Use SSH remotes for git push.
- If `gh` reports no auth inside the sandbox, `.gh-token` is missing or empty
  — check it on the host and relaunch.

## Web search API keys

pi's web-search provider keys (`~/.pi/web-search.json`: openai, brave, exa,
jina, ...) are provisioned the same way: the gitignored `.web-search.json`
file next to `sandbox.sh` is copied into the sandbox-private store on every
launch and bound read-only. **Never print, export, or commit those keys**
either; rotate by editing `.web-search.json` and relaunching.
