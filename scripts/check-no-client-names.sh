#!/usr/bin/env bash
# check-no-client-names.sh
#
# Watchlist gate for client / buyer / end-client terms that must not appear
# in public artifacts. Companion to:
#   scripts/check-no-private-leaks.sh  paths, hostnames, machine homes
#   scripts/check-client-leaks.sh      secret-backed literals (CLIENT_LEAK_PATTERNS)
#
# This file never embeds watchlist terms. Load from (first found):
#   1. $CLIENT_NAME_WATCHLIST_FILE
#   2. .client-name-watchlist.local under repo root
#   3. $CLIENT_NAME_PATTERNS (newline or | separated)
#
# If no watchlist: WARN + exit 0 (gate inactive) so public CI without a secret
# does not false-fail. Layer A (bot daily org audit) still runs. Set
# CLIENT_NAME_WATCHLIST_REQUIRED=1 to exit 2 when the watchlist is missing.
#
# The client-leak scanner stays. It loads CLIENT_LEAK_PATTERNS (local
# fallback: tag|literal|reason lines in .client-name-watchlist.local) and
# fails closed in CI when that secret is missing. Use this gate for a
# separate operator term list. Never commit either list.
#
# Exit 0 on clean (or inactive). Exit 1 on any violation. Exit 2 on setup error.
#
# Usage:
#   bash scripts/check-no-client-names.sh                     # scan repo root
#   bash scripts/check-no-client-names.sh <path> [<path>...]  # scan explicit paths
#   LEAK_JSON=1 bash scripts/check-no-client-names.sh         # machine-readable
#
# Commit messages (forward only; does not rewrite accepted history):
#   bash scripts/check-no-client-names.sh --commits [<rev-range>]
#   SCAN_COMMIT_MESSAGES=1 bash scripts/check-no-client-names.sh
#   CLIENT_NAME_PR_TITLE="$title" bash scripts/check-no-client-names.sh --commits
#
#   Default range: origin/$GITHUB_BASE_REF..HEAD when that ref exists
#   (local $GITHUB_BASE_REF..HEAD if the remote-tracking ref does not).
#   A set but unresolvable GITHUB_BASE_REF is exit 2, not a fallthrough.
#   If GITHUB_BASE_REF is unset, the default is origin/test..HEAD.
#   Two-dot selects commits reachable from HEAD that are not on the base
#   (the pull-request commit list). Pass an explicit range, including a
#   three-dot range, to override. CLIENT_NAME_COMMIT_RANGE does the same.
#
# Proposed message (commit-msg hook; see scripts/hooks/commit-msg-client-names.sh):
#   bash scripts/check-no-client-names.sh --message-file <path>
#
# File scan stays the default. --commits and --message-file do not scan the
# tree unless you also pass paths. Passing paths together with --commits
# scans both surfaces.
#
# Safe to rerun; read-only. Do not commit real watchlist terms to public git.
# Design: docs/client-name-public-github.md

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
usage: bash scripts/check-no-client-names.sh [options] [<path>...]

  Scan files for operator watchlist terms (default: repo root).
  --commits [<rev-range>]   Scan git commit subjects and bodies.
                            Default range is base..HEAD (pull-request
                            commits only). See the script header.
  --message-file <path>     Scan a proposed commit message file.
  -h, --help                Show this help.

Environment:
  CLIENT_NAME_WATCHLIST_FILE, .client-name-watchlist.local, CLIENT_NAME_PATTERNS
  CLIENT_NAME_WATCHLIST_REQUIRED=1   Exit 2 when no watchlist is loaded.
  SCAN_COMMIT_MESSAGES=1             Same as passing --commits.
  CLIENT_NAME_COMMIT_RANGE           Default rev-range when --commits omits one.
  CLIENT_NAME_PR_TITLE               Also scan this pull-request title in --commits mode.
  LEAK_JSON=1                        One-line JSON summary.

Exit 0 clean or inactive. Exit 1 violation. Exit 2 setup error.
No watchlist: WARN and exit 0, unless CLIENT_NAME_WATCHLIST_REQUIRED=1.
EOF
}

SCAN_COMMITS=0
COMMIT_RANGE=""
MESSAGE_FILE=""
SCAN_PATHS=()

if [[ "${SCAN_COMMIT_MESSAGES:-}" == "1" ]]; then
  SCAN_COMMITS=1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --commits)
      SCAN_COMMITS=1
      if [[ $# -ge 2 && "$2" != -* ]]; then
        COMMIT_RANGE="$2"
        shift
      fi
      shift
      ;;
    --message-file)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "[client-name-check] error: --message-file requires a path" >&2
        exit 2
      fi
      MESSAGE_FILE="$2"
      shift 2
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        SCAN_PATHS+=("$1")
        shift
      done
      ;;
    -*)
      echo "[client-name-check] error: unknown option: $1" >&2
      exit 2
      ;;
    *)
      SCAN_PATHS+=("$1")
      shift
      ;;
  esac
done

DO_MESSAGE=0
DO_COMMIT=0
DO_FILE=0
[[ -n "$MESSAGE_FILE" ]] && DO_MESSAGE=1
[[ "$SCAN_COMMITS" == 1 ]] && DO_COMMIT=1

if [[ ${#SCAN_PATHS[@]} -gt 0 ]]; then
  DO_FILE=1
elif [[ "$DO_COMMIT" == 0 && "$DO_MESSAGE" == 0 ]]; then
  DO_FILE=1
  SCAN_PATHS=("$REPO_ROOT")
fi

if [[ "$DO_MESSAGE" == 1 && ! -f "$MESSAGE_FILE" ]]; then
  echo "[client-name-check] error: commit message file not found: $MESSAGE_FILE" >&2
  exit 2
fi

if [[ "$DO_FILE" == 1 ]]; then
  for _path in "${SCAN_PATHS[@]}"; do
    if [[ ! -e "$_path" ]]; then
      echo "[client-name-check] error: scan path not found: $_path" >&2
      exit 2
    fi
  done
  unset _path
fi

if ! command -v grep >/dev/null 2>&1; then
  echo "[client-name-check] error: grep not found on PATH" >&2
  exit 2
fi

# Same exclude set as check-no-private-leaks.sh (build/dev artifacts + self).
# .client-name-watchlist.local holds the terms on purpose, so it is not a hit.
EXCLUDE_DIRS=(node_modules .git dist build .next .turbo .pnpm coverage target .direnv .nyc_output)
EXCLUDE_FILES=(
  pnpm-lock.yaml package-lock.json yarn.lock Cargo.lock
  check-no-client-names.sh
  check-no-private-leaks.sh
  client-name-watchlist.example
  .client-name-watchlist.local
  .git
  '*.png' '*.jpg' '*.jpeg' '*.gif' '*.webp' '*.pdf' '*.zip' '*.tar.gz' '*.tgz'
  '*.ico' '*.woff' '*.woff2' '*.ttf' '*.otf'
)

grep_excludes=()
for d in "${EXCLUDE_DIRS[@]}"; do
  grep_excludes+=(--exclude-dir="$d")
done
for f in "${EXCLUDE_FILES[@]}"; do
  grep_excludes+=(--exclude="$f")
done

# --- Load watchlist patterns (no real terms in this source file) ---
declare -a PATTERNS=()
WATCHLIST_SOURCE=""
WATCHLIST_FILE_SKIP=""

load_patterns_from_file() {
  local file="$1"
  local raw line
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    # Strip trailing CR (Windows watchlist files).
    raw="${raw%$'\r'}"
    # Full-line comments.
    [[ "$raw" =~ ^[[:space:]]*# ]] && continue
    # Strip inline comments after #
    line="${raw%%#*}"
    # Trim whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    PATTERNS+=("$line")
  done < "$file"
}

if [[ -n "${CLIENT_NAME_WATCHLIST_FILE:-}" ]]; then
  if [[ ! -f "$CLIENT_NAME_WATCHLIST_FILE" ]]; then
    echo "[client-name-check] error: CLIENT_NAME_WATCHLIST_FILE not found: $CLIENT_NAME_WATCHLIST_FILE" >&2
    exit 2
  fi
  load_patterns_from_file "$CLIENT_NAME_WATCHLIST_FILE"
  WATCHLIST_SOURCE="CLIENT_NAME_WATCHLIST_FILE=$CLIENT_NAME_WATCHLIST_FILE"
  WATCHLIST_FILE_SKIP="$CLIENT_NAME_WATCHLIST_FILE"
elif [[ -f "$REPO_ROOT/.client-name-watchlist.local" ]]; then
  load_patterns_from_file "$REPO_ROOT/.client-name-watchlist.local"
  WATCHLIST_SOURCE="$REPO_ROOT/.client-name-watchlist.local"
  WATCHLIST_FILE_SKIP="$REPO_ROOT/.client-name-watchlist.local"
elif [[ -n "${CLIENT_NAME_PATTERNS:-}" ]]; then
  # Newline or | separated.
  _tmp="${CLIENT_NAME_PATTERNS}"
  if [[ "$_tmp" == *$'\n'* ]]; then
    while IFS= read -r raw || [[ -n "$raw" ]]; do
      line="${raw%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      PATTERNS+=("$line")
    done <<< "$_tmp"
  else
    IFS='|' read -ra _parts <<< "$_tmp"
    for raw in "${_parts[@]}"; do
      line="${raw#"${raw%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      PATTERNS+=("$line")
    done
  fi
  unset _tmp _parts raw line
  WATCHLIST_SOURCE="CLIENT_NAME_PATTERNS"
fi

if [[ ${#PATTERNS[@]} -eq 0 ]]; then
  if [[ "${CLIENT_NAME_WATCHLIST_REQUIRED:-}" == "1" ]]; then
    echo "[client-name-check] error: no watchlist loaded and CLIENT_NAME_WATCHLIST_REQUIRED=1" >&2
    echo "[client-name-check] set CLIENT_NAME_WATCHLIST_FILE, add .client-name-watchlist.local, or CLIENT_NAME_PATTERNS" >&2
    exit 2
  fi
  echo "[client-name-check] WARN: no watchlist found; gate inactive (exit 0)." >&2
  echo "[client-name-check] Layer A (bot daily org audit) still runs. To activate Layer B:" >&2
  echo "[client-name-check]   copy templates/client-name-watchlist.example -> .client-name-watchlist.local" >&2
  echo "[client-name-check]   or set CLIENT_NAME_WATCHLIST_FILE / CLIENT_NAME_PATTERNS" >&2
  if [[ -n "${LEAK_JSON:-}" ]]; then
    printf '{"violations":0,"inactive":true,"entries":[]}\n'
  fi
  exit 0
fi

# A watchlist file inside the scan tree contains the terms on purpose.
is_watchlist_source_file() {
  local file="$1"
  local skip="$WATCHLIST_FILE_SKIP"
  [[ -z "$skip" ]] && return 1
  file="${file#./}"
  skip="${skip#./}"
  [[ "$file" == "$skip" ]] && return 0
  [[ "$file" == "$REPO_ROOT/$skip" ]] && return 0
  [[ "$REPO_ROOT/$file" == "$skip" ]] && return 0
  return 1
}

# Escape a literal string for use as an ERE (watchlist terms are literals).
# `]` is first inside the bracket expression so it is literal.
ere_escape() {
  printf '%s' "$1" | sed -e 's/[][\\.^$|?*+(){}]/\\&/g'
}

violations=0
json_entries=()

record_hit() {
  local file="$1"
  local line="$2"
  local content="$3"

  if [[ -n "${LEAK_JSON:-}" ]]; then
    if command -v jq >/dev/null 2>&1; then
      if [[ "$line" =~ ^[0-9]+$ ]]; then
        json_entries+=("$(jq -cn --arg tag "client-name" --arg file "$file" --arg line "$line" --arg reason "watchlist term match" --arg content "$content" \
          '{tag:$tag, file:$file, line:($line|tonumber), reason:$reason, content:$content}')")
      else
        json_entries+=("$(jq -cn --arg tag "client-name" --arg file "$file" --arg line "$line" --arg reason "watchlist term match" --arg content "$content" \
          '{tag:$tag, file:$file, line:$line, reason:$reason, content:$content}')")
      fi
    else
      safe_content="${content//\\/\\\\}"
      safe_content="${safe_content//\"/\\\"}"
      safe_content="${safe_content//$'\n'/\\n}"
      safe_content="${safe_content//$'\t'/\\t}"
      safe_file="${file//\\/\\\\}"
      safe_file="${safe_file//\"/\\\"}"
      safe_line="${line//\\/\\\\}"
      safe_line="${safe_line//\"/\\\"}"
      if [[ "$line" =~ ^[0-9]+$ ]]; then
        json_entries+=("{\"tag\":\"client-name\",\"file\":\"$safe_file\",\"line\":$line,\"reason\":\"watchlist term match\",\"content\":\"$safe_content\"}")
      else
        json_entries+=("{\"tag\":\"client-name\",\"file\":\"$safe_file\",\"line\":\"$safe_line\",\"reason\":\"watchlist term match\",\"content\":\"$safe_content\"}")
      fi
    fi
  else
    printf '[LEAK:client-name] %s:%s - watchlist term match\n  -> %s\n' "$file" "$line" "$content"
  fi
  violations=$((violations + 1))
}

# Match one literal term against one text blob. Reports the first matching line.
scan_text_field() {
  local file_label="$1"
  local line_label="$2"
  local text="$3"
  local term regex hit_line
  [[ -z "$text" ]] && return 0
  for term in "${PATTERNS[@]}"; do
    regex="$(ere_escape "$term")"
    hit_line="$(printf '%s\n' "$text" | grep -iE -a -m 1 --color=never -- "$regex" || true)"
    if [[ -n "$hit_line" ]]; then
      record_hit "$file_label" "$line_label" "$hit_line"
    fi
  done
}

scan_files() {
  local term regex hit file rest_ line content
  for term in "${PATTERNS[@]}"; do
    regex="$(ere_escape "$term")"
    # -H always prints the path. A single explicit file otherwise omits it,
    # which breaks hit parsing and watchlist self-skip.
    # -r recursive, -E ERE, -I skip binary, -n line numbers, -i case-insensitive.
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      file="${hit%%:*}"
      rest_="${hit#*:}"
      line="${rest_%%:*}"
      content="${rest_#*:}"

      is_watchlist_source_file "$file" && continue

      record_hit "$file" "$line" "$content"
    done < <(grep -rHEIni "${grep_excludes[@]}" -- "$regex" "${SCAN_PATHS[@]}" 2>/dev/null || true)
  done
}

# Two-dot base..HEAD: commits on HEAD that are not on the base.
# Does not select commits that exist only on the base (accepted history).
resolve_commit_range() {
  local base_ref=""
  if [[ -n "$COMMIT_RANGE" ]]; then
    printf '%s' "$COMMIT_RANGE"
    return 0
  fi
  if [[ -n "${CLIENT_NAME_COMMIT_RANGE:-}" ]]; then
    printf '%s' "${CLIENT_NAME_COMMIT_RANGE}"
    return 0
  fi
  if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
    if git -C "$REPO_ROOT" rev-parse --verify --quiet --end-of-options "origin/${GITHUB_BASE_REF}^{commit}" >/dev/null 2>&1; then
      base_ref="origin/${GITHUB_BASE_REF}"
    elif git -C "$REPO_ROOT" rev-parse --verify --quiet --end-of-options "${GITHUB_BASE_REF}^{commit}" >/dev/null 2>&1; then
      base_ref="${GITHUB_BASE_REF}"
    else
      echo "[client-name-check] error: GITHUB_BASE_REF is set but not found: ${GITHUB_BASE_REF}" >&2
      return 1
    fi
  elif git -C "$REPO_ROOT" rev-parse --verify --quiet --end-of-options "origin/test^{commit}" >/dev/null 2>&1; then
    base_ref="origin/test"
  else
    echo "[client-name-check] error: no commit range. Pass --commits <base>..HEAD or set GITHUB_BASE_REF / CLIENT_NAME_COMMIT_RANGE." >&2
    return 1
  fi
  printf '%s..HEAD' "$base_ref"
}

scan_commits() {
  local range="$1"
  local log_file err_file record sha rest subject body

  if ! command -v git >/dev/null 2>&1; then
    echo "[client-name-check] error: git not found on PATH" >&2
    exit 2
  fi

  log_file="$(mktemp)"
  err_file="$(mktemp)"
  if ! git -C "$REPO_ROOT" log -z --format='%H%x1f%s%x1f%b' "$range" >"$log_file" 2>"$err_file"; then
    echo "[client-name-check] error: git log failed for range: $range" >&2
    cat "$err_file" >&2
    rm -f "$log_file" "$err_file"
    exit 2
  fi
  rm -f "$err_file"

  while IFS= read -r -d '' record || [[ -n "$record" ]]; do
    [[ -z "$record" ]] && continue
    sha="${record%%$'\x1f'*}"
    rest="${record#*$'\x1f'}"
    subject="${rest%%$'\x1f'*}"
    body="${rest#*$'\x1f'}"
    scan_text_field "commit:${sha}" "subject" "$subject"
    scan_text_field "commit:${sha}" "body" "$body"
  done < "$log_file"
  rm -f "$log_file"
}

scan_message_file() {
  local file="$1"
  local raw subject="" body="" seen=0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    # Git drops lines that start with the comment character. Do the same.
    [[ "$raw" == \#* ]] && continue
    if [[ "$seen" -eq 0 ]]; then
      [[ -z "${raw//[[:space:]]/}" ]] && continue
      subject="$raw"
      seen=1
      continue
    fi
    body+="${raw}"$'\n'
  done < "$file"
  scan_text_field "commit:proposed" "subject" "$subject"
  scan_text_field "commit:proposed" "body" "$body"
}

RESOLVED_RANGE=""
if [[ "$DO_FILE" == 1 ]]; then
  scan_files
fi
if [[ "$DO_COMMIT" == 1 ]]; then
  if ! RESOLVED_RANGE="$(resolve_commit_range)"; then
    exit 2
  fi
  scan_commits "$RESOLVED_RANGE"
  if [[ -n "${CLIENT_NAME_PR_TITLE:-}" ]]; then
    scan_text_field "pr" "title" "$CLIENT_NAME_PR_TITLE"
  fi
fi
if [[ "$DO_MESSAGE" == 1 ]]; then
  scan_message_file "$MESSAGE_FILE"
fi

if [[ -n "${LEAK_JSON:-}" ]]; then
  if command -v jq >/dev/null 2>&1; then
    source_json="$(jq -cn --arg s "$WATCHLIST_SOURCE" '$s')"
  else
    source_json="$(printf '"%s"' "${WATCHLIST_SOURCE//\"/\\\"}")"
  fi
  printf '{"violations":%d,"inactive":false,"source":%s,"entries":[%s]}\n' \
    "$violations" \
    "$source_json" \
    "$(IFS=,; echo "${json_entries[*]:-}")"
fi

if (( violations > 0 )); then
  [[ -z "${LEAK_JSON:-}" ]] && echo "[client-name-check] FAIL - $violations violation(s). Fix before publishing." >&2
  exit 1
fi

if [[ -z "${LEAK_JSON:-}" ]]; then
  if [[ "$DO_FILE" == 1 ]]; then
    echo "[client-name-check] OK - no watchlist terms across: ${SCAN_PATHS[*]} (source: $WATCHLIST_SOURCE)"
  fi
  if [[ "$DO_COMMIT" == 1 ]]; then
    pr_note=""
    if [[ -n "${CLIENT_NAME_PR_TITLE:-}" ]]; then
      pr_note=" and CLIENT_NAME_PR_TITLE"
    fi
    echo "[client-name-check] OK - no watchlist terms in commits${pr_note}: ${RESOLVED_RANGE} (source: $WATCHLIST_SOURCE)"
  fi
  if [[ "$DO_MESSAGE" == 1 ]]; then
    echo "[client-name-check] OK - no watchlist terms in commit message (source: $WATCHLIST_SOURCE)"
  fi
fi
exit 0
