# shellcheck shell=bash
# with-secrets <ns...> -- <cmd> [args...]
#
# Runs <cmd> with revvault secrets from the given revealui/env/<ns> namespaces
# loaded into the child process environment only. Nothing leaks back to the
# calling shell. Prefer this (or `revvault run`) on stream, never
# $(revvault get) inside CLI flags (pnpm prints argv).
#
# Usage examples:
#   with-secrets stripe -- pnpm dev:api
#   with-secrets core stripe neon -- pnpm test:integration
#   with-secrets npm -- pnpm changeset:publish
#   with-secrets core -- pnpm kek:rotate
#   with-secrets license -- pnpm test          # public license key only (GAP-260 P2-2)
#   REVVAULT_ALLOW_PRIVATE=1 with-secrets license-signing -- pnpm tsx scripts/setup/issue-revforge-license.ts
#
# When `revvault run` supports --namespace (stream-safe secrets), prefer:
#   revvault run --namespace stripe --namespace neon -- pnpm …
#
# GAP-260 P2-2 license namespaces:
#   license          → revealui/env/license (public SPKI only) via export-env --public-only
#   license-signing  → revealui/env/license-signing (private PKCS#8); requires REVVAULT_ALLOW_PRIVATE=1
with-secrets() {
    if [[ $# -eq 0 ]]; then
        printf 'usage: with-secrets <ns...> -- <cmd> [args...]\n' >&2
        return 1
    fi

    local nses=()
    local cmd=()
    local past_sep=0

    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then
            past_sep=1
            continue
        fi
        if [[ $past_sep -eq 1 ]]; then
            cmd+=("$arg")
        else
            nses+=("$arg")
        fi
    done

    if [[ ${#nses[@]} -eq 0 ]]; then
        printf 'with-secrets: no namespaces given before --\n' >&2
        return 1
    fi

    if [[ ${#cmd[@]} -eq 0 ]]; then
        printf 'with-secrets: no command given after --\n' >&2
        return 1
    fi

    local ns
    for ns in "${nses[@]}"; do
        # One vault path segment. A slash or ".." would select a different
        # store entry, and that entry's export is eval'd below.
        case "$ns" in
            ''|-*|*[!A-Za-z0-9_-]*)
                printf 'with-secrets: namespace must be one identifier of letters, digits, underscore, or hyphen (got %s)\n' "$ns" >&2
                return 1
                ;;
        esac
    done

    local rv
    rv="$(command -v revvault 2>/dev/null)"
    if [[ -z "$rv" ]]; then
        printf 'with-secrets: revvault not found in PATH\n' >&2
        return 1
    fi

    # Prefer native revvault run when it accepts --namespace (stream-safe path).
    if "$rv" run --help 2>&1 | grep -q -- '--namespace'; then
        local run_args=()
        local ns
        for ns in "${nses[@]}"; do
            run_args+=(--namespace "$ns")
        done
        exec "$rv" run "${run_args[@]}" -- "${cmd[@]}"
    fi

    local out
    (
        for ns in "${nses[@]}"; do
            # Fail closed. A nonexistent/typo'd namespace, a locked age key, or
            # any other revvault error exits nonzero here. Do NOT swallow it
            # (no 2>/dev/null, no `|| true`): swallowing would let exec run the
            # command with NO secrets loaded, silently. A prod-shaped command
            # stripped of its credentials. Abort the subshell so the caller
            # sees a nonzero status and the command never runs.
            case "$ns" in
                license-signing)
                    if [[ "${REVVAULT_ALLOW_PRIVATE:-}" != "1" ]]; then
                        printf 'with-secrets: namespace license-signing requires REVVAULT_ALLOW_PRIVATE=1 (GAP-260 P2-2)\n' >&2
                        exit 1
                    fi
                    if ! out="$("$rv" export-env "revealui/env/license-signing")"; then
                        printf 'with-secrets: failed to load namespace %s\n' "$ns" >&2
                        exit 1
                    fi
                    ;;
                license)
                    # Public-only: refuses private PEM even if the vault path is mis-filled.
                    if ! out="$("$rv" export-env --public-only "revealui/env/license")"; then
                        printf 'with-secrets: failed to load namespace %s (public-only)\n' "$ns" >&2
                        exit 1
                    fi
                    ;;
                *)
                    if ! out="$("$rv" export-env "revealui/env/$ns")"; then
                        printf 'with-secrets: failed to load namespace %s\n' "$ns" >&2
                        exit 1
                    fi
                    ;;
            esac
            eval "$out"
        done
        exec "${cmd[@]}"
    )
}
