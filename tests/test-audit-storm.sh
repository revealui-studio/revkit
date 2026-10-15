#!/usr/bin/env bash
# test-audit-storm.sh: leftover audit du/find must not wedge rfg, and must not
# take grok, rfg, or unrelated processes with them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWEEP="$ROOT/shell/lib/kill-audit-storms.sh"
PRE="$ROOT/shell/lib/rfg-storm-preflight.sh"
WRAP="$ROOT/shell/bin/kill-audit-storms.sh"
RFG="$ROOT/shell/bin/rfg.sh"
BOOT="$ROOT/bootstrap.sh"
DOCS="$ROOT/docs/rfg-launcher.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

victims=()
cleanup() {
  local p
  if [ "${#victims[@]}" -gt 0 ]; then
    for p in "${victims[@]}"; do
      kill -KILL "$p" 2>/dev/null || true
    done
  fi
  wait 2>/dev/null || true
}
trap cleanup EXIT

alive() { kill -0 "$1" 2>/dev/null; }

# argv0 may contain spaces so the ps cmdline carries both the program name
# and an audit pattern. sleep's only real argument stays the duration.
# disown so this shell does not print a job-control "Killed" line later.
spawn_as() {
  local arg0="$1" p
  set -m
  bash -c 'exec -a "$1" sleep 120' _ "$arg0" >/dev/null 2>&1 &
  p=$!
  disown "$p" 2>/dev/null || true
  set +m
  victims+=("$p")
  last_pid="$p"
}

echo "=== test-audit-storm.sh ==="

# shellcheck disable=SC1090
. "$SWEEP"

echo "--- etime parser ---"
if [ "$(audit_storm_etime_to_sec '1-02:03:04')" -eq 93784 ]; then
  pass "etime days+hms"
else
  fail "etime days+hms got $(audit_storm_etime_to_sec '1-02:03:04')"
fi
if [ "$(audit_storm_etime_to_sec '01:02:03')" -eq 3723 ]; then
  pass "etime hms"
else
  fail "etime hms got $(audit_storm_etime_to_sec '01:02:03')"
fi
if [ "$(audit_storm_etime_to_sec '05:06')" -eq 306 ]; then
  pass "etime ms"
else
  fail "etime ms got $(audit_storm_etime_to_sec '05:06')"
fi
if [ "$(audit_storm_etime_to_sec '7')" -eq 7 ]; then
  pass "etime seconds"
else
  fail "etime seconds got $(audit_storm_etime_to_sec '7')"
fi

echo "--- cmdline matcher ---"
home="${HOME:-}"
marker="$(basename "$home")-audit"
match_yes() {
  if audit_storm_cmd_match "$1"; then
    pass "match: $1"
  else
    fail "should match: $1"
  fi
}
match_no() {
  if audit_storm_cmd_match "$1"; then
    fail "should not match: $1"
  else
    pass "skip: $1"
  fi
}
match_yes "du -sh $home"
match_yes "du -sh $home/"
match_yes "du -sh $home/projects"
match_yes "find $home"
match_yes "find $home/.grok -type d"
match_yes "find $home/.claude"
match_yes "find $home/.local/share"
match_yes "notes REVFLEET HARDCODE leftovers"
match_yes "WHO CREATES ~/revfleet"
match_yes "TOP-LEVEL DETAILED"
match_yes "HOME TOP-LEVEL"
match_yes "fleet-identity scan"
match_yes "runner $marker once"
match_no "du -sh /tmp"
match_no "find /tmp/.grok"
match_no "find ."
match_no "sleep 1"
match_no "grok"
match_no "bash /usr/local/bin/rfg.sh revealui"
if audit_storm_dstate_cmd_match "du -sh /tmp" \
  && audit_storm_dstate_cmd_match "find ." \
  && audit_storm_dstate_cmd_match "find $home/.grok" \
  && audit_storm_dstate_cmd_match "$marker" \
  && ! audit_storm_dstate_cmd_match "sleep 9"; then
  pass "D-state matcher keeps du -sh, find ., and home audits"
else
  fail "D-state matcher drifted from the corrected filter"
fi

echo "--- protection ---"
if audit_storm_pid_protected "$$" "du -sh $home"; then
  pass "current pid is protected"
else
  fail "current pid should be protected"
fi
if audit_storm_pid_protected 999999 "grok du -sh $home"; then
  pass "grok executable is protected"
else
  fail "grok executable should be protected"
fi
if audit_storm_pid_protected 999999 "/usr/bin/grok --prompt fleet-identity"; then
  pass "grok path is protected"
else
  fail "grok path should be protected"
fi
if audit_storm_pid_protected 999999 "bash /usr/local/bin/rfg.sh revealui"; then
  pass "rfg.sh cmdline is protected"
else
  fail "rfg.sh cmdline should be protected"
fi
if audit_storm_pid_protected 999999 "/usr/local/bin/rfg revealui"; then
  pass "/usr/local/bin/rfg is protected"
else
  fail "/usr/local/bin/rfg should be protected"
fi
if audit_storm_pid_protected 999999 "$home/.local/bin/rfg revealui"; then
  pass "HOME local rfg is protected"
else
  fail "HOME local rfg should be protected"
fi
if audit_storm_pid_protected 999999 "find $home/.grok -type d"; then
  fail "find of .grok must not be treated as grok"
else
  pass "find of .grok is not protected"
fi

echo "--- D-state filter ---"
audit_storm_ps_d() {
  printf '  4242 D 01:00 du -sh %s\n' "$home"
  printf '  4243 S 01:00 du -sh %s\n' "$home"
  printf '  4244 D 01:00 sleep 9\n'
  printf '  4245 D 02:00 find .\n'
  printf '  4246 D 02:00 du -sh /tmp\n'
}
dlines="$(audit_storm_dstate_lines)"
if [[ "$dlines" == *4242* ]] && [[ "$dlines" == *4245* ]] && [[ "$dlines" == *4246* ]] \
  && [[ "$dlines" != *4243* ]] && [[ "$dlines" != *4244* ]]; then
  pass "D-state lines keep du -sh and find . disk-sleep only"
else
  fail "D-state filter got: $dlines"
fi

echo "--- plain pid dedupe ---"
audit_storm_uniq_pids=()
audit_storm_uniq_lines=()
audit_storm_add_cand 10 "01:00" "du -sh $home"
audit_storm_add_cand 10 "01:00" "du -sh $home"
audit_storm_add_cand 11 "01:00" "find $home"
if [ "${#audit_storm_uniq_pids[@]}" -eq 2 ] && [ "${#audit_storm_uniq_lines[@]}" -eq 2 ]; then
  pass "duplicate pids collapse to a plain list"
else
  fail "dedupe count pids=${#audit_storm_uniq_pids[@]} lines=${#audit_storm_uniq_lines[@]}"
fi
if grep -n 'declare -A' "$SWEEP"; then
  fail "sweeper still uses associative arrays"
else
  pass "sweeper has no associative arrays"
fi

echo "--- standalone none ---"
none_out="$(AUDIT_STORM_MIN_AGE_SEC=99999 bash "$SWEEP")" && none_rc=0 || none_rc=$?
if [ "$none_rc" -eq 0 ] && [[ "$none_out" == *"kill-audit-storms: none (min_age=99999s protected=0)"* ]]; then
  pass "sweeper exits 0 and reports none"
else
  fail "sweeper none: rc=$none_rc out=$none_out"
fi

wrap_out="$(AUDIT_STORM_MIN_AGE_SEC=99999 bash "$WRAP")" && wrap_rc=0 || wrap_rc=$?
if [ "$wrap_rc" -eq 0 ] && [[ "$wrap_out" == *"kill-audit-storms: none (min_age=99999s protected=0)"* ]]; then
  pass "bin wrapper reaches the lib"
else
  fail "wrapper: rc=$wrap_rc out=$wrap_out"
fi

echo "--- live processes ---"
spawn_as "du -sh $home"
du_pid="$last_pid"
spawn_as "grok du -sh $home"
grok_pid="$last_pid"
spawn_as "bash /usr/local/bin/rfg.sh du -sh $home"
rfg_pid="$last_pid"
spawn_as "du -sh $home/"
keep_pid="$last_pid"
sleep 0.4

if alive "$du_pid" && alive "$grok_pid" && alive "$rfg_pid" && alive "$keep_pid"; then
  pass "fixtures are running"
else
  fail "fixtures failed to start"
fi

old_out="$(AUDIT_STORM_MIN_AGE_SEC=600 bash "$SWEEP")" && old_rc=0 || old_rc=$?
if [ "$old_rc" -eq 0 ] && [[ "$old_out" == *"none (min_age=600s protected=0)"* ]] \
  && alive "$du_pid" && alive "$grok_pid" && alive "$rfg_pid" && alive "$keep_pid"; then
  pass "younger than min age is left alone"
else
  fail "min-age skip: rc=$old_rc out=$old_out"
fi

dry_out="$(AUDIT_STORM_MIN_AGE_SEC=0 AUDIT_STORM_DRY_RUN=1 bash "$SWEEP")" || true
if [[ "$dry_out" == *"pid=$du_pid"* ]] && [[ "$dry_out" != *"pid=$grok_pid"* ]] \
  && [[ "$dry_out" != *"pid=$rfg_pid"* ]] && alive "$du_pid" && alive "$grok_pid"; then
  pass "dry-run lists the audit du and spares grok and rfg"
else
  fail "dry-run: out=$dry_out"
fi

kill_out="$(AUDIT_STORM_MIN_AGE_SEC=0 RFG_STORM_PROTECT_PIDS="$keep_pid" bash "$SWEEP")" || true
sleep 0.2
if ! alive "$du_pid" && alive "$keep_pid" && alive "$grok_pid" && alive "$rfg_pid" \
  && [[ "$kill_out" == *"pid=$du_pid"* ]] && [[ "$kill_out" == *"killed="* ]]; then
  pass "sweeper killed the audit du and printed it"
else
  fail "kill: out=$kill_out du=$(alive "$du_pid" && echo up || echo down) keep=$(alive "$keep_pid" && echo up || echo down) grok=$(alive "$grok_pid" && echo up || echo down) rfg=$(alive "$rfg_pid" && echo up || echo down)"
fi
if [[ "$kill_out" != *"pid=$grok_pid"* ]] && [[ "$kill_out" != *"pid=$rfg_pid"* ]] \
  && [[ "$kill_out" != *"pid=$keep_pid"* ]]; then
  pass "kill report omits grok, rfg, and the protected pid"
else
  fail "kill report included a protected pid: $kill_out"
fi

cleanup
victims=()

echo "--- agent ancestor skip ---"
name_yes() {
  if audit_storm_agent_name_match "$1"; then
    pass "agent name: $1"
  else
    fail "agent name should match: $1"
  fi
}
name_no() {
  if audit_storm_agent_name_match "$1"; then
    fail "agent name should not match: $1"
  else
    pass "not an agent name: $1"
  fi
}
name_yes "codex"
name_yes "codex-cli"
name_yes "rfx"
name_yes "rfx.sh"
name_yes "/usr/local/bin/rfg"
name_yes "rfc.sh"
name_yes "claude"
name_yes "cursor-agent"
name_yes "/opt/cursor-agent/index.js"
name_no "find"
name_no "sleep"
name_no "node"
name_no "/usr/bin/node"

agent_dir="$(mktemp -d)"
pidfile="$agent_dir/child.pid"
cat >"$agent_dir/parent.py" <<'PY'
import os, sys, time
home, pidfile = sys.argv[1], sys.argv[2]
child = os.fork()
if child == 0:
    os.execv("/bin/sleep", ["du -sh " + home, "120"])
else:
    with open(pidfile, "w", encoding="utf-8") as fh:
        fh.write(str(child) + "\n")
    time.sleep(120)
PY
set -m
bash -c 'exec -a codex python3 "$1" "$2" "$3"' _ "$agent_dir/parent.py" "$home" "$pidfile" >/dev/null 2>&1 &
agent_parent=$!
disown "$agent_parent" 2>/dev/null || true
set +m
victims+=("$agent_parent")
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$pidfile" ] && break
  sleep 0.1
done
agent_child="$(tr -d '[:space:]' <"$pidfile" 2>/dev/null || true)"
if [ -n "$agent_child" ]; then
  victims+=("$agent_child")
fi
spawn_as "du -sh $home"
orphan_pid="$last_pid"
sleep 0.3
if [ -n "$agent_child" ] && alive "$agent_child" && alive "$orphan_pid" \
  && audit_storm_has_agent_ancestor "$agent_child"; then
  pass "du under codex has an agent ancestor ($AUDIT_STORM_AGENT_ANCESTOR)"
else
  fail "ancestor walk missed the codex parent (child=$agent_child)"
fi
agent_out="$(AUDIT_STORM_MIN_AGE_SEC=0 bash "$SWEEP")" || true
sleep 0.2
if alive "$agent_child" && ! alive "$orphan_pid" \
  && [[ "$agent_out" == *"skip pid=$agent_child"* ]] \
  && [[ "$agent_out" == *"pid=$orphan_pid"* ]]; then
  pass "sweeper skips the codex child and still clears the orphan du"
else
  fail "ancestor kill: out=$agent_out child=$(alive "$agent_child" && echo up || echo down) orphan=$(alive "$orphan_pid" && echo up || echo down)"
fi
cleanup
victims=()
rm -rf "$agent_dir"

echo "--- preflight does not hard-fail ---"
skip_out="$(RFG_STORM_PREFLIGHT_SKIP=1 bash "$PRE" 2>&1)" && skip_rc=0 || skip_rc=$?
if [ "$skip_rc" -eq 0 ] && [ -z "$skip_out" ]; then
  pass "RFG_STORM_PREFLIGHT_SKIP=1 is silent"
else
  fail "skip preflight: rc=$skip_rc out=$skip_out"
fi

pre_err="$(bash "$PRE" 2>&1 >/dev/null)" && pre_rc=0 || pre_rc=$?
if [ "$pre_rc" -eq 0 ] && [[ "$pre_err" == *"kill-audit-storms: none (min_age=120s protected=0)"* ]]; then
  pass "preflight default age is 120 and exits 0"
else
  fail "preflight: rc=$pre_rc err=$pre_err"
fi

echo "--- rfg launch and open ---"
TMP="$(mktemp -d)"
mkdir -p "$TMP/bin" "$TMP/fleet/revealui" "$TMP/grok-home"
cat >"$TMP/bin/grok" <<'EOF'
#!/usr/bin/env bash
printf 'GROK_STUB cwd=%s args=%s\n' "$(pwd)" "$*"
exit 0
EOF
chmod +x "$TMP/bin/grok"
export PATH="$TMP/bin:/usr/bin:/bin"
export REVEALFLEET_ROOT="$TMP/fleet"
export REVEALUI_MCP_ENV_SKIP=1
export RFG_GROK_ATTACH_SKIP=1
export GROK_HOME="$TMP/grok-home"
export GIT_AUTHOR_NAME='audit-storm-test'
export GIT_AUTHOR_EMAIL='audit-storm-test@example.com'
export GIT_COMMITTER_NAME='audit-storm-test'
export GIT_COMMITTER_EMAIL='audit-storm-test@example.com'
unset RFG_STORM_PREFLIGHT_SKIP || true

cd "$TMP/fleet"
launch_out="$(bash "$RFG" 2>"$TMP/launch.err")" && launch_rc=0 || launch_rc=$?
launch_err="$(cat "$TMP/launch.err")"
if [ "$launch_rc" -eq 0 ] && [[ "$launch_out" == *"GROK_STUB cwd="* ]] \
  && [[ "$launch_err" == *"kill-audit-storms: none (min_age=120s protected=0)"* ]]; then
  pass "rfg launch runs preflight then execs grok"
else
  fail "rfg launch: rc=$launch_rc out=$launch_out err=$launch_err"
fi

cd "$TMP/fleet"
skip_launch="$(RFG_STORM_PREFLIGHT_SKIP=1 bash "$RFG" 2>"$TMP/skip.err")" && skip_lrc=0 || skip_lrc=$?
skip_lerr="$(cat "$TMP/skip.err")"
if [ "$skip_lrc" -eq 0 ] && [[ "$skip_launch" == *"GROK_STUB cwd="* ]] \
  && [[ "$skip_lerr" != *"kill-audit-storms"* ]]; then
  pass "RFG_STORM_PREFLIGHT_SKIP=1 still launches grok"
else
  fail "rfg skip launch: rc=$skip_lrc out=$skip_launch err=$skip_lerr"
fi

git -C "$TMP/fleet/revealui" init -q
git -C "$TMP/fleet/revealui" checkout -q -b test
git -C "$TMP/fleet/revealui" commit -q --allow-empty -m init
export RFG_WT_ROOT="$TMP/wt"

cd "$TMP/fleet"
open_out="$(bash "$RFG" open revealui storm-open --no-agent 2>"$TMP/open.err")" && open_rc=0 || open_rc=$?
open_err="$(cat "$TMP/open.err")"
if [ "$open_rc" -eq 0 ] && [[ "$open_out" == *"$TMP/wt/storm-open"* ]] \
  && [[ "$open_out" != *"kill-audit-storms"* ]] \
  && [[ "$open_err" == *"kill-audit-storms: none"* ]] \
  && [ -d "$TMP/wt/storm-open" ]; then
  pass "rfg open --no-agent runs preflight and keeps storm output off stdout"
else
  fail "rfg open --no-agent: rc=$open_rc out=$open_out err=$open_err"
fi

cd "$TMP/fleet"
open_g_out="$(bash "$RFG" open revealui storm-open-grok 2>"$TMP/open-grok.err")" && open_g_rc=0 || open_g_rc=$?
open_g_err="$(cat "$TMP/open-grok.err")"
if [ "$open_g_rc" -eq 0 ] && [[ "$open_g_out" == *"GROK_STUB cwd="*"storm-open-grok"* ]] \
  && [[ "$open_g_err" == *"kill-audit-storms: none"* ]]; then
  pass "rfg open runs preflight before grok"
else
  fail "rfg open grok: rc=$open_g_rc out=$open_g_out err=$open_g_err"
fi

echo "--- static wiring ---"
if bash "$RFG" help | grep -q 'RFG_STORM_PREFLIGHT_SKIP=1' \
  && bash "$RFG" help | grep -q 'RFG_STORM_MIN_AGE_SEC' \
  && bash "$RFG" help | grep -q 'AUDIT_STORM_MIN_AGE_SEC'; then
  pass "rfg help documents skip and min-age overrides"
else
  fail "rfg help missing storm env vars"
fi

if awk '
  /^repo="\$\{1:-\}\"/ { inmain=1 }
  inmain && $0 ~ /^_rfg_storm_preflight$/ { if (!pf) pf=NR }
  inmain && /_sync_integration "\$target"/ { if (!sy) sy=NR }
  inmain && /^load_mcp_strict / { if (!mcp) mcp=NR }
  inmain && /exec "\$grok_bin"/ { if (!ex) ex=NR }
  END { exit !(pf && sy && mcp && ex && pf < sy && pf < mcp && pf < ex) }
' "$RFG"; then
  pass "main launch calls preflight before sync, MCP, and grok"
else
  fail "main launch hook order is wrong"
fi

if awk '
  /^  open\)/ { inopen=1; next }
  inopen && /^  -h \| --help/ { inopen=0 }
  inopen && $0 ~ /^    _rfg_storm_preflight$/ { if (!pf) pf=NR }
  inopen && /_sync_integration/ { if (!sy) sy=NR }
  inopen && /load_mcp_strict/ { if (!mcp) mcp=NR }
  inopen && /exec "\$grok_bin"/ { if (!ex) ex=NR }
  END { exit !(pf && sy && mcp && ex && pf < sy && pf < mcp && pf < ex) }
' "$RFG"; then
  pass "rfg open calls preflight before sync, MCP, and grok"
else
  fail "open hook order is wrong"
fi

if grep -q 'kill-audit-storms' "$BOOT" && grep -q 'HELPERS_DIR/kill-audit-storms' "$BOOT"; then
  pass "bootstrap installs unsuffixed kill-audit-storms"
else
  fail "bootstrap missing kill-audit-storms wrapper install"
fi

if grep -F 'shell/lib/"*.sh' "$BOOT" >/dev/null; then
  pass "bootstrap still installs every shell/lib script"
else
  fail "bootstrap lib glob missing"
fi

if bash -n "$SWEEP" && grep -F '*bin/grok*)' "$SWEEP" >/dev/null \
  && grep -F '*/usr/local/bin/rfg*)' "$SWEEP" >/dev/null \
  && ! grep -F 'exec grok' "$SWEEP" >/dev/null; then
  pass "rfg/grok skips are separate case arms and bash -n clean"
else
  fail "grok case pattern is not the corrected form"
fi

if grep -q 'audit_storm_has_agent_ancestor' "$SWEEP" \
  && grep -q 'cursor-agent' "$SWEEP" \
  && grep -q 'codex' "$SWEEP" \
  && grep -q 'rfx.sh' "$SWEEP"; then
  pass "sweeper walks ancestors for codex, rfx, and cursor-agent"
else
  fail "sweeper missing the agent-ancestor guard"
fi

if grep -q 'RFG_STORM_PREFLIGHT_SKIP' "$DOCS" && grep -q 'RFG_STORM_MIN_AGE_SEC' "$DOCS" \
  && grep -q 'AUDIT_STORM_MIN_AGE_SEC' "$DOCS" && grep -q 'kill-audit-storms' "$DOCS"; then
  pass "rfg-launcher.md documents the preflight"
else
  fail "rfg-launcher.md missing storm docs"
fi

# Quote-split so this test does not itself contain the account token.
user_pat='j''oshu'
if grep -nE "${user_pat}|/home/[A-Za-z0-9_]" "$SWEEP" "$PRE" "$WRAP" "$DOCS" >/dev/null; then
  fail "hardcoded home or account name in storm files"
  grep -nE "${user_pat}|/home/[A-Za-z0-9_]" "$SWEEP" "$PRE" "$WRAP" "$DOCS" || true
else
  pass "storm files do not hardcode a home directory or account name"
fi

if grep -q $'\u2014' "$SWEEP" "$PRE" "$WRAP"; then
  fail "em dash in new storm scripts"
else
  pass "new storm scripts have no em dash"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
