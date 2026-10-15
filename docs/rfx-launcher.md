# `rfx` Codex launcher

`rfx` starts an OpenAI Codex CLI session rooted in a RevealFleet repo. It is
the Codex counterpart of `rfg` (Grok) and `rfc` (Claude). Fleet root, worktree
env, storm preflight, and Level 1 RevealUI MCP env match `rfg`.

`rfx` does not auto-continue a previous session. Resume explicitly:

```bash
rfx -- resume --last
```

## Usage

```bash
rfx <repo>                         # cd the checkout, load MCP env, exec codex
rfx                                # $PWD inside the fleet (root or a repo)
rfx open <repo> <label>            # worktree from the integration ref, then codex
rfx open revealui my-label --claim some-surface
rfx --dry-run [repo] [-- args]     # print the plan; no sweep, no sync, no exec
rfx <repo> -- <codex args>         # args after -- pass through to codex
rfx -- <codex args>                # $PWD target, everything after -- goes to codex
rfx mint                           # interactive device-token mint to revvault
rfx smoke                          # auth/MCP health (no secret print)
rfx env                            # non-secret MCP URL + vault path (never the token)
```

Examples:

```bash
rfx revealui
rfx open revealui my-label
rfx --dry-run revealui
rfx revealui -- --search "triage the failing test"
rfx -- resume --last
```

Codex `--worktree` has no base ref and would branch from the checkout HEAD.
`rfx` refuses that unless HEAD is already the integration branch. Create the
worktree with `rfx open <repo> <label>` instead. `RFG_WORKTREE_REF_SKIP=1`
disables the guard.

`rfx env` prints only `REVEALUI_MCP_URL` and `REVEALUI_MCP_TOKEN_VAULT_PATH`.
It never prints `REVEALUI_MCP_TOKEN`.

## Audit-storm sweeper

Before a real launch, `rfx` runs the same preflight as `rfg`
(`shell/lib/rfg-storm-preflight.sh`, which calls `shell/lib/kill-audit-storms.sh`).
`--dry-run` prints the plan and does not run the sweeper.

The sweeper clears leftover home-wide `du` and audit `find` processes that
wedge WSL disk I/O. It skips any process whose ancestor chain, including the
process itself, contains an agent session or launcher:

`codex`, `rfx`, `grok`, `rfg`, `rfc`, `claude`, `cursor-agent`.

Names are matched on the basename of `comm`, argv[0], and argv[1] (so
`bash rfx.sh` and `node .../cursor-agent` count). A `find` or `du` started
inside a live agent session is left alone. Only orphaned storms are cleared.

Skip the preflight with `RFG_STORM_PREFLIGHT_SKIP=1`. Standalone
`kill-audit-storms` uses `AUDIT_STORM_MIN_AGE_SEC` (default 600). The
preflight uses `RFG_STORM_MIN_AGE_SEC` (default 120).

## Install

`bootstrap.sh` installs `shell/bin/*.sh`, so `rfx.sh` lands next to `rfg.sh`
(`/usr/local/bin` on Linux/WSL, `~/.local/bin` on macOS). It also symlinks
the unsuffixed PATH name `rfx` to `rfx.sh` in that same directory. Bootstrap
does not write a Codex vendor home.

Fleet shells define `rfx` from `shell/shellrc.d/56-rfx.sh` (same pattern as
`shell/shellrc.d/55-rfg.sh`).

```bash
cd ~/revealfleet/revkit && bash bootstrap.sh
```

## Env overrides

| Variable | Role |
|----------|------|
| `REVEALFLEET_ROOT` | fleet root override |
| `REVEALUI_MCP_ENV_SKIP=1` | do not load the MCP token |
| `REVEALUI_MCP_ENV_STRICT=0` | launch even if the token is missing |
| `RFX_MCP_ATTACH_SKIP=1` | do not pass RevealUI MCP `-c` overrides |
| `RFX_REVEALUI_POINTER_SKIP=1` | do not point Codex at `.revealui` when `AGENTS.md` is absent |
| `RFX_DRY_RUN=1` | same as `--dry-run` |
| `RFG_WORKTREE_REF` | force the worktree base ref (`rfx open`) |
| `RFG_WORKTREE_REF_SKIP=1` | allow Codex `--worktree` off a non-integration HEAD |
| `RFG_STORM_PREFLIGHT_SKIP=1` | do not clear audit storms before `rfg` launch (the preflight script) |
