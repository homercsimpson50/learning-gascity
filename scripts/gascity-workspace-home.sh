#!/usr/bin/env bash
#
# gascity-workspace-home.sh — switch to LOCAL gas city and open its workspace.
#
# Single-command swap from whatever you were doing (work / nothing) to:
#   - Local launchd-managed gc supervisor (no agent isolation, full host access)
#   - iTerm2 layout against ~/gc with mayor / shell / events feed
#
# Internally:
#   1. Calls gascity-stop.sh? No — gascity-start.sh already auto-stops the
#      Docker supervisor first if it's running. So we just call start.
#   2. Calls gascity-workspace.sh, which is the home iTerm2 layout.
#
# Usage:
#   ./gascity-workspace-home.sh         # plain feed
#   ./gascity-workspace-home.sh --ai    # bottom pane runs gc-feed-ai

set -euo pipefail

# Resolve symlinks so SCRIPT_DIR points at the real scripts/ dir (this file
# is typically reached via ~/.local/bin/gc-workspace-home.sh → scripts/…).
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null && pwd)"

if [ -t 1 ]; then BOLD=$'\033[1m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'; else BOLD=''; GREEN=''; NC=''; fi

echo "${BOLD}→ Switching to LOCAL Gas City (home mode)${NC}"

# gascity-start.sh auto-stops the Docker supervisor if it's running.
"$SCRIPT_DIR/gascity-start.sh"

echo
echo "${BOLD}→ Opening home workspace${NC}"
exec "$SCRIPT_DIR/gascity-workspace.sh" "$@"
