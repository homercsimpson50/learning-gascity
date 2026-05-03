#!/usr/bin/env bash
#
# Gas City iTerm2 Workspace Launcher
#
# Layout (matches the gastown-workspace.sh layout, but with gascity):
#   ┌──────────┬──────────┬──────────┐
#   │          │ gc       │ shell    │
#   │  local   │ mayor    │ ~/code   │
#   │  mayor   │ (cont)   │          │
#   │  (tall)  ├──────────┴──────────┤
#   │          │ gc events --follow  │
#   │          │ (wide)              │
#   └──────────┴─────────────────────┘
#
# Left tall pane:   local gc mayor in ~/gc
# Top-mid pane:     containerized gc mayor (docker compose exec)
# Top-right pane:   plain shell in ~/code
# Bottom-wide pane: live event feed for the local city
#
# Usage:
#   ./gascity-workspace.sh          # Plain feed in the bottom pane
#   ./gascity-workspace.sh --ai     # Bottom pane runs gc-feed-ai (Ollama summary)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER_DIR="$HOME/code/learning-gascity/containerized"

USE_AI=0
if [ "${1:-}" = "--ai" ]; then
    USE_AI=1
fi

LOCAL_MAYOR='cd ~/gc && echo "Starting local Gas City..." && gc supervisor start 2>/dev/null; gc session attach mayor'
CONTAINER_MAYOR="cd $CONTAINER_DIR && docker compose exec gascity gc session attach mayor"
CODE_SHELL='cd ~/code'
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

        -- Step 2: Split right into top-right | bottom-right (feed)
        tell rightPane
            set feedPane to (split horizontally with default profile)
        end tell

        -- Step 3: Split top-right into gc-mayor | shell
        tell rightPane
            set name to "gc-mayor"
            set shellPane to (split vertically with default profile)
        end tell

        tell shellPane
            set name to "code"
        end tell
        tell feedPane
            set name to "feed"
        end tell

        tell current session
            write text "$LOCAL_MAYOR"
        end tell
        tell rightPane
            write text "$CONTAINER_MAYOR"
        end tell
        tell shellPane
            write text "$CODE_SHELL"
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
