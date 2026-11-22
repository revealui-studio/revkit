#!/usr/bin/env bash
# Guards added after the 2026-10-09 exhaustive audit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== test-audit-fixes.sh ==="

echo "--- archive-park slug ---"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src/item" "$TMP/src/stay"
printf 'x\n' > "$TMP/src/item/a.txt"
printf 'y\n' > "$TMP/src/stay/b.txt"
export REVEALFLEET_ARCHIVE="$TMP/archive"
if bash "$ROOT/scripts/archive-park.sh" "$TMP/src/item" audits 'ok-slug' >/dev/null; then
  if [ -d "$TMP/archive/audits/"*"ok-slug" ]; then
    pass "archive-park accepts a single-segment slug"
  else
    fail "archive-park reported success but destination is missing"
  fi
else
  fail "archive-park rejected a safe slug"
fi
out="$(bash "$ROOT/scripts/archive-park.sh" "$TMP/src/stay" audits '../escape' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"single path segment"* ]] && [ -d "$TMP/src/stay" ]; then
  pass "archive-park rejects a slug that leaves the archive root"
else
  fail "archive-park traversal: rc=$rc out=$out"
fi
out="$(bash "$ROOT/scripts/archive-park.sh" "$TMP/src/stay" audits 'nested/name' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"single path segment"* ]]; then
  pass "archive-park rejects a slash in the slug"
else
  fail "archive-park slash: rc=$rc out=$out"
fi

echo "--- mount helper refuses an unlabeled disk ---"
BIN="$(mktemp -d)"
cat >"$BIN/blkid" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$BIN/mount" <<'EOF'
#!/usr/bin/env bash
echo "mount-called" >>"${MOUNT_STAMP:?}"
exit 0
EOF
cat >"$BIN/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$BIN/umount" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/blkid" "$BIN/mount" "$BIN/mountpoint" "$BIN/umount"
STAMP="$TMP/mount-stamp"
: >"$STAMP"
out="$(PATH="$BIN:/usr/bin:/bin" MOUNT_STAMP="$STAMP" SANDBOX_LABEL_RETRIES=1 SANDBOX_LABEL_RETRY_SLEEP=0 bash "$ROOT/shell/bin/mount-sandbox-drive.sh" --mount-only 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"Refusing to guess"* ]] && ! grep -q 'mount-called' "$STAMP"; then
  pass "mount helper exits when the Sandbox label is missing and does not mount"
else
  fail "mount helper: rc=$rc out=$out stamp=$(cat "$STAMP")"
fi
if ! grep -q '/dev/sd\[a-z\]1' "$ROOT/shell/bin/mount-sandbox-drive.sh"; then
  pass "mount helper has no unlabeled sd* scan"
else
  fail "unlabeled ext4 scan is back in mount-sandbox-drive.sh"
fi

echo "--- sandbox ports stay on localhost ---"
if grep -q '127.0.0.1:5433:5432' "$ROOT/shell/docker/compose.yml" \
  && grep -q '127.0.0.1:6380:6379' "$ROOT/shell/docker/compose.yml" \
  && grep -q '127.0.0.1:11434:11434' "$ROOT/shell/docker/compose.yml"; then
  pass "compose publishes postgres, redis, and ollama on 127.0.0.1"
else
  fail "compose ports are not bound to 127.0.0.1"
fi
if grep -q 'PGPASSWORD:-sandbox' "$ROOT/shell/bin/sandbox-services.sh" \
  || grep -q '_p:-sandbox' "$ROOT/shell/shellrc.d/15-docker.sh"; then
  fail "a well-known postgres password default is still present"
else
  pass "postgres password is not defaulted to sandbox"
fi

echo "--- pre-push content gate ---"
if bash "$ROOT/scripts/ci/green-checks.sh" --scope=range --base=abc --head=def --allow-skip; then
  pass "green-checks.sh is clean on this tree"
else
  fail "green-checks.sh failed"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
