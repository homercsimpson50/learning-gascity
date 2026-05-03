#!/usr/bin/env bash
#
# gascity-start.sh — bring up local Gas City. Inverse of gascity-stop.sh.
#
# What it starts:
#   - The machine-wide gc supervisor (idempotent — no-ops if already up).
#     Once running, the supervisor reconciles every city registered in
#     ~/.gc/cities.toml and brings it up (controller, dolt server, mayor).
#   - Optionally, loads the launchd autostart plist so the supervisor
#     comes back on next login (--enable-launchd).
#
# What it does NOT start:
#   - The containerized stack (use containerized/start.sh for that).
#   - Ollama (the gc-feed-ai script handles that on demand).
#   - The iTerm2 workspace layout (use gascity-workspace.sh).
#
# Usage:
#   ./gascity-start.sh                  # bring supervisor up
#   ./gascity-start.sh --enable-launchd # also load the autostart plist
#   ./gascity-start.sh --attach         # after up, attach to mayor session
#   ./gascity-start.sh --workspace      # after up, also launch iTerm2 layout
#   ./gascity-start.sh --workspace --ai # workspace + Ollama summary feed

set -euo pipefail

if [ -t 1 ]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'
    DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; DIM=''; BOLD=''; NC=''
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_DIR="${GC_CITY:-$HOME/gc}"

ENABLE_LAUNCHD=0
ATTACH=0
WORKSPACE=0
WORKSPACE_AI=0
for arg in "$@"; do
    case "$arg" in
        --enable-launchd) ENABLE_LAUNCHD=1 ;;
        --attach)         ATTACH=1 ;;
        --workspace)      WORKSPACE=1 ;;
        --ai)             WORKSPACE_AI=1 ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

step() { echo "${BOLD}→${NC} $*"; }
ok()   { echo "  ${GREEN}✓${NC} $*"; }
warn() { echo "  ${YELLOW}!${NC} $*"; }
err()  { echo "  ${RED}✗${NC} $*"; }

# 0. Sanity: is there actually a city to bring up?
if [ ! -f "$CITY_DIR/city.toml" ]; then
    err "no city.toml at $CITY_DIR — run 'gc init --provider claude $CITY_DIR' first"
    exit 1
fi

# 1. Optionally load launchd autostart.
PLIST="$HOME/Library/LaunchAgents/com.gascity.supervisor.plist"
if [ "$ENABLE_LAUNCHD" -eq 1 ]; then
    if [ -f "$PLIST" ]; then
        step "Loading launchd plist (auto-start on login)"
        launchctl load "$PLIST" 2>/dev/null && ok "loaded $PLIST" \
            || warn "launchctl load failed (already loaded?)"
    else
        warn "no launchd plist at $PLIST — run 'gc start $CITY_DIR' once to install it"
    fi
fi

# 2. Start the supervisor (idempotent).
if gc supervisor status >/dev/null 2>&1; then
    ok "supervisor already running"
else
    step "Starting gc supervisor"
    if gc supervisor start 2>&1 | sed 's/^/    /'; then
        ok "supervisor started"
    else
        err "gc supervisor start failed"
        exit 1
    fi
fi

# 3. Verify our city is registered.
if grep -q "path = \"$CITY_DIR\"" "$HOME/.gc/cities.toml" 2>/dev/null; then
    ok "city registered: $CITY_DIR"
else
    warn "city $CITY_DIR not in ~/.gc/cities.toml — registering"
    gc start "$CITY_DIR" 2>&1 | sed 's/^/    /' || {
        err "gc start failed"
        exit 1
    }
fi

# 4. Wait for the city's mayor session to be active.
step "Waiting for mayor session"
deadline=$((SECONDS + 30))
while [ $SECONDS -lt $deadline ]; do
    state=$(cd "$CITY_DIR" && gc session list 2>/dev/null | awk '$2=="mayor"{print $3; exit}')
    if [ "$state" = "active" ]; then
        ok "mayor: $state"
        break
    fi
    sleep 1
done
if [ "${state:-}" != "active" ]; then
    warn "mayor session is '${state:-unknown}' after 30s (may still be coming up)"
fi

# 5. Optional follow-up actions.
echo
if [ "$WORKSPACE" -eq 1 ]; then
    if [ "$WORKSPACE_AI" -eq 1 ]; then
        step "Launching iTerm2 workspace (--ai)"
        "$SCRIPT_DIR/gascity-workspace.sh" --ai
    else
        step "Launching iTerm2 workspace"
        "$SCRIPT_DIR/gascity-workspace.sh"
    fi
elif [ "$ATTACH" -eq 1 ]; then
    step "Attaching to mayor session"
    cd "$CITY_DIR" && exec gc session attach mayor
else
    echo "  ${DIM}next: cd $CITY_DIR && gc session attach mayor${NC}"
    echo "  ${DIM}      or: $SCRIPT_DIR/gascity-workspace.sh [--ai]${NC}"
fi
