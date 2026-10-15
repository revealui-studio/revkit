#!/usr/bin/env bash
# An untracked gitignored file is not a leak, and the same bytes in a
# tracked file still fail. A directory that is not a git work tree keeps
# the old behavior and still fails.
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/revkit-leak-test.XXXXXX)"
ROOT="$TEST_ROOT/repo"
mkdir -p "$ROOT/scripts" "$TEST_ROOT/home"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
cp "$SOURCE_ROOT/scripts/check-no-private-leaks.sh" "$ROOT/scripts/"
cp "$SOURCE_ROOT/.gitignore" "$ROOT/.gitignore"
fixture_git() {
  env -i HOME="$TEST_ROOT/home" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 \
    git -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"
}
scan() {
  env -i HOME="$TEST_ROOT/home" PATH="$PATH" bash "$SCAN" "$@"
}
fixture_git -C "$ROOT" init -q
SCAN="$ROOT/scripts/check-no-private-leaks.sh"
# Assembled so this tracked test file does not itself contain a leak path.
prefix=/home
user=example
PAYLOAD="${prefix}/${user}/secret"

mkdir -p "$ROOT/.claude"
printf '%s\n' "$PAYLOAD" > "$ROOT/.claude/settings.local.json"
set +e
scan "$ROOT/.claude" >"$TEST_ROOT/untracked.log"
code=$?
set -e
if [[ "$code" -ne 0 ]]; then
  echo "untracked gitignored file should exit 0, got $code" >&2
  cat "$TEST_ROOT/untracked.log" >&2
  exit 1
fi

mkdir -p "$ROOT/leak-scan-fixture"
printf '%s\n' "$PAYLOAD" > "$ROOT/leak-scan-fixture/note.txt"
fixture_git -C "$ROOT" add -- leak-scan-fixture/note.txt
set +e
scan "$ROOT/leak-scan-fixture" >"$TEST_ROOT/tracked.log"
code=$?
set -e
fixture_git -C "$ROOT" rm --cached -q -- leak-scan-fixture/note.txt
rm -rf "$ROOT/leak-scan-fixture"
if [[ "$code" -ne 1 ]]; then
  echo "tracked file should exit 1, got $code" >&2
  cat "$TEST_ROOT/tracked.log" >&2
  exit 1
fi

fixture_git -C "$ROOT" add -f -- .claude/settings.local.json
set +e
scan "$ROOT/.claude" >"$TEST_ROOT/forced.log"
code=$?
set -e
fixture_git -C "$ROOT" rm --cached -q -- .claude/settings.local.json
rm -f "$ROOT/.claude/settings.local.json"
if [[ "$code" -ne 1 ]]; then
  echo "tracked gitignored file should exit 1, got $code" >&2
  cat "$TEST_ROOT/forced.log" >&2
  exit 1
fi

NONGIT="$(mktemp -d "$TEST_ROOT/nongit.XXXXXX")"
mkdir -p "$NONGIT/scripts"
cp "$SCAN" "$NONGIT/scripts/check-no-private-leaks.sh"
printf '%s\n' "$PAYLOAD" > "$NONGIT/note.txt"
set +e
env -i HOME="$TEST_ROOT/home" PATH="$PATH" bash "$NONGIT/scripts/check-no-private-leaks.sh" "$NONGIT" >"$TEST_ROOT/nongit.log"
code=$?
set -e
if [[ "$code" -ne 1 ]]; then
  echo "non-git directory should still exit 1, got $code" >&2
  cat "$TEST_ROOT/nongit.log" >&2
  exit 1
fi

echo "check-no-private-leaks gitignore cases passed"

# Distinguish literal absolute homes from paths rooted in variables or other
# directories. Literal paths stay denied in plain text, code, URLs and markup.
for literal in "$PAYLOAD" "path=$PAYLOAD" "[$PAYLOAD]" "file://$PAYLOAD"; do
  printf '%s\n' "$literal" > "$NONGIT/note.txt"
  if scan "$NONGIT/note.txt" > "$TEST_ROOT/path.log" 2>&1; then
    echo 'literal absolute home was not rejected' >&2
    exit 1
  fi
  grep -q 'abs-home-path' "$TEST_ROOT/path.log"
done
for parameterized in '$CUSTOM/home/sudoers-fixture' '${CUSTOM}/home/missing-log' '$(fixture)/home/entry' '/tmp/home/synthetic'; do
  printf '%s\n' "$parameterized" > "$NONGIT/note.txt"
  if ! scan "$NONGIT/note.txt" > "$TEST_ROOT/path.log" 2>&1; then
    echo 'parameterized or nested synthetic path was rejected' >&2
    cat "$TEST_ROOT/path.log" >&2
    exit 1
  fi
done
echo 'absolute home path boundary cases passed'

# Structural path protection must survive fleet renames without matching variables.
PRIVATE_FIXTURE="$(mktemp -d "$TEST_ROOT/private.XXXXXX")"
for fleet in '~'/revealfleet '/renamed-fleet_2' '/Fleet.v2' '/x'; do
  printf '%s/%s/docs\n' "$fleet" '.jv' > "$PRIVATE_FIXTURE/note.txt"
  if scan "$PRIVATE_FIXTURE/note.txt" > "$PRIVATE_FIXTURE/output.txt" 2>&1; then
    echo "private planning checkout was not rejected: $fleet" >&2
    exit 1
  fi
  if ! grep -q 'private-jv-repo' "$PRIVATE_FIXTURE/output.txt"; then
    cat "$PRIVATE_FIXTURE/output.txt" >&2
    exit 1
  fi
done
for public_path in '~'/revealfleet/revealui '/renamed-fleet_2/docs' '$REVEALFLEET_ROOT/.jv' '$root/.jv' '${fleet}/.jv'; do
  printf '%s\n' "$public_path" > "$PRIVATE_FIXTURE/note.txt"
  if ! scan "$PRIVATE_FIXTURE/note.txt" > "$PRIVATE_FIXTURE/output.txt" 2>&1; then
    echo "public or parameterized path was rejected: $public_path" >&2
    cat "$PRIVATE_FIXTURE/output.txt" >&2
    exit 1
  fi
done
rm -rf "$PRIVATE_FIXTURE"
echo "private planning path cases passed"
