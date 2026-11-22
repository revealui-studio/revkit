# shellcheck shell=bash
# rfx: RevealFleet Codex launcher: short command + completion (interactive).
#
# Implementation: shell/bin/rfx.sh (installed by bootstrap to /usr/local/bin
# or ~/.local/bin, with an unsuffixed symlink named rfx). Loads RevealUI MCP
# token from revvault and execs codex. See docs/rfx-launcher.md.

rfx() {
  local impl
  if command -v rfx.sh >/dev/null 2>&1; then
    impl="$(command -v rfx.sh)"
  elif [ -x /usr/local/bin/rfx.sh ]; then
    impl=/usr/local/bin/rfx.sh
  elif [ -x "$HOME/.local/bin/rfx.sh" ]; then
    impl="$HOME/.local/bin/rfx.sh"
  elif [ -n "${REVEALUI_ROOT:-}" ] && [ -x "$REVEALUI_ROOT/shell/bin/rfx.sh" ]; then
    impl="$REVEALUI_ROOT/shell/bin/rfx.sh"
  else
    echo "rfx: rfx.sh not installed. Re-run revkit bootstrap.sh or: ln -sfn \"\$REVEALFLEET_ROOT/revkit/shell/bin/rfx.sh\" ~/.local/bin/rfx.sh" >&2
    return 1
  fi
  "$impl" "$@"
}

# Bash tab-completion: first arg = fleet repo (same as rfg)
if [ -n "${BASH_VERSION:-}" ] && command -v complete >/dev/null 2>&1; then
  _rfx_complete() {
    [ "${COMP_CWORD:-0}" -eq 1 ] || return 0
    local root="${REVEALFLEET_ROOT:-}"
    [ -n "$root" ] || return 0
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local d repos=(mint smoke env bootstrap claim open help)
    for d in "$root"/*/ "$root"/.*/; do
      [ -e "${d}.git" ] || continue
      d="${d%/}"; repos+=("${d##*/}")
    done
    mapfile -t COMPREPLY < <(compgen -W "${repos[*]}" -- "$cur")
  }
  complete -F _rfx_complete rfx
fi
