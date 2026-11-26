# shellcheck shell=bash
# Shared silent Node initialization for interactive and BASH_ENV consumers.
# nvm owns the default; source it after generic user PATH additions.
revkit_node_env() {
    local manager="${REVKIT_NODE_MANAGER:-nvm}"
    case "$manager" in
        nvm)
            # Retained fnm installations stay available for recovery, but their
            # inherited multishell/version pins must not select this shell.
            local entry cleaned="" remaining="$PATH:"
            while [ -n "$remaining" ]; do
                entry="${remaining%%:*}"
                remaining="${remaining#*:}"
                case "$entry" in
                    "$HOME/.local/share/fnm"|"$HOME/.local/share/fnm/"*|"$HOME/.local/state/fnm_multishells/"*) continue ;;
                esac
                cleaned="${cleaned:+$cleaned:}$entry"
            done
            export PATH="$cleaned"
            export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
            if [ -s "$NVM_DIR/nvm.sh" ]; then
                . "$NVM_DIR/nvm.sh" --no-use
                nvm use --silent default >/dev/null || return
            else
                printf 'revkit: requested nvm installation is missing: %s\n' "$NVM_DIR" >&2
                return 1
            fi
            ;;
        fnm)
            command -v fnm >/dev/null 2>&1 || return 1
            eval "$(fnm env)"
            ;;
        system) ;;
        *) printf 'revkit: unsupported Node manager: %s\n' "$manager" >&2; return 1 ;;
    esac
}
