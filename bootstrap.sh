#!/usr/bin/env bash
# bootstrap.sh - cross-platform RevKit bootstrap (macOS + Linux + WSL2).
# Operator machine kit (not a customer runtime): writes sudoers (WSL), sets git config --global core.hooksPath, installs to /usr/local/bin, wires fleet hooks.
#
# Replaces bootstrap-wsl.sh as the universal entry point. Detect-then-dispatch:
# everything that is platform-agnostic runs unconditionally; WSL-only steps are
# gated by revkit_is_wsl; macOS-specific paths are chosen by revkit_is_macos.
#
# Usage:
#   bash bootstrap.sh                  # install (claude adapter off)
#   bash bootstrap.sh --dry-run        # preview steps, make no changes
#   bash bootstrap.sh --claude-adapter # also project ~/.claude from ~/.revealui
#
# REVKIT_CLAUDE_ADAPTER=1 is the same opt-in as --claude-adapter.
# REVKIT_BOOTSTRAP_ONLY=control runs only the native control layer (tests).

set -euo pipefail

DRY_RUN=0
CLAUDE_ADAPTER=0
if [ "${REVKIT_CLAUDE_ADAPTER:-0}" = "1" ]; then
  CLAUDE_ADAPTER=1
fi
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --claude-adapter) CLAUDE_ADAPTER=1 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 1 ;;
  esac
done
if [ "$CLAUDE_ADAPTER" -eq 1 ]; then
  REVKIT_CLAUDE_ADAPTER=1
else
  REVKIT_CLAUDE_ADAPTER=0
fi
export REVKIT_CLAUDE_ADAPTER

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load OS detection + capability predicates (sets REVKIT_OS; exports predicates).
. "$SCRIPT_DIR/lib/platform.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/shell/lib/fleet-root.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/shell/lib/native-home.sh"

echo ""
echo "=== RevKit Bootstrap ==="
echo "Source:   $SCRIPT_DIR"
echo "Platform: $REVKIT_OS"
[ "$DRY_RUN" -eq 1 ] && echo "Mode:     dry-run (no changes)"
echo ""

# Test harness: prove the control layer without sudo, rc, or git-config writes.
if [ "${REVKIT_BOOTSTRAP_ONLY:-}" = "control" ]; then
  revkit_bootstrap_control_layer
  exit 0
fi

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Resolve platform-appropriate directories
# ---------------------------------------------------------------------------

# helpers dir: user-owned on macOS (no sudo), system-wide on Linux/WSL.
# Matched lib prefix is always <prefix>/lib/revkit next to <prefix>/bin.
if revkit_is_macos; then
  HELPERS_DIR="$HOME/.local/bin"
else
  HELPERS_DIR="/usr/local/bin"
fi
LIBS_DIR="$(cd "$(dirname "$HELPERS_DIR")" && pwd)/lib/revkit"

# RC files: hook into every present rc file + the platform-primary one.
_rc_files=()
[ -f "$HOME/.bashrc" ] && _rc_files+=("$HOME/.bashrc")
[ -f "$HOME/.zshrc"  ] && _rc_files+=("$HOME/.zshrc")
# Ensure at least one file exists to receive the hook.
if [ ${#_rc_files[@]} -eq 0 ]; then
  if revkit_is_macos; then
    _rc_files+=("$HOME/.zshrc")
  else
    _rc_files+=("$HOME/.bashrc")
  fi
fi

# ---------------------------------------------------------------------------
# Step 1: Install helper scripts
# ---------------------------------------------------------------------------
echo "[1] Installing helper scripts to $HELPERS_DIR..."
if [ "$DRY_RUN" -eq 0 ] && ! revkit_is_macos; then
  sudo mkdir -p "$HELPERS_DIR"
elif [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$HELPERS_DIR"
fi

_installed=0
for script in "$SCRIPT_DIR/shell/bin/"*.sh; do
  [ -f "$script" ] || continue
  name="$(basename "$script")"
  # Skip WSL-only helpers on non-WSL platforms.
  case "$name" in
    mount-sandbox-drive.sh | sandbox-services.sh | sandbox-validate.sh | wsl-status.sh)
      if ! revkit_is_wsl; then
        printf '  [skip-wsl] %s\n' "$name"
        continue
      fi
      ;;
  esac
  if revkit_is_macos; then
    run cp "$script" "$HELPERS_DIR/$name"
    run chmod +x "$HELPERS_DIR/$name"
  else
    # Positional-arg form: $script reaches sed as "$1", never re-parsed by a
    # second shell (an injection-safe replacement for `bash -c "... $script ..."`).
    run sh -c 'sed "s/\r$//" "$1" | sudo tee "$2" >/dev/null' _ "$script" "$HELPERS_DIR/$name"
    run sudo chmod +x "$HELPERS_DIR/$name"
  fi
  printf '  Installed: %s/%s\n' "$HELPERS_DIR" "$name"
  _installed=$((_installed + 1))
  # Unsuffixed PATH name so `revkit-mode` works in bare shells too.
  if [ "$name" = "revkit-mode.sh" ]; then
    if revkit_is_macos; then
      run cp "$HELPERS_DIR/$name" "$HELPERS_DIR/revkit-mode"
      run chmod +x "$HELPERS_DIR/revkit-mode"
    else
      run sudo cp "$HELPERS_DIR/$name" "$HELPERS_DIR/revkit-mode"
      run sudo chmod +x "$HELPERS_DIR/revkit-mode"
    fi
    printf '  Installed: %s/revkit-mode\n' "$HELPERS_DIR"
  fi
  # Unsuffixed PATH name so `kill-audit-storms` matches the rfg warning.
  if [ "$name" = "kill-audit-storms.sh" ]; then
    if revkit_is_macos; then
      run cp "$HELPERS_DIR/$name" "$HELPERS_DIR/kill-audit-storms"
      run chmod +x "$HELPERS_DIR/kill-audit-storms"
    else
      run sudo cp "$HELPERS_DIR/$name" "$HELPERS_DIR/kill-audit-storms"
      run sudo chmod +x "$HELPERS_DIR/kill-audit-storms"
    fi
    printf '  Installed: %s/kill-audit-storms\n' "$HELPERS_DIR"
  fi
  # Unsuffixed PATH name next to rfg.sh. Symlink, not a second copy.
  # Does not write a vendor home.
  if [ "$name" = "rfx.sh" ]; then
    if revkit_is_macos; then
      run ln -sfn "$name" "$HELPERS_DIR/rfx"
    else
      run sudo ln -sfn "$name" "$HELPERS_DIR/rfx"
    fi
    printf '  Installed: %s/rfx -> %s\n' "$HELPERS_DIR" "$name"
  fi
done
printf '  %d helper(s) installed.\n' "$_installed"

# GAP-351: the untracked tmux launcher lived at ~/.local/bin/revealui (no
# .sh suffix) and still pointed at ~/projects. Always overwrite that PATH
# name with the tracked retire shim so muscle memory cannot start tmux.
echo "[1b] Installing retired revealui PATH name at ~/.local/bin/revealui..."
_shim="$SCRIPT_DIR/shell/bin/revealui.sh"
if [ -f "$_shim" ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$HOME/.local/bin"
    sed 's/\r$//' "$_shim" > "$HOME/.local/bin/revealui"
    chmod +x "$HOME/.local/bin/revealui"
  else
    printf '  [dry-run] %s -> %s/revealui\n' "$_shim" "$HOME/.local/bin"
  fi
  printf '  Installed: %s/revealui (retired; use rfg / rfc)\n' "$HOME/.local/bin"
else
  printf '  [skip] %s missing\n' "$_shim"
fi

# Matched lib prefix: rfg/rfc copies in <prefix>/bin load <prefix>/lib/revkit.
# This is the portable install unit (Linux /usr/local, macOS ~/.local). Not $HOME/revealfleet.
echo "[1d] Installing matched libs to $LIBS_DIR..."
if [ "$DRY_RUN" -eq 0 ] && ! revkit_is_macos; then
  sudo mkdir -p "$LIBS_DIR"
elif [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$LIBS_DIR"
fi
_lib_n=0
for lib in "$SCRIPT_DIR/shell/lib/"*.sh; do
  [ -f "$lib" ] || continue
  name="$(basename "$lib")"
  if revkit_is_macos; then
    run cp "$lib" "$LIBS_DIR/$name"
  else
    run sh -c 'sed "s/\r$//" "$1" | sudo tee "$2" >/dev/null' _ "$lib" "$LIBS_DIR/$name"
  fi
  _lib_n=$((_lib_n + 1))
done
if [ -d "$SCRIPT_DIR/shell/grok-home" ]; then
  if revkit_is_macos; then
    run mkdir -p "$LIBS_DIR/grok-home"
    run cp "$SCRIPT_DIR/shell/grok-home/AGENTS.md" "$LIBS_DIR/grok-home/AGENTS.md"
  else
    run sudo mkdir -p "$LIBS_DIR/grok-home"
    run sh -c 'sed "s/\r$//" "$1" | sudo tee "$2" >/dev/null' _ \
      "$SCRIPT_DIR/shell/grok-home/AGENTS.md" "$LIBS_DIR/grok-home/AGENTS.md"
  fi
fi
_fleet_pin_rc=0
_FLEET_PIN="$(rfg_infer_fleet_from_path "$SCRIPT_DIR")" || _fleet_pin_rc=$?
if [ "$_fleet_pin_rc" -eq 78 ]; then
  exit 78
fi
unset _fleet_pin_rc
_PIN_BODY="# revkit matched-prefix pin. Absolute paths. Generated by bootstrap.sh."$'\n'
_PIN_BODY+="REVEALUI_ROOT=$SCRIPT_DIR"$'\n'
if [ -n "$_FLEET_PIN" ]; then
  _PIN_BODY+="REVEALFLEET_ROOT=$_FLEET_PIN"$'\n'
fi
if [ "$DRY_RUN" -eq 0 ]; then
  if revkit_is_macos; then
    printf '%s' "$_PIN_BODY" > "$LIBS_DIR/pin.env"
  else
    printf '%s' "$_PIN_BODY" | sudo tee "$LIBS_DIR/pin.env" >/dev/null
  fi
else
  printf '  [dry-run] pin.env REVEALUI_ROOT=%s REVEALFLEET_ROOT=%s\n' \
    "$SCRIPT_DIR" "${_FLEET_PIN:-unset}"
fi
printf '  %d lib(s) + pin at %s\n' "$_lib_n" "$LIBS_DIR"

# Deploy Grok vendor hooks from the product manager (SSOT in git). HOME is
# the attach point Grok CLI requires; operators must not `cp` policy there.
echo "[1c] Attaching Grok vendor hooks from product manager (if present)..."
# shellcheck disable=SC1091
if [ -f "$SCRIPT_DIR/shell/lib/grok-attach.sh" ]; then
  . "$SCRIPT_DIR/shell/lib/grok-attach.sh"
  if [ -f "$SCRIPT_DIR/shell/lib/fleet-root.sh" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/shell/lib/fleet-root.sh"
  fi
  _product=""
  if [ -n "${_FLEET_PIN:-}" ]; then
    _product="$_FLEET_PIN/revealui"
  else
    _product_rc=0
    _product="$(rfg_resolve_fleet_root)" || _product_rc=$?
    if [ "$_product_rc" -eq 78 ]; then
      exit 78
    fi
    unset _product_rc
    [ -n "$_product" ] && _product="$_product/revealui"
  fi
  if [ -z "$_product" ]; then
    printf '  [skip] fleet root unresolved (set REVEALFLEET_ROOT)\n'
  elif [ "$DRY_RUN" -eq 0 ]; then
    rfg_attach_grok_constitution
    rfg_attach_grok_hooks "$_product"
    printf '  Attached Grok HOME stub + hooks from %s\n' "$_product"
  else
    printf '  [dry-run] rfg_attach_grok_constitution; rfg_attach_grok_hooks %s\n' "$_product"
  fi
else
  printf '  [skip] grok-attach.sh missing\n'
fi

# Shared shell libs (rfg worktree-env, mcp-env, …) next to helpers so installed
# rfg.sh can source them without requiring a revkit git checkout on PATH.
_lib_installed=0
_lib_dest="$(dirname "$HELPERS_DIR")/lib/revkit"
if [ "$DRY_RUN" -eq 0 ]; then
  if revkit_is_macos; then
    mkdir -p "$_lib_dest"
  else
    sudo mkdir -p "$_lib_dest"
  fi
fi
for lib in "$SCRIPT_DIR/shell/lib/"*.sh; do
  [ -f "$lib" ] || continue
  name="$(basename "$lib")"
  if revkit_is_macos; then
    run cp "$lib" "$_lib_dest/$name"
    run chmod 644 "$_lib_dest/$name"
  else
    run sh -c 'sed "s/\r$//" "$1" | sudo tee "$2" >/dev/null' _ "$lib" "$_lib_dest/$name"
    run sudo chmod 644 "$_lib_dest/$name"
  fi
  printf '  Installed lib: %s/%s\n' "$_lib_dest" "$name"
  _lib_installed=$((_lib_installed + 1))
done
printf '  %d shell lib(s) installed.\n' "$_lib_installed"

# Grok HOME stub (AGENTS.md only) next to grok-attach.sh.
_gh_src="$SCRIPT_DIR/shell/grok-home"
_gh_dest="$_lib_dest/grok-home"
if [ -f "$_gh_src/AGENTS.md" ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    if revkit_is_macos; then
      mkdir -p "$_gh_dest"
    else
      sudo mkdir -p "$_gh_dest"
    fi
  fi
  if revkit_is_macos; then
    run cp "$_gh_src/AGENTS.md" "$_gh_dest/AGENTS.md"
    run chmod 644 "$_gh_dest/AGENTS.md"
  else
    run sh -c 'sed "s/\r$//" "$1" | sudo tee "$2" >/dev/null' _ "$_gh_src/AGENTS.md" "$_gh_dest/AGENTS.md"
    run sudo chmod 644 "$_gh_dest/AGENTS.md"
  fi
  printf '  Installed Grok home stub: %s/AGENTS.md\n' "$_gh_dest"
else
  printf '  [skip] shell/grok-home/AGENTS.md missing\n'
fi

# ---------------------------------------------------------------------------
# Step 2: Sudoers. WSL only (passwordless mount for sandbox drive)
# ---------------------------------------------------------------------------
if revkit_is_wsl; then
  echo "[2] Configuring sudoers for passwordless mount..."
  SUDOERS_FILE="/etc/sudoers.d/wsl-revealui"
  CURRENT_USER="$(whoami)"
  if [ "$DRY_RUN" -eq 0 ]; then
    sudo tee "$SUDOERS_FILE" > /dev/null << EOF
# RevKit. Passwordless mount (pinned to --mount-only; --init requires interactive sudo).
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/local/bin/mount-sandbox-drive.sh --mount-only
EOF
    sudo chmod 0440 "$SUDOERS_FILE"
    if sudo visudo -cf "$SUDOERS_FILE" > /dev/null 2>&1; then
      echo "  Sudoers validated (NOPASSWD pinned to --mount-only)"
    else
      echo "  ERROR: Sudoers syntax error, removing" >&2
      sudo rm "$SUDOERS_FILE"
      exit 1
    fi
  else
    printf '  [dry-run] would write %s\n' "$SUDOERS_FILE"
  fi
else
  echo "[2] Sudoers. Skipped (not WSL)"
fi

# ---------------------------------------------------------------------------
# Step 3: RC hook (bash + zsh)
# ---------------------------------------------------------------------------
echo "[3] Adding RevKit hook to rc file(s)..."
MARKER="# --- RevealUI environment mode ---"
END_MARKER="# --- end RevealUI ---"

for rcfile in "${_rc_files[@]}"; do
  # One-time pristine backup before any in-place rewrite. Guarded so re-runs
  # never clobber the original snapshot with already-modified content.
  if [ "$DRY_RUN" -eq 0 ] && [ -f "$rcfile" ] && [ ! -f "$rcfile.revkit.bak" ]; then
    cp "$rcfile" "$rcfile.revkit.bak"
  fi

  # Self-healing: remove any stale RevKit block before re-adding. Strip only
  # when BOTH markers are present. A lone OPEN marker (truncated/hand-edited
  # rc) would otherwise make awk drop everything to EOF.
  if grep -qF "$MARKER" "$rcfile" 2>/dev/null && grep -qF "$END_MARKER" "$rcfile" 2>/dev/null; then
    if [ "$DRY_RUN" -eq 0 ]; then
      # Temp beside the target so the final mv is an atomic same-fs rename.
      _tmp="$(mktemp "${rcfile}.revkit.XXXXXX")"
      # END guard: if the OPEN block never closed, drop stays set -> exit 3 ->
      # leave the original untouched rather than truncate it.
      if awk -v s="$MARKER" -v e="$END_MARKER" '
        $0 == s { drop = 1 }
        drop != 1 { print }
        $0 == e { drop = 0 }
        END { if (drop) exit 3 }
      ' "$rcfile" > "$_tmp"; then
        mv "$_tmp" "$rcfile"
        printf '  Removed stale hook from %s (reinstalling)\n' "$rcfile"
      else
        rm -f "$_tmp"
        printf '  WARNING: %s has an unterminated RevKit block; left untouched\n' "$rcfile" >&2
      fi
    else
      printf '  Removed stale hook from %s (reinstalling)\n' "$rcfile"
    fi
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    # Atomic append: assemble (existing + new block) in a sibling temp, then
    # rename into place so the rc file is never left half-written.
    _tmp="$(mktemp "${rcfile}.revkit.XXXXXX")"
    [ -f "$rcfile" ] && cat "$rcfile" > "$_tmp"
    cat >> "$_tmp" << HOOKEOF

# --- RevealUI environment mode ---
# Absolute pins captured at bootstrap. Not \$HOME/revealfleet at runtime.
export REVEALUI_ROOT="$SCRIPT_DIR"
${_FLEET_PIN:+export REVEALFLEET_ROOT="$_FLEET_PIN"}
# Guard: apply once per terminal session. Mode resolution (env >
# ~/.config/revkit/mode > fleet) lives in shell/lib/revkit-mode.sh.
# managed is a silent alias for fleet. Subshells inherit REVEALUI_SHELL_READY.
if [ -z "\${REVEALUI_SHELL_READY:-}" ]; then
  if [ -f "\${REVEALUI_ROOT}/shell/lib/revkit-mode.sh" ]; then
    . "\${REVEALUI_ROOT}/shell/lib/revkit-mode.sh"
    revkit_mode_activate
  else
    export REVEALUI_MODE="bare"
    export REVEALUI_SHELL_READY=1
    printf '\033[0;37m● RevKit: bare\033[0m\n'
  fi
fi
# --- end RevealUI ---
HOOKEOF
    mv "$_tmp" "$rcfile"
  else
    printf '  [dry-run] would append hook to %s\n' "$rcfile"
  fi
  printf '  Hook installed: %s\n' "$rcfile"
done

# ---------------------------------------------------------------------------
# Step 4: Git + SSH configs
# ---------------------------------------------------------------------------
echo "[4] Linking git and SSH configs..."
CONFIGS_DIR="$SCRIPT_DIR/shell/config"
LOCAL_CFG="$HOME/.config/revkit"

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$LOCAL_CFG"
  if [ ! -f "$LOCAL_CFG/identity.gitconfig" ]; then
    _gn="$(git config --global user.name 2>/dev/null || true)"
    _ge="$(git config --global user.email 2>/dev/null || true)"
    {
      echo "# RevKit per-user git identity. Machine-local, never committed."
      echo "[user]"
      printf '\tname = %s\n' "$_gn"
      printf '\temail = %s\n' "$_ge"
    } > "$LOCAL_CFG/identity.gitconfig"
    if [ -n "$_gn" ] && [ -n "$_ge" ]; then
      echo "  Seeded $LOCAL_CFG/identity.gitconfig from existing git identity"
    else
      echo "  Created $LOCAL_CFG/identity.gitconfig. Set your git name + email there"
    fi
  else
    echo "  $LOCAL_CFG/identity.gitconfig already exists"
  fi

  if [ ! -f "$LOCAL_CFG/ssh.local" ]; then
    {
      echo "# RevKit per-user SSH overrides. Machine-local, never committed."
      echo "# Add Host blocks here; the tracked ssh-config includes this file."
    } > "$LOCAL_CFG/ssh.local"
    echo "  Created $LOCAL_CFG/ssh.local"
  fi

  if [ -f "$CONFIGS_DIR/gitconfig" ]; then
    git config --global include.path "$CONFIGS_DIR/gitconfig"
    echo "  Git config: include.path → $CONFIGS_DIR/gitconfig"
  fi

  if [ -f "$CONFIGS_DIR/ssh-config" ]; then
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    if ! grep -qF "Include $CONFIGS_DIR/ssh-config" ~/.ssh/config 2>/dev/null; then
      if [ -f ~/.ssh/config ]; then
        _tmp="$(mktemp)"
        printf 'Include %s\n\n' "$CONFIGS_DIR/ssh-config" > "$_tmp"
        cat ~/.ssh/config >> "$_tmp"
        mv "$_tmp" ~/.ssh/config
      else
        printf 'Include %s\n' "$CONFIGS_DIR/ssh-config" > ~/.ssh/config
      fi
      chmod 600 ~/.ssh/config
      echo "  SSH config: Include directive added"
    else
      echo "  SSH config: Include already present"
    fi
  fi
else
  printf '  [dry-run] would seed %s/{identity.gitconfig,ssh.local}\n' "$LOCAL_CFG"
  printf '  [dry-run] would set git include.path + SSH Include\n'
fi

# ---------------------------------------------------------------------------
# Step 5: WSL boot optimization. WSL only
# ---------------------------------------------------------------------------
if revkit_is_wsl; then
  echo "[5] Running WSL boot optimization..."
  BOOT_SCRIPT="$SCRIPT_DIR/shell/setup-wsl-boot.sh"
  if [ -f "$BOOT_SCRIPT" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      sudo bash "$BOOT_SCRIPT"
    else
      printf '  [dry-run] would run %s\n' "$BOOT_SCRIPT"
    fi
  else
    printf '  WARNING: %s not found, skipping\n' "$BOOT_SCRIPT" >&2
  fi
else
  echo "[5] WSL boot optimization. Skipped (not WSL)"
fi

# ---------------------------------------------------------------------------
# Step 6: Sandbox directory init. WSL only
# ---------------------------------------------------------------------------
if revkit_is_wsl; then
  if mountpoint -q /mnt/sandbox 2>/dev/null; then
    echo "[6] Initializing Sandbox directories..."
    for d in databases/postgres databases/redis databases/supabase models cache; do
      run mkdir -p "/mnt/sandbox/$d"
    done
    echo "  Sandbox directories initialized"
  else
    echo "[6] Sandbox drive not mounted, skipping directory init"
  fi
else
  echo "[6] Sandbox directories. Skipped (not WSL)"
fi

# ---------------------------------------------------------------------------
# Steps 7-9: native control home, then vendor projections
# ---------------------------------------------------------------------------
# ~/.revealui is written first. The claude adapter is off unless
# --claude-adapter or REVKIT_CLAUDE_ADAPTER=1. When on, it projects pointers
# from that native home. It does not clone a vendor config repo and it does
# not run the claude CLI. Fleet link uses --editor revealui. Extra editors
# come from REVKIT_LINK_EDITORS because revcon copy mode replaces files.
revkit_bootstrap_control_layer

# ---------------------------------------------------------------------------
# Step 10: Fleet-wide pre-push hook (M-11)
# ---------------------------------------------------------------------------
echo "[10] Wiring fleet-wide pre-push hook (M-11)..."
HOOKS_SRC_DIR="$SCRIPT_DIR/git-hooks"
PRE_PUSH_HOOK="$HOOKS_SRC_DIR/pre-push"
# Deploy hooks to a stable, user-owned path OUTSIDE the repo. Pointing
# core.hooksPath at the in-repo copy would run a CRLF-corrupted hook whenever
# the tree was checked out with autocrlf=true; deploying an LF-normalized copy
# here keeps M-11 working regardless of the clone's line-ending settings.
HOOKS_DIR="$HOME/.config/revkit/git-hooks"

if [ ! -f "$PRE_PUSH_HOOK" ]; then
  printf '  WARNING: %s not found. Skipping M-11\n' "$PRE_PUSH_HOOK" >&2
elif ! bash -n "$PRE_PUSH_HOOK" >/dev/null 2>&1; then
  printf '  ERROR: %s failed bash -n; refusing to wire M-11\n' "$PRE_PUSH_HOOK" >&2
  exit 1
else
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$HOOKS_DIR"
    sed 's/\r$//' "$PRE_PUSH_HOOK" > "$HOOKS_DIR/pre-push"
    chmod +x "$HOOKS_DIR/pre-push"
    EXISTING="$(git config --global --get core.hooksPath 2>/dev/null || true)"
    if [ "$EXISTING" = "$HOOKS_DIR" ]; then
      echo "  global core.hooksPath already set (no-op)"
    elif [ -z "$EXISTING" ] || [ "$EXISTING" = "$HOOKS_SRC_DIR" ]; then
      # Fresh install, or migrating off the legacy in-repo hooks path.
      git config --global core.hooksPath "$HOOKS_DIR"
      printf '  Set: global core.hooksPath = %s\n' "$HOOKS_DIR"
    else
      printf '  ERROR: global core.hooksPath already points elsewhere:\n' >&2
      printf '    current: %s\n' "$EXISTING" >&2
      printf '    revkit:  %s\n' "$HOOKS_DIR" >&2
      printf '  Resolve: git config --global --unset core.hooksPath\n' >&2
      exit 1
    fi
    echo "  M-11 active: pre-push rejects direct/force/unsigned pushes to main + test"
  else
    printf '  [dry-run] would deploy LF-normalized pre-push to %s and set core.hooksPath\n' "$HOOKS_DIR"
  fi
fi

echo ""
echo "=== RevKit Bootstrap Complete ($REVKIT_OS) ==="
echo ""
echo "Restart your shell or:"
if revkit_is_macos; then
  echo "  source ~/.zshrc"
else
  echo "  source ~/.bashrc"
fi
echo ""
