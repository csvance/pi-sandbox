# pi-sandbox repo instructions

Instructions for working in **this repo** (`~/Git/pi-sandbox`), which
contains the sandbox itself: the bwrap policy, the launch wrappers, and
their documentation. Sandbox-global agent rules (scratch space, gh, secret
provisioning) live in `AGENTS.sandbox.md` and are installed to
`~/.pi/agent/AGENTS.md` (pi's global context file) on every launch.

## Layout

- `sandbox.sh` — the sandbox policy: mount allowlists, environment allowlist
  (`--clearenv` + `ENV_PASS`), credential provisioning from `secrets/`,
  `--check` probe and `--print-policy`
- `sandbox-project.sh` — scoped wrapper: binds only one project; seeds a
  blank `AGENTS.md` into new projects
- `SANDBOX.md` — the policy documentation; keep it in sync with script edits
- `PI.md` — pi's integration notes inside this sandbox
- `HERDR.md`, `README.md` — herdr integration and repo overview
- `secrets/` — gitignored credentials, provisioned into the sandbox at
  launch (never commit anything in it)

## Editing and testing

- After editing `sandbox.sh` or `sandbox-project.sh`: run `bash -n` on both.
- After a policy change, run `./sandbox.sh --check` **on the host** and read
  the probe output: mount table, credential channels, surviving environment
  (credential-shaped values are redacted).
- `./sandbox.sh --print-policy` prints the assembled bwrap command without
  launching.
- Docs mirror the policy: change `SANDBOX.md` in the same change as the
  script.
