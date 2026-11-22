#!/usr/bin/env bash
# commit-msg hook helper for the client-name watchlist gate.
#
# Reads the proposed commit message (git's commit-msg path argument) and
# runs scripts/check-no-client-names.sh --message-file. Same watchlist load
# order and exit codes as the file gate. Inactive (WARN, exit 0) when no
# local watchlist, CLIENT_NAME_WATCHLIST_FILE, or CLIENT_NAME_PATTERNS is set.
# Set CLIENT_NAME_WATCHLIST_REQUIRED=1 to fail closed (exit 2) instead.
#
# This helper is opt-in. Bootstrap and git-hooks/ do not install it.
# Do not commit real watchlist terms.
#
# Wire locally:
#   ln -sfn ../../scripts/hooks/commit-msg-client-names.sh .git/hooks/commit-msg
#
# Husky (.husky/commit-msg):
#   bash scripts/hooks/commit-msg-client-names.sh "$1"
#
# Lefthook (lefthook.yml):
#   commit-msg:
#     commands:
#       client-names:
#         run: bash scripts/hooks/commit-msg-client-names.sh {1}
#
# Design: docs/client-name-public-github.md

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MSG_FILE="${1:-}"

if [[ -z "$MSG_FILE" ]]; then
  echo "[client-name-check] error: commit-msg hook requires the message file path" >&2
  echo "[client-name-check] usage: bash scripts/hooks/commit-msg-client-names.sh <message-file>" >&2
  exit 2
fi

if [[ ! -f "$MSG_FILE" ]]; then
  echo "[client-name-check] error: commit message file not found: $MSG_FILE" >&2
  exit 2
fi

exec bash "$REPO_ROOT/scripts/check-no-client-names.sh" --message-file "$MSG_FILE"
