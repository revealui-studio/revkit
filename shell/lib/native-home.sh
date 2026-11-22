# shellcheck shell=bash
# native-home.sh: install the native control home, then project vendor adapters.
#
# ~/.revealui is the operator control home. Repo .revealui/content is the
# policy reference. Vendor homes (.grok, and .claude only when opted in) are
# projections of that native tree. This file never clones a vendor config
# repo and never invokes the claude CLI.
#
# Claude adapter (off by default):
#   bootstrap.sh --claude-adapter
#   REVKIT_CLAUDE_ADAPTER=1
#
# Test harness (skips privileged bootstrap steps):
#   REVKIT_BOOTSTRAP_ONLY=control

revkit_repo_root() {
  if [ -n "${REVKIT_ROOT:-}" ]; then
    printf '%s\n' "$REVKIT_ROOT"
    return 0
  fi
  if [ -n "${SCRIPT_DIR:-}" ]; then
    printf '%s\n' "$SCRIPT_DIR"
    return 0
  fi
  return 1
}

revkit_native_home() {
  if [ -n "${REVEALUI_NATIVE_HOME:-}" ]; then
    printf '%s\n' "$REVEALUI_NATIVE_HOME"
    return 0
  fi
  printf '%s\n' "${HOME:?}/.revealui"
}

revkit_claude_adapter_on() {
  [ "${REVKIT_CLAUDE_ADAPTER:-0}" = "1" ]
}

# Marker written into every file this installer creates. A later run may
# replace a file in place only when the marker is in the header: the first
# 5 lines, or the first JSON key for JSON. A mention later in the file is
# not ownership.
REVKIT_PROJECTION_MARKER='generated-by-revkit'

revkit_is_revkit_backup() {
  local base
  base="$(basename -- "$1")"
  case "$base" in
    *.revkit-bak-*) return 0 ;;
  esac
  return 1
}

# True when the first JSON key is the projection marker.
revkit_json_first_key_is_marker() {
  local f="$1"
  awk -v marker="$REVKIT_PROJECTION_MARKER" '
    BEGIN { key = ""; stage = 0; done = 0 }
    {
      s = $0
      while (length(s) > 0 && !done) {
        if (stage == 0 || stage == 1) {
          if (s ~ /^[[:space:]]/) {
            sub(/^[[:space:]]+/, "", s)
            continue
          }
          c = substr(s, 1, 1)
          if (stage == 0 && c != "{") exit 1
          if (stage == 1 && c != "\"") exit 1
          s = substr(s, 2)
          stage++
          continue
        }
        c = substr(s, 1, 1)
        if (c == "\\") {
          s = substr(s, 3)
          continue
        }
        if (c == "\"") {
          done = 1
          break
        }
        key = key c
        s = substr(s, 2)
      }
    }
    END {
      if (!done) exit 1
      if (key != marker) exit 1
    }
  ' "$f"
}

revkit_has_projection_marker() {
  local f="$1"
  local kind="${2:-}"
  [ -f "$f" ] || return 1
  [ -L "$f" ] && return 1
  if [ -z "$kind" ]; then
    case "$f" in
      *.json) kind=json ;;
      *) kind=text ;;
    esac
  fi
  if [ "$kind" = "json" ]; then
    revkit_json_first_key_is_marker "$f"
    return
  fi
  local header
  header="$(head -n 5 -- "$f")"
  case "$header" in
    *"$REVKIT_PROJECTION_MARKER"*) return 0 ;;
  esac
  return 1
}

# True when ~/.revealui is a revkit checkout. Writing adapters/ or hooks/
# there would leave untracked files in that clone.
revkit_native_home_is_revkit_checkout() {
  local native
  native="$(revkit_native_home)"
  [ -e "$native/.git" ] || return 1
  [ -f "$native/bootstrap.sh" ] || return 1
  [ -f "$native/shell/lib/native-home.sh" ] || return 1
  return 0
}

revkit_warn_revkit_checkout_once() {
  if [ "${REVKIT_NATIVE_CHECKOUT_WARNED:-0}" = "1" ]; then
    return 0
  fi
  REVKIT_NATIVE_CHECKOUT_WARNED=1
  printf '  WARNING: %s is a revkit checkout. Not writing adapters/ or hooks/ into it.\n' \
    "$(revkit_native_home)" >&2
}

# Move a user-owned file aside. The caller then writes the projection.
revkit_backup_user_file() {
  local dest="$1"
  local stamp bak n
  stamp="$(date -u +%Y%m%d%H%M%S)"
  bak="${dest}.revkit-bak-${stamp}"
  n=0
  while [ -e "$bak" ] || [ -L "$bak" ]; do
    n=$((n + 1))
    bak="${dest}.revkit-bak-${stamp}-${n}"
  done
  mv "$dest" "$bak"
  printf '  WARNING: %s differs and has no generated-by-revkit header marker. Moved it to %s\n' \
    "$dest" "$bak" >&2
}

# Stamp a projection marker into tmp. Idempotent when the header already
# carries the marker.
revkit_stamp_projection() {
  local src="$1"
  local tmp="$2"
  local stamped kind
  sed 's/\r$//' "$src" > "$tmp"
  case "$src" in
    *.json) kind=json ;;
    *) kind=text ;;
  esac
  if revkit_has_projection_marker "$tmp" "$kind"; then
    return 0
  fi
  stamped="$(mktemp)"
  case "$src" in
    *.json)
      awk '
        BEGIN { done = 0 }
        {
          if (!done && $0 ~ /^\{/) {
            print "{"
            print "  \"generated-by-revkit\": true,"
            sub(/^\{/, "")
            if (length($0) > 0) print $0
            done = 1
            next
          }
          print
        }
      ' "$tmp" > "$stamped"
      ;;
    *.js)
      # Node recognizes a shebang only on the first line.
      if head -n 1 -- "$tmp" | grep -q '^#!'; then
        {
          head -n 1 -- "$tmp"
          printf '%s\n' '// generated-by-revkit'
          tail -n +2 -- "$tmp"
        } > "$stamped"
      else
        { printf '%s\n' '// generated-by-revkit'; cat "$tmp"; } > "$stamped"
      fi
      ;;
    *.md)
      { printf '%s\n' '<!-- generated-by-revkit -->'; cat "$tmp"; } > "$stamped"
      ;;
    *)
      { printf '%s\n' '# generated-by-revkit'; cat "$tmp"; } > "$stamped"
      ;;
  esac
  mv "$stamped" "$tmp"
}

# Copy a text file. An existing target with no projection marker is backed
# up before a different body is written. A marked target may be replaced.
revkit_copy_file() {
  local src="$1"
  local dest="$2"
  local tmp
  if revkit_is_revkit_backup "$src" || revkit_is_revkit_backup "$dest"; then
    return 0
  fi
  if [ ! -f "$src" ]; then
    printf '  WARNING: missing %s\n' "$src" >&2
    return 0
  fi
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    if [ -e "$dest" ]; then
      printf '  [dry-run] would copy %s -> %s (unmarked existing file is backed up first)\n' \
        "$src" "$dest"
    else
      printf '  [dry-run] would copy %s -> %s\n' "$src" "$dest"
    fi
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp)"
  revkit_stamp_projection "$src" "$tmp"
  if [ -L "$dest" ]; then
    revkit_backup_user_file "$dest"
  elif [ -e "$dest" ]; then
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
      rm -f "$tmp"
      return 0
    fi
    if revkit_has_projection_marker "$dest"; then
      :
    else
      revkit_backup_user_file "$dest"
    fi
  fi
  mv "$tmp" "$dest"
  chmod 0644 "$dest"
  printf '  Deployed: %s\n' "$dest"
}

revkit_sync_tree() {
  local src="$1"
  local dest="$2"
  local f rel
  [ -d "$src" ] || return 0
  while IFS= read -r -d '' f; do
    if revkit_is_revkit_backup "$f"; then
      continue
    fi
    rel="${f#"$src"/}"
    revkit_copy_file "$f" "$dest/$rel"
  done < <(find "$src" -type f ! -name '*.revkit-bak-*' -print0)
}

revkit_install_native_templates() {
  local repo native
  if revkit_native_home_is_revkit_checkout; then
    revkit_warn_revkit_checkout_once
    return 0
  fi
  repo="$(revkit_repo_root)" || return 1
  native="$(revkit_native_home)"
  revkit_sync_tree "$repo/templates/adapters/grok" "$native/adapters/grok"
  revkit_sync_tree "$repo/templates/adapters/claude" "$native/adapters/claude"
  if [ -f "$repo/templates/grok/config.toml" ]; then
    revkit_copy_file "$repo/templates/grok/config.toml" "$native/adapters/grok/config.toml"
  fi
}

revkit_install_m4() {
  local repo src session dest_root
  if revkit_native_home_is_revkit_checkout; then
    revkit_warn_revkit_checkout_once
    return 0
  fi
  repo="$(revkit_repo_root)" || return 1
  src="$repo/shell/bin/m4-sudoers-fs-scanner.js"
  session="$repo/templates/hooks/session-start.js"
  dest_root="$(revkit_native_home)/hooks"
  if [ ! -f "$src" ]; then
    printf '  WARNING: %s not found, M-4 scanner not deployed\n' "$src" >&2
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "  WARNING: node not in PATH, skipping M-4 scanner deploy" >&2
    return 0
  fi
  if ! node --check "$src" >/dev/null 2>&1; then
    printf '  ERROR: %s failed node --check; refusing to deploy\n' "$src" >&2
    exit 1
  fi
  if [ -f "$session" ] && ! node --check "$session" >/dev/null 2>&1; then
    printf '  ERROR: %s failed node --check; refusing to deploy\n' "$session" >&2
    exit 1
  fi
  revkit_copy_file "$src" "$dest_root/m4-sudoers-fs-scanner.js"
  if [ -f "$session" ]; then
    revkit_copy_file "$session" "$dest_root/session-start.js"
  fi
  echo "  M-4 scanner native path: $dest_root/m4-sudoers-fs-scanner.js"
  echo "  Adapters invoke that path. The script is not copied into a vendor home."
}

revkit_grok_hook_src() {
  local installed repo
  installed="$(revkit_native_home)/adapters/grok/hooks/m4-sudoers-fs-scan.json"
  if [ -f "$installed" ] && ! revkit_native_home_is_revkit_checkout; then
    printf '%s\n' "$installed"
    return 0
  fi
  repo="$(revkit_repo_root)" || return 1
  if [ -f "$repo/templates/adapters/grok/hooks/m4-sudoers-fs-scan.json" ]; then
    printf '%s\n' "$repo/templates/adapters/grok/hooks/m4-sudoers-fs-scan.json"
    return 0
  fi
  return 1
}

revkit_grok_config_src() {
  local installed repo
  installed="$(revkit_native_home)/adapters/grok/config.toml"
  if [ -f "$installed" ] && ! revkit_native_home_is_revkit_checkout; then
    printf '%s\n' "$installed"
    return 0
  fi
  repo="$(revkit_repo_root)" || return 1
  if [ -f "$repo/templates/grok/config.toml" ]; then
    printf '%s\n' "$repo/templates/grok/config.toml"
    return 0
  fi
  return 1
}

revkit_claude_projection_root() {
  local installed repo
  installed="$(revkit_native_home)/adapters/claude"
  if [ -d "$installed" ] && ! revkit_native_home_is_revkit_checkout; then
    printf '%s\n' "$installed"
    return 0
  fi
  repo="$(revkit_repo_root)" || return 1
  printf '%s\n' "$repo/templates/adapters/claude"
}

revkit_project_grok_adapter() {
  local native dest hook tmpl
  native="$(revkit_native_home)"
  dest="${GROK_HOME:-$HOME/.grok}"
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    printf '  [dry-run] would project %s/hooks from %s/adapters/grok\n' "$dest" "$native"
    printf '  [dry-run] would seed Grok [compat.claude] defaults into %s/config.toml\n' "$dest"
    return 0
  fi
  hook="$(revkit_grok_hook_src)" || hook=""
  if [ -n "$hook" ] && [ -f "$hook" ]; then
    revkit_copy_file "$hook" "$dest/hooks/m4-sudoers-fs-scan.json"
  fi
  tmpl="$(revkit_grok_config_src)" || tmpl=""
  if [ -z "$tmpl" ] || [ ! -f "$tmpl" ]; then
    return 0
  fi
  # shellcheck disable=SC1091
  . "$(revkit_repo_root)/shell/lib/grok-attach.sh"
  REVEALUI_NATIVE_HOME="$native" rfg_seed_grok_compat
  echo "  Grok config: [compat.claude] hooks, mcps, and sessions stay off unless set"
}

revkit_project_claude_adapter() {
  local native dest
  if ! revkit_claude_adapter_on; then
    echo "  Claude adapter: off (pass --claude-adapter or set REVKIT_CLAUDE_ADAPTER=1)"
    return 0
  fi
  native="$(revkit_claude_projection_root)"
  dest="${REVKIT_CLAUDE_HOME:-$HOME/.claude}"
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    printf '  [dry-run] would project %s from %s\n' "$dest" "$native"
    return 0
  fi
  echo "  Claude adapter: projecting $dest from $native"
  echo "  Projection only. Not a vendor config repo, and the claude CLI is not run."
  revkit_sync_tree "$native" "$dest"
}

revkit_link_fleet() {
  local link_sh repo rest profiles_csv mode target_dir editor
  local -a profile_args editors
  if [ -z "${REVEALFLEET_ROOT:-}" ] && [ -n "${_FLEET_PIN:-}" ]; then
    REVEALFLEET_ROOT="$_FLEET_PIN"
  fi
  if [ -z "${REVEALFLEET_ROOT:-}" ] && type rfg_resolve_fleet_root >/dev/null 2>&1; then
    local rc=0
    REVEALFLEET_ROOT="$(rfg_resolve_fleet_root)" || rc=$?
    if [ "$rc" -eq 78 ]; then
      exit 78
    fi
    if [ "$rc" -ne 0 ]; then
      REVEALFLEET_ROOT=""
    fi
  fi
  if [ -z "${REVEALFLEET_ROOT:-}" ]; then
    echo "  WARNING: fleet root unresolved, skipping revcon link (set REVEALFLEET_ROOT)" >&2
    return 0
  fi
  link_sh="$REVEALFLEET_ROOT/revcon/link.sh"
  if [ ! -f "$link_sh" ]; then
    printf '  WARNING: %s not found, skipping (clone the revcon repo first)\n' "$link_sh" >&2
    return 0
  fi

  # Native editor first. revcon copy mode replaces a differing file, so
  # vendor editors run only when REVKIT_LINK_EDITORS names them.
  local -a fleet_targets=(
    "revealui:revealfleet,revealui:copy"
    "revdev:revealfleet:copy"
    "revvault:revealfleet:copy"
    "revcon:revealfleet:copy"
    "revforge:revealfleet:copy"
    "revskills:revealfleet:copy"
    "revkit:revealfleet:copy"
  )
  local extra
  local -a _link_editors
  editors=(revealui)
  if [ -n "${REVKIT_LINK_EDITORS:-}" ]; then
    IFS=',' read -ra _link_editors <<< "$REVKIT_LINK_EDITORS"
    for extra in "${_link_editors[@]}"; do
      [ -n "$extra" ] || continue
      [ "$extra" = "revealui" ] && continue
      editors+=("$extra")
    done
  fi

  for entry in "${fleet_targets[@]}"; do
    repo="${entry%%:*}"
    rest="${entry#*:}"
    profiles_csv="${rest%%:*}"
    mode="symlink"
    case "$rest" in
      *:*) mode="${rest#*:}" ;;
    esac
    target_dir="${REVEALFLEET_ROOT}/$repo"
    if [ ! -d "$target_dir" ]; then
      printf '  [skip] %s not found at %s\n' "$repo" "$target_dir"
      continue
    fi
    profile_args=()
    local p
    IFS=',' read -ra _profiles <<< "$profiles_csv"
    for p in "${_profiles[@]}"; do
      profile_args+=("--profile" "$p")
    done
    for editor in "${editors[@]}"; do
      printf '  [%s] editor %s profiles %s (mode %s)\n' "$repo" "$editor" "$profiles_csv" "$mode"
      if [ "${DRY_RUN:-0}" -eq 1 ]; then
        printf '  [dry-run] would run revcon/link.sh --editor %s --mode %s for %s\n' \
          "$editor" "$mode" "$repo"
      else
        bash "$link_sh" --target "$target_dir" --editor "$editor" --mode "$mode" \
          "${profile_args[@]}" 2>&1 | sed 's/^/    /'
      fi
    done
  done
  echo "  Done."
}

revkit_bootstrap_control_layer() {
  echo "[7] Writing native control home (~/.revealui)..."
  revkit_install_native_templates
  if revkit_claude_adapter_on; then
    echo "  Claude adapter requested. It projects pointers from the native home."
  else
    echo "  Claude adapter: off (pass --claude-adapter or set REVKIT_CLAUDE_ADAPTER=1)"
  fi

  echo "[8] Deploying M-4 scanner to the native hooks directory..."
  revkit_install_m4
  revkit_project_grok_adapter
  revkit_project_claude_adapter

  echo "[9] Wiring fleet rules via revcon (editor revealui; extra editors from REVKIT_LINK_EDITORS)..."
  revkit_link_fleet
}
