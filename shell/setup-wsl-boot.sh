#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 -B "$SCRIPT_DIR/../scripts/provision-wsl-boot.py" "$@"
