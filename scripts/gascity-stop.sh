#!/usr/bin/env bash
#
# gascity-stop.sh — cleanly stop everything the local Gas City setup runs.
#
# What it stops:
#   - The machine-wide gc supervisor (this also takes down its managed
#     cities, controllers, agent sessions, and the per-city Dolt server).
#   - Optionally, the launchd autostart plist (so the supervisor does not
#     come back on next login) — pass --disable-launchd.
#
# What it does NOT stop:
#   - The containerized stack under containerized/ (use `./start.sh --down`
#     there for that — different scope).
#   - Ollama, if running for gc-feed-ai (gc-feed-ai's own EXIT trap handles
#     that when you Ctrl-C the feed pane).
#
# Usage:
#   ./gascity-stop.sh                  # graceful stop, blocks until clean
#   ./gascity-stop.sh --disable-launchd  # also unload the launchd plist
#   ./gascity-stop.sh --force          # SIGKILL anything still alive after wait

set -euo pipefail

if [ -t 1 ]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'
    DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; DIM=''; BOLD=''; NC=''
fi

DISABLE_LAUNCHD=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --disable-launchd) DISABLE_LAUNCHD=1 ;;
        --force)           FORCE=1 ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "unknown option: $arg" >&2
            exit 2 ;;
    esac
done

step() { echo "${BOLD}→${NC} $*"; }
ok()   { echo "  ${GREEN}✓${NC} $*"; }
warn() { echo "  ${YELLOW}!${NC} $*"; }
err()  { echo "  ${RED}✗${NC} $*"; }

# 1. Ask the supervisor to stop. --wait blocks until the socket is gone,
#    but the gc process itself can linger doing async cleanup, so we poll
#    after for the actual PID to disappear.
if gc supervisor status >/dev/null 2>&1; then
    step "Stopping gc supervisor (and all managed cities)"
    if gc supervisor stop --wait 2>&1 | sed 's/^/    /'; then
        ok "supervisor acknowledged stop"
    else
        warn "gc supervisor stop --wait returned non-zero; will verify below"
    fi
else
    ok "supervisor was not running"
fi

# 2. Poll until the supervisor process is really gone. up to 10s.
deadline=$((SECONDS + 10))
while [ $SECONDS -lt $deadline ]; do
    if ! pgrep -f "gc supervisor run|gc supervisor start" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

# 3. Verify nothing is left over. If --force, SIGKILL stragglers.
LEFTOVER_GC=$(pgrep -f "gc supervisor run|gc supervisor start" 2>/dev/null || true)
LEFTOVER_DOLT=$(pgrep -f "dolt sql-server.*$HOME/gc" 2>/dev/null || true)
LEFTOVER_TMUX=$(tmux list-sessions 2>/dev/null | awk -F: '/^gc[-_]/ {print $1}' || true)

if [ -n "$LEFTOVER_GC$LEFTOVER_DOLT$LEFTOVER_TMUX" ]; then
    if [ "$FORCE" -eq 1 ]; then
        step "Force-killing leftovers"
        [ -n "$LEFTOVER_GC" ]   && kill -9 $LEFTOVER_GC   2>/dev/null && ok "killed gc:   $LEFTOVER_GC"
        [ -n "$LEFTOVER_DOLT" ] && kill -9 $LEFTOVER_DOLT 2>/dev/null && ok "killed dolt: $LEFTOVER_DOLT"
        for s in $LEFTOVER_TMUX; do
            tmux kill-session -t "$s" 2>/dev/null && ok "killed tmux: $s"
        done
    else
        warn "leftovers still running (use --force to SIGKILL):"
        [ -n "$LEFTOVER_GC" ]   && err "  gc:   $LEFTOVER_GC"
        [ -n "$LEFTOVER_DOLT" ] && err "  dolt: $LEFTOVER_DOLT"
        [ -n "$LEFTOVER_TMUX" ] && err "  tmux: $(echo $LEFTOVER_TMUX | tr '\n' ' ')"
    fi
else
    ok "no leftover gc/dolt/tmux processes"
fi

# 3. Optionally unload launchd autostart.
PLIST="$HOME/Library/LaunchAgents/com.gascity.supervisor.plist"
if [ "$DISABLE_LAUNCHD" -eq 1 ]; then
    if [ -f "$PLIST" ]; then
        step "Unloading launchd plist (disables auto-start on login)"
        launchctl unload "$PLIST" 2>/dev/null && ok "unloaded $PLIST" \
            || warn "launchctl unload failed (already unloaded?)"
    else
        ok "no launchd plist installed"
    fi
else
    if [ -f "$PLIST" ]; then
        echo "  ${DIM}launchd plist still loaded — supervisor will auto-start on next login.${NC}"
        echo "  ${DIM}Pass --disable-launchd to unload it.${NC}"
    fi
fi

# 4. Final status.
echo
if gc supervisor status >/dev/null 2>&1; then
    err "supervisor is STILL running after stop"
    exit 1
fi
ok "${GREEN}clean${NC}"
