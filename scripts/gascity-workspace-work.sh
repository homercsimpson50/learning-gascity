#!/usr/bin/env bash
#
# gascity-workspace-work.sh — switch to DOCKER gas city and open its workspace.
#
# Single-command swap from whatever you were doing (home / nothing) to:
#   - Shim-aware backgrounded gc supervisor (agents run in scoped containers)
#   - iTerm2 layout against ~/gc-docker with mayor / shell / events feed,
#     painted in a desert color scheme so you can tell which workspace is
#     which at a glance.
#
# Internally:
#   1. Calls gascity-docker-start.sh which auto-stops the LOCAL launchd
#      supervisor first.
#   2. Calls gascity-docker-workspace.sh — the docker iTerm2 layout.
#
# Usage:
#   ./gascity-workspace-work.sh         # gc-feed-ai TUI in the bottom pane (default)
#   ./gascity-workspace-work.sh --raw   # raw JSON event stream

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -t 1 ]; then BOLD=$'\033[1m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'; else BOLD=''; GREEN=''; NC=''; fi

echo "${BOLD}→ Switching to DOCKER Gas City (work mode)${NC}"

# gascity-docker-start.sh auto-stops the local launchd supervisor first.
"$SCRIPT_DIR/gascity-docker-start.sh"

echo
echo "${BOLD}→ Opening docker workspace${NC}"
exec "$SCRIPT_DIR/gascity-docker-workspace.sh" "$@"
