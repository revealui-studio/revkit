# shellcheck shell=bash
# RevealUI Studio / RevealFleet project aliases and shortcuts
#
# Naming: RevealUI = product monorepo; RevealUI Studio = company; RevealFleet = umbrella.
# Coordination: TRACKER free surfaces, fleet workboard, base origin/test, PR→test.
#
# Configure the planning checkout with REVEALFLEET_PLANNING. Its folder name
# is independent of REVEALFLEET_ROOT. TRACKER and workboard can be configured
# separately with REVEALUI_TRACKER and REVEALUI_WORKBOARD.

# Fleet root comes from the rc pin / install pin. Do not guess $HOME.
# REVEALFLEET_ROOT only. The legacy root variable is not read.

# Use the same maintained resolver as the launchers.
if ! declare -F __rv_planning_root >/dev/null; then
  # shellcheck source=../lib/fleet-root.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fleet-root.sh"
fi

# Quick project navigation
# cdreveal → primary RevealUI checkout (WSL-native ext4 at ~/revealfleet/revealui).
alias cdreveal='cd "$REVEALFLEET_ROOT/revealui" 2>/dev/null || echo "cdreveal: RevealUI checkout not found under \$REVEALFLEET_ROOT" >&2'
alias cdjv='cd "$(__rv_planning_root)" 2>/dev/null || echo "cdjv: private planning tree not found (set REVEALFLEET_PLANNING)" >&2'
alias cdfleet='cd "$REVEALFLEET_ROOT" 2>/dev/null || echo "cdfleet: \$REVEALFLEET_ROOT not found" >&2'
alias cdprojects='cd ~/projects'

# Day-to-day free surfaces (fleet methodology). Same idea as Nix shell `tracker`.
tracker() {
  local t="${REVEALUI_TRACKER:-}" planning
  if [ -z "$t" ]; then
    planning="$(__rv_planning_root)" || return 1
    t="$planning/docs/TRACKER.md"
  fi
  if [ ! -f "$t" ]; then
    echo "tracker: not found (set REVEALUI_TRACKER or open the private planning checkout)" >&2
    return 1
  fi
  if [ "${1:-}" = "watch" ]; then
    watch -n5 "glow '$t' 2>/dev/null || cat '$t'"
  else
    command -v glow >/dev/null 2>&1 && glow "$t" || less -R "$t"
  fi
}

# Canonical fleet workboard is <planning>/.revealui/workboard.md.
wb() {
  local _wb="${REVEALUI_WORKBOARD:-}" planning
  if [ -z "$_wb" ]; then
    planning="$(__rv_planning_root)" || return 1
    _wb="$planning/.revealui/workboard.md"
  fi
  if [ ! -f "$_wb" ]; then
    echo "wb: workboard not found (set REVEALUI_WORKBOARD). Expected .revealui/workboard.md" >&2
    return 1
  fi
  if [ "${1:-}" = "once" ]; then
    command -v glow >/dev/null 2>&1 && glow "$_wb" || cat "$_wb"
  else
    watch -n3 "glow '$_wb' 2>/dev/null || cat '$_wb'"
  fi
}

# Keep local integration refs (test/main) at origin tip. Thin wrapper onto
# the configured planning checkout's fleet-sync-integration.js.
# Never switches the current branch.
# Usage:
#   sync-test                  # --fix revealui
#   sync-test revkit           # --fix revkit
#   sync-test --status         # report revealui
#   sync-test --all --fix      # every fleet repo
sync-test() {
  local planning script
  planning="$(__rv_planning_root)" || return 1
  script="$planning/scripts/fleet-sync-integration.js"
  if [ ! -f "$script" ]; then
    echo "sync-test: missing $script in the configured planning checkout" >&2
    return 1
  fi
  if [ "$#" -eq 0 ]; then
    node "$script" --fix revealui
    return $?
  fi
  if [ "$#" -eq 1 ] && { [ "$1" = "--status" ] || [ "$1" = "-s" ]; }; then
    node "$script" --status revealui
    return $?
  fi
  node "$script" "$@"
}
