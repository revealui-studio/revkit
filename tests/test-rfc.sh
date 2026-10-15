#!/usr/bin/env bash
# test-rfc.sh — Claude launcher shares rfg launch surface (fleet-root, MCP env, worktrees).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RFC="$ROOT/shell/bin/rfc.sh"
DOCS="$ROOT/docs/rfc-launcher.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

FAKE_TOKEN="rvui_dev_$(printf 'ab%.0s' {1..32})"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/fleet/revealui"

cat >"$TMP/bin/revvault" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "get" ]; then
  printf '%s' '$FAKE_TOKEN'
  exit 0
fi
exit 1
EOF
chmod +x "$TMP/bin/revvault"

cat >"$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'CLAUDE_STUB cwd=%s args=%s\n' "$(pwd)" "$*"
exit 0
EOF
chmod +x "$TMP/bin/claude"

export PATH="$TMP/bin:/usr/bin:/bin"
unset REVEALFLEET_ROOT REVFLEET_ROOT REVEALUI_ROOT || true
export REVEALFLEET_ROOT="$TMP/fleet"
export REVEALUI_MCP_ENV_SKIP=1
unset REVEALUI_MCP_TOKEN || true
export GIT_AUTHOR_NAME='rfc-test'
export GIT_AUTHOR_EMAIL='rfc-test@example.com'
export GIT_COMMITTER_NAME='rfc-test'
export GIT_COMMITTER_EMAIL='rfc-test@example.com'

echo "=== test-rfc.sh ==="

echo "--- Fleet-root session ---"
cd "$TMP/fleet"
out="$(bash "$RFC" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"CLAUDE_STUB cwd="* ]]; then
  pass "rfc with no args at fleet root starts a session"
else
  fail "rfc fleet-root no-arg: rc=$rc out=$out"
fi

cd "$TMP/fleet"
out="$(bash "$RFC" . 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"CLAUDE_STUB cwd="* ]]; then
  pass "rfc . at fleet root starts a session"
else
  fail "rfc . fleet-root: rc=$rc out=$out"
fi

cd "$TMP/fleet/revealui"
out="$(bash "$RFC" . 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"CLAUDE_STUB cwd="*"revealui"* ]]; then
  pass "rfc . in product stays in product"
else
  fail "rfc . product: rc=$rc out=$out"
fi

cd "$TMP/fleet"
out="$(bash "$RFC" .. 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"single fleet checkout"* ]]; then
  pass "rfc .. is rejected"
else
  fail "rfc .. : rc=$rc out=$out"
fi

echo "--- Product launch ---"
cd "$TMP/fleet/revealui"
out="$(bash "$RFC" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"CLAUDE_STUB cwd="*"revealui"* ]]; then
  pass "rfc in product execs claude stub"
else
  fail "rfc product: rc=$rc out=$out"
fi

cd "$TMP/fleet"
out="$(bash "$RFC" revealui --continue 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"--continue"* ]]; then
  pass "rfc revealui passes trailing args"
else
  fail "rfc trailing args: rc=$rc out=$out"
fi

echo "--- rfc env never prints token ---"
unset REVEALUI_MCP_ENV_SKIP || true
errfile="$TMP/err"
out="$(bash "$RFC" env 2>"$errfile")" && rc=0 || rc=$?
err="$(cat "$errfile")"
combined="$out"$'\n'"$err"
if [ "$rc" -eq 0 ]; then
  pass "rfc env exits 0 when vault returns a valid token"
else
  fail "rfc env exit $rc stderr=$err"
fi
if [[ "$combined" == *"$FAKE_TOKEN"* ]] || [[ "$combined" == *rvui_dev_* ]] || [[ "$combined" == *"REVEALUI_MCP_TOKEN="* ]]; then
  fail "rfc env leaked token or assignment"
else
  pass "rfc env does not emit the token"
fi
if [[ "$out" == *"REVEALUI_MCP_URL="* ]] && [[ "$out" == *"REVEALUI_MCP_TOKEN_VAULT_PATH="* ]]; then
  pass "rfc env prints non-secret URL + vault path"
else
  fail "rfc env missing non-secret exports: $out"
fi
export REVEALUI_MCP_ENV_SKIP=1

echo "--- bootstrap + claim ---"
export REVEALUI_CLAIMS_DIR="$TMP/claims"
export REVEALUI_WT_ENV_DIR="$TMP/wtenv"
wt="$TMP/wt-sample"
mkdir -p "$wt"
out="$(bash "$RFC" bootstrap "$wt" wt-sample 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"RFG_PORT_BASE="* ]] && [ -f "$wt/.env.worktree" ]; then
  pass "rfc bootstrap wrote .env.worktree"
else
  fail "rfc bootstrap: rc=$rc out=$out"
fi

file="$(RFG_CLAIM_AGENT=test bash "$RFC" claim acquire revealui 'marketing/rfc-test' 1 2>/dev/null)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$file" ]; then
  pass "rfc claim acquire wrote $file"
else
  fail "rfc claim acquire failed rc=$rc file=$file"
fi
if bash "$RFC" claim check revealui 'marketing/rfc-test' >/dev/null; then
  pass "rfc claim check active"
else
  fail "rfc claim should be active"
fi
bash "$RFC" claim release revealui 'marketing/rfc-test' >/dev/null
if bash "$RFC" claim check revealui 'marketing/rfc-test' >/dev/null 2>&1; then
  fail "rfc claim still active after release"
else
  pass "rfc claim free after release"
fi

echo "--- rfc open rejects path segments ---"
export RFG_WT_ROOT="$TMP/wt"
out="$(bash "$RFC" open '../outside' rfc-open-label --no-agent 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"single fleet checkout"* ]]; then
  pass "rfc open rejects a repo path that leaves the fleet root"
else
  fail "rfc open repo traversal: rc=$rc out=$out"
fi
out="$(bash "$RFC" open revealui '../outside' --no-agent 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"single path segment"* ]] && [ ! -e "$TMP/outside" ]; then
  pass "rfc open rejects a label that leaves the worktree root"
else
  fail "rfc open label traversal: rc=$rc out=$out"
fi

echo "--- rfc open --no-agent ---"
git -C "$TMP/fleet/revealui" init -q
git -C "$TMP/fleet/revealui" checkout -q -b test
git -C "$TMP/fleet/revealui" commit -q --allow-empty -m init
export RFG_WT_ROOT="$TMP/wt"
out="$(bash "$RFC" open revealui rfc-open-label --no-agent 2>"$TMP/open.err")" && rc=0 || rc=$?
err="$(cat "$TMP/open.err")"
if [ "$rc" -eq 0 ] && [ -d "$TMP/wt/rfc-open-label" ] && [ -f "$TMP/wt/rfc-open-label/.env.worktree" ]; then
  pass "rfc open --no-agent created worktree + env"
else
  fail "rfc open: rc=$rc out=$out err=$err"
fi

echo "--- Static ---"
if grep -q 'rfc open' "$RFC" && grep -q 'fleet-root session' "$RFC"; then
  pass "rfc.sh documents open + fleet-root session"
else
  fail "rfc.sh missing open or fleet-root copy"
fi
if grep -q 'rfc open' "$DOCS" && grep -q 'rfc claim' "$DOCS"; then
  pass "rfc-launcher.md documents claim + open"
else
  fail "rfc-launcher.md missing claim/open"
fi
if grep -nE "printf ['\"]export REVEALUI_MCP_TOKEN=" "$RFC"; then
  fail "rfc.sh prints an export of REVEALUI_MCP_TOKEN"
else
  pass "rfc.sh has no printf export of REVEALUI_MCP_TOKEN"
fi
if grep -q 'rfg_attach_grok' "$RFC"; then
  fail "rfc.sh must not run Grok attach"
else
  pass "rfc.sh does not call Grok attach"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
