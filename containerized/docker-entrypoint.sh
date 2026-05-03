#!/bin/sh
# Container entrypoint for the gascity image.
#
# Responsibilities, in order:
#   1. Apply git/dolt config from env vars (idempotent every start).
#   2. Start D-Bus + GNOME Keyring so Claude Code can persist credentials
#      via libsecret instead of re-prompting on each container boot.
#   3. Sync host ~/.claude (read-only mount) into the writable home volume
#      so Max subscription / OAuth carries over without browser re-login.
#   4. Sync host ~/.config/gh hosts.yml so `git push` from agents works.
#   5. Run `gc init` once to materialize the city scaffold; on subsequent
#      starts, skip and continue.
#   6. Exec the container CMD (default: `gc supervisor run`).

set -e

# --- 1. Git / Dolt identity ---
if [ -n "$GIT_USER" ] && [ -n "$GIT_EMAIL" ]; then
    git config --global user.name  "$GIT_USER"
    git config --global user.email "$GIT_EMAIL"
    git config --global credential.helper store
    dolt config --global --add user.name  "$GIT_USER"
    dolt config --global --add user.email "$GIT_EMAIL"
fi

# --- 2. D-Bus + GNOME Keyring (for Claude Code on Linux) ---
if command -v gnome-keyring-daemon >/dev/null 2>&1; then
    if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
        eval "$(dbus-launch --sh-syntax)" 2>/dev/null || true
        export DBUS_SESSION_BUS_ADDRESS
    fi
    eval "$(printf '' | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)" || true
    export GNOME_KEYRING_CONTROL
    export SSH_AUTH_SOCK
    if [ -n "$CLAUDE_ENV_FILE" ]; then
        cat >> "$CLAUDE_ENV_FILE" <<ENVEOF
export DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
export GNOME_KEYRING_CONTROL="${GNOME_KEYRING_CONTROL:-}"
ENVEOF
    fi
fi

# --- 3. Host Claude config sync (read-only staging → writable home) ---
CLAUDE_HOST="/home/agent/.claude-host"
CLAUDE_HOME="/home/agent/.claude"
if [ -d "$CLAUDE_HOST" ]; then
    mkdir -p "$CLAUDE_HOME"
    for f in settings.json settings.local.json .credentials.json; do
        if [ -f "$CLAUDE_HOST/$f" ] && [ ! -f "$CLAUDE_HOME/$f" ]; then
            cp "$CLAUDE_HOST/$f" "$CLAUDE_HOME/$f"
        fi
    done
    if [ -d "$CLAUDE_HOST/projects" ] && [ ! -d "$CLAUDE_HOME/projects" ]; then
        cp -r "$CLAUDE_HOST/projects" "$CLAUDE_HOME/projects"
    fi
fi

# --- 4. Host gh CLI credentials sync (for git push from agents) ---
GH_HOST="/home/agent/.config/gh-host"
GH_HOME="/home/agent/.config/gh"
if [ -d "$GH_HOST" ] && [ -f "$GH_HOST/hosts.yml" ]; then
    mkdir -p "$GH_HOME"
    if [ ! -f "$GH_HOME/hosts.yml" ]; then
        cp "$GH_HOST/hosts.yml" "$GH_HOME/hosts.yml"
    fi
    gh auth setup-git 2>/dev/null || true
fi

# --- 5. One-time city scaffold via `gc init` ---
if [ ! -f /city/city.toml ]; then
    echo "[entrypoint] Initializing Gas City workspace at /city (provider=${GC_PROVIDER:-claude-code})..."
    cd /city && gc init --provider "${GC_PROVIDER:-claude-code}" .
else
    echo "[entrypoint] Gas City workspace already initialized at /city."
fi

exec "$@"
