# Agent coordination

The native control tree is `.revealui`. Read and write it first.
Vendor homes (`.claude`, `.grok`, `.cursor`, and the other adapter
directories) are projections of that tree. They are not the policy source.

## Policy

Author rules, agents, and skills under `.revealui/content/`.
`scripts/verify-copy-lockstep.sh` treats that tree as the reference and
checks each vendor projection against it.

## Workboard

The file board, when a repo uses one, is `.revealui/workboard.md`.
Set `REVEALUI_WORKBOARD` to an absolute path when the board lives elsewhere.
The shell `wb` helper reads `.revealui/workboard.md` from the planning
checkout (`REVEALFLEET_PLANNING`).

A vendor workboard path is not authoritative.

## Hooks

Bootstrap installs the M-4 scanner to `~/.revealui/hooks/m4-sudoers-fs-scanner.js`.
Adapter hook files point at that native script. They do not install a second
copy into a vendor home.

`templates/hooks/session-start.js` is the native SessionStart helper. It runs
the scanner. It does not continue a previous session.

## Grok compat

`templates/grok/config.toml` ships `[compat.claude]` with `hooks`, `mcps`,
and `sessions` off. `skills` stays off unless those skills are projections
generated from `.revealui/content`. MCP servers stay opt-in. A fresh Grok
config does not enable them.

## Claude adapter

A default `bootstrap.sh` run does not write `~/.claude` and does not run the
`claude` CLI. Pass `--claude-adapter`, or set `REVKIT_CLAUDE_ADAPTER=1`, to
project `~/.claude` from `~/.revealui`. That projection is not the policy home.
