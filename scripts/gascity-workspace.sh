#!/usr/bin/env bash
#
# Gas City iTerm2 Workspace Launcher
#
# Layout:
#   ┌──────────┬─────────────────────┐
#   │          │ shell (interactive) │
#   │  local   │                     │
#   │  mayor   │                     │
#   │  (tall)  ├─────────────────────┤
#   │          │ feed (wide)         │
#   │          │                     │
#   └──────────┴─────────────────────┘
#
# Left tall pane:    local gc mayor in ~/gc (gc session attach mayor)
# Top-right pane:    blank interactive shell — no command sent
# Bottom-right pane: gc events --follow (or gc-feed-ai with --ai)
#
# Usage:
#   ./gascity-workspace.sh          # Plain feed in the bottom pane
#   ./gascity-workspace.sh --ai     # Bottom pane runs gc-feed-ai (Ollama summary)

set -euo pipefail

# Use BASH_SOURCE[0] not $0 so SCRIPT_DIR is correct even when this file
# is `source`d (then $0 is the parent shell's argv[0]).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

USE_AI=0
if [ "${1:-}" = "--ai" ]; then
    USE_AI=1
fi

if [ "$USE_AI" -eq 1 ] && [ ! -x "$SCRIPT_DIR/gc-feed-ai" ]; then
    echo "error: $SCRIPT_DIR/gc-feed-ai not found or not executable" >&2
    exit 1
fi

LOCAL_MAYOR="cd ~/gc && $SCRIPT_DIR/gascity-start.sh && gc session attach mayor"
if [ "$USE_AI" -eq 1 ]; then
    EVENT_FEED="cd ~/gc && $SCRIPT_DIR/gc-feed-ai"
else
    EVENT_FEED='cd ~/gc && gc events --follow'
fi

osascript <<APPLESCRIPT
tell application "iTerm2"
    activate
    create window with default profile

    tell current tab of current window
        -- Step 1: Split into left (local mayor) | right
        tell current session
            set name to "local-mayor"
            set rightPane to (split vertically with default profile)
        end tell

        -- Step 2: Split right horizontally → top-right (shell, small)
        --                                    + bottom-right (feed, big)
        tell rightPane
            set name to "shell"
            set feedPane to (split horizontally with default profile)
        end tell

        tell feedPane
            set name to "feed"
        end tell

        -- Make the shell (top-right) small so the feed gets ~3/4 of the
        -- right column. iTerm's session rows property does the resize
        -- without needing Accessibility permissions.
        try
            tell rightPane to set rows to 8
        end try

        -- Send commands. Top-right pane is left blank (just an open shell).
        tell current session
            write text "$LOCAL_MAYOR"
        end tell
        tell feedPane
            write text "$EVENT_FEED"
        end tell
    end tell

    -- Resize window to ~90% of screen (centered for 1440x900)
    set bounds of current window to {72, 45, 1368, 855}

end tell
APPLESCRIPT

echo "Gas City workspace launched"
