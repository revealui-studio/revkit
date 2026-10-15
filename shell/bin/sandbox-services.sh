#!/bin/bash
# Sandbox infrastructure service manager
# Installed to /usr/local/bin/ by bootstrap.sh
# Shell alias: sandbox() in bashrc.d/15-docker.sh

set -euo pipefail

COMPOSE_DIR="${REVEALUI_ROOT:?REVEALUI_ROOT not set. Run bootstrap.sh, then source ~/.bashrc, or set explicitly}/shell/docker"
COMPOSE_FILE="$COMPOSE_DIR/compose.yml"

# --- Helpers ---

die() { echo "error: $*" >&2; exit 1; }

require_tier() {
    if [ "${DEVKIT_TIER:-T0}" = "T0" ]; then
        die "Sandbox drive not mounted (tier T0). Mount it first: mount-sandbox-drive.sh"
    fi
}

ensure_docker() {
    if ! command -v docker &>/dev/null; then
        die "docker not found. Install Docker Engine first."
    fi
    if ! docker info &>/dev/null 2>&1; then
        # setup-wsl-boot.sh disables docker.service at boot but deliberately
        # leaves docker.socket ENABLED, so a `docker` call is normally
        # socket-activated with no manual start. If the socket is not active
        # (boot optimization not applied), fall back to starting the service,
        # but never block on an interactive sudo password prompt: use `sudo -n`
        # and fail fast with remediation when passwordless sudo is unavailable.
        echo "Starting Docker daemon..."
        if ! sudo -n systemctl start docker 2>/dev/null; then
            if [ ! -t 0 ]; then
                die "Docker is not running and could not be started non-interactively. Enable socket activation once (\`sudo systemctl enable --now docker.socket\`) or start it interactively (\`sudo systemctl start docker\`), then re-run."
            fi
            die "Docker is not running and \`sudo -n systemctl start docker\` failed (no passwordless sudo). Start it with \`sudo systemctl start docker\`, or enable socket activation: \`sudo systemctl enable --now docker.socket\`."
        fi
        # Wait for daemon to be ready
        local retries=10
        while ! docker info &>/dev/null 2>&1; do
            retries=$((retries - 1))
            if [ "$retries" -le 0 ]; then
                die "Docker daemon failed to start"
            fi
            sleep 1
        done
    fi
}

compose() {
    docker compose -f "$COMPOSE_FILE" "$@"
}

usage() {
    cat <<EOF
Sandbox infrastructure manager

Usage: sandbox <command> [options]

Commands:
  up [--ai]      Start services (add --ai for Ollama)
  down           Stop all services
  status         Show container status and health
  logs [service] Tail logs (optionally for a specific service)
  pull           Pull latest images
  psql [args]    Connect to Postgres via psql
  redis-cli      Connect to Redis via redis-cli
  validate       Run environment health checks
  help           Show this help message
EOF
}

# --- Commands ---

cmd_up() {
    require_tier
    ensure_docker

    if [ ! -f "$COMPOSE_FILE" ]; then
        die "Compose file not found: $COMPOSE_FILE"
    fi

    local profiles=()
    for arg in "$@"; do
        case "$arg" in
            --ai|ai) profiles+=(--profile ai) ;;
            *) die "Unknown option: $arg" ;;
        esac
    done

    echo "Starting Sandbox services..."
    if [ ${#profiles[@]} -gt 0 ]; then
        compose "${profiles[@]}" up -d
    else
        compose up -d
    fi
    echo ""
    compose ps
}

cmd_down() {
    ensure_docker
    echo "Stopping Sandbox services..."
    compose --profile ai down
}

cmd_status() {
    ensure_docker
    compose ps -a
}

cmd_logs() {
    ensure_docker
    if [ $# -gt 0 ]; then
        compose logs -f "$1"
    else
        compose logs -f
    fi
}

cmd_pull() {
    ensure_docker
    echo "Pulling latest images..."
    compose --profile ai pull
}

cmd_psql() {
    ensure_docker
    # POSTGRES_USER/DB are exported by the sandbox() wrapper from shell/docker/.env
    # (point-of-use scoping); forward the password into the container so a
    # password-auth Postgres accepts the connection (ignored under trust auth).
    # Password comes from the caller (the sandbox() wrapper reads shell/docker/.env).
    # Do not invent a well-known password when it is unset.
    if [ -n "${PGPASSWORD:-}" ]; then
        docker exec -e PGPASSWORD="$PGPASSWORD" -it sandbox-postgres psql -U "${POSTGRES_USER:-sandbox}" -d "${POSTGRES_DB:-sandbox}" "$@"
    else
        docker exec -it sandbox-postgres psql -U "${POSTGRES_USER:-sandbox}" -d "${POSTGRES_DB:-sandbox}" "$@"
    fi
}

cmd_redis_cli() {
    ensure_docker
    docker exec -it sandbox-redis redis-cli "$@"
}

# --- Main ---

if [ $# -eq 0 ]; then
    usage
    exit 0
fi

command="$1"
shift

case "$command" in
    up)        cmd_up "$@" ;;
    down)      cmd_down ;;
    status)    cmd_status ;;
    logs)      cmd_logs "$@" ;;
    pull)      cmd_pull ;;
    psql)      cmd_psql "$@" ;;
    redis-cli) cmd_redis_cli "$@" ;;
    validate)  exec /usr/local/bin/sandbox-validate.sh "$@" ;;
    help|-h|--help) usage ;;
    *)         die "Unknown command: $command. Run 'sandbox help' for usage." ;;
esac
