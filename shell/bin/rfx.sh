#!/usr/bin/env bash
# rfx - RevealFleet Codex launcher (WSL / native Linux / macOS)
#
# Starts an OpenAI Codex CLI session rooted in a RevealFleet repo with the same
# fleet root, worktree env, storm preflight and Level 1 RevealUI MCP env as rfg.
# Codex counterpart of rfg (Grok) and rfc (Claude).
#
# Usage:
#   rfx                  # use $PWD if inside the fleet (root or repo)
#   rfx revealui         # cd product checkout + load MCP env + exec codex
#   rfx / rfx . at fleet root starts a fleet-root session (does not exit 2)
#   rfx revealui -- --search "fix x"  # args after -- pass through to codex
#   rfx -- <codex args>  # $PWD target, everything after -- goes to codex
#   rfx -- resume --last # explicit resume. rfx does not auto-continue
#   rfx --dry-run [repo] [-- args]    # print the launch plan; no sweep, no exec
#   rfx mint             # interactive device-token mint to revvault
#   rfx smoke            # auth/MCP health (no secret print)
#   rfx env              # print non-secret MCP URL + vault path (never the token)
#   rfx bootstrap [path] # write .env.worktree (hash ports)
#   rfx claim ...        # claim acquire|release|list|check|sweep
#   rfx open <repo> <label> [--claim surface] [--no-agent] [-- codex args]
#                        # create <fleet>/.wt/<label> from the integration ref,
#                        # bootstrap env, optional claim, optional codex
#
# Override fleet root: REVEALFLEET_ROOT
# Skip MCP load: REVEALUI_MCP_ENV_SKIP=1
# Non-strict (launch even if token missing): REVEALUI_MCP_ENV_STRICT=0
# Skip RevealUI MCP attach flags for codex: RFX_MCP_ATTACH_SKIP=1
# Skip the .revealui pointer for checkouts without AGENTS.md: RFX_REVEALUI_POINTER_SKIP=1
# Allow codex --worktree off a non-integration HEAD: RFG_WORKTREE_REF_SKIP=1
# Force worktree base ref (rfx open): RFG_WORKTREE_REF=test
# Dry run: RFX_DRY_RUN=1 (same as --dry-run)

set -euo pipefail

# Resolve through the ~/.local/bin/rfx symlink so the lib lookup below finds the
# real tree (revkit/shell/lib in the source tree, <prefix>/lib/revkit when installed).
_rfx_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
RFX_HERE="$(cd "$(dirname "$_rfx_self")" 2>/dev/null && pwd)"

die() { echo "rfx: $*" >&2; exit 1; }

# Same lookup order as rfg: source tree, matched install prefix, REVEALUI_ROOT.
_rfx_source_lib() {
  local name="$1" f
  for f in \
    "$RFX_HERE/../lib/$name" \
    "$(dirname "$RFX_HERE")/lib/revkit/$name" \
    "${REVEALUI_ROOT:+$REVEALUI_ROOT/shell/lib/$name}"
  do
    if [ -n "$f" ] && [ -f "$f" ]; then
      # shellcheck disable=SC1090
      . "$f"
      return 0
    fi
  done
  return 1
}

_rfx_source_lib fleet-root.sh || rfg_resolve_fleet_root() {
  if [ -n "${REVEALFLEET_ROOT:-}" ]; then printf '%s\n' "$REVEALFLEET_ROOT"; return 0; fi
  return 1
}
FLEET_ROOT="$(rfg_resolve_fleet_root)" || true

case "$(uname -s 2>/dev/null)" in
  Linux | Darwin) : ;;
  *) die "must run in a POSIX shell (WSL, Linux, or macOS)" ;;
esac

RFX_DRY_RUN="${RFX_DRY_RUN:-0}"
if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ]; then
  RFX_DRY_RUN=1
  shift
fi

# Mode: rfg does not set REVEALUI_MODE; it inherits it from the shell. rfx does
# the same and only resolves it for the dry-run report.
_rfx_mode_report() {
  local pref="unknown"
  if _rfx_source_lib revkit-mode.sh; then
    pref="$(revkit_resolve_mode 2>/dev/null || echo fleet)"
  fi
  printf 'inherited REVEALUI_MODE=%s (resolved preference: %s)\n' "${REVEALUI_MODE:-<unset>}" "$pref"
}

# GAP-496 style launch stamp, one jsonl row per exec. Never the MCP token.
_rfx_stamp_launch() {
  local dir="${XDG_DATA_HOME:-$HOME/.local/share}/revealui/usage"
  mkdir -p "$dir" || return 0
  python3 - "$dir/launches.jsonl" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PWD" "${1:-codex}" <<'PY' || true
import json, sys
path, ts, cwd, binp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
row = {"ts": ts, "launcher": "rfx", "cwd": cwd, "agent": "codex", "bin": binp}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
}

# Fast-forward idle local integration refs (test/main). Never switches branches.
_sync_integration() {
  local repo="${1:-}"
  local script="$FLEET_ROOT/.jv/scripts/fleet-sync-integration.js"
  [ -f "$script" ] || return 0
  if [ -n "$repo" ]; then
    node "$script" --auto "$repo" >/dev/null || true
  else
    node "$script" --auto >/dev/null || true
  fi
}

# MCP env: shared revkit loader only. rfg also embeds a fallback copy of the
# loader; rfx fails closed instead of carrying a third copy.
if ! _rfx_source_lib revealui-mcp-env.sh; then
  _revealui_mcp_env_load() {
    echo "revealui-mcp-env: revealui-mcp-env.sh not found (re-run revkit bootstrap)" >&2
    [ "${REVEALUI_MCP_ENV_STRICT:-0}" = 1 ] && return 1
    return 0
  }
fi

load_mcp_strict() {
  if [ "${REVEALUI_MCP_ENV_SKIP:-0}" = 1 ]; then
    return 0
  fi
  REVEALUI_MCP_ENV_STRICT="${REVEALUI_MCP_ENV_STRICT:-1}"
  export REVEALUI_MCP_ENV_STRICT
  _revealui_mcp_env_load
}

resolve_codex() {
  if command -v codex >/dev/null 2>&1; then command -v codex; return 0; fi
  local c
  for c in "$HOME/.local/bin/codex" "${CODEX_HOME:-$HOME/.codex}/packages/standalone/current/bin/codex"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

# Integration base for new worktrees: origin/test when present, else origin/main.
# Owner hardline 2026-07-21: never inherit a feature-branch HEAD as the worktree parent.
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

# rfg injects --ref <integration> into grok --worktree. Codex --worktree takes no
# base ref and starts from the checkout HEAD, so rfx refuses it unless HEAD is
# already the integration branch. Use `rfx open <repo> <label>` instead.
_rfx_guard_codex_worktree() {
  local root="$1"
  shift
  [ "${RFG_WORKTREE_REF_SKIP:-0}" = 1 ] && return 0
  local a has=0
  for a in "$@"; do
    case "$a" in
      --worktree | --worktree=*) has=1 ;;
    esac
  done
  [ "$has" -eq 1 ] || return 0
  local ref head
  ref="$(_resolve_integration_ref "$root")"
  head="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  if [ "$head" != "$ref" ]; then
    die "codex --worktree would branch from HEAD '$head', not integration '$ref'. Use: rfx open <repo> <label> (or RFG_WORKTREE_REF_SKIP=1)"
  fi
}

# Audit-storm preflight. The fleet copy in .jv/scripts is tried first because it
# carries the agent-ancestor guard; the installed copy can lag until the owner
# reinstalls it under /usr/local/lib/revkit.
_rfx_storm_preflight() {
  local f
  for f in \
    "${FLEET_ROOT:+$FLEET_ROOT/.jv/scripts/rfg-storm-preflight.sh}" \
    "$RFX_HERE/../lib/revkit/rfg-storm-preflight.sh" \
    "$RFX_HERE/../lib/rfg-storm-preflight.sh" \
    /usr/local/lib/revkit/rfg-storm-preflight.sh
  do
    if [ -n "$f" ] && [ -x "$f" ]; then
      if [ "$RFX_DRY_RUN" = 1 ]; then
        echo "storm preflight: would run $f"
      else
        "$f" || true
      fi
      return 0
    fi
  done
  [ "$RFX_DRY_RUN" = 1 ] && echo "storm preflight: none found"
  return 0
}

_toml_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# Extra codex argv built by rfx. Placed before the pass-through args so a user
# -c of the same key comes later on the command line.
RFX_CODEX_PRE=()

# RevealUI MCP attach. rfg exports REVEALUI_MCP_TOKEN/URL and the product's
# committed .grok/config.toml references them. Codex has no project config in
# the product, so rfx passes -c overrides. Only the env var NAME goes on argv;
# Codex reads the bearer token from the environment.
_rfx_mcp_args() {
  [ "${RFX_MCP_ATTACH_SKIP:-0}" = 1 ] && return 0
  [ -n "${REVEALUI_MCP_TOKEN:-}" ] || return 0
  local cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
  if [ -f "$cfg" ] && grep -Eq '^\[mcp_servers\.("?)revealui("?)\]' "$cfg"; then
    return 0
  fi
  case "${REVEALUI_MCP_URL:-}" in
    https://* | http://*) : ;;
    *) echo "rfx: REVEALUI_MCP_URL is not an http(s) URL; skipping MCP attach" >&2; return 0 ;;
  esac
  RFX_CODEX_PRE+=(
    -c "mcp_servers.revealui.url=$(_toml_str "$REVEALUI_MCP_URL")"
    -c 'mcp_servers.revealui.bearer_token_env_var="REVEALUI_MCP_TOKEN"'
    -c 'mcp_servers.revealui.startup_timeout_sec=45'
    -c 'mcp_servers.revealui.tool_timeout_sec=120'
  )
}

# Codex reads AGENTS.override.md / AGENTS.md from the git root down to the cwd.
_rfx_has_agents_md() {
  local dir="$1" top cur
  [ -d "$dir" ] || return 1
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$dir")"
  cur="$(cd "$dir" && pwd -P)"
  top="$(cd "$top" && pwd -P)"
  while :; do
    if [ -s "$cur/AGENTS.override.md" ] || [ -s "$cur/AGENTS.md" ]; then
      return 0
    fi
    [ "$cur" = "$top" ] && break
    case "$cur" in "$top"/*) cur="$(dirname "$cur")" ;; *) break ;; esac
  done
  return 1
}

# .revealui-first: products ship AGENTS.md as an adapter orientation generated
# from .revealui. When a checkout has .revealui/manager.json but no AGENTS.md,
# rfx points Codex at .revealui through developer_instructions instead of
# writing a vendor file. rfg's equivalent is the grok-home pointer stub.
_rfx_revealui_pointer() {
  local root="$1" top text adapter=""
  [ "${RFX_REVEALUI_POINTER_SKIP:-0}" = 1 ] && return 0
  [ -d "$root" ] || return 0
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$root")"
  [ -f "$top/.revealui/manager.json" ] || return 0
  _rfx_has_agents_md "$root" && return 0
  [ -f "$top/.revealui/adapters/codex.md" ] && adapter=".revealui/adapters/codex.md, then "
  text="RevealFleet rfx: this checkout has no AGENTS.md. Project policy lives in .revealui/ at $top. Read ${adapter}.revealui/manager.json (tracker.path, contentRoot; default .revealui/content/). Edit .revealui sources, never vendor copies. Secrets via revvault; product I/O via RevealUI MCP."
  RFX_CODEX_PRE+=(-c "developer_instructions=$(_toml_str "$text")")
}

# Skipped from rfg on purpose:
# - grok-attach constitution stub: the Codex home equivalent is
#   ~/.codex/AGENTS.md, which already holds owner content; rfx does not overwrite it.
# - grok hooks + token-budget sync: .revealui/adapters/codex.md declares no Codex
#   lifecycle-hook integration, and there is no Codex token-budget adapter.
# - [compat.claude] rules = false: Codex does not read CLAUDE.md unless
#   project_doc_fallback_filenames names it, so nothing to disable.
# - usage-delta: GAP-496 compares rfg against bare grok only.
# - SessionStart auto-continue: none. Use `rfx -- resume --last` explicitly.

_rfx_print_plan() {
  local target="$1" bin="$2"
  shift 2
  echo "rfx dry-run (nothing executed, no sweep, no integration sync)"
  echo "fleet root: ${FLEET_ROOT:-<unresolved>}"
  echo "target: $target"
  echo "mode: $(_rfx_mode_report)"
  echo "codex: $bin ($("$bin" --version 2>/dev/null || echo 'version unknown'))"
  _rfx_storm_preflight
  if [ "${REVEALUI_MCP_ENV_SKIP:-0}" = 1 ]; then
    echo "mcp: skipped (REVEALUI_MCP_ENV_SKIP=1)"
  elif [ -n "${REVEALUI_MCP_TOKEN:-}" ]; then
    echo "mcp: token loaded from revvault (${REVEALUI_MCP_TOKEN_VAULT_PATH:-?}), url ${REVEALUI_MCP_URL:-?}"
  else
    echo "mcp: no token loaded"
  fi
  if _rfx_has_agents_md "$target"; then
    echo "instructions: AGENTS.md found (native Codex discovery)"
  fi
  printf 'exec: cd %q &&' "$target"
  printf ' %q' "$bin" ${RFX_CODEX_PRE[@]+"${RFX_CODEX_PRE[@]}"} "$@"
  printf '\n'
}

list_repos() {
  local d
  for d in "$FLEET_ROOT"/*/ "$FLEET_ROOT"/.*/; do
    [ -e "${d}.git" ] || continue
    d="${d%/}"; echo "  ${d##*/}"
  done
}

# Resolve a fleet helper installed next to this script or in the revkit tree.
_resolve_helper() {
  local name="$1" c
  for c in \
    "$RFX_HERE/$name" \
    "/usr/local/bin/$name" \
    "$HOME/.local/bin/$name" \
    "${REVEALUI_ROOT:+$REVEALUI_ROOT/shell/bin/$name}"
  do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

_rfx_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$_rfx_self"
}

cmd="${1:-}"
case "$cmd" in
  mint | smoke | env | help | --help | -h) ;;
  *)
    [ -n "${FLEET_ROOT:-}" ] || die "fleet root not found (set REVEALFLEET_ROOT or re-run bootstrap)"
    ;;
esac
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
    # Load to validate the vault, then drop the token before any print.
    REVEALUI_MCP_ENV_STRICT=1
    export REVEALUI_MCP_ENV_STRICT
    _revealui_mcp_env_load || exit 1
    unset REVEALUI_MCP_TOKEN
    printf 'export REVEALUI_MCP_URL=%q\n' "$REVEALUI_MCP_URL"
    printf 'export REVEALUI_MCP_TOKEN_VAULT_PATH=%q\n' "$REVEALUI_MCP_TOKEN_VAULT_PATH"
    echo "rfx env: token not printed. Load MCP with rfx <repo>, rfx mint, or rfx smoke." >&2
    exit 0
    ;;
  bootstrap)
    shift || true
    _rfx_source_lib worktree-env.sh || die "worktree-env.sh not found (re-run revkit bootstrap)"
    path="${1:-$PWD}"
    label="${2:-}"
    envf="$(rfg_write_worktree_env "$path" "$label")"
    echo "rfx: wrote $envf"
    set -a
    # shellcheck disable=SC1090
    . "$envf"
    set +a
    echo "rfx: RFG_PORT_BASE=${RFG_PORT_BASE:-?} MARKETING_PORT=${MARKETING_PORT:-?} API_PORT=${API_PORT:-?}"
    exit 0
    ;;
  claim)
    shift || true
    _rfx_source_lib worktree-env.sh || die "worktree-env.sh not found (re-run revkit bootstrap)"
    sub="${1:-list}"
    shift || true
    case "$sub" in
      acquire | take)
        repo="${1:-}"; surface="${2:-}"; ttl="${3:-24}"
        [ -n "$repo" ] && [ -n "$surface" ] || die "usage: rfx claim acquire <repo> <surface> [ttl_hours]"
        RFG_CLAIM_AGENT="${RFG_CLAIM_AGENT:-codex}" rfg_claim_acquire "$repo" "$surface" "$ttl"
        ;;
      release | drop)
        repo="${1:-}"; surface="${2:-}"
        [ -n "$repo" ] && [ -n "$surface" ] || die "usage: rfx claim release <repo> <surface>"
        rfg_claim_release "$repo" "$surface"
        ;;
      list)
        rfg_claim_list "${1:-}"
        ;;
      check)
        repo="${1:-}"; surface="${2:-}"
        [ -n "$repo" ] && [ -n "$surface" ] || die "usage: rfx claim check <repo> <surface>"
        rfg_claim_check "$repo" "$surface"
        ;;
      sweep)
        rfg_claim_sweep
        ;;
      *)
        die "usage: rfx claim acquire|release|list|check|sweep ..."
        ;;
    esac
    exit 0
    ;;
  open)
    # rfx open <repo> <label> [--claim surface] [--no-agent] [-- codex args...]
    shift || true
    _rfx_source_lib worktree-env.sh || die "worktree-env.sh not found (re-run revkit bootstrap)"
    open_repo="${1:-}"
    open_label="${2:-}"
    [ -n "$open_repo" ] && [ -n "$open_label" ] || die "usage: rfx open <repo> <label> [--claim surface] [--no-agent] [-- codex-args...]"
    shift 2 || true
    claim_surface=""
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
        --no-agent)
          no_agent=1
          shift
          ;;
        --)
          shift
          open_extra+=("$@")
          break
          ;;
        *)
          open_extra+=("$1")
          shift
          ;;
      esac
    done

    case "$open_repo" in
      . | .. | */* | -*) die "repo name must be a single fleet checkout (got '$open_repo')" ;;
    esac
    case "$open_label" in
      . | .. | */* | -*) die "label must be a single path segment (got '$open_label')" ;;
    esac
    source_repo="$FLEET_ROOT/$open_repo"
    [ -d "$source_repo" ] || die "no such fleet repo: $open_repo"
    wt_root="$(rfg_wt_root)"
    wt_path="$wt_root/$open_label"
    ref="$(_resolve_integration_ref "$source_repo")"

    if [ "$RFX_DRY_RUN" = 1 ]; then
      codex_bin="$(resolve_codex)" || die "codex not found on PATH or in ~/.local/bin / ~/.codex/packages"
      echo "worktree: $wt_path (feat/$open_label from origin/$ref, created only on a real run)"
      [ -n "$claim_surface" ] && echo "claim: $open_repo / $claim_surface (agent ${RFG_CLAIM_AGENT:-codex})"
      if [ "$no_agent" -eq 1 ]; then
        echo "no-agent: would print $wt_path and exit"
        exit 0
      fi
      load_mcp_strict || die "MCP env not ready (mint with: rfx mint)"
      _rfx_mcp_args
      [ -d "$wt_path" ] && _rfx_revealui_pointer "$wt_path"
      _rfx_print_plan "$wt_path" "$codex_bin" ${open_extra[@]+"${open_extra[@]}"}
      exit 0
    fi

    if [ -e "$wt_path" ]; then
      echo "rfx: worktree path exists: $wt_path (bootstrap only)" >&2
    else
      mkdir -p "$wt_root"
      echo "rfx: syncing origin/$ref ..." >&2
      _sync_integration "$source_repo"
      git -C "$source_repo" fetch origin "$ref" 2>/dev/null || git -C "$source_repo" fetch origin || true
      base="origin/$ref"
      if ! git -C "$source_repo" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
        base="$ref"
      fi
      branch="feat/${open_label}"
      if git -C "$source_repo" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$source_repo" worktree add "$wt_path" "$branch"
      else
        git -C "$source_repo" worktree add -b "$branch" "$wt_path" "$base"
      fi
      echo "rfx: created $wt_path ($branch from $base)" >&2
    fi

    envf="$(rfg_write_worktree_env "$wt_path" "$open_label")"
    echo "rfx: bootstrap $envf" >&2

    if [ -n "$claim_surface" ]; then
      RFG_CLAIM_WORKTREE="$wt_path"
      RFG_CLAIM_AGENT="${RFG_CLAIM_AGENT:-codex}"
      export RFG_CLAIM_WORKTREE RFG_CLAIM_AGENT
      claim_file="$(rfg_claim_acquire "$open_repo" "$claim_surface")" || die "claim failed for $claim_surface"
      echo "rfx: claimed $claim_file" >&2
    fi

    if [ "$no_agent" -eq 1 ]; then
      echo "$wt_path"
      exit 0
    fi

    _rfx_storm_preflight
    codex_bin="$(resolve_codex)" || die "codex not found on PATH or in ~/.local/bin / ~/.codex/packages"
    load_mcp_strict || die "MCP env not ready (mint with: rfx mint)"
    cd "$wt_path"
    _rfx_mcp_args
    _rfx_revealui_pointer "$wt_path"
    set -a
    # shellcheck disable=SC1090
    . "$envf"
    set +a
    _rfx_stamp_launch "$codex_bin"
    exec "$codex_bin" ${RFX_CODEX_PRE[@]+"${RFX_CODEX_PRE[@]}"} ${open_extra[@]+"${open_extra[@]}"}
    ;;
  -h | --help | help)
    _rfx_help
    exit 0
    ;;
esac

repo="${1:-}"
if [ "$repo" = "--" ]; then
  repo=""
  shift
elif [ -n "$repo" ]; then
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
    echo "rfx: name a fleet repo, e.g. 'rfx revealui'. Available:" >&2
    list_repos >&2
    exit 2
    ;;
  *)
    if [ -n "${repo:-}" ]; then
      case "$repo" in
        -*) die "name a fleet repo before codex flags, or cd into the fleet root / a repo" ;;
        .. | ../* | */.. | */../* | /* | */*) die "repo name must be a single fleet checkout (got '$repo')" ;;
        *) die "no such fleet repo: '$repo' (under $FLEET_ROOT)" ;;
      esac
    fi
    die "could not resolve launch target"
    ;;
esac

# `rfx <repo> -- <codex args>`: drop the separator so codex sees its own flags.
if [ "${1:-}" = "--" ]; then
  shift
fi

codex_bin="$(resolve_codex)" || die "codex not found on PATH or in ~/.local/bin / ~/.codex/packages"
_rfx_guard_codex_worktree "$target" "$@"

if [ "$RFX_DRY_RUN" = 1 ]; then
  load_mcp_strict || die "MCP env not ready (mint with: rfx mint)"
  _rfx_mcp_args
  _rfx_revealui_pointer "$target"
  _rfx_print_plan "$target" "$codex_bin" "$@"
  exit 0
fi

_rfx_storm_preflight
_sync_integration "$target"
load_mcp_strict || die "MCP env not ready (mint with: rfx mint)"

cd "$target"
_rfx_mcp_args
_rfx_revealui_pointer "$target"
_rfx_stamp_launch "$codex_bin"
exec "$codex_bin" ${RFX_CODEX_PRE[@]+"${RFX_CODEX_PRE[@]}"} "$@"
