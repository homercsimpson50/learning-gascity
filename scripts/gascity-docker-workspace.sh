#!/usr/bin/env bash
#
# Gas City *Docker* iTerm2 Workspace Launcher.
#
# Mirrors gascity-workspace.sh exactly — same 3-pane layout, same
# pane contents — but routes the supervisor through gc-docker so
# spawned agents land in scoped Docker containers. Painted in a
# desert color scheme so this workspace can't be confused with the
# local (host-agent) one.
#
# Layout:
#   ┌──────────┬─────────────────────┐
#   │          │ shell (interactive) │
#   │  docker  │                     │
#   │  mayor   ├─────────────────────┤
#   │  (tall)  │ feed (gc-feed-ai)   │
#   │          │                     │
#   └──────────┴─────────────────────┘
#
# Left tall pane:    docker mayor (gc session attach mayor against the shim-aware supervisor)
# Top-right pane:    blank interactive shell, cd'd to the city
# Bottom-right pane: gc-feed-ai by default (TUI). Pass --raw for plain `gc events --follow`.
#
# Knobs:
#   GC_DOCKER_CITY   path to the city (default: $HOME/gc-docker)
#
# Usage:
#   ./gascity-docker-workspace.sh           # gc-feed-ai TUI in the bottom pane
#   ./gascity-docker-workspace.sh --raw     # raw JSON event stream

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

USE_RAW=0
if [ "${1:-}" = "--raw" ]; then
    USE_RAW=1
fi

CITY="${GC_DOCKER_CITY:-$HOME/gc-docker}"

# --- Pre-flight ------------------------------------------------------------
if ! command -v gc-docker >/dev/null 2>&1; then
    echo "error: 'gc-docker' not on PATH" >&2
    echo "       run learning-gascity/containerized/install.sh first" >&2
    exit 1
fi
if [ ! -x "$SCRIPT_DIR/gc-feed-ai" ] && [ "$USE_RAW" -eq 0 ]; then
    echo "warning: $SCRIPT_DIR/gc-feed-ai missing — falling back to raw events" >&2
    USE_RAW=1
fi

# --- Pane commands (mirror local layout) -----------------------------------
DOCKER_MAYOR="cd $CITY && $SCRIPT_DIR/gascity-docker-start.sh && gc session attach mayor"
SHELL_CMD="cd $CITY"
if [ "$USE_RAW" -eq 1 ]; then
    FEED_CMD="cd $CITY && gc events --follow"
else
    FEED_CMD="cd $CITY && $SCRIPT_DIR/gc-feed-ai"
fi

# --- Desert color scheme (16-bit RGB per iTerm2 AppleScript) ---------------
# Background: deep coffee  ~ RGB(40, 30, 20)
# Foreground: warm cream   ~ RGB(230, 200, 150)
BG_COLOR="{10240, 7680, 5120}"
FG_COLOR="{58880, 51200, 38400}"

osascript <<APPLESCRIPT
tell application "iTerm2"
    activate
    create window with default profile

    tell current tab of current window
        -- Step 1: split left (docker mayor) | right
        tell current session
            set name to "docker-mayor"
            set background color to $BG_COLOR
            set foreground color to $FG_COLOR
            set rightPane to (split vertically with default profile)
        end tell

        -- Step 2: split right horizontally → top-right shell + bottom-right feed
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

        -- Make the top-right shell pane small so feed gets ~3/4 of right column.
        try
            tell rightPane to set rows to 8
        end try

        -- Send commands. Top-right is just an open shell at the city dir.
        tell current session
            write text "$DOCKER_MAYOR"
        end tell
        tell rightPane
            write text "$SHELL_CMD"
        end tell
        tell feedPane
            write text "$FEED_CMD"
        end tell
    end tell

    set bounds of current window to {120, 90, 1416, 900}
end tell
APPLESCRIPT

echo "Gas City *Docker* workspace launched at $CITY"
