#!/usr/bin/env bash
# uninstall.sh — reverse install.sh.
#
# Removes:
#   - shim binary + symlinks at ~/.local/bin/gascity-shims/
#   - the PATH lines install.sh added to your shell rc (matched by markers)
#
# Preserves (delete by hand if you want them gone):
#   - The agent image (`docker rmi gascity-agent-runner:claude`).
#   - Your config at ~/.config/gascity-docker-runner/config.toml.
#   - Session logs at ~/.local/state/gascity-docker-runner/logs/.

set -euo pipefail

SHIM_BIN_DIR="$HOME/.local/bin/gascity-shims"
say()  { printf '\e[1;36m→\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m✓\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m⚠\e[0m %s\n' "$*"; }

# Shim + symlinks
say "Removing $SHIM_BIN_DIR"
rm -f "$SHIM_BIN_DIR/gc-docker-runner" \
      "$SHIM_BIN_DIR/claude" \
      "$SHIM_BIN_DIR/codex" \
      "$SHIM_BIN_DIR/gemini"
rmdir "$SHIM_BIN_DIR" 2>/dev/null || true
ok "Shim removed"

# Shell rc cleanup — strip the marker-fenced block
detect_rc() {
    case "${SHELL##*/}" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash) [ -f "$HOME/.bashrc" ] && echo "$HOME/.bashrc" || echo "$HOME/.bash_profile" ;;
        *)    echo "$HOME/.profile" ;;
    esac
}
RC="$(detect_rc)"
if [ -f "$RC" ] && grep -qF '# >>> learning-gascity shim PATH' "$RC"; then
    say "Removing PATH lines from $RC"
    # POSIX sed -i differs between BSD (mac) and GNU; use a tmp file for portability.
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
printf '\e[1;32m✓ Uninstalled.\e[0m  Open a new terminal so the PATH change takes effect.\n\n'
cat <<EOF
Preserved (delete by hand if you want them gone):
    docker rmi gascity-agent-runner:claude
    rm -rf ~/.config/gascity-docker-runner
    rm -rf ~/.local/state/gascity-docker-runner
EOF
