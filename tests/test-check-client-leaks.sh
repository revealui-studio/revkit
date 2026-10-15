#!/usr/bin/env bash
# Placeholder patterns only. The contiguous placeholder is assembled at
# runtime so a repo scan for that literal does not match this file.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/scripts/check-client-leaks.sh"

lit_a=acme-
lit_b=placeholder
LIT="${lit_a}${lit_b}"
TAG=example-tag
REASON=example
LINE="${TAG}|${LIT}|${REASON}"
OTHER_TAG=example-other
OTHER_LIT=zz-other-placeholder
OTHER_LINE="${OTHER_TAG}|${OTHER_LIT}|${REASON}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_expect() {
  local want="$1"
  shift
  local out code
  set +e
  out="$("$@" 2>&1)"
  code=$?
  set -e
  if [[ "$code" -ne "$want" ]]; then
    echo "FAIL: expected exit $want, got $code" >&2
    echo "cmd: $*" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

assert_has() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
    echo "FAIL: $label" >&2
    echo "missing: $needle" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

assert_lacks() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null; then
    echo "FAIL: $label" >&2
    echo "unexpected: $needle" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

clean_env() {
  env -u CI -u GITHUB_ACTIONS -u CLIENT_LEAK_PATTERNS -u LEAK_JSON "$@"
}

echo "=== test-check-client-leaks.sh ==="

fix="$TMP/repo"
mkdir -p "$fix/scripts" "$fix/clean" "$fix/dirty"
cp "$SCAN" "$fix/scripts/check-client-leaks.sh"
SCAN_COPY="$fix/scripts/check-client-leaks.sh"
printf 'hello\n' > "$fix/clean/note.txt"
printf 'see %s here\n' "$LIT" > "$fix/dirty/note.txt"

# Clean tree, env list, not CI.
out="$(run_expect 0 clean_env CLIENT_LEAK_PATTERNS="$LINE" bash "$SCAN_COPY" "$fix/clean")"
assert_has "$out" "[client-leak] OK:" "clean scan prints OK"

# Hit.
out="$(run_expect 1 clean_env CLIENT_LEAK_PATTERNS="$LINE" bash "$SCAN_COPY" "$fix/dirty")"
assert_has "$out" "[CLIENT-LEAK:${TAG}]" "hit prints the tag"
assert_has "$out" "CLIENT_LEAK_PATTERNS org secret" "hit tells the operator to use the org secret"

# JSON hit still exits 1.
out="$(run_expect 1 clean_env LEAK_JSON=1 CLIENT_LEAK_PATTERNS="$LINE" bash "$SCAN_COPY" "$fix/dirty")"
assert_has "$out" '"violations":1' "json summary counts the hit"

# Comments and blank lines are ignored.
out="$(run_expect 0 clean_env CLIENT_LEAK_PATTERNS=$'# note\n\n'"$LINE" bash "$SCAN_COPY" "$fix/clean")"
assert_has "$out" "[client-leak] OK:" "comments do not become patterns"

# Malformed env line fails closed and does not echo the line.
bad_token=bad-token-should-stay-hidden
out="$(run_expect 2 clean_env CLIENT_LEAK_PATTERNS="${TAG}|${bad_token}" bash "$SCAN_COPY" "$fix/clean")"
assert_has "$out" "tag|literal|reason" "malformed line explains the format"
assert_lacks "$out" "$bad_token" "malformed line is not echoed"

# Local: neither source.
out="$(run_expect 2 clean_env bash "$SCAN_COPY" "$fix/clean")"
assert_has "$out" "WARN: no client-leak patterns loaded." "local miss warns"
assert_has "$out" "not a clean scan" "local miss is not a pass"
assert_lacks "$out" "[client-leak] OK:" "local miss does not print OK"

# Local file fallback. Plain one-term lines are ignored.
printf 'plain-term-only\n%s\n' "$LINE" > "$fix/.client-name-watchlist.local"
out="$(run_expect 0 clean_env bash "$SCAN_COPY" "$fix/clean")"
assert_has "$out" "[client-leak] OK:" "local file supplies patterns"
out="$(run_expect 1 clean_env bash "$SCAN_COPY" "$fix/dirty")"
assert_has "$out" "[CLIENT-LEAK:${TAG}]" "local file pattern matches"

# The fallback file itself is not a hit when the scan root contains it.
out="$(run_expect 0 clean_env bash "$SCAN_COPY" "$fix/clean" "$fix/.client-name-watchlist.local")"
assert_has "$out" "[client-leak] OK:" "watchlist file is excluded"

# Env wins over the local file. The file would have matched; the env pattern does not.
out="$(run_expect 0 clean_env CLIENT_LEAK_PATTERNS="$OTHER_LINE" bash "$SCAN_COPY" "$fix/dirty")"
assert_has "$out" "[client-leak] OK:" "env list replaces the local file"

# CI: empty and missing secret fail closed, and the local file is not used.
out="$(run_expect 2 env -u GITHUB_ACTIONS CI=true CLIENT_LEAK_PATTERNS= bash "$SCAN_COPY" "$fix/dirty")"
assert_has "$out" "CLIENT_LEAK_PATTERNS is missing or empty." "CI empty names the secret"
assert_has "$out" "fails closed" "CI empty says fail closed"
assert_lacks "$out" "$LIT" "CI empty does not scan or print the literal"
assert_lacks "$out" "[client-leak] OK:" "CI empty is not a pass"

out="$(run_expect 2 env -u GITHUB_ACTIONS -u CLIENT_LEAK_PATTERNS CI=true bash "$SCAN_COPY" "$fix/dirty")"
assert_has "$out" "CLIENT_LEAK_PATTERNS" "CI missing names the secret"
assert_lacks "$out" "[CLIENT-LEAK:" "CI missing does not report a hit from the local file"

out="$(run_expect 2 env -u CI -u CLIENT_LEAK_PATTERNS GITHUB_ACTIONS=true bash "$SCAN_COPY" "$fix/dirty")"
assert_has "$out" "CLIENT_LEAK_PATTERNS is missing or empty." "GITHUB_ACTIONS missing fails closed"

# CI with the secret still scans, and ignores the local file's extra pattern.
out="$(run_expect 0 env CI=true GITHUB_ACTIONS=true CLIENT_LEAK_PATTERNS="$OTHER_LINE" bash "$SCAN_COPY" "$fix/dirty")"
assert_has "$out" "[client-leak] OK:" "CI uses only the env list"

out="$(run_expect 1 env CI=true CLIENT_LEAK_PATTERNS="$LINE" bash "$SCAN_COPY" "$fix/dirty")"
assert_has "$out" "[CLIENT-LEAK:${TAG}]" "CI with the secret reports a hit"

# Real tree, placeholder env, must be clean.
out="$(run_expect 0 clean_env CLIENT_LEAK_PATTERNS="$LINE" bash "$SCAN")"
assert_has "$out" "[client-leak] OK:" "repo tree is clean for the placeholder"

echo "check-client-leaks secret-pattern cases passed"
