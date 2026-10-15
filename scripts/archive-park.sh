#!/usr/bin/env bash
# archive-park.sh moves a path into ~/revealfleet/archive/cold/<bucket>/ with a dated name.
#
# Usage:
#   archive-park.sh <source-path> <bucket> [slug]
#
# Buckets: handoffs | workboard | audits | sessions | worktrees | repos/revealui | repos/jv | repos/revdev | repos/misc
#
# Does NOT delete git history. If source is inside a git repo, prints a reminder
# to git rm in a follow-up PR after you confirm nothing still links to it.

set -euo pipefail

SRC="${1:-}"
BUCKET="${2:-}"
SLUG="${3:-}"

ARCHIVE_ROOT="${REVEALFLEET_ARCHIVE:-$HOME/revealfleet/archive/cold}"

usage() {
  echo "Usage: $0 <source-path> <bucket> [slug]" >&2
  echo "Buckets: handoffs workboard audits sessions worktrees repos/revealui repos/jv repos/revdev repos/misc" >&2
  exit 1
}

[[ -n "$SRC" && -n "$BUCKET" ]] || usage
[[ -e "$SRC" ]] || { echo "not found: $SRC" >&2; exit 1; }

case "$BUCKET" in
  handoffs|workboard|audits|sessions|worktrees|repos/revealui|repos/jv|repos/revdev|repos/misc) ;;
  *) echo "unknown bucket: $BUCKET" >&2; usage ;;
esac

# Slug becomes one path segment under the bucket. A slash or ".." would
# leave the archive root. Empty slug keeps the source basename.
if [[ -n "$SLUG" ]]; then
  case "$SLUG" in
    . | .. | */* | -*)
      echo "slug must be a single path segment: $SLUG" >&2
      exit 1
      ;;
  esac
fi

BASE="$(basename "$SRC")"
DATE="$(date -u +%Y-%m-%d)"
if [[ -n "$SLUG" ]]; then
  DEST_NAME="${DATE}-${SLUG}"
else
  DEST_NAME="${DATE}-${BASE}"
fi

DEST_DIR="$ARCHIVE_ROOT/$BUCKET"
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/$DEST_NAME"

if [[ -e "$DEST" ]]; then
  echo "destination exists: $DEST" >&2
  exit 1
fi

mv "$SRC" "$DEST"
echo "parked: $SRC -> $DEST"

# Heuristic: if parent is a git work tree, remind operator
if git -C "$(dirname "$SRC")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "note: source was under a git repo. Update any in-repo links, then 'git rm' the old path in a dedicated PR if it was tracked." >&2
fi
