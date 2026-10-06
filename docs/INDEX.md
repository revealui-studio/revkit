---
type: repo-doc-index
repo: revkit
updated: 2026-09-24
---

# RevKit documentation index

Operator machine kit (macOS + Linux + WSL2, WSL-first) for RevealUI development.
Not a customer runtime. Neutral-config bootstrap, shell config, WSL boot
optimization, editor configs.

## Start here

- [`ONBOARDING.md`](./ONBOARDING.md). Fresh operator machine to working environment. Read the privilege warning before `bootstrap.sh`.

## This repo's masters

- [`MASTER_PLAN.md`](./MASTER_PLAN.md). Authoritative plan for RevKit
- [`MASTER_SPEC.md`](./MASTER_SPEC.md). Surface area + configuration model

## Reference

- [`client-name-public-github.md`](./client-name-public-github.md). Public client-name defense: secret-backed scanner plus watchlist gate.
- [`rfc-launcher.md`](./rfc-launcher.md). The `rfc` secure Claude launcher
- [`rfx-launcher.md`](./rfx-launcher.md). The `rfx` Codex launcher, and the audit-storm sweeper's agent-ancestor skip.
- [`tier-capabilities.md`](./tier-capabilities.md). T0/T1 (sandbox-drive) capabilities
- [`WSL-QuickReference.md`](./WSL-QuickReference.md) + [`WSL-CheatSheet.txt`](./WSL-CheatSheet.txt). WSL ops
- [`windows-terminal-profiles.sample.json`](./windows-terminal-profiles.sample.json). Optional WT profile fragment (merge; do not overwrite user settings)

## Fleet coordination

Part of [RevealFleet](https://github.com/RevealUIStudio). Cross-fleet coordination, planning, and lane tracking live in the agent dev environment, not in this public repo.
