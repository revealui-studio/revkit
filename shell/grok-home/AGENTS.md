# Grok — vendor home is a cache

`$HOME/.grok` is Grok's attach point (auth, sessions, UI, hooks). It is **not**
an authoring surface and **not** the policy SSOT.

RevKit (`rfg` / `bootstrap.sh`) may copy this stub here. Do not edit it in
place. Do not put constitution, identity, or private planning paths under
`$HOME/.grok/rules/`.

## Product sessions

Launch with `rfg <repo>` (cwd is the product). Then:

1. `.revealui/manager.json` then `.revealui/content/` (SSOT)
2. `<repo>/.grok/rules/` (harnesses materialize; preamble + adapter orientation)
3. TRACKER from the manager `tracker.path`
4. Product I/O via RevealUI MCP. Secrets via revvault.

`[compat.claude]` hooks, mcps, and sessions stay off unless opted in. skills stays off unless those skills are projections from `.revealui/content`. Do not ingest a vendor dump.

Git identity is `git config user.email` (RevKit `identity.gitconfig`). Mechanical
deny is PreToolUse hooks deployed from the product manager.

Do not invent parallel queues under `$HOME/.grok`.
