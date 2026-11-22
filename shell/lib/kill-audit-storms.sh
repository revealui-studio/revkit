#!/usr/bin/env bash
# kill-audit-storms: clear leftover laptop audit du/find storms that wedge WSL I/O.
# Only known audit patterns, and only processes older than AUDIT_STORM_MIN_AGE_SEC
# (default 600). Never kills live grok, the current rfg process, this sweeper,
# or unrelated user work.
#
# Never kills a process whose ancestor chain (PPID walk up to init), including
# the process itself, contains an agent session or launcher: codex, rfx, grok,
# rfg, rfc, claude, or cursor-agent. Those scans belong to a live session.
# Only orphaned storms are cleared.
#
# AUDIT_STORM_MIN_AGE_SEC   default 600 (standalone). rfg preflight passes 120.
# AUDIT_STORM_DRY_RUN=1     print candidates, do not signal them.
# AUDIT_STORM_REPORT_ONLY=1 same as dry-run.
# RFG_STORM_PROTECT_PIDS    extra PIDs to leave alone (the calling rfg).
# shellcheck shell=bash
set -euo pipefail

# [[dd-]hh:]mm:ss -> seconds. Empty or junk -> 0.
audit_storm_etime_to_sec() {
  local e="${1:-}" d=0 h=0 m=0 s=0
  local -a parts=()
  if [ -z "$e" ]; then
    printf '0\n'
    return 0
  fi
  if [[ "$e" == *-* ]]; then
    d="${e%%-*}"
    e="${e#*-}"
  fi
  IFS=: read -ra parts <<< "$e"
  case "${#parts[@]}" in
    3) h="${parts[0]}"; m="${parts[1]}"; s="${parts[2]}" ;;
    2) m="${parts[0]}"; s="${parts[1]}" ;;
    1) s="${parts[0]}" ;;
  esac
  d="${d//[^0-9]/}"
  h="${h//[^0-9]/}"
  m="${m//[^0-9]/}"
  s="${s//[^0-9]/}"
  printf '%s\n' "$((10#${d:-0} * 86400 + 10#${h:-0} * 3600 + 10#${m:-0} * 60 + 10#${s:-0}))"
}

# True when this pid/cmdline must not be signaled.
# Case arms stay separate. A combined pattern with a quoted grok* glob is a bash syntax error.
# find of ~/.grok does not contain bin/grok, so those audits still qualify.
audit_storm_pid_protected() {
  local pid="$1" cmd="$2" base p home_rfg
  local -a extra=()
  [ "$pid" = "$$" ] && return 0
  if [ -n "${PPID:-}" ] && [ "$pid" = "$PPID" ]; then
    return 0
  fi
  if [ -n "${RFG_STORM_PROTECT_PIDS:-}" ]; then
    # shellcheck disable=SC2206
    extra=(${RFG_STORM_PROTECT_PIDS})
    for p in "${extra[@]}"; do
      [ "$pid" = "$p" ] && return 0
    done
  fi
  case "$cmd" in
    *kill-audit-storms*) return 0 ;;
    *rfg.sh*) return 0 ;;
    */usr/local/bin/rfg*) return 0 ;;
    *bin/grok*) return 0 ;;
  esac
  if [ -n "${HOME:-}" ] && [ "$HOME" != "/" ]; then
    home_rfg="${HOME}/.local/bin/rfg"
    case "$cmd" in
      *"$home_rfg"*) return 0 ;;
    esac
  fi
  # Bare argv0 (grok on PATH, rfg with no path) still must not be signaled.
  base="${cmd%% *}"
  base="${base##*/}"
  case "$base" in
    grok|rfg|rfg.sh|kill-audit-storms|kill-audit-storms.sh) return 0 ;;
  esac
  return 1
}

# Known orphan audit cmdlines only.
# Home path comes from $HOME (home-wide du, find of home / .grok / .claude / .local).
# Pack markers are the audit strings those leftovers leave in argv.
audit_storm_cmd_match() {
  local cmd="$1" home marker
  case "$cmd" in
    *'REVFLEET HARDCODE'*|*'WHO CREATES'*|*'TOP-LEVEL DETAILED'*|*'HOME TOP-LEVEL'*|*'fleet-identity'*)
      return 0
      ;;
  esac
  home="${HOME:-}"
  if [ -n "$home" ] && [ "$home" != "/" ]; then
    case "$cmd" in
      *"du -sh ${home}"*|*"find ${home}"*) return 0 ;;
    esac
    marker="$(basename "$home")-audit"
    case "$cmd" in
      *"$marker"*) return 0 ;;
    esac
  fi
  return 1
}

# D-state leftovers use the wider corrected filter: any du -sh, find of $HOME,
# a relative find ., and the home audit marker. Age and rfg/grok skips still apply.
audit_storm_dstate_cmd_match() {
  local cmd="$1" home marker
  case "$cmd" in
    *'du -sh'*) return 0 ;;
    *'find .'*) return 0 ;;
  esac
  home="${HOME:-}"
  if [ -n "$home" ] && [ "$home" != "/" ]; then
    case "$cmd" in
      *"find ${home}"*) return 0 ;;
    esac
    marker="$(basename "$home")-audit"
    case "$cmd" in
      *"$marker"*) return 0 ;;
    esac
  fi
  return 1
}

audit_storm_ps_etime() {
  ps -eo pid=,etime=,cmd= 2>/dev/null || ps -axo pid=,etime=,command= 2>/dev/null || true
}

audit_storm_ps_d() {
  ps -eo pid=,stat=,etime=,cmd= 2>/dev/null || ps -axo pid=,stat=,etime=,command= 2>/dev/null || true
}

# pid, etime, cmd  (tab-separated). Last field keeps the rest of the cmdline.
audit_storm_rows_etime() {
  audit_storm_ps_etime | awk '
    $1 ~ /^[0-9]+$/ && NF >= 2 {
      pid=$1
      et=$2
      $1=""
      $2=""
      sub(/^[[:space:]]+/, "", $0)
      printf "%s\t%s\t%s\n", pid, et, $0
    }
  ' || true
}

# pid, stat, etime, cmd
audit_storm_rows_d() {
  audit_storm_ps_d | awk '
    $1 ~ /^[0-9]+$/ && NF >= 3 {
      pid=$1
      st=$2
      et=$3
      $1=""
      $2=""
      $3=""
      sub(/^[[:space:]]+/, "", $0)
      printf "%s\t%s\t%s\t%s\n", pid, st, et, $0
    }
  ' || true
}

# Matching D-state audit processes still present (any age). Printed for the preflight warning.
audit_storm_dstate_lines() {
  local pid stat et cmd
  while IFS=$'\t' read -r pid stat et cmd; do
    [ -n "${pid:-}" ] || continue
    [[ "${stat:-}" == *D* ]] || continue
    audit_storm_dstate_cmd_match "${cmd:-}" || continue
    printf '%s %s %s %s\n' "$pid" "$stat" "$et" "$cmd"
  done < <(audit_storm_rows_d)
  return 0
}

audit_storm_min_age() {
  local min="${AUDIT_STORM_MIN_AGE_SEC:-600}"
  case "$min" in
    ''|*[!0-9]*) min=600 ;;
  esac
  printf '%s\n' "$min"
}

# Plain pid list. No associative arrays: WSL bash reports "bad array subscript"
# for those, and also for "${array[@]:-}" when the list is still empty.
audit_storm_already_listed() {
  local want="$1" x
  [ "${#audit_storm_uniq_pids[@]}" -eq 0 ] && return 1
  for x in "${audit_storm_uniq_pids[@]}"; do
    [ "$x" = "$want" ] && return 0
  done
  return 1
}

# Agent-session name. Matched on the basename of comm, argv[0], and argv[1]
# (argv[1] covers `bash rfg.sh` and `node .../cursor-agent`). A path that
# contains /cursor-agent/ matches before the basename check.
audit_storm_agent_name_match() {
  local raw="$1" b
  [ -n "$raw" ] || return 1
  case "$raw" in
    */cursor-agent/*) return 0 ;;
  esac
  b="${raw##*/}"
  case "$b" in
    codex | codex-* | rfx | rfx.sh | grok | grok-* | rfg | rfg.sh | rfc | rfc.sh | \
    claude | claude-* | cursor-agent | cursor-agent-*)
      return 0
      ;;
  esac
  return 1
}

# Print the PPID of $1 (empty when the process is gone).
audit_storm_ppid_of() {
  local stat rest
  if [ -r "/proc/$1/stat" ]; then
    stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 0
    # comm may contain spaces or parens; fields after the last ") " are fixed.
    rest="${stat##*) }"
    # shellcheck disable=SC2086
    set -- $rest
    printf '%s\n' "${2:-}"
    return 0
  fi
  ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '
}

# Status 0 and sets AUDIT_STORM_AGENT_ANCESTOR="<name> pid=<n>" when $1 itself
# or any ancestor is an agent session (self covers `codex exec "<prompt naming find>"`).
# Walks at most 64 hops and stops at pid 1.
AUDIT_STORM_AGENT_ANCESTOR=""
audit_storm_has_agent_ancestor() {
  local p comm a0 a1 hit hops=0
  AUDIT_STORM_AGENT_ANCESTOR=""
  p="$1"
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$hops" -lt 64 ]; do
    comm="$(cat "/proc/$p/comm" 2>/dev/null || ps -o comm= -p "$p" 2>/dev/null || true)"
    a0=""; a1=""
    if [ -r "/proc/$p/cmdline" ]; then
      { IFS= read -r -d '' a0 && IFS= read -r -d '' a1; } < "/proc/$p/cmdline" 2>/dev/null || true
    fi
    hit=""
    if audit_storm_agent_name_match "$comm"; then hit="$comm"
    elif audit_storm_agent_name_match "$a0"; then hit="$a0"
    elif audit_storm_agent_name_match "$a1"; then hit="$a1"
    fi
    if [ -n "$hit" ]; then
      AUDIT_STORM_AGENT_ANCESTOR="${hit##*/} pid=$p"
      return 0
    fi
    p="$(audit_storm_ppid_of "$p")"
    hops=$((hops + 1))
  done
  return 1
}

audit_storm_add_cand() {
  local pid="$1" et="$2" cmd="$3"
  [ -n "$pid" ] || return 0
  audit_storm_already_listed "$pid" && return 0
  if audit_storm_has_agent_ancestor "$pid"; then
    audit_storm_uniq_pids+=("$pid")
    audit_storm_protected=$(( ${audit_storm_protected:-0} + 1 ))
    echo "kill-audit-storms: skip pid=$pid (agent session: $AUDIT_STORM_AGENT_ANCESTOR) cmd=$cmd"
    return 0
  fi
  audit_storm_uniq_pids+=("$pid")
  audit_storm_uniq_lines+=("$pid|$et|$cmd")
}

audit_storm_main() {
  local min dry report killed warned_d
  local pid et cmd age stat rest c
  min="$(audit_storm_min_age)"
  dry="${AUDIT_STORM_DRY_RUN:-0}"
  report="${AUDIT_STORM_REPORT_ONLY:-0}"
  killed=0
  warned_d=0
  audit_storm_protected=0
  audit_storm_uniq_pids=()
  audit_storm_uniq_lines=()

  while IFS=$'\t' read -r pid et cmd; do
    [ -n "${pid:-}" ] || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    age="$(audit_storm_etime_to_sec "${et:-}")"
    [ "$age" -lt "$min" ] && continue
    audit_storm_pid_protected "$pid" "${cmd:-}" && continue
    audit_storm_cmd_match "${cmd:-}" || continue
    audit_storm_add_cand "$pid" "$et" "$cmd"
  done < <(audit_storm_rows_etime)

  while IFS=$'\t' read -r pid stat et cmd; do
    [ -n "${pid:-}" ] || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "${stat:-}" == *D* ]] || continue
    age="$(audit_storm_etime_to_sec "${et:-}")"
    [ "$age" -lt "$min" ] && continue
    audit_storm_pid_protected "$pid" "${cmd:-}" && continue
    if audit_storm_dstate_cmd_match "${cmd:-}"; then
      audit_storm_add_cand "$pid" "$et" "$cmd"
    else
      warned_d=$((warned_d + 1))
    fi
  done < <(audit_storm_rows_d)

  if [ "${#audit_storm_uniq_lines[@]}" -eq 0 ]; then
    echo "kill-audit-storms: none (min_age=${min}s protected=${audit_storm_protected})"
    return 0
  fi

  echo "kill-audit-storms: ${#audit_storm_uniq_lines[@]} candidate(s) older than ${min}s"
  for c in "${audit_storm_uniq_lines[@]}"; do
    pid="${c%%|*}"
    rest="${c#*|}"
    et="${rest%%|*}"
    cmd="${rest#*|}"
    echo "  pid=$pid etime=$et cmd=$cmd"
    if [ "$report" = 1 ] || [ "$dry" = 1 ]; then
      continue
    fi
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.2
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
    killed=$((killed + 1))
  done

  echo "kill-audit-storms: killed=$killed protected=${audit_storm_protected} dry_run=$dry report_only=$report other_D_warned=$warned_d"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  audit_storm_main
fi
