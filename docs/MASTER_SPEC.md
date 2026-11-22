---
type: master-spec
repo: revkit
last-updated: 2026-09-13
owner: RevealUI Studio
staleness-status: FRESH
---

# RevKit master spec

**Last Updated:** 2026-09-13
**Status:** Pre-1.0. Cross-platform foundation shipped (macOS + Linux + WSL2); surface stable for daily use, external-contributor onboarding is Phase C (see MASTER_PLAN)
**Repo:** [RevealUIStudio/revkit](https://github.com/RevealUIStudio/revkit) (product name: RevealUI DevKit)

> Surface area, architecture, configuration model. Companion to [`MASTER_PLAN.md`](./MASTER_PLAN.md) (status + roadmap).

---

## Mission

Operator machine kit (macOS + Linux + WSL2, WSL-first). Not a customer runtime.
Take a fresh operator workstation and turn it into a RevealUI Studio-grade
environment from one detect-then-dispatch bootstrap, with per-machine values
kept machine-local (never committed).

---

## Repository structure

```
revkit/
├── README.md
├── bootstrap.sh                     # Universal entry point (macOS + Linux + WSL2); detect-then-dispatch
├── bootstrap-wsl.sh                 # Deprecation shim → execs bootstrap.sh (legacy invocation path)
├── bootstrap.ps1                    # Windows-host prep entrypoint (PowerShell)
├── lib/
│   └── platform.sh                  # OS detector: sets REVKIT_OS ∈ {wsl,linux,macos}; exports predicates
├── shell/
│   ├── shellrc.d/                   # shell config fragments sourced by .bashrc/.zshrc (00-base.sh, 25-local-ai.sh, 50-rfc.sh, …)
│   ├── modes/                       # fleet.list / vibe.list + vibe-only fragments
│   ├── lib/                         # fleet-root, revkit-mode resolver, worktree-env, …
│   ├── bin/                         # helper scripts → /usr/local/bin (or ~/.local/bin on macOS)
│   │   ├── rfc.sh                   # WSL-native (and macOS/Linux) Claude launcher
│   │   ├── rfg.sh                   # Grok launcher (MCP token from revvault)
│   │   ├── rfx.sh                   # Codex launcher (same MCP env as rfg)
│   │   ├── revkit-mode.sh           # print/set shell mode (fleet|vibe|bare)
│   │   ├── revealui.sh              # GAP-351 retire shim (overwrites ~/.local/bin/revealui)
│   │   ├── mount-sandbox-drive.sh   # WSL-only sandbox-drive mount helper
│   │   ├── sandbox-services.sh      # WSL-only sandbox service control
│   │   ├── sandbox-validate.sh      # WSL-only tier consistency check
│   │   ├── wsl-status.sh            # WSL-only status banner
│   │   └── m4-sudoers-fs-scanner.js # M-4 scanner; bootstrap installs it to ~/.revealui/hooks
│   ├── config/                      # neutral tracked configs (no per-user identity)
│   │   ├── wsl.conf                 # WSL distro config
│   │   ├── wslconfig                # Windows-host WSL global config (.wslconfig)
│   │   ├── gitconfig                # tracked git config; includes per-user identity.gitconfig
│   │   └── ssh-config               # tracked SSH host aliases; Includes per-user ssh.local
│   ├── docker/                      # Docker-related config (T1 services)
│   ├── setup-wsl-boot.sh            # idempotent WSL boot optimization (--revert supported)
│   ├── compact-vhdx.ps1             # VHDx compaction helper
│   └── Register-VHDxCompactTask.ps1 # conhost --headless wrap (Sunday 04:00)
├── scripts/
│   ├── check-no-private-leaks.sh    # private-path / credential scan (CI)
│   ├── check-backup-staleness.ps1   # weekly-backup staleness guard
│   ├── weekly-wsl-backup.ps1        # scheduled task. Exports Ubuntu distro
│   ├── Register-WeeklyBackupTask.ps1 # conhost --headless + WakeToRun (Sunday 03:00)
│   ├── Move-WslVhdx.ps1             # wsl --manage --move C:\WSL -> E:\WSL
│   └── Apply-WslHostFix.ps1         # elevated: register backup wrap, then move VHD
├── powershell/
│   └── Modules/
│       └── RevealUI.RevStation/     # PowerShell module (Mount-WSLDev, Sync-RevealUIToWindows, etc.)
├── editor-configs/
│   └── zed/                         # portable Zed settings.json + tasks.json (rfc task)
├── git-hooks/                       # M-11 fleet-wide pre-push hook (wired via core.hooksPath)
├── docs/                            # this directory
└── tests/                           # bash + Pester + platform-fixture suites
```

The TOML-profile + `scripts/render.sh` rendering subsystem and the old
`profiles/` directory were removed in #64/#65 in favor of the neutral
tracked configs + per-user `include.path` model below. `templates/` is in
use again for the client-name watchlist sample and adapter hooks. It is
not the old config-render tree.

---

## Configuration model

RevKit ships **neutral, committable configs** and keeps every per-machine /
per-user value machine-local. Nothing committed carries personal identity.

| Layer | Location | Committed? | Purpose |
|---|---|---|---|
| Tracked configs | `shell/config/` | Yes | Generic, identity-free git/ssh/wsl config |
| Per-user git identity | `~/.config/revkit/identity.gitconfig` | No (machine-local) | name + email; seeded from existing git identity on bootstrap |
| Per-user SSH overrides | `~/.config/revkit/ssh.local` | No (machine-local) | host blocks; Included by the tracked `ssh-config` |
| Shell mode preference | `~/.config/revkit/mode` | No (machine-local) | `fleet` / `vibe` / `bare`; written by `revkit-mode` |

### Shell modes (`REVEALUI_MODE`)

Three modes. Resolution on interactive login: env `REVEALUI_MODE` >
`~/.config/revkit/mode` > `fleet` (not vibe: existing engineers keep the
full surface). `managed` maps silently to `fleet`.

| Mode | Banner | Fragments |
|---|---|---|
| **fleet** | `● RevKit: fleet` (cyan) | all `shell/shellrc.d/*.sh` via `shell/modes/fleet.list` |
| **vibe** | `● RevKit: vibe` (magenta) | curated subset in `shell/modes/vibe.list` (base, tools, local-ai, vibe aliases/prompt). `rfg`/`rfc` stay on PATH; claim/worktree ceremony is not on the happy path |
| **bare** | `● RevKit: bare` (gray) | none (escape hatch) |

`revkit-mode` (no args) prints the workflow mode **and** the stream overlay
(`mode: fleet` / `stream: off`). `revkit-mode fleet|vibe|bare` sets the
workflow mode for this shell (when the wrapper function is loaded) and writes
`~/.config/revkit/mode`. Re-run `bootstrap.sh` so existing machines get the
new hook.

### Stream overlay (orthogonal to workflow mode)

Streaming safety is **not** a fourth `REVEALUI_MODE`. There is no
`REVEALUI_MODE=stream`. Use fleet, vibe, or bare, then turn the overlay on
in that window:

| Overlay | How | Effect |
|---|---|---|
| **stream-safe** | `revkit-mode stream-safe`, `stream-safe`, `STREAM_SAFE=1`, or `RV_STREAM=1` in the terminal profile | Secrets only via `revvault run` / `with-secrets`; no TTY print/clip. Prompt shows `stream`. |
| **vault-private** | `revkit-mode vault-private` or `vault-private` | Full get/clip allowed. Prompt shows `VAULT`. Keep this window out of OBS / YouTube capture. |
| **off** | default | neither |

These commands do **not** change `REVEALUI_MODE` or `~/.config/revkit/mode`.

**YouTube / OBS:** use **fleet or vibe** plus stream-safe ON in the captured
terminal. Keep any vault-private window out of the capture layout.

**Limit:** stream-safe does not redact IDE chat panes (Claude, Grok, Cursor,
Zed). Treat those as vault-private surfaces; do not put them in the stream.

Sample Windows Terminal profile fragments (merge into your settings; RevKit
does not overwrite user WT JSON): [`windows-terminal-profiles.sample.json`](./windows-terminal-profiles.sample.json).

Wiring (done by `bootstrap.sh` step 4):

- Git: `git config --global include.path <repo>/shell/config/gitconfig`; the tracked `gitconfig` in turn `[include]`s `~/.config/revkit/identity.gitconfig`.
- SSH: `~/.ssh/config` gains `Include <repo>/shell/config/ssh-config`; the tracked `ssh-config` Includes `~/.config/revkit/ssh.local`.

### OS detection (`lib/platform.sh`)

Sourced by `bootstrap.sh` and the shell fragments. Sets `REVKIT_OS` to exactly
one of `wsl | linux | macos` (honoring a validated `REVKIT_OS` override) and
exports capability predicates:

| Predicate | True when |
|---|---|
| `revkit_is_wsl` | running under WSL |
| `revkit_is_macos` | macOS |
| `revkit_is_linux` | native (non-WSL) Linux |
| `revkit_is_posix` | any of wsl/linux/macos |
| `revkit_has_systemd` | `/run/systemd/system` present |
| `revkit_has_wsl_interop` | WSL interop available |

Tested by `tests/test-platform-detect.sh` against `tests/platform-fixtures/`
(runs on the ubuntu CI runner).

---

## Bootstrap (`bootstrap.sh`)

Universal cross-platform entry point for **operator machines only**.
Detect-then-dispatch: platform-agnostic steps run unconditionally; WSL-only
steps are gated by `revkit_is_wsl`; macOS-specific paths are chosen by
`revkit_is_macos` (e.g. helpers install to `~/.local/bin` without sudo on
macOS, `/usr/local/bin` elsewhere). `--dry-run` previews every step without
writing.

A default run is privileged. It writes WSL sudoers, installs helpers to
`/usr/local/bin` on Linux/WSL, sets `git config --global core.hooksPath`, and
wires fleet rules into `.revealui` when `revcon` is present. The Claude
adapter is off unless `--claude-adapter` or `REVKIT_CLAUDE_ADAPTER=1`.

| Step | What | Platform |
|---|---|---|
| 1 | Install `shell/bin/*` helpers (WSL-only helpers skipped off WSL) | all |
| 1b | Overwrite `~/.local/bin/revealui` with the GAP-351 retire shim (no tmux) | all |
| 1c | Attach Grok vendor hooks from the product manager plus HOME stub `AGENTS.md` (no prose rules in `$HOME/.grok`) | all |
| 2 | Sudoers for passwordless sandbox mount (pinned to `--mount-only`) | WSL |
| 3 | Self-healing rc-hook into `.bashrc`/`.zshrc` (resolves mode, sources `shell/modes/*.list`; prints `● RevKit: fleet`/`vibe`/`bare`) | all |
| 4 | Git + SSH includes (neutral configs + per-user `~/.config/revkit/`) | all |
| 5 | WSL boot optimization (`shell/setup-wsl-boot.sh`) | WSL |
| 6 | Sandbox directory init (if `/mnt/sandbox` mounted) | WSL |
| 7 | Write the native control home `~/.revealui`. Claude adapter off by default (`--claude-adapter` or `REVKIT_CLAUDE_ADAPTER=1` projects `~/.claude` from that home; no vendor config repo, no `claude` CLI) | all |
| 8 | Deploy the M-4 scanner to `~/.revealui/hooks` and attach it per enabled adapter | all |
| 9 | Wire fleet rules via `revcon/link.sh`: `--editor revealui` first, then vendor projections | all |
| 10 | Fleet-wide M-11 pre-push hook. `core.hooksPath` at `~/.config/revkit/git-hooks` (Linux/WSL, LF-normalized copy) or `<repo>/git-hooks` (Windows, in-repo) | all |

`bootstrap-wsl.sh` is a thin deprecation shim that execs `bootstrap.sh`. It
exists only to keep the legacy `bash ~/.revealui/bootstrap-wsl.sh` invocation
path (deployed clones, handoff instructions) working. `bootstrap.ps1` is the
Windows-host prep entrypoint.

---

## Tier model

| Tier | Trigger | Capabilities |
|---|---|---|
| **T0** | Sandbox drive not mounted | Shell env, git+SSH, Node (fnm), age secrets, Chrome bridge (WSL), `sandbox` CLI partial (help/validate work; `up` blocked) |
| **T1** | Sandbox drive mounted at `/mnt/sandbox` | All T0 + Docker services, Postgres (5433), Redis (6380), Ollama (11434, T1+ only via `sandbox up --ai`), build/package caches, `sandbox validate` full |

**Tier transitions** are detected automatically on shell login by
`shell/shellrc.d/00-base.sh`. The `sandbox validate` command verifies tier
consistency (no env-var drift between expected + actual).

The sandbox drive's role changed 2026-04-24 from "primary dev infra" to
"product-demo + security-research use." The T1 capabilities above remain
documented for completeness but are NOT the recommended deployment for daily
dev infra.
`pnpm store`, Docker data-root, Ollama models, build caches, and active ext4
working trees should stay on the primary WSL ext4 vhdx, not the sandbox drive
(NTFS/9p hostile + USB unplugability).

### Env vars

| Variable | T0 | T1 | Purpose |
|---|---|---|---|
| `REVKIT_OS` | set | set | Detected OS (`wsl`/`linux`/`macos`) |
| `DEVKIT_TIER` | `T0` | `T1` | Shell-detectable tier signal |
| `REVEALUI_ROOT` | set | set | RevKit repo root (pinned at bootstrap) |
| `REVKIT_CLAUDE_ADAPTER` | unset | unset | Set to `1` to project `~/.claude` from `~/.revealui`. Default off. |
| `REVEALUI_MODE` | `fleet`/`vibe`/`bare` | `fleet`/`vibe`/`bare` | Workflow fragment set. `managed` is a deprecated silent alias for `fleet`. When unset, `~/.config/revkit/mode` then `fleet`. Not a stream flag. |
| `STREAM_SAFE` / `REVVAULT_STREAM_SAFE` | overlay | overlay | Stream overlay ON (orthogonal). Also `RV_STREAM=1` from a terminal profile. |
| `REVVAULT_ALLOW_PRINT` | overlay | overlay | Vault-private overlay (full get/clip; keep window out of capture). |
| `REVEALUI_SANDBOX` | `/mnt/sandbox` | `/mnt/sandbox` | Sandbox-drive mount point (post-revkit#13) |
| `REVEALUI_SANDBOX_MOUNTED` | unset | `1` | Boolean signal |
| `SANDBOX_DATABASE_URL` | set (string) | set (string) | Postgres conn string at port 5433 |
| `SANDBOX_REDIS_URL` | set (string) | set (string) | Redis conn string at port 6380 |

**Drift note:** Joshua's deployed WSL still uses the legacy `forge` names
(`/mnt/forge`, `REVEALUI_FORGE`, `mount-forge-drive.sh`). Source repo
post-revkit#13 uses `sandbox` names. Re-bootstrap pending (no functional impact).
Tracked in MASTER_PLAN's Owner Action Queue.

---

## PowerShell surface (`RevealUI.RevStation` module)

| Cmdlet | Purpose |
|---|---|
| `Mount-WSLDev` | Mount the sandbox/forge drive into WSL via `wsl --mount` |
| `Sync-RevealUIToWindows` | One-shot mirror of the WSL RevealUI tree to a Windows path (manual / `wslsync` alias) |
| `Compact-VHDx` | Compact the WSL ext4.vhdx file to reclaim disk |
| `Register-VHDxCompactTask` | Install scheduled task to compact VHDx weekly |

Module discovery: profile chain in `C:\Program Files\PowerShell\7\profile.ps1` →
sources `~\.config\shell\profile.ps1` → loads RevealUI.RevStation when E:
connected. The VHDx helpers ship at `shell/compact-vhdx.ps1` +
`shell/Register-VHDxCompactTask.ps1`.

---

## Boot optimization

`shell/setup-wsl-boot.sh` (idempotent, supports `--revert`):

- Deploys `wsl.conf` and `.wslconfig`
- Masks hardware/desktop services unnecessary in WSL
- Disables Docker + snap auto-start (sockets preserved for on-demand activation)
- Default systemd target: `multi-user.target` (skips graphical transitions)
- WSL 2.7.0 pre-release recommended (`wsl --update --pre-release`)

---

## Backup model

**Weekly WSL `.tar` snapshot**. `scripts/weekly-wsl-backup.ps1` runs Sunday
03:00 via scheduled task `RevealUI-WSL-Weekly-Backup`; exports Ubuntu distro to
`E:\backups\wsl-snapshots\current\Ubuntu-<date>.tar`; keeps 2 most recent.
Task action is `conhost.exe --headless pwsh.exe ...` (bare `pwsh.exe` flashes
when Windows Terminal is the default console) with `WakeToRun=true` so a
sleeping host actually runs 03:00. Register with
`scripts/Register-WeeklyBackupTask.ps1`. Recovery: `wsl --import`.
`scripts/check-backup-staleness.ps1` guards against silent backup failures.
The live VHD lives at `E:\WSL\Ubuntu\ext4.vhdx` after `Move-WslVhdx.ps1`;
scripts fall back from `C:\WSL\` to `E:\WSL\` when the C: file is gone.
`wsl --manage --move` creates the destination. Do not pre-create it. An empty
leftover directory from an aborted move is removed first. After `wsl --shutdown`,
wait until the source VHD opens with `FileShare.None` before `--move`; retry on
`WSL_E_DISTRO_NOT_STOPPED`. One named mutex serializes concurrent launches.

The previous Windows-side mirror infrastructure (read-only `E:\projects\*`
clones synced by the `RevealUI-Repo-Sync` scheduled task; backup-guard hooks)
was retired 2026-05-08. GitHub remotes + the weekly WSL snapshot above are now
the redundancy layer.

---

## Versioning

Pre-1.0. RevKit is a config/shell repo (no `package.json`, no changeset). See
[`MASTER_PLAN.md`](./MASTER_PLAN.md) for the A/B/C/D phase scheme.

---

## Compose / coexistence

| Other product | Relationship |
|---|---|
| **RevealUI** | Independent. RevealUI runs anywhere with Node 24 + pnpm + Postgres; RevKit is one provisioning option |
| **RevVault** | RevKit sets up the age-identity mount path RevVault expects |
| **RevDev** | Independent. RevDev's harness daemon runs on whatever workstation RevKit (or any other tool) provisioned |
| **RevCon** | Pairs cleanly. RevKit wires fleet rules via `revcon/link.sh` native mode first, then vendor projections (bootstrap step 9) |
| **RevForge** | Independent. RevForge runs on a workstation; RevKit can provision that workstation |
| **RevSkills** | Independent. Skills are markdown, work in any RevKit-provisioned env |

---

## See also

- [`docs/MASTER_PLAN.md`](./MASTER_PLAN.md). Current status, A/B/C/D phases, owner actions
- [`docs/rfc-launcher.md`](./rfc-launcher.md). The `rfc` secure Claude launcher
- [`docs/tier-capabilities.md`](./tier-capabilities.md). Full T0/T1 capability matrix
- [`docs/WSL-CheatSheet.txt`](./WSL-CheatSheet.txt), [`docs/WSL-QuickReference.md`](./WSL-QuickReference.md)
- [`README.md`](../README.md). Quick start
- Fleet-level navigation lives in RevealUI Studio's separate private planning repository
