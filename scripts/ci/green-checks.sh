#!/usr/bin/env bash
# Local content gate for this repo.
#
# git-hooks/pre-push runs, from the repo being pushed:
#   bash scripts/ci/green-checks.sh --scope=range --base=<sha> --head=<sha> --allow-skip
#
# These scanners read the working tree. They do not need a compiler. A leak
# hit fails the push. --allow-skip does not hide that.
set -euo pipefail

while [ $# -gt 0 ]; do
  case "$1" in
    --scope|--base|--head)
      shift 2 || exit 2
      ;;
    --scope=*|--base=*|--head=*|--allow-skip)
      shift
      ;;
    *)
      shift
      ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
bash "$ROOT/scripts/check-client-leaks.sh" || fail=1
bash "$ROOT/scripts/check-no-private-leaks.sh" || fail=1
bash "$ROOT/scripts/check-no-client-names.sh" || fail=1
exit "$fail"
