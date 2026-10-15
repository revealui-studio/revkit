# RevKit — Contributor Onboarding

RevKit is an **operator machine kit**, not a customer runtime. Use it to
provision a RevealUI Studio workstation (macOS, native Linux, WSL2; WSL-first).
Do not run the bootstrap on a customer host.

## Privilege warning

`bootstrap.sh` is a privileged installer. A default run writes WSL sudoers
(`/etc/sudoers.d/wsl-revealui`), sets `git config --global core.hooksPath`,
installs helpers to `/usr/local/bin` on Linux/WSL, and wires fleet rules
into `.revealui` when `revcon` is present. Always preview first (`--dry-run`).

## Prerequisites

- `git` and `bash`.
- macOS, native Linux, or Windows + WSL2 (Ubuntu).
- `node` is optional. If it is absent, the M-4 scanner install is skipped with a warning (everything else still runs).
- No prior RevealUI setup is assumed.

## 1. Clone

```bash
# macOS / native Linux
git clone https://github.com/RevealUIStudio/revkit.git

# WSL2 (clone into your Windows home so WSL reaches it via /mnt/c/)
#   PowerShell:  cd $env:USERPROFILE; git clone https://github.com/RevealUIStudio/revkit.git .revealui
```

## 2. Preview, then bootstrap

`bootstrap.sh` is the single, universal entry point. It detects your OS via
`lib/platform.sh` (`REVKIT_OS` ∈ `macos`/`linux`/`wsl`) and runs only the steps
that apply. **Always preview first:**

```bash
bash bootstrap.sh --dry-run     # prints every step, changes nothing
bash bootstrap.sh               # apply
```

> `bootstrap-wsl.sh` still works (it is a thin shim that execs `bootstrap.sh`) —
> prefer `bootstrap.sh` in new docs and scripts.

## 3. What bootstrap does

| Step | What | Where it runs |
|---|---|---|
| 1 | Install `shell/bin/*` helpers (WSL-only helpers skipped off WSL; `/usr/local/bin` on Linux/WSL) | all |
| 2 | Sudoers for passwordless sandbox mount | WSL only |
| 3 | Self-healing rc-hook into `.bashrc`/`.zshrc` | all |
| 4 | Git + SSH config includes (see below) | all |
| 5 | WSL boot optimization | WSL only |
| 6 | Sandbox directory init (if `/mnt/sandbox` mounted) | WSL only |
| 7 | Write the native control home `~/.revealui`. The Claude adapter is off unless `--claude-adapter` or `REVKIT_CLAUDE_ADAPTER=1`. When on, it projects `~/.claude` from that home. It does not clone a vendor config repo and it does not run the `claude` CLI. | all |
| 8 | Deploy the M-4 scanner to `~/.revealui/hooks` and attach it from each enabled adapter | all |
| 9 | Wire fleet rules via `revcon/link.sh`: `--editor revealui` first, then project vendor editors (skipped if revcon is absent) | all |
| 10 | Fleet-wide M-11 pre-push hook (`git config --global core.hooksPath`) | all |

## 4. Configuration model — neutral configs, machine-local identity

RevKit ships **identity-free** configs under `shell/config/` (committed). Your
**personal** values stay machine-local and are **never committed** — bootstrap
seeds them into `~/.config/revkit/`:

| File | What you set |
|---|---|
| `~/.config/revkit/identity.gitconfig` | your git `name` + `email` (seeded from your existing git identity if present) |
| `~/.config/revkit/ssh.local` | your SSH `Host` blocks |

The tracked `shell/config/gitconfig` and `shell/config/ssh-config` `include` /
`Include` those files. To set your identity, edit them directly — there is **no
profile or render step** (the old TOML-profile/`render.sh` model was removed).

## 5. Verify

Open a new shell — you should see:

```
● RevKit: fleet (/path/to/revkit)
```

That is the default engineer/fleet mode (formerly `managed`; `REVEALUI_MODE=managed` still maps to fleet). Switch with `revkit-mode`:

```
revkit-mode                 # print workflow mode + stream overlay
revkit-mode vibe            # product-first subset; banner ● RevKit: vibe
revkit-mode bare            # no fragments; banner ● RevKit: bare
revkit-mode fleet           # full shellrc.d surface
revkit-mode stream-safe     # overlay ON (does not change fleet/vibe/bare)
revkit-mode vault-private   # overlay vault-private (does not change mode)
```

Preference for the **workflow** mode is stored in `~/.config/revkit/mode` and used on the next login when `REVEALUI_MODE` is unset. The stream overlay is per-window (not written to that file).

### Workflow modes vs stream overlay

`bare` / `fleet` / `vibe` are the only workflow modes. Streaming safety is
orthogonal: `STREAM_SAFE`, `RV_STREAM=1`, `stream-safe`, `vault-private`, or
`revkit-mode stream-safe` / `revkit-mode vault-private`. There is no
`REVEALUI_MODE=stream`.

**YouTube / OBS:** capture a **fleet or vibe** terminal with stream-safe ON.
Keep any vault-private window out of the capture layout. Stream-safe does
**not** redact IDE chat panes (Claude, Grok, Cursor, Zed) — keep those off
stream.

Optional Windows Terminal profiles (merge the sample into your settings; RevKit
does not overwrite them): [`windows-terminal-profiles.sample.json`](./windows-terminal-profiles.sample.json).

On WSL, run `wsl --shutdown` from Windows once to apply the boot optimization.

To start a secure, WSL-native Claude session in a fleet repo, use `rfc <repo>`
(see [`rfc-launcher.md`](./rfc-launcher.md)).

## 6. Upgrading an older install

The runtime tree moved from `wsl/` to `shell/` (and `bashrc.d/` to
`shellrc.d/`). Just re-run `bootstrap.sh` — the rc-hook is self-healing and
migrates in place.

## More

- [`MASTER_SPEC.md`](./MASTER_SPEC.md). Full surface area and configuration model.
- [`agent-coordination.md`](./agent-coordination.md). Native `.revealui` paths and `.revealui/workboard.md`
- [`MASTER_PLAN.md`](./MASTER_PLAN.md) — status + roadmap
- [`tier-capabilities.md`](./tier-capabilities.md) — T0/T1 (sandbox-drive) capabilities
- [`rfc-launcher.md`](./rfc-launcher.md) — the `rfc` secure Claude launcher
- [`WSL-QuickReference.md`](./WSL-QuickReference.md) + [`WSL-CheatSheet.txt`](./WSL-CheatSheet.txt) — WSL ops
