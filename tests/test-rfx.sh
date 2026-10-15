#!/usr/bin/env bash
# test-rfx.sh: Codex launcher wiring. Does not exec a Codex session.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RFX="$ROOT/shell/bin/rfx.sh"
RFG="$ROOT/shell/bin/rfg.sh"
BOOT="$ROOT/bootstrap.sh"
DOCS="$ROOT/docs/rfx-launcher.md"
README="$ROOT/README.md"
SHELLRC="$ROOT/shell/shellrc.d/56-rfx.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== test-rfx.sh ==="

if [ -f "$RFX" ] && [ -x "$RFX" ]; then
  pass "rfx.sh exists and is executable"
else
  fail "rfx.sh missing or not executable"
fi

if bash -n "$RFX" && bash -n "$SHELLRC"; then
  pass "bash -n rfx.sh and 56-rfx.sh"
else
  fail "bash -n failed"
fi

help="$(bash "$RFX" --help 2>&1)" || true
for needle in \
  'rfx revealui' \
  'rfx --dry-run' \
  'rfx open <repo> <label>' \
  'rfx -- <codex args>' \
  'rfx -- resume --last' \
  'RFX_DRY_RUN'
do
  if [[ "$help" == *"$needle"* ]]; then
    pass "help contains: $needle"
  else
    fail "help missing: $needle"
  fi
done
if [[ "$help" == *"auto-continue"* ]] || [[ "$help" == *"never auto-continues"* ]] \
  || [[ "$help" == *"Use \`rfx -- resume --last\` explicitly"* ]]; then
  pass "help says there is no auto-continue"
else
  fail "help should say resume is explicit"
fi

# Same three lib locations rfg uses: source tree, matched install prefix, REVEALUI_ROOT.
for needle in '/../lib/' '/lib/revkit/' '/shell/lib/'; do
  if grep -F "$needle" "$RFX" >/dev/null && grep -F "$needle" "$RFG" >/dev/null; then
    pass "lib lookup shared with rfg: $needle"
  else
    fail "lib lookup differs from rfg: $needle"
  fi
done
for lib in fleet-root.sh revealui-mcp-env.sh worktree-env.sh revkit-mode.sh rfg-storm-preflight.sh; do
  if grep -F "$lib" "$RFX" >/dev/null; then
    pass "rfx references $lib"
  else
    fail "rfx missing reference to $lib"
  fi
done

if grep -F 'ln -sfn "$name" "$HELPERS_DIR/rfx"' "$BOOT" >/dev/null \
  && grep -F '[ "$name" = "rfx.sh" ]' "$BOOT" >/dev/null; then
  pass "bootstrap symlinks rfx next to the rfx.sh install"
else
  fail "bootstrap missing the rfx symlink"
fi
if grep -E 'CODEX_HOME|/\.codex' "$BOOT" >/dev/null; then
  fail "bootstrap must not write a Codex vendor home"
else
  pass "bootstrap does not write a Codex home"
fi

if [ -f "$SHELLRC" ] && grep -q '^rfx()' "$SHELLRC"; then
  pass "fleet shellrc defines rfx"
else
  fail "missing shell/shellrc.d/56-rfx.sh"
fi
if grep -q '56-rfx.sh' "$ROOT/shell/modes/vibe.list"; then
  fail "vibe list should not load 56-rfx.sh"
else
  pass "vibe list omits 56-rfx.sh"
fi

if grep -q 'rfx <repo>' "$DOCS" && grep -q 'rfx open' "$DOCS" \
  && grep -q -- '--dry-run' "$DOCS" && grep -q 'rfx -- resume --last' "$DOCS" \
  && grep -q 'cursor-agent' "$DOCS" && grep -q 'ancestor' "$DOCS"; then
  pass "rfx-launcher.md covers usage and the ancestor skip"
else
  fail "rfx-launcher.md missing required usage or sweeper notes"
fi
if grep -q 'docs/rfx-launcher.md' "$README" && grep -q 'rfx -- resume --last' "$README"; then
  pass "README points at rfx next to the other launchers"
else
  fail "README missing the rfx section"
fi

if grep -q $'\u2014' "$RFX" "$SHELLRC" "$DOCS"; then
  fail "em dash in new rfx files"
else
  pass "new rfx files have no em dash"
fi

user_pat='j''oshu'
if grep -nE "${user_pat}|/home/[A-Za-z0-9_]" "$RFX" "$SHELLRC" "$DOCS" >/dev/null; then
  fail "hardcoded home or account name in rfx files"
else
  pass "rfx files do not hardcode a home directory or account name"
fi

# Synthetic device-token shape. Not a live secret.
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
CODEX_LOG="$TMP/codex.log"
: >"$CODEX_LOG"
cat >"$TMP/bin/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CODEX_LOG"
if [ "\${1:-}" = "--version" ]; then
  echo "codex-stub 0.0.0"
  exit 0
fi
echo "CODEX_LAUNCHED \$*"
exit 99
EOF
chmod +x "$TMP/bin/codex"

export PATH="$TMP/bin:/usr/bin:/bin"
export REVEALFLEET_ROOT="$TMP/fleet"
export REVEALUI_MCP_ENV_SKIP=1
unset REVEALUI_MCP_TOKEN || true

echo "--- dry-run does not exec codex ---"
cd "$TMP/fleet"
dry_out="$(bash "$RFX" --dry-run revealui -- --search "triage" 2>"$TMP/dry.err")" && dry_rc=0 || dry_rc=$?
dry_err="$(cat "$TMP/dry.err")"
dry_log="$(cat "$CODEX_LOG")"
if [ "$dry_rc" -eq 0 ] && [[ "$dry_out" == *"rfx dry-run"* ]] \
  && [[ "$dry_out" == *"exec:"* ]] && [[ "$dry_out" == *"--search"* ]] \
  && [[ "$dry_out" != *"CODEX_LAUNCHED"* ]] && [[ "$dry_err" != *"CODEX_LAUNCHED"* ]] \
  && [ "$(grep -c . "$CODEX_LOG")" -eq 1 ] && [[ "$dry_log" == *"--version"* ]]; then
  pass "dry-run prints the plan and only probes codex --version"
else
  fail "dry-run: rc=$dry_rc out=$dry_out err=$dry_err log=$dry_log"
fi
if [[ "$dry_out" == *"storm preflight: would run"* ]]; then
  pass "dry-run does not execute the sweeper"
else
  fail "dry-run should name the preflight without running it: $dry_out"
fi

: >"$CODEX_LOG"
cd "$TMP/fleet"
open_out="$(bash "$RFX" --dry-run open revealui my-label 2>"$TMP/open.err")" && open_rc=0 || open_rc=$?
open_err="$(cat "$TMP/open.err")"
if [ "$open_rc" -eq 0 ] && [[ "$open_out" == *"worktree:"* ]] \
  && [[ "$open_out" == *"my-label"* ]] && [ ! -d "$TMP/fleet/.wt/my-label" ] \
  && [[ "$open_out" != *"CODEX_LAUNCHED"* ]]; then
  pass "rfx open --dry-run plans a worktree and does not create it"
else
  fail "open dry-run: rc=$open_rc out=$open_out err=$open_err"
fi

: >"$CODEX_LOG"
cd "$TMP/fleet"
resume_out="$(bash "$RFX" --dry-run -- resume --last 2>"$TMP/resume.err")" && resume_rc=0 || resume_rc=$?
if [ "$resume_rc" -eq 0 ] && [[ "$resume_out" == *"resume"* ]] \
  && [[ "$resume_out" == *"--last"* ]] && [[ "$resume_out" != *"CODEX_LAUNCHED"* ]]; then
  pass "rfx -- resume --last stays a dry-run plan"
else
  fail "resume dry-run: rc=$resume_rc out=$resume_out"
fi

echo "--- rfx env does not print the token ---"
unset REVEALUI_MCP_ENV_SKIP || true
env_out="$(bash "$RFX" env 2>"$TMP/env.err")" && env_rc=0 || env_rc=$?
env_err="$(cat "$TMP/env.err")"
env_all="$env_out"$'\n'"$env_err"
if [ "$env_rc" -eq 0 ] && [[ "$env_all" != *"$FAKE_TOKEN"* ]] \
  && [[ "$env_out" == *"REVEALUI_MCP_URL="* ]] \
  && [[ "$env_all" != *"REVEALUI_MCP_TOKEN="* ]]; then
  pass "rfx env prints the URL and not the token"
else
  fail "rfx env: rc=$env_rc out=$env_out err=$env_err"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
