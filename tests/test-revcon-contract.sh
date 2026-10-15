#!/usr/bin/env bash
# Exercise the maintained RevCon linker in a private fleet. The source is an
# explicit test dependency, never inferred from the operator's fleet or HOME.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" != --source ] || [ "$#" -ne 2 ] || [ ! -f "$2/link.sh" ]; then
  echo "usage: bash tests/test-revcon-contract.sh --source REVCON_SOURCE" >&2
  exit 2
fi
SOURCE="$2"
TEST_ROOT="$(mktemp -d /tmp/revkit-revcon-contract.XXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
FLEET="$TEST_ROOT/revealfleet"
mkdir -p "$FLEET/.wt/source" "$FLEET/revkit" "$FLEET/revcon/profiles/revealfleet/revealui/rules" "$TEST_ROOT/home"
cp -R "$ROOT/bootstrap.sh" "$ROOT/lib" "$ROOT/shell" "$ROOT/templates" "$FLEET/.wt/source/"
cp "$SOURCE/link.sh" "$FLEET/revcon/link.sh"
printf '# Synthetic native policy\n' > "$FLEET/revcon/profiles/revealfleet/revealui/rules/contract.md"
run_boot() {
  (cd "$TEST_ROOT/home" && env -i HOME="$TEST_ROOT/home" PATH="$PATH" TMPDIR="$TEST_ROOT" \
    REVEALFLEET_ROOT="$FLEET" REVKIT_BOOTSTRAP_ONLY=control \
    bash "$FLEET/.wt/source/bootstrap.sh")
}
snapshot() {
  find "$FLEET/revkit" "$FLEET/revcon/.revealui" "$FLEET/revcon/.claude" "$FLEET/revcon/.grok" \
    "$TEST_ROOT/home" -type f -exec sha256sum {} + | sort
}
run_boot > "$TEST_ROOT/first.log" 2>&1 || { cat "$TEST_ROOT/first.log"; exit 1; }
for target in revkit revcon; do
  for vendor in .claude .grok; do
    grep -Fxq '<!-- generated from .revealui/content/rules/contract.md -->' \
      "$FLEET/$target/$vendor/rules/contract.md"
  done
  bash "$ROOT/scripts/verify-copy-lockstep.sh" --target "$FLEET/$target"
done
snapshot > "$TEST_ROOT/first.sha"
run_boot > "$TEST_ROOT/second.log" 2>&1 || { cat "$TEST_ROOT/second.log"; exit 1; }
snapshot > "$TEST_ROOT/second.sha"
cmp "$TEST_ROOT/first.sha" "$TEST_ROOT/second.sha"
echo 'PASS: canonical RevCon native materialization, projections, lockstep and idempotent bootstrap'
