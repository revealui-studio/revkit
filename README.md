# RevealUI DevKit

Operator machine kit for RevealUI Studio workstations (macOS + Linux + WSL2, WSL-first).
This is **not** a customer runtime, product SDK, or end-user installer.

`bootstrap.sh` provisions the machine that runs the fleet: helper scripts, sudoers, global git hooks, and Claude/Grok launchers. Do not treat a clone of this repo as something to ship to a customer host.

## Version

`VERSION` is `0.3.0`. This is the first recorded field for this repo. It is
not a scaffold stamp: bootstrap, shell modes (fleet/vibe/bare), and the
fleet-root `rfg`/`rfc` launcher have all shipped. Still `0.x`. There is no
stable external contract. Not aligned to any other repo's number.


## Privilege warning

A default `bootstrap.sh` run is a privileged install. Preview first (`--dry-run`). It will:

- install helpers to `/usr/local/bin` on Linux/WSL (uses `sudo`; `~/.local/bin` on macOS)
- write WSL sudoers for passwordless sandbox-drive mounting (`/etc/sudoers.d/wsl-revealui`)
- set `git config --global core.hooksPath` to the fleet pre-push hook
- wire fleet rules into `.revealui` first when `revcon` is present, then project vendor dirs

Do not run this on a customer machine or any host you do not want those changes on.

## Quick Start

`bootstrap.sh` is the universal entry point. It detects the OS (macOS, Linux, or WSL2) and runs the platform-appropriate steps.

### macOS / native Linux

```bash
git clone https://github.com/RevealUIStudio/revkit.git
bash revkit/bootstrap.sh            # add --dry-run to preview
```

### WSL2 (Windows host)

Clone to your Windows home so WSL can reach it via `/mnt/c/`:

```powershell
# From PowerShell
cd $env:USERPROFILE
git clone https://github.com/RevealUIStudio/revkit.git .revealui
```

Then bootstrap from WSL:

```bash
bash /mnt/c/Users/$USER/.revealui/bootstrap.sh
```

> `bootstrap-wsl.sh` still works as a backward-compatible alias. It is now a thin shim that execs `bootstrap.sh` (which auto-detects WSL).

In more detail, the bootstrap also adds a `~/.bashrc`/`~/.zshrc` hook that resolves the shell mode (`fleet` / `vibe` / `bare`; `managed` is a silent alias for `fleet`) and sources the matching fragments from `shell/modes/*.list`, links git and SSH configs via `include.path` (per-user identity stays machine-local in `~/.config/revkit/`), applies WSL boot optimization (WSL), initializes Sandbox drive directories (if `/mnt/sandbox` is mounted), and deploys the M-4 sudoers/filesystem security scanner to `~/.revealui/hooks/`. A default run does not write `~/.claude` and does not run the `claude` CLI. `--claude-adapter` (or `REVKIT_CLAUDE_ADAPTER=1`) projects `~/.claude` from `~/.revealui`.

Launchers: **`rfc <repo>`** starts Claude in a fleet repo (WSL-native; same `bootstrap` / `claim` / `open` isolation as `rfg`); **`rfg <repo>`** starts Grok with RevealUI MCP token loaded from revvault (see [`docs/rfg-launcher.md`](docs/rfg-launcher.md) and [`docs/rfc-launcher.md`](docs/rfc-launcher.md)). The old `revealui` tmux workspace launcher is **retired** (GAP-351 / ADR 2026-06-23); `bootstrap.sh` overwrites `~/.local/bin/revealui` with a shim that prints `rfg` / `rfc`.

> **Upgrading from an older install:** the runtime tree moved from `wsl/` to `shell/` (and `bashrc.d/` to `shellrc.d/`). Just re-run `bootstrap.sh`. The rc hook is self-healing and migrates in place. No manual edit needed.

Open a new shell. You should see a `● RevKit: fleet` banner (default). `revkit-mode vibe` switches to the product-first subset; `revkit-mode bare` is the no-fragment escape hatch. `REVEALUI_MODE=managed` still works (silent alias for fleet). Streaming safety is an overlay (`revkit-mode stream-safe` / `RV_STREAM=1`), not a fourth mode. On WSL, run `wsl --shutdown` from Windows to apply the boot optimization.

### Per-machine configuration

RevKit ships **neutral, identity-free configs** under `shell/config/`. Per-user values are kept machine-local and are **not** committed. On bootstrap they are seeded into `~/.config/revkit/`:

- `~/.config/revkit/identity.gitconfig`. Your git name + email (seeded from your existing git identity if present)
- `~/.config/revkit/ssh.local`. Your SSH host blocks

Edit those files directly; the tracked `gitconfig` / `ssh-config` Include them. There is no profile/render step. That subsystem was removed in favor of this model.

## Structure

Planning tools use `REVEALFLEET_PLANNING`, an absolute path to your planning
checkout, independent of the fleet root and folder name. Configure it in your
shell configuration when using `tracker`, `wb`, `sync-test`, or private profiles.
These tools do not assume a personal planning folder. Launcher integration sync
is optional when no planning checkout is configured.

```
revkit/
  bootstrap.sh         # Universal entry point (macOS + Linux + WSL2)
  bootstrap-wsl.sh     # Deprecation shim → execs bootstrap.sh
  bootstrap.ps1        # Windows-host PowerShell prep
  lib/platform.sh      # OS detector (REVKIT_OS + capability predicates)
  shell/               # shellrc.d/, modes/, bin/, config/, docker/, setup-wsl-boot.sh
  scripts/             # backup + private-leak-scan scripts
  powershell/          # RevealUI.RevStation PowerShell module
  editor-configs/zed/  # portable Zed settings + rfc task
  git-hooks/           # M-11 fleet-wide pre-push hook
  docs/                # documentation
  tests/               # bash + Pester + platform-fixture suites
```

See [`docs/MASTER_SPEC.md`](docs/MASTER_SPEC.md) for the full surface area + configuration model, and [`docs/MASTER_PLAN.md`](docs/MASTER_PLAN.md) for status + roadmap.

## License

MIT

## RevealFleet Claude launcher (`rfc`)

`rfc <repo>` starts a Claude Code session whose process runs **inside WSL**,
rooted in a `~/revealfleet/*` repo. The configuration that makes a secure,
prompt-free session possible (commands stay native instead of being wrapped in
`wsl.exe`, so they allowlist by real prefix and the deny-list hooks fire). On
macOS and native Linux `rfc` runs the session locally in the target repo.

Deployed automatically by `bootstrap.sh` (`/usr/local/bin/rfc.sh` +
`shell/shellrc.d/50-rfc.sh`). Per-surface wiring (WSL terminal, Zed terminal, Zed
`claude-acp` extension) and the Claude Desktop limitation are documented in
[`docs/rfc-launcher.md`](docs/rfc-launcher.md).

## RevealFleet Codex launcher (`rfx`)

`rfx <repo>` starts Codex in a fleet repo with the same fleet root, worktree
env, storm preflight, and RevealUI MCP env as `rfg`. It does not auto-continue
a session. Resume with `rfx -- resume --last`.

```bash
rfx revealui
rfx open revealui my-label
rfx --dry-run revealui
rfx revealui -- --search "triage the failing test"
```

`bootstrap.sh` installs `rfx.sh` next to `rfg.sh` and symlinks the unsuffixed
PATH name `rfx` to that script. It does not write a Codex vendor home. The
audit-storm sweeper skips processes whose ancestor chain includes codex, rfx,
grok, rfg, rfc, claude, or cursor-agent. Details are in
[`docs/rfx-launcher.md`](docs/rfx-launcher.md).
