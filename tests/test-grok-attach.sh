#!/usr/bin/env bash
# test-grok-attach.sh — RevKit deploys Grok hooks from the product manager.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/shell/lib/grok-attach.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== test-grok-attach.sh ==="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
unset GROK_HOME
mkdir -p "$HOME"

FLEET="$TMP/fleet"
mkdir -p "$FLEET/revealui/.git" "$FLEET/revkit/.git"

cd "$FLEET"
if rfg_pwd_is_fleet_root "$FLEET"; then
  pass "pwd at fleet root is fleet root"
else
  fail "expected fleet root"
fi
if rfg_path_is_fleet_root "$FLEET" "$FLEET/."; then
  pass "path FLEET/. is fleet root"
else
  fail "expected FLEET/. to be fleet root"
fi

cd "$FLEET/revealui"
if rfg_pwd_is_fleet_root "$FLEET"; then
  fail "product checkout must not count as fleet root"
else
  pass "pwd in revealui is not fleet root"
fi

SRC="$TMP/product"
mkdir -p "$SRC/.revealui/adapters/grok/hooks"
printf '%s\n' '{"hooks":{"SessionStart":[]}}' >"$SRC/.revealui/adapters/grok/hooks/session-start.json"
printf '%s\n' '{"hooks":{"SessionEnd":[]}}' >"$SRC/.revealui/adapters/grok/hooks/session-end.json"
printf '%s\n' '{"hooks":{"PreToolUse":[]}}' >"$SRC/.revealui/adapters/grok/hooks/pre-tool.json"
printf '%s\n' '{"ignore":true}' >"$SRC/.revealui/adapters/grok/hooks/extra.json"

rfg_attach_grok_hooks "$SRC"
dest="$HOME/.grok/hooks"
if cmp -s "$SRC/.revealui/adapters/grok/hooks/session-start.json" "$dest/session-start.json"; then
  pass "session-start.json deployed"
else
  fail "session-start.json missing or different"
fi
if cmp -s "$SRC/.revealui/adapters/grok/hooks/pre-tool.json" "$dest/pre-tool.json"; then
  pass "pre-tool.json deployed"
else
  fail "pre-tool.json missing"
fi
if [ -f "$dest/extra.json" ]; then
  fail "non-allowlisted extra.json must not be copied"
else
  pass "allowlist skips extra.json"
fi

printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"grep|run_terminal_command","hooks":[{"type":"command","command":"node cap-tool-output.js"}]}]}}' \
  >"$SRC/.revealui/adapters/grok/hooks/cap-tool-output.json"
printf '%s\n' '{"contextWindowTokens":500000,"compactionAtTokens":160000,"models":["grok-4.7","grok-4.7-build"]}' \
  >"$SRC/.revealui/adapters/grok/token-budget.json"
mkdir -p "$HOME/.grok"
printf '%s\n' '[session]
load_envrc = true
auto_compact_threshold_percent = 85
' >"$HOME/.grok/config.toml"
FLEET_ROOT="$(cd "$ROOT/.." && pwd)"
if [ -d "$FLEET_ROOT/revskills/scripts" ]; then
  REVEALFLEET_ROOT="$FLEET_ROOT" rfg_attach_grok_hooks "$SRC"
else
  rfg_attach_grok_hooks "$SRC"
fi
if cmp -s "$SRC/.revealui/adapters/grok/hooks/cap-tool-output.json" "$dest/cap-tool-output.json"; then
  pass "cap-tool-output.json deployed"
else
  fail "cap-tool-output.json missing or different"
fi
if cmp -s "$SRC/.revealui/adapters/grok/token-budget.json" \
  "$HOME/.local/share/revealui/hooks/token-budget.json"; then
  pass "token-budget.json deployed to XDG hooks"
else
  fail "token-budget.json missing from XDG hooks"
fi
if grep -q 'auto_compact_threshold_percent = 32' "$HOME/.grok/config.toml" \
  && grep -q 'compaction_at_tokens = 160000' "$HOME/.grok/config.toml" \
  && grep -q 'load_envrc = true' "$HOME/.grok/config.toml"; then
  pass "token budget merged into grok config.toml"
else
  fail "token budget did not merge into grok config.toml"
fi
if grep -q 'hooks = false' "$HOME/.grok/config.toml" \
  && grep -q 'mcps = false' "$HOME/.grok/config.toml" \
  && grep -q 'sessions = false' "$HOME/.grok/config.toml" \
  && grep -q 'skills = false' "$HOME/.grok/config.toml"; then
  pass "missing compat.claude section is seeded off"
else
  fail "compat.claude defaults were not seeded into an existing config"
fi

mkdir -p "$SRC/packages/harnesses/scripts"
printf '%s\n' 'module.exports = {};' >"$SRC/packages/harnesses/scripts/public-security-comment-pretool.cjs"
rfg_attach_grok_hooks "$SRC"
if cmp -s "$SRC/packages/harnesses/scripts/public-security-comment-pretool.cjs" \
  "$HOME/.local/share/revealui/hooks/public-security-comment-pretool.cjs"; then
  pass "pretool helper deployed to XDG data dir"
else
  fail "pretool helper missing from XDG data dir"
fi

RFG_GROK_ATTACH_SKIP=1 rfg_attach_grok_hooks "$SRC"
pass "skip env does not error"
unset RFG_GROK_ATTACH_SKIP

rfg_attach_grok_hooks "$TMP/no-manager"
if [ -d "$HOME/.grok/hooks" ]; then
  pass "missing manager tree is a no-op"
else
  fail "hooks dir vanished"
fi

export GROK_HOME="$TMP/grok-alt"
rfg_attach_grok_hooks "$SRC"
if [ -f "$GROK_HOME/hooks/session-start.json" ]; then
  pass "GROK_HOME override is the attach dest"
else
  fail "GROK_HOME was ignored"
fi
unset GROK_HOME

echo "--- HOME stub (AGENTS.md only; no prose rules) ---"
rfg_attach_grok_constitution
if cmp -s "$ROOT/shell/grok-home/AGENTS.md" "$HOME/.grok/AGENTS.md"; then
  pass "AGENTS.md stub deployed to Grok home"
else
  fail "AGENTS.md missing or different"
fi
if [ -d "$HOME/.grok/rules" ]; then
  fail "HOME attach must not create $HOME/.grok/rules"
else
  pass "no prose rules directory under HOME"
fi

export GROK_HOME="$TMP/grok-const"
rfg_attach_grok_constitution
if [ -f "$GROK_HOME/AGENTS.md" ] && [ ! -d "$GROK_HOME/rules" ]; then
  pass "stub respects GROK_HOME and does not copy rules"
else
  fail "constitution wrote rules into GROK_HOME or skipped AGENTS.md"
fi
unset GROK_HOME

export GROK_HOME="$TMP/grok-fresh"
rfg_seed_grok_compat
if grep -q 'hooks = false' "$GROK_HOME/config.toml" \
  && grep -q 'mcps = false' "$GROK_HOME/config.toml" \
  && grep -q 'sessions = false' "$GROK_HOME/config.toml"; then
  pass "fresh Grok config ships compat.claude off"
else
  fail "fresh Grok config did not ship compat.claude off"
fi
unset GROK_HOME

export GROK_HOME="$TMP/grok-optin"
mkdir -p "$GROK_HOME"
printf '%s\n' '[compat.claude]
hooks = true
mcps = true
sessions = true
skills = true
' > "$GROK_HOME/config.toml"
rfg_seed_grok_compat
if grep -q 'hooks = true' "$GROK_HOME/config.toml" \
  && grep -q 'mcps = true' "$GROK_HOME/config.toml"; then
  pass "explicit compat.claude opt-in is left in place"
else
  fail "seed overwrote an explicit compat.claude section"
fi
unset GROK_HOME

if grep -q 'mkdir -p ~/.grok/hooks' "$ROOT/shell/bin/rfg.sh" 2>/dev/null; then
  fail "rfg.sh must not document a home cp recipe"
else
  pass "rfg.sh has no home cp recipe"
fi

echo "--- Behavioral: rfg.sh fleet-root session + product attach ---"
RFG="$ROOT/shell/bin/rfg.sh"
mkdir -p "$FLEET/revealui/.revealui/adapters/grok/hooks" "$TMP/bin"
cp "$SRC/.revealui/adapters/grok/hooks/"*.json "$FLEET/revealui/.revealui/adapters/grok/hooks/"
cat >"$TMP/bin/grok" <<'EOF'
#!/usr/bin/env bash
printf 'GROK_STUB cwd=%s\n' "$(pwd)"
exit 0
EOF
chmod +x "$TMP/bin/grok"
export PATH="$TMP/bin:/usr/bin:/bin"
export REVEALUI_MCP_ENV_SKIP=1
unset REVEALUI_ROOT || true
export REVEALFLEET_ROOT="$FLEET"

cd "$FLEET"
out="$(bash "$RFG" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"GROK_STUB cwd="*"$(basename "$FLEET")"* || "$out" == *"GROK_STUB cwd=$FLEET"* ]]; then
  pass "rfg with no args at fleet root starts a session"
else
  fail "rfg fleet-root no-arg: rc=$rc out=$out"
fi

cd "$FLEET"
out="$(bash "$RFG" . 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"GROK_STUB cwd="* ]]; then
  pass "rfg . at fleet root starts a session"
else
  fail "rfg . fleet-root: rc=$rc out=$out"
fi

cd "$FLEET/revealui"
out="$(bash "$RFG" . 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"GROK_STUB cwd="*revealui ]]; then
  pass "rfg . in product stays in product"
else
  fail "rfg . product: rc=$rc out=$out"
fi

cd "$FLEET"
out="$(bash "$RFG" .. 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"single fleet checkout"* ]]; then
  pass "rfg .. is rejected"
else
  fail "rfg .. : rc=$rc out=$out"
fi

rm -rf "$HOME/.grok/hooks"
cd "$FLEET/revealui"
out="$(bash "$RFG" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"GROK_STUB cwd="*revealui ]]; then
  pass "rfg in product execs grok stub"
else
  fail "rfg product: rc=$rc out=$out"
fi
if cmp -s "$FLEET/revealui/.revealui/adapters/grok/hooks/session-start.json" "$HOME/.grok/hooks/session-start.json"; then
  pass "rfg deploys manager hooks on product launch"
else
  fail "rfg did not deploy session-start.json"
fi
if [ -f "$HOME/.grok/hooks/extra.json" ]; then
  fail "rfg copied non-allowlisted extra.json"
else
  pass "rfg attach allowlist on product launch"
fi
if cmp -s "$ROOT/shell/grok-home/AGENTS.md" "$HOME/.grok/AGENTS.md"; then
  pass "rfg deploys HOME constitution on product launch"
else
  fail "rfg did not deploy AGENTS.md on product launch"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
