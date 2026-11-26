#!/bin/bash
# mount-sandbox-drive.sh mounts only the approved Sandbox disk identity.
# Called by Windows mount script (Mount-WSLDev.ps1) after wsl --mount --bare.
#
# Defense-in-depth checks (GAP-118 + GAP-119, 2026-04-24):
#
#  1. Explicit mode required (--mount-only or --init). The sudoers entry in
#     /etc/sudoers.d/wsl-revealui pins NOPASSWD to `--mount-only` so that any
#     future expansion of this script's arg surface is automatically rejected
#     until the sudoers rule is updated to match.
#
#  2. After mount, $MOUNT_POINT/.sandbox-marker MUST exist (placed during one-
#     time `--init` setup). If it's missing, the script unmounts immediately
#     and exits 1. Root-owned identity configuration pins disk/GPT/filesystem
#     identity; neither a label nor a marker selects the device.
#
#  3. Every mount attempt is logged to /var/log/revealui-mount.log (timestamp,
#     mode, source, device, outcome).
#
# Usage:
#   sudo /usr/local/bin/mount-sandbox-drive.sh --mount-only   # steady-state, NOPASSWD path
#   sudo /usr/local/bin/mount-sandbox-drive.sh --init         # one-time setup; creates marker
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

MOUNT_POINT="/mnt/sandbox"
DRIVE_LABEL="Sandbox"
MARKER_FILE="$MOUNT_POINT/.sandbox-marker"
LOG_FILE="/var/log/revealui-mount.log"

INIT_MARKER=false
MOUNT_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mount-only)
            MOUNT_ONLY=true
            shift
            ;;
        --init)
            INIT_MARKER=true
            shift
            ;;
        --help|-h)
            cat <<HELP
Usage: $0 --mount-only | --init

  --mount-only  Mount the Sandbox drive and verify $MARKER_FILE exists.
                If marker missing, unmount and exit 1. This is the steady-
                state mode used by the NOPASSWD sudoers rule.
  --init        Mount the Sandbox drive and create $MARKER_FILE if missing.
                Use this once when first connecting a new Sandbox drive.
                Requires interactive sudo (not covered by the NOPASSWD rule).
HELP
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

if [[ "$INIT_MARKER" == "false" && "$MOUNT_ONLY" == "false" ]]; then
    echo "ERROR: Must specify --mount-only or --init." >&2
    echo "  --mount-only : steady-state mount, marker required (NOPASSWD path)." >&2
    echo "  --init       : one-time setup, creates marker after mount." >&2
    exit 1
fi

if [[ "$INIT_MARKER" == "true" && "$MOUNT_ONLY" == "true" ]]; then
    echo "ERROR: --mount-only and --init are mutually exclusive." >&2
    exit 1
fi

# Best-effort mount logging. Never blocks the mount path.
log_mount() {
    local msg="$1"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
        printf '[%s] mode=%s msg=%s\n' \
            "$ts" \
            "$([[ "$INIT_MARKER" == "true" ]] && echo init || echo mount-only)" \
            "$msg"
    } >> "$LOG_FILE" 2>/dev/null || true
}

IDENTITY_HELPER="/usr/local/lib/revealfleet/wsl-disk-identity.py"
IDENTITY_CONFIG="/etc/revealfleet/disks/sandbox.json"

verify_identity() {
    /usr/bin/python3 -I -c '
import os, pathlib, stat, sys
for text in sys.argv[1:]:
    path = pathlib.Path(text)
    for component in [*reversed(path.parents), path]:
        info = component.lstat()
        if info.st_uid != 0 or info.st_mode & 0o022 or stat.S_ISLNK(info.st_mode):
            raise SystemExit("Root-owned non-writable identity tooling/configuration required")
    if not stat.S_ISREG(path.lstat().st_mode):
        raise SystemExit("Identity tooling/configuration must be regular files")
' "$IDENTITY_HELPER" "$IDENTITY_CONFIG" || return
    /usr/bin/python3 -I "$IDENTITY_HELPER" --identity "$IDENTITY_CONFIG" \
        --require-mount-point "$MOUNT_POINT" --require-label "$DRIVE_LABEL" --deadline-seconds 30
}

if ! IDENTITY_REPORT="$(verify_identity)"; then
    echo "ERROR: Configure the approved Sandbox identity through RevKit provisioning at $IDENTITY_CONFIG; no filesystem was mounted." >&2
    exit 1
fi
IDENTITY_FIELDS="$(printf '%s' "$IDENTITY_REPORT" | /usr/bin/python3 -I -c '
import json, sys
value = json.load(sys.stdin)
if value.get("identityVerified") is not True or value.get("mountState") not in {"MOUNTED", "NOT_MOUNTED"}:
    raise SystemExit("Incomplete identity verification")
print(value["partitionPath"])
print(value["mountState"])
')"
mapfile -t VERIFIED_FIELDS <<< "$IDENTITY_FIELDS"
if [ "${#VERIFIED_FIELDS[@]}" -ne 2 ]; then
    echo "ERROR: Invalid identity probe response." >&2
    exit 1
fi
EXTDEV="${VERIFIED_FIELDS[0]}"
MOUNT_STATE="${VERIFIED_FIELDS[1]}"
SOURCE="approved-identity"

# Already mounted? Still verify the marker so a previously-mounted wrong drive
# doesn't pass through unchecked.
if [ "$MOUNT_STATE" = "MOUNTED" ]; then
    if [[ "$INIT_MARKER" == "true" ]]; then
        if [[ ! -f "$MARKER_FILE" ]]; then
            echo "Sandbox drive already mounted but marker missing. Creating $MARKER_FILE."
            printf 'Sandbox drive marker created %s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
            chmod 644 "$MARKER_FILE"
            log_mount "init=created-marker-on-already-mounted"
        else
            log_mount "init=marker-already-present"
        fi
        echo "Already mounted at $MOUNT_POINT (marker present)."
        exit 0
    fi
    if [[ ! -f "$MARKER_FILE" ]]; then
        echo "ERROR: $MOUNT_POINT is mounted but $MARKER_FILE is missing." >&2
        echo "       Refusing to proceed. The mounted device may be the wrong drive." >&2
        echo "       Unmount manually + run with --init if this is the correct drive." >&2
        log_mount "rejected=already-mounted-no-marker"
        exit 1
    fi
    log_mount "ok=already-mounted-marker-present"
    echo "Already mounted at $MOUNT_POINT (marker present)."
    exit 0
fi

if [ -L "$MOUNT_POINT" ]; then
    echo "ERROR: Sandbox mountpoint cannot be a symbolic link." >&2
    exit 1
fi

mkdir -p "$MOUNT_POINT"

echo "Mounting $EXTDEV (source=$SOURCE) at $MOUNT_POINT..."
mount -t ext4 -o defaults,noatime "$EXTDEV" "$MOUNT_POINT"

if ! mountpoint -q "$MOUNT_POINT"; then
    echo "ERROR: Mount failed for $EXTDEV." >&2
    log_mount "failed=mount-syscall-failed device=$EXTDEV source=$SOURCE"
    exit 1
fi

if ! POST_MOUNT_REPORT="$(verify_identity)"; then
    umount "$MOUNT_POINT"
    echo "ERROR: Mounted filesystem identity failed revalidation." >&2
    exit 1
fi
if ! POST_MOUNT_STATE="$(printf '%s' "$POST_MOUNT_REPORT" | /usr/bin/python3 -I -c '
import json, sys
value = json.load(sys.stdin)
if value.get("identityVerified") is not True or value.get("mountState") != "MOUNTED":
    raise SystemExit("Mounted identity is unverified")
print(value["mountState"])
')"; then
    umount "$MOUNT_POINT"
    echo "ERROR: Mounted identity response is invalid." >&2
    exit 1
fi
if [ "$POST_MOUNT_STATE" != "MOUNTED" ]; then
    umount "$MOUNT_POINT"
    echo "ERROR: Mount state failed exact verification." >&2
    exit 1
fi

# --- Marker verification (or creation) ---
if [[ "$INIT_MARKER" == "true" ]]; then
    if [[ ! -f "$MARKER_FILE" ]]; then
        printf 'Sandbox drive marker created %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
        chmod 644 "$MARKER_FILE"
        echo "Created $MARKER_FILE."
        log_mount "init=created-marker device=$EXTDEV source=$SOURCE"
    else
        log_mount "init=marker-already-present device=$EXTDEV source=$SOURCE"
    fi
    echo "SUCCESS: Mounted at $MOUNT_POINT (init complete)."
    exit 0
fi

# --mount-only: marker MUST be present
if [[ ! -f "$MARKER_FILE" ]]; then
    echo "ERROR: Mounted device $EXTDEV (source=$SOURCE) has no $MARKER_FILE." >&2
    echo "       Unmounting. This is the wrong drive, or it was never initialized with --init." >&2
    log_mount "rejected=no-marker device=$EXTDEV source=$SOURCE"
    umount "$MOUNT_POINT" 2>/dev/null || true
    exit 1
fi

log_mount "ok device=$EXTDEV source=$SOURCE"
echo "SUCCESS: Mounted at $MOUNT_POINT (marker verified)."
