#!/usr/bin/env bash
#
# gascity-docker-start.sh — bring up Gas City with a SHIM-AWARE supervisor.
#
# Sister script to gascity-start.sh, but for the work-machine
# (containerized) flow. There's only ONE supervisor per machine, and it
# inherits its env from whoever started it. To get the supervisor to
# route agent invocations through the gc-docker shim, we need to start
# it from a shell that has the shim dir on PATH — which launchd doesn't
# do. So this script:
#
#   1. Stops any existing (launchd) supervisor.
#   2. Starts `gc supervisor run` in the background, with the shim dir
#      prepended to PATH so spawned agents resolve `claude` to the shim
#      and end up inside Docker containers.
#   3. Waits until the mayor session for the city is up.
#
# What this means for your local setup: while this is running, your
# normal local supervisor is NOT. To go back, run:
#
#     pkill -f 'gc supervisor run'
#     gc start ~/gc
#
# Usage:
#   ./gascity-docker-start.sh                # bring shim-aware supervisor up
#   ./gascity-docker-start.sh --city PATH    # use a non-default city dir
#
# Env:
#   GC_DOCKER_CITY   default: $HOME/gc-docker

set -euo pipefail

if [ -t 1 ]; then
    GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'
    DIM=$'\033[2m'; NC=$'\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; DIM=''; NC=''
fi

CITY="${GC_DOCKER_CITY:-$HOME/gc-docker}"
SHIM_DIR="$HOME/.local/bin/gascity-shims"
LOG_FILE="$HOME/.local/state/gascity-docker-runner/supervisor.log"
PIDFILE="$HOME/.local/state/gascity-docker-runner/supervisor.pid"

while [ $# -gt 0 ]; do
    case "$1" in
        --city) CITY="$2"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# --- Pre-flight ------------------------------------------------------------
if ! command -v gc-docker >/dev/null 2>&1; then
    echo "${RED}error:${NC} gc-docker not on PATH — run learning-gascity/containerized/install.sh first" >&2
    exit 1
fi
if [ ! -x "$SHIM_DIR/gc-docker-runner" ]; then
    echo "${RED}error:${NC} shim missing at $SHIM_DIR/gc-docker-runner" >&2
    exit 1
fi
if [ ! -f "$CITY/city.toml" ]; then
    echo "${YELLOW}→${NC} city missing at $CITY — running gc-docker init"
    gc-docker init --provider claude --skip-provider-readiness "$CITY"
fi
mkdir -p "$(dirname "$LOG_FILE")"

# --- Step 1: stop any existing supervisor (local launchd OR previous docker) -
# There can only be one supervisor on the machine. Whichever one is up
# right now — local (launchd) or a previous shim-aware backgrounded one —
# must be COMPLETELY gone before we start a fresh shim-aware one. This
# block is paranoid on purpose because earlier versions returned too
# fast and our new supervisor saw "supervisor already running" and
# exited, leaving the OLD (non-shim-aware) supervisor in charge.

stop_supervisor_completely() {
    # 1. Ask gc supervisor to stop politely.
    if gc supervisor status 2>/dev/null | grep -q running; then
        echo "${YELLOW}→${NC} stopping existing supervisor"
        gc supervisor stop 2>&1 | sed 's/^/    /' || true
    fi

    # 2. Bring down our previous backgrounded one if pidfile is live.
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        kill -TERM "$(cat "$PIDFILE")" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"

    # 3. Unload the launchd plist (gc supervisor stop alone may leave it
    #    loaded, and launchd would relaunch the process).
    PLIST="$HOME/Library/LaunchAgents/com.gascity.supervisor.plist"
    if launchctl list 2>/dev/null | grep -q com.gascity.supervisor; then
        launchctl unload "$PLIST" 2>/dev/null || \
            launchctl bootout "gui/$(id -u)/com.gascity.supervisor" 2>/dev/null || true
    fi

    # 4. Belt-and-braces: kill any stray 'gc supervisor' processes by name.
    pgrep -f 'gc supervisor (run|start)' 2>/dev/null | xargs -r kill -TERM 2>/dev/null || true

    # 5. Wait for everything to actually be gone (up to 15s, then SIGKILL
    #    anything still alive).
    for _ in $(seq 1 15); do
        if ! gc supervisor status 2>/dev/null | grep -q running \
           && ! pgrep -f 'gc supervisor (run|start)' >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "${YELLOW}    polite stop didn't finish — SIGKILLing stragglers${NC}"
    pgrep -f 'gc supervisor (run|start)' 2>/dev/null | xargs -r kill -KILL 2>/dev/null || true
    sleep 2

    if pgrep -f 'gc supervisor (run|start)' >/dev/null 2>&1; then
        echo "${RED}    failed to stop existing supervisor — bail${NC}" >&2
        pgrep -fl 'gc supervisor' >&2
        return 1
    fi
}
stop_supervisor_completely

# --- Step 2: start gc supervisor with shim PATH in background --------------
echo "${GREEN}→${NC} starting shim-aware supervisor"
echo "    PATH adds:  $SHIM_DIR"
echo "    log:        $LOG_FILE"
nohup env PATH="$SHIM_DIR:$PATH" gc supervisor run \
    > "$LOG_FILE" 2>&1 &
SUPER_PID=$!
echo "$SUPER_PID" > "$PIDFILE"
disown "$SUPER_PID" 2>/dev/null || true
echo "    pid:        $SUPER_PID"

# --- Step 3: wait for mayor session ----------------------------------------
echo -n "${DIM}    waiting for mayor"
for _ in $(seq 1 30); do
    if (cd "$CITY" && gc session list 2>/dev/null | grep -qE '\bmayor\b'); then
        echo " ✓${NC}"
        echo "${GREEN}✓${NC} ready. attach with:  ${GREEN}cd $CITY && gc session attach mayor${NC}"
        echo "${DIM}  stop with:  pkill -f 'gc supervisor run'${NC}"
        exit 0
    fi
    echo -n "."
    sleep 2
done
echo
echo "${YELLOW}⚠${NC} mayor didn't come up in 60s. Check the log:"
echo "    tail -50 $LOG_FILE"
exit 1
