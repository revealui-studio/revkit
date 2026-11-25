# shellcheck shell=bash
# Tool initialization: direnv, Node, bun, rust, go, pulumi, pip

# Zig / user bin
[ -d "$HOME/bin" ] && export PATH="$HOME/bin:$PATH"

# direnv
if command -v direnv &>/dev/null; then
    eval "$(direnv hook bash)"
    export DIRENV_LOG_FORMAT=""
    export DIRENV_WARN_TIMEOUT=""
fi

# bun
export BUN_INSTALL="$HOME/.bun"
[ -d "$BUN_INSTALL/bin" ] && export PATH="$BUN_INSTALL/bin:$PATH"

# rust / cargo (must precede 60-license.sh which calls `command -v revvault`)
[ -d "$HOME/.cargo/bin" ] && export PATH="$HOME/.cargo/bin:$PATH"

# go
[ -d "$HOME/go-install/go/bin" ] && export PATH="$PATH:$HOME/go-install/go/bin"

# pulumi
[ -d "$HOME/.pulumi/bin" ] && export PATH="$PATH:$HOME/.pulumi/bin"

# pip
export PIP_DEFAULT_TIMEOUT=300
export PIP_RETRIES=10

# local bin
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"

# Share the same selector with the maintained noninteractive environment.
# Run last so generic user PATH entries cannot shadow nvm's default.
if [ -r "${REVEALUI_ROOT:-}/shell/lib/node-env.sh" ]; then
    . "$REVEALUI_ROOT/shell/lib/node-env.sh"
    revkit_node_env
elif [ -r "$HOME/.config/shell/node-env.sh" ]; then
    . "$HOME/.config/shell/node-env.sh"
    revkit_node_env
fi
