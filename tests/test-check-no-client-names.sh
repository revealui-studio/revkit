#!/usr/bin/env bash
# File scan stays the default. Commit-message mode, the commit-msg helper,
# and the inactive-without-watchlist path use placeholder patterns only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/scripts/check-no-client-names.sh"
HOOK="$ROOT/scripts/hooks/commit-msg-client-names.sh"

# Public placeholders already used by templates/client-name-watchlist.example.
# Assembled so this sentence stays readable; the contiguous token is intentional.
TERM=buyer_example
OTHER=agency_client_example
LITERAL_DOT=end_client.example
# Split so a repo-wide file scan for this token does not match this test.
absent_prefix=zzclientgate
absent_suffix=placeholder
ABSENT="${absent_prefix}${absent_suffix}"

unset CLIENT_NAME_WATCHLIST_FILE CLIENT_NAME_PATTERNS CLIENT_NAME_WATCHLIST_REQUIRED || true
unset CLIENT_NAME_COMMIT_RANGE CLIENT_NAME_PR_TITLE SCAN_COMMIT_MESSAGES LEAK_JSON GITHUB_BASE_REF || true

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

echo "=== test-check-no-client-names.sh ==="

# --- real script: default file scan, inactive, setup errors ---

out="$(run_expect 0 bash "$SCAN")"
assert_has "$out" "gate inactive" "real repo without a watchlist stays inactive"
assert_lacks "$out" "[LEAK:client-name]" "inactive file scan must not report hits"

out="$(run_expect 0 bash "$SCAN" --commits 'definitely-missing..HEAD')"
assert_has "$out" "gate inactive" "commit mode without a watchlist stays inactive even if the range is bad"

out="$(run_expect 0 env LEAK_JSON=1 bash "$SCAN" --commits 'definitely-missing..HEAD')"
assert_has "$out" '"inactive":true' "inactive JSON flag"

out="$(run_expect 2 env CLIENT_NAME_WATCHLIST_REQUIRED=1 bash "$SCAN" --commits 'origin/test..HEAD')"
assert_has "$out" "CLIENT_NAME_WATCHLIST_REQUIRED=1" "required watchlist exits 2 before a commit scan"

out="$(run_expect 2 bash "$SCAN" --no-such-flag)"
assert_has "$out" "unknown option" "unknown flag is a setup error"

out="$(run_expect 0 bash "$SCAN" --help)"
assert_has "$out" "--commits" "help lists commit mode"
assert_has "$out" "--message-file" "help lists message-file mode"

wl="$TMP/watchlist.txt"
printf '%s\n' "# comment" "$ABSENT" > "$wl"
out="$(run_expect 0 env CLIENT_NAME_WATCHLIST_FILE="$wl" bash "$SCAN")"
assert_has "$out" "OK - no watchlist terms across:" "default file scan still prints the file OK line"
assert_lacks "$out" "in commits" "default file scan does not scan commits"

# Placeholder term in a fixture file, not in this repo's commit messages.
fix="$TMP/fixture"
mkdir -p "$fix/nested"
printf '%s\n' "demo share seed" > "$fix/nested/clean.txt"
out="$(run_expect 0 env CLIENT_NAME_PATTERNS="$TERM|$OTHER" bash "$SCAN" "$fix")"
assert_has "$out" "OK - no watchlist terms across:" "clean tree passes file scan"

printf '%s\n' "Seed ${TERM} host" > "$fix/nested/note.txt"
out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN" "$fix")"
assert_has "$out" "[LEAK:client-name] $fix/nested/note.txt:1 - watchlist term match" "file hit keeps path:line form"
assert_has "$out" "FAIL - 1 violation" "file hit exits 1"

printf '%s\n' "Seed Buyer_Example host" > "$fix/nested/note.txt"
out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN" "$fix")"
assert_has "$out" "note.txt:1" "file match is case-insensitive"

printf '%s\n' "end_clientXexample" > "$fix/nested/note.txt"
out="$(run_expect 0 env CLIENT_NAME_PATTERNS="$LITERAL_DOT" bash "$SCAN" "$fix")"
assert_lacks "$out" "[LEAK:client-name]" "dotted pattern stays literal in file mode"

printf '%s\n' "end_client.example" > "$fix/nested/note.txt"
out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$LITERAL_DOT" bash "$SCAN" "$fix")"
assert_has "$out" "note.txt:1" "literal dot matches itself"

# Watchlist file inside the scan tree is skipped; a sibling still fails.
printf '%s\n' "$TERM" > "$fix/names.txt"
out="$(run_expect 0 env CLIENT_NAME_WATCHLIST_FILE="$fix/names.txt" bash "$SCAN" "$fix/names.txt")"
assert_lacks "$out" "[LEAK:client-name]" "watchlist source file is not a hit"
printf '%s\n' "clean demo" > "$fix/nested/note.txt"
printf '%s\n' "$TERM" > "$fix/nested/hit.txt"
out="$(run_expect 1 env CLIENT_NAME_WATCHLIST_FILE="$fix/names.txt" bash "$SCAN" "$fix")"
assert_has "$out" "hit.txt:1" "sibling of the watchlist file still fails"
assert_lacks "$out" "names.txt" "watchlist file path is omitted"

# --- commit mode, isolated repo (script copy so git -C is the fixture) ---

repo="$TMP/repo"
mkdir -p "$repo/scripts/hooks"
cp "$SCAN" "$repo/scripts/check-no-client-names.sh"
cp "$HOOK" "$repo/scripts/hooks/commit-msg-client-names.sh"
SCAN_COPY="$repo/scripts/check-no-client-names.sh"
HOOK_COPY="$repo/scripts/hooks/commit-msg-client-names.sh"

git -C "$repo" init -b test >/dev/null
git -C "$repo" config user.email "gate-test@example.com"
git -C "$repo" config user.name "Gate Test"
git -C "$repo" config commit.gpgsign false

printf '%s\n' "demo" > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m "chore: base demo"
base_clean="$(git -C "$repo" rev-parse HEAD)"

printf '%s\n' "history" >> "$repo/README.md"
git -C "$repo" commit -q -am "chore: note ${TERM} on the base"
git -C "$repo" update-ref refs/remotes/origin/test HEAD

git -C "$repo" checkout -q -b feature
printf '%s\n' "more" >> "$repo/README.md"
git -C "$repo" commit -q -am "feat: demo share seed"
clean_sha="$(git -C "$repo" rev-parse HEAD)"

printf '%s\n' "slug" >> "$repo/README.md"
git -C "$repo" commit -q -am "feat: wire ${TERM} slug"
bad_subject="$(git -C "$repo" rev-parse HEAD)"

printf '%s\n' "body" >> "$repo/README.md"
git -C "$repo" commit -q -am "feat: demo shell" -m "Seed ${TERM} for the share host."
bad_body="$(git -C "$repo" rev-parse HEAD)"

printf '%s\n' "case" >> "$repo/README.md"
git -C "$repo" commit -q -am "feat: Buyer_Example token"
bad_case="$(git -C "$repo" rev-parse HEAD)"

patterns="$(printf '%s\n' "$TERM" "$OTHER")"

out="$(run_expect 0 env CLIENT_NAME_PATTERNS="$patterns" bash "$SCAN_COPY" --commits "origin/test..${clean_sha}")"
assert_has "$out" "OK - no watchlist terms in commits:" "clean commit range passes"
assert_lacks "$out" "[LEAK:client-name]" "clean range has no hits"
assert_lacks "$out" "across:" "commit-only mode does not file-scan"

# Base holds the placeholder. Two-dot from origin/test must not select it.
out="$(run_expect 0 env CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" --commits "origin/test..${clean_sha}")"
assert_lacks "$out" "[LEAK:client-name]" "two-dot range ignores accepted history on the base"

out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" --commits "${clean_sha}..${bad_subject}")"
assert_has "$out" "commit:${bad_subject}:subject" "subject hit uses commit:<sha>:subject"
assert_has "$out" "FAIL - 1 violation" "subject hit exits 1"
assert_lacks "$out" "commit:${bad_subject}:body" "subject-only commit does not report a body hit"

out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" --commits "${bad_subject}..${bad_body}")"
assert_has "$out" "commit:${bad_body}:body" "body hit uses commit:<sha>:body"
assert_lacks "$out" "commit:${bad_body}:subject" "body-only commit does not report a subject hit"

out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" --commits "${bad_body}..${bad_case}")"
assert_has "$out" "commit:${bad_case}:subject" "commit subject match is case-insensitive"

out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" --commits "origin/test..HEAD")"
assert_has "$out" "commit:${bad_subject}:subject" "explicit origin/test..HEAD sees the feature commit"
assert_has "$out" "commit:${bad_body}:body" "explicit range sees the body hit"
assert_lacks "$out" "note ${TERM} on the base" "origin/test..HEAD does not report the base commit"
# The base subject is not in the leak list. Guard via the base sha.
assert_lacks "$out" "commit:$(git -C "$repo" rev-parse origin/test):" "base sha is not reported"

out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$TERM" SCAN_COMMIT_MESSAGES=1 bash "$SCAN_COPY")"
assert_has "$out" "commit:${bad_case}:subject" "SCAN_COMMIT_MESSAGES=1 defaults to origin/test..HEAD"

out="$(run_expect 0 env CLIENT_NAME_PATTERNS="$ABSENT" GITHUB_BASE_REF=test bash "$SCAN_COPY" --commits)"
assert_has "$out" "origin/test..HEAD" "GITHUB_BASE_REF selects origin/<ref>..HEAD"
out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$TERM" GITHUB_BASE_REF=test bash "$SCAN_COPY" --commits)"
assert_has "$out" "commit:${bad_subject}:subject" "GITHUB_BASE_REF range includes feature commits"

out="$(run_expect 0 env CLIENT_NAME_PATTERNS="$TERM" GITHUB_BASE_REF=test CLIENT_NAME_COMMIT_RANGE="origin/test..${clean_sha}" bash "$SCAN_COPY" --commits)"
assert_has "$out" "origin/test..${clean_sha}" "CLIENT_NAME_COMMIT_RANGE overrides GITHUB_BASE_REF"

out="$(run_expect 0 env CLIENT_NAME_PATTERNS="$TERM" GITHUB_BASE_REF=missing CLIENT_NAME_COMMIT_RANGE="${base_clean}..${clean_sha}" bash "$SCAN_COPY" --commits "origin/test..${clean_sha}")"
assert_has "$out" "origin/test..${clean_sha}" "explicit --commits range wins over the environment"
assert_lacks "$out" "[LEAK:client-name]" "explicit clean range is not replaced by a dirty env range"

out="$(run_expect 2 env CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" --commits 'does-not-exist..HEAD')"
assert_has "$out" "git log failed" "bad range is exit 2 when a watchlist is loaded"

out="$(run_expect 2 env CLIENT_NAME_PATTERNS="$TERM" GITHUB_BASE_REF=missing-base bash "$SCAN_COPY" --commits)"
assert_has "$out" "GITHUB_BASE_REF is set but not found" "a missing GITHUB_BASE_REF does not fall through to origin/test"

# No origin/test and no GITHUB_BASE_REF: setup error, not a full-history scan.
git -C "$repo" update-ref -d refs/remotes/origin/test
out="$(run_expect 2 env CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" --commits)"
assert_has "$out" "no commit range" "missing default base is exit 2"
git -C "$repo" update-ref refs/remotes/origin/test "$(git -C "$repo" rev-parse test)"

# File dirty, commits not scanned unless asked.
printf '%s\n' "$TERM" > "$repo/tracked.txt"
out="$(run_expect 0 env CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" --commits "origin/test..${clean_sha}")"
assert_lacks "$out" "tracked.txt" "commit mode does not scan a dirty worktree file"
out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" "$repo/tracked.txt")"
assert_has "$out" "tracked.txt:1" "explicit path still file-scans when commit mode is off"
out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" --commits "origin/test..${clean_sha}" "$repo/tracked.txt")"
assert_has "$out" "tracked.txt:1" "paths plus --commits scans files too"
assert_lacks "$out" "commit:${clean_sha}" "clean commit range adds no commit hit beside the file hit"

# Safe public words are not the placeholder.
out="$(run_expect 0 env CLIENT_NAME_PR_TITLE='feat: demo for agency client' CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" --commits "origin/test..${clean_sha}")"
assert_has "$out" "CLIENT_NAME_PR_TITLE" "clean PR title is included in the OK line"
assert_lacks "$out" "pr:title" "generic public title is not a hit"

out="$(run_expect 1 env CLIENT_NAME_PR_TITLE="Ship ${TERM}" CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" --commits "origin/test..${clean_sha}")"
assert_has "$out" "[LEAK:client-name] pr:title - watchlist term match" "PR title hit"
assert_lacks "$out" "commit:${clean_sha}" "PR title hit does not invent a commit hit"

# PR title env must not change file-only mode.
printf '%s\n' "demo" > "$fix/nested/note.txt"
rm -f "$fix/nested/hit.txt"
out="$(run_expect 0 env CLIENT_NAME_PR_TITLE="Ship ${TERM}" CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN" "$fix/nested")"
assert_lacks "$out" "pr:title" "file mode ignores CLIENT_NAME_PR_TITLE"

out="$(run_expect 1 env LEAK_JSON=1 CLIENT_NAME_PATTERNS="$TERM" bash "$SCAN_COPY" --commits "${clean_sha}..${bad_subject}")"
assert_has "$out" '"inactive":false' "commit JSON is active"
assert_has "$out" "\"file\":\"commit:${bad_subject}\"" "commit JSON file field"
assert_has "$out" '"line":"subject"' "commit JSON line label"
assert_lacks "$out" "FAIL -" "JSON mode suppresses the human FAIL line"

# Dotted literal in a commit subject.
printf '%s\n' "dot" >> "$repo/README.md"
git -C "$repo" commit -q -am "feat: end_clientXexample stays generic"
dot_clean="$(git -C "$repo" rev-parse HEAD)"
out="$(run_expect 0 env CLIENT_NAME_PATTERNS="$LITERAL_DOT" bash "$SCAN_COPY" --commits "${bad_case}..${dot_clean}")"
assert_lacks "$out" "[LEAK:client-name]" "commit mode does not treat a dot as any-character"

git -C "$repo" commit -q --allow-empty -m "feat: end_client.example token"
dot_bad="$(git -C "$repo" rev-parse HEAD)"
out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$LITERAL_DOT" bash "$SCAN_COPY" --commits "${dot_clean}..${dot_bad}")"
assert_has "$out" "commit:${dot_bad}:subject" "commit mode matches a literal dot"

# --- commit-msg helper (real hook, message file only) ---

msg="$TMP/COMMIT_EDITMSG"
printf '%s\n' "feat: demo share seed" "" "Agency client shell." > "$msg"
out="$(run_expect 0 env CLIENT_NAME_PATTERNS="$TERM" bash "$HOOK" "$msg")"
assert_has "$out" "OK - no watchlist terms in commit message" "clean proposed message passes"

printf '%s\n' "feat: add ${TERM} slug" > "$msg"
out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$TERM" bash "$HOOK" "$msg")"
assert_has "$out" "commit:proposed:subject" "hook reports a proposed subject hit"

printf '%s\n' "feat: demo shell" "" "Seed ${TERM} host." > "$msg"
out="$(run_expect 0 env CLIENT_NAME_WATCHLIST_FILE="$wl" CLIENT_NAME_PATTERNS="$TERM" bash "$HOOK" "$msg")"
# Watchlist file holds only ABSENT, and it outranks CLIENT_NAME_PATTERNS.
assert_lacks "$out" "[LEAK:client-name]" "CLIENT_NAME_WATCHLIST_FILE outranks CLIENT_NAME_PATTERNS"

printf '%s\n' "$TERM" >> "$wl"
printf '%s\n' "feat: demo shell" "" "Seed ${TERM} host." > "$msg"
out="$(run_expect 1 env CLIENT_NAME_WATCHLIST_FILE="$wl" bash "$HOOK" "$msg")"
assert_has "$out" "commit:proposed:body" "hook reports a proposed body hit"

printf '%s\n' "feat: demo shell" "" "# ${TERM}" "body stays generic" > "$msg"
out="$(run_expect 0 env CLIENT_NAME_PATTERNS="$TERM" bash "$HOOK" "$msg")"
assert_lacks "$out" "[LEAK:client-name]" "git comment lines in the message file are ignored"

printf '%s\n' "feat: Buyer_Example token" > "$msg"
out="$(run_expect 1 env CLIENT_NAME_PATTERNS="$TERM" bash "$HOOK_COPY" "$msg")"
assert_has "$out" "commit:proposed:subject" "copied hook matches case-insensitively"

out="$(run_expect 0 bash "$HOOK" "$msg")"
assert_has "$out" "gate inactive" "hook without a watchlist is inactive"
assert_lacks "$out" "[LEAK:client-name]" "inactive hook does not report the placeholder"

out="$(run_expect 2 bash "$HOOK")"
assert_has "$out" "requires the message file path" "hook without an argument is exit 2"

out="$(run_expect 2 bash "$HOOK" "$TMP/missing-message")"
assert_has "$out" "commit message file not found" "hook with a missing file is exit 2"

out="$(run_expect 2 env CLIENT_NAME_WATCHLIST_REQUIRED=1 bash "$HOOK" "$msg")"
assert_has "$out" "CLIENT_NAME_WATCHLIST_REQUIRED=1" "hook honors required mode"

echo "check-no-client-names commit and file cases passed"
