# shellcheck shell=bash
# Sandbox Docker infrastructure helpers

# Main CLI builds the DB URL at call time (not at shell startup) so credentials
# are never broadcast into the global interactive environment.
sandbox() {
    local script="/usr/local/bin/sandbox-services.sh"
    if [ ! -x "$script" ]; then
        echo "sandbox-services.sh not installed. Run bootstrap." >&2
        return 1
    fi
    local _denv="${REVEALUI_ROOT}/shell/docker/.env"
    local _u="" _p="" _d="" _user _db _dburl
    if [ -f "$_denv" ]; then
        _u=$(grep '^POSTGRES_USER=' "$_denv" | cut -d= -f2- | tr -d '"')
        _p=$(grep '^POSTGRES_PASSWORD=' "$_denv" | cut -d= -f2- | tr -d '"')
        _d=$(grep '^POSTGRES_DB=' "$_denv" | cut -d= -f2- | tr -d '"')
    fi
    _user="${_u:-sandbox}"
    _db="${_d:-sandbox}"
    # No password in the URL unless .env actually set one. A missing file must
    # not fall back to the well-known string "sandbox".
    if [ -n "$_p" ]; then
        _dburl="postgresql://${_user}:${_p}@localhost:5433/${_db}"
    else
        _dburl="postgresql://${_user}@localhost:5433/${_db}"
    fi
    SANDBOX_DATABASE_URL="$_dburl" \
    SANDBOX_REDIS_URL="redis://localhost:6380" \
    POSTGRES_USER="$_user" \
    POSTGRES_DB="$_db" \
    PGPASSWORD="$_p" \
    "$script" "$@"
}

export SANDBOX_REDIS_URL="redis://localhost:6380"
