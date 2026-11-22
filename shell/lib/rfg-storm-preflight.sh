#!/usr/bin/env bash
# rfg-storm-preflight: called from rfg before sync, MCP load, and grok.
# Clears known audit du/find storms. Warns on stderr if a matching process
# is still in uninterruptible disk sleep, then continues. Never hard-fails launch.
# The sweeper skips a process whose ancestor chain includes codex, rfx, grok,
# rfg, rfc, claude, or cursor-agent. A live agent scan is not an orphan.
#
# Skip: RFG_STORM_PREFLIGHT_SKIP=1
# Min age seconds (default 120): RFG_STORM_MIN_AGE_SEC
# shellcheck shell=bash
set -euo pipefail

if [ "${RFG_STORM_PREFLIGHT_SKIP:-0}" = 1 ]; then
  exit 0
fi

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_script=""
_c=""
for _c in \
  "$_here/kill-audit-storms.sh" \
  "/usr/local/lib/revkit/kill-audit-storms.sh" \
  "${REVEALUI_ROOT:-}/shell/lib/kill-audit-storms.sh"
do
  if [ -n "$_c" ] && [ -f "$_c" ]; then
    _script="$_c"
    break
  fi
done

if [ -n "$_script" ]; then
  # shellcheck disable=SC1090
  . "$_script"
  AUDIT_STORM_MIN_AGE_SEC="${RFG_STORM_MIN_AGE_SEC:-120}"
  export AUDIT_STORM_MIN_AGE_SEC
  RFG_STORM_PROTECT_PIDS="${RFG_STORM_PROTECT_PIDS:-} $$ ${PPID:-}"
  export RFG_STORM_PROTECT_PIDS
  # stderr: rfg open --no-agent prints the worktree path on stdout.
  audit_storm_main >&2 || true
fi

_d_left=""
if declare -F audit_storm_dstate_lines >/dev/null 2>&1; then
  _d_left="$(audit_storm_dstate_lines || true)"
fi
if [ -n "$_d_left" ]; then
  echo "rfg: warning: disk-sleep leftovers still present (I/O may stall). Ctrl-C and re-run, or: kill-audit-storms" >&2
  echo "$_d_left" >&2
fi
exit 0
