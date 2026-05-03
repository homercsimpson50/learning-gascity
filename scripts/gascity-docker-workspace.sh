#!/usr/bin/env bash
#
# Gas City *Docker* iTerm2 Workspace Launcher
#
# Sister script to gascity-workspace.sh, but for the work-machine
# (containerized) flow. Spawns gc-docker so agents run in scoped
# Docker containers, and paints all panes in a desert color scheme so
# you can tell at a glance which workspace is which.
#
# Layout (mirrors the local one):
#   ┌──────────┬─────────────────────┐
#   │          │ docker-shell        │
#   │  docker- │ (cd'd to city)      │
#   │  super   ├─────────────────────┤
#   │  (tall)  │ docker-feed         │
#   │          │ (gc events --follow)│
#   └──────────┴─────────────────────┘
#
# Left tall pane:    gc-docker supervisor run  (foreground supervisor)
# Top-right pane:    blank shell, cd'd to the city
# Bottom-right pane: gc events --follow  (or gc-feed-ai with --ai)
#
# Knobs (env vars):
#   GC_DOCKER_CITY   path to the city (default: $HOME/gc-docker)
#                    auto-init'd via `gc-docker init --provider claude`
#                    if it doesn't exist yet.
#
# Usage:
#   ./gascity-docker-workspace.sh         # plain feed in the bottom pane
#   ./gascity-docker-workspace.sh --ai    # bottom pane runs gc-feed-ai

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

USE_AI=0
if [ "${1:-}" = "--ai" ]; then
    USE_AI=1
fi

if [ "$USE_AI" -eq 1 ] && [ ! -x "$SCRIPT_DIR/gc-feed-ai" ]; then
    echo "error: $SCRIPT_DIR/gc-feed-ai not found or not executable" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Pre-flight: gc-docker must be installed.
# ---------------------------------------------------------------------------
if ! command -v gc-docker >/dev/null 2>&1; then
    echo "error: 'gc-docker' not on PATH" >&2
    echo "       run learning-gascity/containerized/install.sh first" >&2
    exit 1
fi

CITY="${GC_DOCKER_CITY:-$HOME/gc-docker}"

# Auto-init the city if missing. Init doesn't spawn agents so it's safe
# to do here without the supervisor.
if [ ! -f "$CITY/city.toml" ]; then
    echo "→ initializing city at $CITY (one-time)"
    gc-docker init --provider claude --skip-provider-readiness "$CITY"
fi

# ---------------------------------------------------------------------------
# Pane commands.
# ---------------------------------------------------------------------------
SUPERVISOR_CMD="cd $CITY && gc-docker supervisor run"
SHELL_CMD="cd $CITY"
if [ "$USE_AI" -eq 1 ]; then
    FEED_CMD="cd $CITY && $SCRIPT_DIR/gc-feed-ai"
else
    FEED_CMD="cd $CITY && gc events --follow"
fi

# ---------------------------------------------------------------------------
# Desert color preset (16-bit RGB values per iTerm2's AppleScript model).
#   Background: deep coffee ~ RGB(40, 30, 20)
#   Foreground: warm cream  ~ RGB(230, 200, 150)
# Distinct enough from the user's default profile that you can't mix the
# Docker workspace up with the local one.
# ---------------------------------------------------------------------------
BG_COLOR="{10240, 7680, 5120}"
FG_COLOR="{58880, 51200, 38400}"

osascript <<APPLESCRIPT
tell application "iTerm2"
    activate
    create window with default profile

    tell current tab of current window
        -- Step 1: split left (supervisor) | right
        tell current session
            set name to "docker-supervisor"
            set background color to $BG_COLOR
            set foreground color to $FG_COLOR
            set rightPane to (split vertically with default profile)
        end tell

        -- Step 2: split right horizontally → top-right + bottom-right
        tell rightPane
            set name to "docker-shell"
            set background color to $BG_COLOR
            set foreground color to $FG_COLOR
            set feedPane to (split horizontally with default profile)
        end tell

        tell feedPane
            set name to "docker-feed"
            set background color to $BG_COLOR
            set foreground color to $FG_COLOR
        end tell

        -- Make the top-right shell pane small so the feed gets ~3/4 of
        -- the right column.
        try
            tell rightPane to set rows to 8
        end try

        -- Send commands. Top-right is just an open shell at the city dir.
        tell current session
            write text "$SUPERVISOR_CMD"
        end tell
        tell rightPane
            write text "$SHELL_CMD"
        end tell
        tell feedPane
            write text "$FEED_CMD"
        end tell
    end tell

    -- Resize window (centered for 1440x900). Slightly offset from where
    -- the local workspace lands so they don't overlap perfectly when
    -- both are open.
    set bounds of current window to {120, 90, 1416, 900}
end tell
APPLESCRIPT

echo "Gas City *Docker* workspace launched at $CITY"
