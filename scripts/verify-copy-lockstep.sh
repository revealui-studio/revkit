#!/usr/bin/env bash
# verify-copy-lockstep.sh: native .revealui/content is the reference.
#
# Vendor trees (.claude, .grok, .cursor, and the other adapter dirs) are
# projections. They are checked against .revealui/content. A vendor manifest
# is not the reference.
#
# Checks:
#   1. .revealui/.revcon-manifest.json present, mode=copy, editor=revealui
#   2. Every manifest entry exists as a real file with the recorded sha256
#   3. Every file under .revealui/content/{rules,agents,skills} is in the manifest
#   4. When a vendor projection dir exists, its rules/agents/skills files match
#      the native bytes, and every native file in that subdir is projected
#   Backup files named *.revkit-bak-* are not projections and are ignored.
#
# Usage:
#   bash scripts/verify-copy-lockstep.sh --target /path/to/repo
#   bash scripts/verify-copy-lockstep.sh --target . --dot .claude
#
# --dot selects one vendor projection to check. The reference stays native.
#
# Exit: 0 ok, 1 drift or missing native manifest, 2 usage error

set -euo pipefail

TARGET=""
ONLY_VENDOR=""
MATERIALIZED_SUBDIRS=(rules agents skills)
VENDOR_DOTS=(.claude .grok .cursor .codex .gemini .windsurf .continue .agents)

usage() {
  cat <<'EOF'
Usage: verify-copy-lockstep.sh --target DIR [--dot VENDOR]

Options:
  --target DIR   Repo root that owns .revealui/content (required)
  --dot NAME     Check only this vendor projection (for example .claude)
  -h, --help     Show this help

The reference is always .revealui/content. Vendor directories are projections.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --dot)    ONLY_VENDOR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "error: --target is required" >&2
  usage >&2
  exit 2
fi

if [[ ! -d "$TARGET" ]]; then
  echo "error: target is not a directory: $TARGET" >&2
  exit 2
fi

TARGET="$(cd "$TARGET" && pwd)"
NATIVE_DOT=".revealui"
REF_ROOT="$TARGET/$NATIVE_DOT/content"
MANIFEST="$TARGET/$NATIVE_DOT/.revcon-manifest.json"

if [[ ! -f "$MANIFEST" ]]; then
  echo "FAIL missing $NATIVE_DOT/.revcon-manifest.json" >&2
  echo "  Reference is $NATIVE_DOT/content. Materialize native first:" >&2
  echo "    bash ~/revealfleet/revcon/link.sh --target $TARGET --profile revealfleet --editor revealui --mode copy" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 2
fi

mode="$(jq -r '.mode // empty' "$MANIFEST")"
editor="$(jq -r '.editor // empty' "$MANIFEST")"
if [[ "$mode" != "copy" ]]; then
  echo "FAIL $NATIVE_DOT/.revcon-manifest.json mode is '${mode:-missing}' (expected copy)" >&2
  exit 1
fi
if [[ "$editor" != "revealui" ]]; then
  echo "FAIL $NATIVE_DOT/.revcon-manifest.json editor is '${editor:-missing}' (expected revealui)" >&2
  exit 1
fi

if ! jq -e '.files | type == "object"' "$MANIFEST" >/dev/null 2>&1; then
  echo "FAIL $NATIVE_DOT/.revcon-manifest.json missing files map" >&2
  exit 1
fi

hash_file() {
  sha256sum "$1" | awk '{print $1}'
}

problems=0
count=0
declare -A manifest_paths=()

while IFS=$'\t' read -r rel src want; do
  [[ -n "$rel" ]] || continue
  count=$((count + 1))
  file_rel="$NATIVE_DOT/$rel"
  manifest_paths["$file_rel"]=1
  abs="$TARGET/$NATIVE_DOT/$rel"
  if [[ ! -e "$abs" ]]; then
    echo "  $file_rel missing on disk (manifest source: $src)" >&2
    problems=$((problems + 1))
    continue
  fi
  if [[ -L "$abs" ]]; then
    echo "  $file_rel is a symlink; native policy must be a real file" >&2
    problems=$((problems + 1))
    continue
  fi
  if [[ ! -f "$abs" ]]; then
    echo "  $file_rel is not a regular file" >&2
    problems=$((problems + 1))
    continue
  fi
  have="$(hash_file "$abs")"
  if [[ "$have" != "$want" ]]; then
    echo "  $file_rel content differs from the native manifest." >&2
    echo "    Edit .revealui/content, then refresh the native manifest." >&2
    problems=$((problems + 1))
  fi
done < <(jq -r '.files | to_entries[] | [.key, (.value.source // ""), (.value.sha256 // "")] | @tsv' "$MANIFEST")

if [[ -d "$REF_ROOT" ]]; then
  while IFS= read -r -d '' abs; do
    rel="${abs#"$TARGET"/}"
    if [[ -z "${manifest_paths[$rel]+x}" ]]; then
      echo "  $rel is under .revealui/content but not in the native manifest." >&2
      problems=$((problems + 1))
    fi
  done < <(find "$REF_ROOT" -type f ! -name '*.revkit-bak-*' -print0)
  if find "$REF_ROOT" -type l ! -name '*.revkit-bak-*' -print -quit | grep -q .; then
    echo "  .revealui/content contains a symlink; native policy must be real files" >&2
    problems=$((problems + 1))
  fi
else
  echo "  .revealui/content is missing" >&2
  problems=$((problems + 1))
fi

check_vendor() {
  local dot="$1"
  local sub native_dir vendor_dir native_file rel vendor_file
  local -A native_rels=()
  [[ -d "$TARGET/$dot" ]] || return 0
  for sub in "${MATERIALIZED_SUBDIRS[@]}"; do
    native_dir="$REF_ROOT/$sub"
    vendor_dir="$TARGET/$dot/$sub"
    [[ -d "$vendor_dir" ]] || continue
    native_rels=()
    if [[ -d "$native_dir" ]]; then
      while IFS= read -r -d '' native_file; do
        rel="${native_file#"$native_dir"/}"
        native_rels["$rel"]=1
        vendor_file="$vendor_dir/$rel"
        if [[ ! -f "$vendor_file" || -L "$vendor_file" ]]; then
          echo "  $dot/$sub/$rel is not a projection of .revealui/content/$sub/$rel" >&2
          problems=$((problems + 1))
          continue
        fi
        if [[ "$(hash_file "$native_file")" != "$(hash_file "$vendor_file")" ]]; then
          echo "  $dot/$sub/$rel differs from .revealui/content/$sub/$rel" >&2
          problems=$((problems + 1))
        fi
      done < <(find "$native_dir" -type f ! -name '*.revkit-bak-*' -print0)
    fi
    while IFS= read -r -d '' vendor_file; do
      rel="${vendor_file#"$vendor_dir"/}"
      case "$(basename "$vendor_file")" in
        *.revkit-bak-*) continue ;;
      esac
      if [[ -z "${native_rels[$rel]+x}" ]]; then
        echo "  $dot/$sub/$rel has no native reference at .revealui/content/$sub/$rel" >&2
        problems=$((problems + 1))
      fi
    done < <(find "$vendor_dir" -type f ! -name '*.revkit-bak-*' -print0)
  done
}

if [[ -n "$ONLY_VENDOR" ]]; then
  check_vendor "$ONLY_VENDOR"
else
  for dot in "${VENDOR_DOTS[@]}"; do
    check_vendor "$dot"
  done
fi

profiles="$(jq -r '.profiles | join(", ")' "$MANIFEST" 2>/dev/null || echo "?")"

if (( problems > 0 )); then
  echo "FAIL copy-lockstep: $problems violation(s) ($count native manifest entr(y/ies), profiles: $profiles)" >&2
  echo "  Reference is .revealui/content. Re-apply native first:" >&2
  echo "    bash ~/revealfleet/revcon/link.sh --target $TARGET --editor revealui --mode copy --profile revealfleet" >&2
  echo "  Then project vendor editors from that tree." >&2
  exit 1
fi

echo "ok copy-lockstep: $count native file(s) match the manifest (profiles: $profiles); vendor projections match .revealui/content"
exit 0
