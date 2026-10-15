#!/usr/bin/env bash
# shellcheck shell=bash
#
# bootstrap-wsl.sh: deprecation shim.
#
# Existing deployed clones and handoff instructions invoke this path directly
# (e.g. `bash ~/.revealui/bootstrap-wsl.sh`). This shim preserves that path
# while routing all execution to the cross-platform bootstrap.sh, the single
# maintained entry point, which auto-detects WSL via lib/platform.sh.
#
# This shim does not install a vendor policy home. bootstrap.sh writes the
# native control home at ~/.revealui. The workboard path is
# .revealui/workboard.md. Vendor homes are projections.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

printf 'bootstrap-wsl.sh is deprecated; delegating to the cross-platform bootstrap.sh (auto-detects WSL).\n' >&2

exec bash "$SCRIPT_DIR/bootstrap.sh" "$@"
