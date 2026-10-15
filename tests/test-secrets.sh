#!/usr/bin/env bash
# test-secrets.sh — Tests for shell/shellrc.d/40-secrets.sh (passenv security)
set -euo pipefail

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

assert_ok() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: $label (should have failed)"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label — expected to contain: $needle"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_SH="$PROJECT_ROOT/shell/shellrc.d/40-secrets.sh"

echo "=== test-secrets.sh ==="
echo "Source:   $SECRETS_SH"
echo ""

# We test passenv validation in a subshell to isolate side effects.
# passenv needs REVVAULT_STORE set and the `revvault` command, but for
# validation tests (which reject before calling revvault) we can mock
# the environment enough to test the guard logic.

# ---------------------------------------------------------------------------
# Helper: run passenv in an isolated subshell
# ---------------------------------------------------------------------------
# Sources 40-secrets.sh, sets a dummy REVVAULT_STORE, stubs `revvault` to
# return a dummy value (so valid-name tests can reach the export path),
# then calls passenv with the given arguments.

run_passenv() {
  (
    # Source the secrets file
    source "$SECRETS_SH"

    # Set up minimal environment so passenv doesn't bail on REVVAULT_STORE
    export REVVAULT_STORE="/tmp/fake-revvault-store"
    export PASSAGE_DIR="$REVVAULT_STORE"  # backward-compat alias

    # Stub revvault to return a value — only reached for valid names
    revvault() {
      echo "dummy-secret-value"
    }
    export -f revvault

    passenv "$@"
  )
}

# ---------------------------------------------------------------------------
# 1. Invalid variable names are rejected
# ---------------------------------------------------------------------------

echo "--- Variable name validation ---"

# Names with spaces
assert_fail "rejects name with space" run_passenv "BAD NAME" "some/path"

# Names starting with digits
assert_fail "rejects name starting with digit" run_passenv "1INVALID" "some/path"
assert_fail "rejects name starting with digit (0)" run_passenv "0VAR" "some/path"

# Names with special characters
assert_fail "rejects name with dash" run_passenv "BAD-NAME" "some/path"
assert_fail "rejects name with dot" run_passenv "BAD.NAME" "some/path"
assert_fail "rejects name with slash" run_passenv "BAD/NAME" "some/path"
assert_fail "rejects name with equals" run_passenv "BAD=NAME" "some/path"
assert_fail "rejects empty name" run_passenv "" "some/path"

# Check that error message mentions invalid
invalid_err="$(run_passenv "BAD NAME" "some/path" 2>&1 || true)"
assert_contains "invalid name error message" "$invalid_err" "invalid variable name"

# ---------------------------------------------------------------------------
# 2. Dangerous/protected variables are blocked
# ---------------------------------------------------------------------------

echo ""
echo "--- Protected variable blocking ---"

assert_fail "blocks PATH" run_passenv "PATH" "some/path"
assert_fail "blocks LD_PRELOAD" run_passenv "LD_PRELOAD" "some/path"
assert_fail "blocks LD_LIBRARY_PATH" run_passenv "LD_LIBRARY_PATH" "some/path"
assert_fail "blocks HOME" run_passenv "HOME" "some/path"
assert_fail "blocks SHELL" run_passenv "SHELL" "some/path"
assert_fail "blocks USER" run_passenv "USER" "some/path"
assert_fail "blocks LOGNAME" run_passenv "LOGNAME" "some/path"
assert_fail "blocks IFS" run_passenv "IFS" "some/path"

# Verify error message mentions "protected"
path_err="$(run_passenv "PATH" "some/path" 2>&1 || true)"
assert_contains "protected variable error message" "$path_err" "protected variable"

# ---------------------------------------------------------------------------
# 3. Valid variable names are accepted
# ---------------------------------------------------------------------------

echo ""
echo "--- Valid variable names ---"

assert_ok "accepts simple uppercase name" run_passenv "MY_SECRET" "some/path"
assert_ok "accepts lowercase name" run_passenv "my_secret" "some/path"
assert_ok "accepts mixed case" run_passenv "MySecret_123" "some/path"
assert_ok "accepts underscore-prefixed name" run_passenv "_PRIVATE" "some/path"
assert_ok "accepts single letter" run_passenv "X" "some/path"
assert_ok "accepts name with numbers" run_passenv "API_KEY_2" "some/path"

# ---------------------------------------------------------------------------
# 4. REVVAULT_STORE must be set
# ---------------------------------------------------------------------------

echo ""
echo "--- REVVAULT_STORE requirement ---"

# Run passenv without REVVAULT_STORE set.
# Capture the real exit code OUTSIDE the command substitution. The previous
# version put `|| true` INSIDE the `$( … )`, so the substitution always
# returned 0 and `no_dir_exit=$?` was a dead assertion (always 0). Use the
# set -e-safe `cmd && rc=0 || rc=$?` idiom so the genuine exit status survives.
no_dir_result="$(
  (
    source "$SECRETS_SH"
    unset REVVAULT_STORE
    unset PASSAGE_DIR
    passenv "VALID_NAME" "some/path"
  ) 2>&1
)" && no_dir_exit=0 || no_dir_exit=$?

# passenv must fail (nonzero) AND explain why when REVVAULT_STORE is unset.
if [[ $no_dir_exit -ne 0 ]] && [[ "$no_dir_result" == *"REVVAULT_STORE"* ]]; then
  echo "PASS: passenv fails when REVVAULT_STORE is unset"
  PASS=$((PASS + 1))
else
  echo "FAIL: passenv should fail when REVVAULT_STORE is unset (exit=$no_dir_exit, output: $no_dir_result)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# 4b. Store resolution — canonical data-dir store wins over stale dotfile
#     exports (GAP-413 split-store regression)
# ---------------------------------------------------------------------------
#
# The old guard looked for "$REVEALUI_ROOT/passage-store", but bootstrap pins
# REVEALUI_ROOT to the revkit REPO checkout, so the guard never matched and a
# stale `export PASSAGE_DIR=~/.passage/store` from an earlier dotfile silently
# won — interactive shells on the legacy store, clean-env units on the
# canonical one. These tests pin the fixed contract.

echo ""
echo "--- Store resolution (GAP-413) ---"

sr_sandbox="$(mktemp -d "${TMPDIR:-/tmp}/test-secrets-sr.XXXXXX")"
mkdir -p "$sr_sandbox/home/.revealui/passage-store" "$sr_sandbox/repo" "$sr_sandbox/legacy"

# A. Canonical store exists + stale legacy PASSAGE_DIR + repo-pinned
#    REVEALUI_ROOT (no passage-store under it): resolution must land on the
#    canonical data-dir store and correct the stale alias.
sr_resolved="$(
  (
    export HOME="$sr_sandbox/home"
    export REVEALUI_ROOT="$sr_sandbox/repo"
    export PASSAGE_DIR="$sr_sandbox/legacy"
    unset REVVAULT_STORE
    source "$SECRETS_SH"
    printf '%s|%s' "${REVVAULT_STORE:-}" "${PASSAGE_DIR:-}"
  )
)"
sr_expect="$sr_sandbox/home/.revealui/passage-store"
if [[ "$sr_resolved" == "$sr_expect|$sr_expect" ]]; then
  echo "PASS: canonical data-dir store overrides stale legacy PASSAGE_DIR"
  PASS=$((PASS + 1))
else
  echo "FAIL: expected $sr_expect for both, got: $sr_resolved"
  FAIL=$((FAIL + 1))
fi

# B. Explicit REVVAULT_STORE wins over the canonical default.
sr_explicit="$(
  (
    export HOME="$sr_sandbox/home"
    export REVVAULT_STORE="$sr_sandbox/legacy"
    unset PASSAGE_DIR
    source "$SECRETS_SH"
    printf '%s|%s' "${REVVAULT_STORE:-}" "${PASSAGE_DIR:-}"
  )
)"
if [[ "$sr_explicit" == "$sr_sandbox/legacy|$sr_sandbox/legacy" ]]; then
  echo "PASS: explicit REVVAULT_STORE wins and PASSAGE_DIR follows it"
  PASS=$((PASS + 1))
else
  echo "FAIL: expected explicit store for both, got: $sr_explicit"
  FAIL=$((FAIL + 1))
fi

rm -rf "$sr_sandbox"

# ---------------------------------------------------------------------------
# 5. passenv-file also blocks protected variables
# ---------------------------------------------------------------------------

echo ""
echo "--- passenv-file protected variable blocking ---"

# passenv-file reads its env-file content via `revvault get` (40-secrets.sh).
# Stub revvault to return a blob that puts a protected variable (PATH) between
# two safe ones; passenv-file must export the safe vars and refuse PATH.
pf_output="$(
  (
    source "$SECRETS_SH"

    revvault() {
      printf 'SAFE_VAR=good\nPATH=/evil\nANOTHER_SAFE=also_good\n'
    }
    export -f revvault

    passenv-file "test/path" 2>&1
  )
)"

assert_contains "passenv-file warns about PATH override attempt" "$pf_output" "protected variable"

# ---------------------------------------------------------------------------
# 6. Real revvault: multi-line secrets are returned in full (regression)
# ---------------------------------------------------------------------------
#
# Regression witness for the fix shipped alongside revkit #90/#97: `revvault
# get` DEFAULTS to first-line-only, so passenv / passenv-file MUST pass --full
# or multi-line secrets (PEM/SSH keys, JSON service-account blobs, multi-key
# env files) are silently truncated to their first line while still returning
# success. Unlike the sections above (which stub `revvault`), this exercises
# the REAL revvault binary against a sandboxed store: a temp HOME plus temp
# store-dir, so the developer's real ~/.config/age identity and vault are
# never touched. Skipped (not failed) when revvault is unavailable or the
# sandbox cannot be initialised.

echo ""
echo "--- Real revvault multi-line round-trip ---"

if ! command -v revvault >/dev/null 2>&1; then
  echo "SKIP: revvault not on PATH (multi-line regression test not run)"
else
  rv_sandbox="$(mktemp -d "${TMPDIR:-/tmp}/test-secrets-rv.XXXXXX")"
  rv_rc=0
  (
    # Sandbox: override HOME so the real ~/.config/age is never touched.
    export HOME="$rv_sandbox/home"
    mkdir -p "$HOME"
    export REVVAULT_STORE="$rv_sandbox/store"
    unset REVEALUI_ROOT PASSAGE_DIR

    revvault init --store-dir "$REVVAULT_STORE" >/dev/null 2>&1 || exit 3

    # Multi-line, PEM-shaped secret (no trailing newline).
    printf -- '-----BEGIN TEST KEY-----\nline-two-abc\nline-three-xyz\n-----END TEST KEY-----' \
      | revvault set test/multiline >/dev/null 2>&1 || exit 3
    # Multi-line KEY=value env blob for passenv-file.
    printf 'FIRST_KEY=first_value\nSECOND_KEY=second_value\nTHIRD_KEY=third_value\n' \
      | revvault set test/envfile >/dev/null 2>&1 || exit 3

    # Load the real loader (NOT stubbed), pointed at the sandbox store.
    source "$SECRETS_SH"
    export REVVAULT_STORE="$rv_sandbox/store"   # re-assert after sourcing

    # passenv must return the FULL multi-line value, not just line 1.
    passenv MULTILINE_SECRET test/multiline || exit 4
    case "$MULTILINE_SECRET" in
      *"line-three-xyz"*"-----END TEST KEY-----"*) : ;;
      *) exit 5 ;;
    esac

    # passenv-file must export keys beyond the first line.
    passenv-file test/envfile || exit 6
    [ "${SECOND_KEY:-}" = "second_value" ] && [ "${THIRD_KEY:-}" = "third_value" ] || exit 7
    exit 0
  ) || rv_rc=$?
  rm -rf "$rv_sandbox"

  case "$rv_rc" in
    0)
      echo "PASS: passenv returns the full multi-line secret (not truncated to line 1)"
      PASS=$((PASS + 1))
      echo "PASS: passenv-file exports keys beyond the first line"
      PASS=$((PASS + 1))
      ;;
    3)
      echo "SKIP: revvault sandbox init/set failed (multi-line regression test not run)"
      ;;
    5)
      echo "FAIL: passenv truncated the multi-line secret to its first line (missing --full in 40-secrets.sh)"
      FAIL=$((FAIL + 1))
      ;;
    7)
      echo "FAIL: passenv-file dropped keys after the first line (missing --full in 40-secrets.sh)"
      FAIL=$((FAIL + 1))
      ;;
    *)
      echo "FAIL: multi-line regression subshell failed (rc=$rv_rc)"
      FAIL=$((FAIL + 1))
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# 5. with-secrets namespaces are one path segment
# ---------------------------------------------------------------------------

echo ""
echo "--- with-secrets namespace guard ---"

WITH_SECRETS_SH="$PROJECT_ROOT/shell/shellrc.d/45-with-secrets.sh"

run_with_secrets() {
  (
    # shellcheck disable=SC1090
    source "$WITH_SECRETS_SH"
    revvault() {
      echo "revvault-called" >&2
      printf 'export PWNED=1\n'
    }
    export -f revvault
    with-secrets "$@"
  )
}

assert_fail "rejects namespace with a slash" run_with_secrets '../vault' -- true
trav_err="$(run_with_secrets '../vault' -- true 2>&1 || true)"
assert_contains "traversal error names the rule" "$trav_err" "namespace must be one identifier"
if [[ "$trav_err" == *"revvault-called"* ]]; then
  echo "FAIL: traversal namespace still called revvault"
  FAIL=$((FAIL + 1))
else
  echo "PASS: traversal namespace does not call revvault"
  PASS=$((PASS + 1))
fi
assert_fail "rejects namespace that starts with a dash" run_with_secrets '-namespace' -- true
# license-signing is a legal identifier. Without the private-key opt-in it
# must fail that gate, not the shape gate.
shape_err="$(run_with_secrets license-signing -- true 2>&1 || true)"
assert_contains "license-signing still hits the private-key gate" "$shape_err" "REVVAULT_ALLOW_PRIVATE"
if [[ "$shape_err" == *"namespace must be one identifier"* ]]; then
  echo "FAIL: license-signing was rejected as a bad identifier"
  FAIL=$((FAIL + 1))
else
  echo "PASS: license-signing is an accepted identifier"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
