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

# Shim + symlinks + wrapper
say "Removing shim and wrapper"
rm -f "$SHIM_BIN_DIR/gc-docker-runner" \
      "$SHIM_BIN_DIR/claude" \
      "$SHIM_BIN_DIR/codex" \
      "$SHIM_BIN_DIR/gemini"
rmdir "$SHIM_BIN_DIR" 2>/dev/null || true
rm -f "$WRAPPER_BIN"
ok "Shim and wrapper removed"

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

echo
printf '\e[1;32m✓ Uninstalled.\e[0m\n\n'
cat <<EOF
Preserved (delete by hand if you want them gone):
    docker rmi gascity-agent-runner:claude
    rm -rf ~/.config/gascity-docker-runner
    rm -rf ~/.local/state/gascity-docker-runner
EOF
