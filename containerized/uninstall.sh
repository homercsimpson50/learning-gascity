#!/usr/bin/env bash
# uninstall.sh — reverse install.sh.
#
# Removes:
#   - shim files at ~/.local/bin/gascity-shims/
#   - the gc-docker wrapper at ~/.local/bin/gc-docker
#   - any leftover marker-fenced PATH block in your shell rc (from older
#     versions of install.sh that did pollute PATH — current versions
#     don't, so this is just for cleanup).
#
# Preserves (delete by hand if you want them gone):
#   - The agent image (`docker rmi gascity-agent-runner:claude`).
#   - Your config at ~/.config/gascity-docker-runner/config.toml.
#   - Session logs at ~/.local/state/gascity-docker-runner/logs/.

set -euo pipefail

SHIM_BIN_DIR="$HOME/.local/bin/gascity-shims"
WRAPPER_BIN="$HOME/.local/bin/gc-docker"
say()  { printf '\e[1;36m→\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m✓\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m⚠\e[0m %s\n' "$*"; }

# An older revision of install.sh used to symlink ~/.local/bin/claude to
# the shim. Current install.sh doesn't, but if a user is uninstalling on
# a machine that ran the older script, restore the host claude binary
# from the .real-claude sidecar before removing the shim.
USER_CLAUDE="$HOME/.local/bin/claude"
REAL_CLAUDE_SIDECAR="$SHIM_BIN_DIR/.real-claude"
if [ -L "$USER_CLAUDE" ] && [ "$(readlink "$USER_CLAUDE")" = "$SHIM_BIN_DIR/gc-docker-runner" ]; then
    if [ -s "$REAL_CLAUDE_SIDECAR" ] && [ -x "$(cat "$REAL_CLAUDE_SIDECAR")" ]; then
        REAL="$(cat "$REAL_CLAUDE_SIDECAR")"
        ln -sf "$REAL" "$USER_CLAUDE"
        ok "Restored $USER_CLAUDE → $REAL (from .real-claude sidecar)"
    else
        warn "$USER_CLAUDE points at shim but .real-claude is missing — leaving it; reinstall claude to fix"
    fi
fi

# Shim + symlinks + wrapper + workspace launcher symlink
say "Removing shim, wrapper, and workspace launcher"
rm -f "$SHIM_BIN_DIR/gc-docker-runner" \
      "$SHIM_BIN_DIR/claude" \
      "$SHIM_BIN_DIR/codex" \
      "$SHIM_BIN_DIR/gemini" \
      "$SHIM_BIN_DIR/.real-claude" \
      "$SHIM_BIN_DIR/.real-codex" \
      "$SHIM_BIN_DIR/.real-gemini"
rmdir "$SHIM_BIN_DIR" 2>/dev/null || true
rm -f "$WRAPPER_BIN" \
      "$HOME/.local/bin/gc-workspace.sh" \
      "$HOME/.local/bin/gc-docker-start.sh" \
      "$HOME/.local/bin/gc-docker-stop.sh" \
      "$HOME/.local/bin/gc-broker-creds-extract.sh" \
      "$HOME/.local/bin/gc-workspace-home.sh" \
      "$HOME/.local/bin/gc-workspace-work.sh" \
      "$HOME/.local/bin/gc-workspace-home.py" \
      "$HOME/.local/bin/gc-workspace-work.py"
ok "Shim, wrapper, start/stop, and mode-swap launchers removed"
# (gc-workspace.sh deliberately removed too — it was the old ambiguous
# alias; explicit gc-workspace-home/work scripts replace it.)

# Shell rc cleanup — strip any leftover marker-fenced PATH block.
detect_rc() {
    case "${SHELL##*/}" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash) [ -f "$HOME/.bashrc" ] && echo "$HOME/.bashrc" || echo "$HOME/.bash_profile" ;;
        *)    echo "$HOME/.profile" ;;
    esac
}
RC="$(detect_rc)"
if [ -f "$RC" ] && grep -qF '# >>> learning-gascity shim PATH' "$RC"; then
    say "Removing leftover PATH lines from $RC (older install.sh used to add them)"
    awk '
        /^# >>> learning-gascity shim PATH/ {skip=1; next}
        /^# <<< learning-gascity shim PATH/ {skip=0; next}
        !skip {print}
    ' "$RC" > "$RC.uninstall.tmp"
    mv "$RC.uninstall.tmp" "$RC"
    ok "PATH lines removed from $RC"
else
    ok "$RC has no learning-gascity PATH lines (nothing to clean)"
fi

# Stop & remove v2 broker containers if running, then their networks/volume.
say "Cleaning up v2 broker runtime state"
for broker in gc-broker-anthropic gc-broker-github-api gc-broker-github-ssh; do
    if docker ps --format '{{.Names}}' | grep -qx "$broker"; then
        docker stop --time=5 "$broker" >/dev/null 2>&1 || true
        ok "Stopped $broker"
    fi
done
docker network rm gc-broker-net gc-egress-net 2>/dev/null && \
    ok "Removed networks gc-broker-net + gc-egress-net" || \
    ok "Networks already absent (or in use)"
docker volume rm gc-sshagent-sock 2>/dev/null && \
    ok "Removed volume gc-sshagent-sock" || \
    ok "Volume gc-sshagent-sock already absent (or in use)"

echo
printf '\e[1;32m✓ Uninstalled.\e[0m\n\n'
cat <<EOF
Preserved (delete by hand if you want them gone):
    docker rmi gascity-agent-runner:claude
    docker rmi gascity-broker-anthropic:v1 gascity-broker-github-api:v1 gascity-broker-github-ssh:v1
    rm -rf ~/.config/gascity-docker-runner
    rm -rf ~/.local/state/gascity-docker-runner
    rm -rf ~/.local/state/gascity-broker
EOF
