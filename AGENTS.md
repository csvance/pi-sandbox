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
