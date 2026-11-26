# shellcheck shell=bash
# Discover the existing native user-manager bus; never start a manager or copy
# another platform's session variables into this process.
revkit_native_session_env() {
    [ "$(uname -s)" = Linux ] || return 0
    local uid runtime owner
    uid="$(id -u)" || return
    runtime="${XDG_RUNTIME_DIR:-/run/user/$uid}"
    [ -d "$runtime" ] || return 0
    owner="$(stat -c %u "$runtime" 2>/dev/null)" || return 0
    [ "$owner" = "$uid" ] || return 0
    [ -n "${XDG_RUNTIME_DIR:-}" ] || export XDG_RUNTIME_DIR="$runtime"
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$runtime/bus" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus"
    fi
}
