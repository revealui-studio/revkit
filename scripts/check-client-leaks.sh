#!/usr/bin/env bash
# check-client-leaks.sh
#
# Scans a tree for any reference to a RevealUI Studio client, prospect,
# or warm-intro contact. Customer and prospect names belong in the private
# internal repo only. They must never appear on this public surface.
#
# The literal pattern list is not stored in this file. Load it at runtime:
#   1. CLIENT_LEAK_PATTERNS (multiline; one tag|literal|reason line per line)
#   2. Local only: gitignored .client-name-watchlist.local (same line format)
#
# In CI (CI=true or GITHUB_ACTIONS=true) the local file is not a fallback.
# An empty or missing CLIENT_LEAK_PATTERNS exits 2. That names the org
# Actions secret and does not name any client.
#
# Locally, if neither source yields a pattern line, print a warning and
# exit 2. That is not a clean scan.
#
# Exit 0 on clean. Exit 1 on any violation. Exit 2 on tool or setup error.
#
# Usage:
#   bash scripts/check-client-leaks.sh                     # scan repo root
#   bash scripts/check-client-leaks.sh <path> [<path>...]  # scan specific paths
#   LEAK_JSON=1 bash scripts/check-client-leaks.sh         # machine-readable
#
# CI wiring: .github/workflows/check-client-leaks.yml
# REQUIRED status check on `test` and `main` branch protection.
#
# Adding a client, prospect, or contact:
#   Add one line to the CLIENT_LEAK_PATTERNS org secret (never to a
#   committed file). Format: tag|literal|reason.
#   There is no .leakignore for this scanner. The property is unconditional.
#
# REGEX-CONFIG-BOUNDARY: matching uses grep -F (fixed strings). Each
# pattern is a literal substring. This script does not author a regex.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN_PATHS=("$@")
[[ ${#SCAN_PATHS[@]} -eq 0 ]] && SCAN_PATHS=("$REPO_ROOT")

for _path in "${SCAN_PATHS[@]}"; do
  if [[ ! -e "$_path" ]]; then
    echo "[client-leak] error: scan path not found: $_path" >&2
    exit 2
  fi
done
unset _path

in_ci=0
if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
  in_ci=1
fi

declare -a PATTERNS=()

# $1 = trimmed line, $2 = 1 when a missing delimiter is an error (the env var).
# Lines with no "|" are skipped in the local file so a one-term-per-line
# watchlist is not misread as this scanner's list.
consider_line() {
  local line="$1"
  local strict="$2"
  local tag rest pattern reason

  case "$line" in
    *\|*) ;;
    *)
      if [[ "$strict" == "1" ]]; then
        echo "[client-leak] error: CLIENT_LEAK_PATTERNS has a line that is not tag|literal|reason." >&2
        exit 2
      fi
      return 0
      ;;
  esac

  tag="${line%%|*}"
  rest="${line#*|}"
  pattern="${rest%%|*}"
  reason="${rest#*|}"
  if [[ -z "$tag" || -z "$pattern" || "$reason" == "$rest" || -z "$reason" ]]; then
    echo "[client-leak] error: expected tag|literal|reason with three non-empty fields." >&2
    echo "[client-leak] Check CLIENT_LEAK_PATTERNS or .client-name-watchlist.local. The line was not printed." >&2
    exit 2
  fi
  PATTERNS+=("$line")
}

load_lines() {
  local strict="$1"
  local raw line
  while IFS= read -r raw || [[ -n "${raw:-}" ]]; do
    raw="${raw%$'\r'}"
    line="${raw#"${raw%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    case "$line" in
      \#*) continue ;;
    esac
    consider_line "$line" "$strict"
  done
}

if [[ "$in_ci" == "1" ]]; then
  if [[ -n "${CLIENT_LEAK_PATTERNS:-}" ]]; then
    load_lines 1 <<< "${CLIENT_LEAK_PATTERNS}"
  fi
  if [[ ${#PATTERNS[@]} -eq 0 ]]; then
    echo "[client-leak] error: CLIENT_LEAK_PATTERNS is missing or empty." >&2
    echo "[client-leak] CI fails closed until the org Actions secret CLIENT_LEAK_PATTERNS is set and visible to this repo." >&2
    echo "[client-leak] Format is one tag|literal|reason line per line. Do not commit the list." >&2
    exit 2
  fi
else
  if [[ -n "${CLIENT_LEAK_PATTERNS:-}" ]]; then
    load_lines 1 <<< "${CLIENT_LEAK_PATTERNS}"
  elif [[ -f "$REPO_ROOT/.client-name-watchlist.local" ]]; then
    load_lines 0 < "$REPO_ROOT/.client-name-watchlist.local"
  fi
  if [[ ${#PATTERNS[@]} -eq 0 ]]; then
    echo "[client-leak] WARN: no client-leak patterns loaded." >&2
    echo "[client-leak] Set CLIENT_LEAK_PATTERNS, or add tag|literal|reason lines to .client-name-watchlist.local (gitignored)." >&2
    echo "[client-leak] Add new lines to the CLIENT_LEAK_PATTERNS org secret, never to a committed file." >&2
    echo "[client-leak] This is not a clean scan." >&2
    exit 2
  fi
fi

# Directories / file globs to skip.
# .client-name-watchlist.local is the local fallback list, so it is not a hit.
EXCLUDE_DIRS=(node_modules .git dist build .next .turbo .pnpm coverage target .direnv .nyc_output playwright-report test-results)
EXCLUDE_FILES=(
  pnpm-lock.yaml package-lock.json yarn.lock Cargo.lock
  .client-name-watchlist.local
  CHANGELOG.md
  '*.png' '*.jpg' '*.jpeg' '*.gif' '*.webp' '*.pdf' '*.zip' '*.tar.gz' '*.tgz'
  '*.ico' '*.woff' '*.woff2' '*.ttf' '*.otf'
  '*.har' '*.snap'
)

if ! command -v grep >/dev/null 2>&1; then
  echo "[client-leak] error: grep not found on PATH" >&2
  exit 2
fi

grep_excludes=()
for d in "${EXCLUDE_DIRS[@]}"; do
  grep_excludes+=(--exclude-dir="$d")
done
for f in "${EXCLUDE_FILES[@]}"; do
  grep_excludes+=(--exclude="$f")
done

violations=0
json_entries=()

for entry in "${PATTERNS[@]}"; do
  tag="${entry%%|*}"
  rest="${entry#*|}"
  pattern="${rest%%|*}"
  reason="${rest#*|}"

  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file="${hit%%:*}"
    rest_="${hit#*:}"
    line="${rest_%%:*}"
    content="${rest_#*:}"

    if [[ -n "${LEAK_JSON:-}" ]]; then
      if command -v jq >/dev/null 2>&1; then
        json_entries+=("$(jq -cn --arg tag "$tag" --arg file "$file" --arg line "$line" --arg reason "$reason" --arg content "$content" \
          '{tag:$tag, file:$file, line:($line|tonumber), reason:$reason, content:$content}')")
      else
        safe="${content//\\/\\\\}"
        safe="${safe//\"/\\\"}"
        safe="${safe//$'\n'/\\n}"
        safe="${safe//$'\t'/\\t}"
        sreason="${reason//\\/\\\\}"
        sreason="${sreason//\"/\\\"}"
        json_entries+=("{\"tag\":\"$tag\",\"file\":\"$file\",\"line\":$line,\"reason\":\"$sreason\",\"content\":\"$safe\"}")
      fi
    else
      printf '[CLIENT-LEAK:%s] %s:%s: %s\n  %s\n' "$tag" "$file" "$line" "$reason" "$content"
    fi
    violations=$((violations + 1))
  done < <(grep -rFIn "${grep_excludes[@]}" -- "$pattern" "${SCAN_PATHS[@]}" 2>/dev/null || true)
done

if [[ -n "${LEAK_JSON:-}" ]]; then
  printf '{"violations":%d,"entries":[%s]}\n' "$violations" "$(IFS=,; echo "${json_entries[*]:-}")"
fi

if (( violations > 0 )); then
  if [[ -z "${LEAK_JSON:-}" ]]; then
    echo "" >&2
    echo "[client-leak] FAIL: $violations violation(s)." >&2
    echo "" >&2
    echo "Customer / prospect names must NEVER appear in this public-facing repo." >&2
    echo "Move the content to the private internal repo (or genericize with a" >&2
    echo "placeholder like 'Acme Corp' / 'acme' / 'first customer')." >&2
    echo "" >&2
    echo "To cover a new client, prospect, or contact, add the line to the" >&2
    echo "CLIENT_LEAK_PATTERNS org secret (never to a committed file)." >&2
  fi
  exit 1
fi

[[ -z "${LEAK_JSON:-}" ]] && echo "[client-leak] OK: no client/prospect names detected across: ${SCAN_PATHS[*]}"
exit 0
