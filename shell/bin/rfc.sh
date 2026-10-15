#!/usr/bin/env bash
# rfc — RevealFleet Claude launcher (WSL / native Linux / macOS)
#
# Starts a `claude` session rooted in a RevealFleet repo, running in the current
# POSIX shell. On WSL this is the entire point: claude's Bash tool-calls run
# native (`git status`, not `wsl.exe -d Ubuntu -- bash -lc '... git status'`) —
# the wsl.exe wrapper is (a) un-allowlistable (the payload is an opaque string,
# so only `Bash(wsl.exe *)` covers it, equivalent to bypassPermissions) and
# (b) slips past the PreToolUse deny-list hook; launching in WSL instead means
# commands allowlist by real prefix AND the deny-list + hooks fire. On native
# Linux/macOS there is no wrapper to defeat, so rfc is simply a thin cd + exec
# convenience. See docs/rfc-launcher.md for the full per-surface rationale.
#
# Usage:
#   rfc                  # use $PWD if inside the fleet (root or repo)
#   rfc revealui         # cd product checkout + exec claude
#   rfc / rfc . at fleet root starts a fleet-root session (does not exit 2)
#   rfc revealui --continue  # trailing args pass through to claude
#   rfc mint             # interactive device-token mint → revvault
#   rfc smoke            # auth/MCP health (no secret print)
#   rfc env              # non-secret MCP URL + vault path (never the token)
#   rfc bootstrap [path] # Rift-inspired: write .env.worktree (hash ports)
#   rfc claim …          # claim acquire|release|list|check|sweep
#   rfc worktree retire <repo> <label>  # exact owned, merged, idle checkout
#   rfc open <repo> <label> [--claim surface] [--pr number] [--no-agent]
#                        # create ~/revealfleet/.wt/<label> from integration ref,
#                        # bootstrap env, optional claim, optional claude
#
# Override fleet root: REVEALFLEET_ROOT
# Skip MCP load: REVEALUI_MCP_ENV_SKIP=1
# Strict MCP (die if token missing): RFC_MCP_STRICT=1
# Force worktree base ref: RFG_WORKTREE_REF=test

set -euo pipefail

_load_fleet_root_lib() {
  local here f
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  for f in \
    "$here/../lib/fleet-root.sh" \
    "$(dirname "$here")/lib/revkit/fleet-root.sh" \
    "${REVEALUI_ROOT:-}/shell/lib/fleet-root.sh"
  do
    if [ -n "$f" ] && [ -f "$f" ]; then
      # shellcheck disable=SC1090
      . "$f"
      return 0
    fi
  done
  return 1
}
_load_fleet_root_lib || {
  echo "revkit: fleet-root.sh is missing; reinstall revkit with bootstrap.sh" >&2
  exit 1
}
_rfc_root_rc=0
FLEET_ROOT="$(rfg_resolve_fleet_root)" || _rfc_root_rc=$?
# 78 is the legacy ~/revfleet ban. Do not continue into worktree create.
if [ "$_rfc_root_rc" -eq 78 ]; then
  exit 78
fi
unset _rfc_root_rc

die() { echo "rfc: $*" >&2; exit 1; }

# Fast-forward idle local integration refs (test/main). Never switches branches.
_sync_integration() {
  local repo="${1:-}"
  local planning script
  [ -n "${REVEALFLEET_PLANNING:-}" ] || return 0
  planning="$(__rv_planning_root)" || return 1
  script="$planning/scripts/fleet-sync-integration.js"
  [ -f "$script" ] || return 0
  if [ -n "$repo" ]; then
    node "$script" --auto "$repo" >/dev/null || true
  else
    node "$script" --auto >/dev/null || true
  fi
}

case "$(uname -s 2>/dev/null)" in
  Linux | Darwin) : ;;
  *) die "must run in a POSIX shell (WSL, Linux, or macOS); not Git Bash/cmd" ;;
esac
[ -n "${FLEET_ROOT:-}" ] && [ -d "$FLEET_ROOT" ] || die "fleet root not found (set REVEALFLEET_ROOT or re-run bootstrap)"

_load_mcp_lib() {
  local here f
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  local candidates=(
    "$here/../lib/revealui-mcp-env.sh"
    "$(dirname "$here")/lib/revkit/revealui-mcp-env.sh"
    "${REVEALUI_ROOT:-}/shell/lib/revealui-mcp-env.sh"
  )
  local f
  for f in "${candidates[@]}"; do
    if [ -n "$f" ] && [ -f "$f" ]; then
      # shellcheck disable=SC1090
      . "$f"
      return 0
    fi
  done
  return 1
}

if _load_mcp_lib; then
  :
else
  _revealui_mcp_env_load() { return 0; }
fi

load_mcp() {
  if [ "${REVEALUI_MCP_ENV_SKIP:-0}" = 1 ]; then
    return 0
  fi
  # Claude can launch without RevealUI MCP; Grok (rfg) is strict by default.
  REVEALUI_MCP_ENV_STRICT="${REVEALUI_MCP_ENV_STRICT:-${RFC_MCP_STRICT:-0}}"
  export REVEALUI_MCP_ENV_STRICT
  _revealui_mcp_env_load
}

resolve_claude() {
  if command -v claude >/dev/null 2>&1; then command -v claude; return 0; fi
  local c
  for c in "$HOME/.local/bin.override/claude" "$HOME/.local/bin/claude"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

# Integration base for new worktrees: origin/test when present, else origin/main.
_resolve_integration_ref() {
  local repo="$1"
  if [ -n "${RFG_WORKTREE_REF:-}" ]; then
    echo "$RFG_WORKTREE_REF"
    return 0
  fi
  if [ -d "$repo/.git" ] || [ -f "$repo/.git" ]; then
    if git -C "$repo" rev-parse --verify --quiet origin/test >/dev/null 2>&1; then
      echo "test"
      return 0
    fi
    if git -C "$repo" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
      echo "main"
      return 0
    fi
  fi
  case "${repo##*/}" in
    revealui) echo "test"; return 0 ;;
  esac
  echo "main"
}

list_repos() {
  local d
  for d in "$FLEET_ROOT"/*/ "$FLEET_ROOT"/.*/; do
    [ -e "${d}.git" ] || continue
    d="${d%/}"; echo "  ${d##*/}"
  done
}

_resolve_helper() {
  local name="$1"
  local d c
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  for c in \
    "$d/$name" \
    "/usr/local/bin/$name" \
    "$HOME/.local/bin/$name" \
    "${REVEALUI_ROOT:-}/shell/bin/$name"
  do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

_load_worktree_env_lib() {
  local here f
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  for f in \
    "$here/../lib/worktree-env.sh" \
    "$(dirname "$here")/lib/revkit/worktree-env.sh" \
    "${REVEALUI_ROOT:-}/shell/lib/worktree-env.sh"
  do
    if [ -n "$f" ] && [ -f "$f" ]; then
      # shellcheck disable=SC1090
      . "$f"
      return 0
    fi
  done
  return 1
}

cmd="${1:-}"
case "$cmd" in
  mint)
    shift || true
    helper="$(_resolve_helper revealui-mcp-mint.sh)" || die "revealui-mcp-mint.sh not installed (re-run revkit bootstrap)"
    exec "$helper" "$@"
    ;;
  smoke)
    shift || true
    helper="$(_resolve_helper revealui-mcp-smoke.sh)" || die "revealui-mcp-smoke.sh not installed (re-run revkit bootstrap)"
    exec "$helper" "$@"
    ;;
  env)
    REVEALUI_MCP_ENV_STRICT=1
    export REVEALUI_MCP_ENV_STRICT
    _revealui_mcp_env_load || exit 1
    unset REVEALUI_MCP_TOKEN
    printf 'export REVEALUI_MCP_URL=%q\n' "$REVEALUI_MCP_URL"
    printf 'export REVEALUI_MCP_TOKEN_VAULT_PATH=%q\n' "$REVEALUI_MCP_TOKEN_VAULT_PATH"
    echo "rfc env: token not printed. Load MCP with rfc <repo>, rfc mint, or rfc smoke." >&2
    exit 0
    ;;
  bootstrap)
    shift || true
    _load_worktree_env_lib || die "worktree-env.sh not found (re-run revkit bootstrap)"
    path="${1:-$PWD}"
    label="${2:-}"
    envf="$(rfg_write_worktree_env "$path" "$label")"
    echo "rfc: wrote $envf"
    # shellcheck disable=SC1090
    set -a
    # shellcheck disable=SC1090
    . "$envf"
    set +a
    echo "rfc: RFG_PORT_BASE=${RFG_PORT_BASE:-?} MARKETING_PORT=${MARKETING_PORT:-?} API_PORT=${API_PORT:-?}"
    exit 0
    ;;
  claim)
    shift || true
    _load_worktree_env_lib || die "worktree-env.sh not found (re-run revkit bootstrap)"
    sub="${1:-list}"
    shift || true
    case "$sub" in
      acquire | take)
        repo="${1:-}"; surface="${2:-}"; ttl="${3:-24}"
        [ -n "$repo" ] && [ -n "$surface" ] || die "usage: rfc claim acquire <repo> <surface> [ttl_hours]"
        rfg_claim_acquire "$repo" "$surface" "$ttl"
        ;;
      release | drop)
        repo="${1:-}"; surface="${2:-}"
        [ -n "$repo" ] && [ -n "$surface" ] || die "usage: rfc claim release <repo> <surface>"
        rfg_claim_release "$repo" "$surface"
        ;;
      list)
        rfg_claim_list "${1:-}"
        ;;
      check)
        repo="${1:-}"; surface="${2:-}"
        [ -n "$repo" ] && [ -n "$surface" ] || die "usage: rfc claim check <repo> <surface>"
        rfg_claim_check "$repo" "$surface"
        ;;
      sweep)
        rfg_claim_sweep
        ;;
      *)
        die "usage: rfc claim acquire|release|list|check|sweep …"
        ;;
    esac
    exit 0
    ;;
  worktree)
    shift || true
    _load_worktree_env_lib || die "worktree-env.sh not found (re-run revkit bootstrap)"
    [ "${1:-}" = retire ] && [ "$#" -eq 3 ] || die "usage: rfc worktree retire <repo> <label>"
    rfg_worktree_retire "$2" "$3" "$FLEET_ROOT/$2" || die "worktree retirement denied"
    exit 0
    ;;
  open)
    shift || true
    _load_worktree_env_lib || die "worktree-env.sh not found (re-run revkit bootstrap)"
    open_repo="${1:-}"
    open_label="${2:-}"
    [ -n "$open_repo" ] && [ -n "$open_label" ] || die "usage: rfc open <repo> <label> [--claim surface] [--no-agent] [claude-args…]"
    shift 2 || true
    claim_surface=""
    open_pr=""
    no_agent=0
    open_extra=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --claim)
          claim_surface="${2:-}"
          [ -n "$claim_surface" ] || die "--claim requires a surface id"
          shift 2
          ;;
        --claim=*)
          claim_surface="${1#--claim=}"
          shift
          ;;
        --pr)
          open_pr="${2:-}"
          [ -n "$open_pr" ] || die "--pr requires a number"
          shift 2
          ;;
        --pr=*)
          open_pr="${1#--pr=}"
          shift
          ;;
        --no-agent)
          no_agent=1
          shift
          ;;
        *)
          open_extra+=("$1")
          shift
          ;;
      esac
    done

    source_repo="$FLEET_ROOT/$open_repo"
    _rfg_worktree_validate_name "$open_repo" || die "invalid repository name"
    _rfg_worktree_validate_name "$open_label" || die "invalid worktree label"
    [ -d "$source_repo" ] || die "no such fleet repo: $open_repo"
    wt_root="$(rfg_wt_root)"
    wt_path="$wt_root/$open_label"
    ref="$(_resolve_integration_ref "$source_repo")"

    if [ -e "$wt_path" ]; then
      echo "rfc: worktree path exists: $wt_path (bootstrap only)" >&2
    else
      mkdir -p "$wt_root"
      echo "rfc: syncing origin/$ref …" >&2
      _sync_integration "$source_repo"
      git -C "$source_repo" fetch origin "$ref" 2>/dev/null || git -C "$source_repo" fetch origin || true
      base="origin/$ref"
      if ! git -C "$source_repo" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
        base="$ref"
      fi
      branch="feat/${open_label}"
      RFG_CLAIM_AGENT="${RFG_CLAIM_AGENT:-claude}" rfg_worktree_reserve "$open_repo" "$open_label" "$wt_path" "${claim_surface:-$open_label}" "$source_repo" "$open_pr" || die "worktree lifecycle reservation failed; nothing created: $wt_path"
      if git -C "$source_repo" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$source_repo" worktree add "$wt_path" "$branch"
      else
        git -C "$source_repo" worktree add -b "$branch" "$wt_path" "$base"
      fi
      echo "rfc: created $wt_path ($branch from $base)" >&2
    fi

    rfg_worktree_register "$open_repo" "$open_label" "$wt_path" "$source_repo" || die "worktree exists but lifecycle registration failed: $wt_path"
    envf="$(rfg_write_worktree_env "$wt_path" "$open_label")" || die "worktree exists but environment bootstrap failed: $wt_path"
    echo "rfc: bootstrap $envf" >&2

    if [ -n "$claim_surface" ]; then
      RFG_CLAIM_WORKTREE="$wt_path"
      RFG_CLAIM_AGENT="${RFG_CLAIM_AGENT:-claude}"
      export RFG_CLAIM_WORKTREE RFG_CLAIM_AGENT
      claim_file="$(rfg_claim_acquire "$open_repo" "$claim_surface")" || die "claim failed for $claim_surface"
      echo "rfc: claimed $claim_file" >&2
    fi

    if [ "$no_agent" -eq 1 ]; then
      echo "$wt_path"
      exit 0
    fi

    claude_bin="$(resolve_claude)" || die "claude not found on PATH or in ~/.local/bin*"
    load_mcp || { [ "${RFC_MCP_STRICT:-0}" = 1 ] && die "MCP env not ready (mint with: rfc mint)"; }
    cd "$wt_path"
    # shellcheck disable=SC1090
    set -a
    # shellcheck disable=SC1090
    . "$envf"
    set +a
    exec "$claude_bin" "${open_extra[@]}"
    ;;
  -h | --help | help)
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

repo="${1:-}"
if [ -n "${repo:-}" ]; then
  shift
fi

rfg_resolve_launch_target "$FLEET_ROOT" "${repo:-}" "$PWD" && rc=0 || rc=$?
case "$rc" in
  0)
    target="$RFG_LAUNCH_TARGET"
    if [ "${RFG_LAUNCH_KEEP_FLAGS:-0}" = 1 ]; then
      set -- "$repo" "$@"
    fi
    ;;
  2)
    echo "rfc: name a fleet repo, e.g. 'rfc revealui'. Available:" >&2
    list_repos >&2
    exit 2
    ;;
  *)
    if [ -n "${repo:-}" ]; then
      case "$repo" in
        -*) die "name a fleet repo before claude flags, or cd into the fleet root / a repo" ;;
        .. | ../* | */.. | */../* | /* | */*) die "repo name must be a single fleet checkout (got '$repo')" ;;
        *) die "no such fleet repo: '$repo' (under $FLEET_ROOT)" ;;
      esac
    fi
    die "could not resolve launch target"
    ;;
esac

claude_bin="$(resolve_claude)" || die "claude not found on PATH or in ~/.local/bin*"

_sync_integration "$target"
load_mcp || { [ "${RFC_MCP_STRICT:-0}" = 1 ] && die "MCP env not ready (mint with: rfc mint)"; }

cd "$target"
exec "$claude_bin" "$@"
