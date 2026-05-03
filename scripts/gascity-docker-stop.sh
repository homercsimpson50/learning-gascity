#!/usr/bin/env bash
#
# gascity-docker-stop.sh — cleanly stop the shim-aware (Docker) supervisor.
#
# Sister to gascity-stop.sh. The two are mutually exclusive (only one
# supervisor at a time per machine), so this script:
#
#   1. Reads the pid of the backgrounded gc supervisor that
#      gascity-docker-start.sh wrote to the pidfile.
#   2. SIGTERMs it; SIGKILLs after a grace period if --force.
#   3. As a belt-and-braces step, kills any running 'gc supervisor run'
#      processes (handles the case where pidfile is stale).
#   4. With --restart-local, brings your normal local supervisor back
#      up via gc start so you're back in your default state.
#
# What this does NOT touch:
#   - The agent-runner image, the shim, the gc-docker wrapper, your
#     config, or session logs. Use containerized/uninstall.sh for those.
#   - Any stranded agent containers (they self-clean via 'docker run --rm',
#     but check 'docker ps' if anything looks off).
#
# Usage:
#   ./gascity-docker-stop.sh                  # graceful stop
#   ./gascity-docker-stop.sh --force          # SIGKILL after wait
#   ./gascity-docker-stop.sh --restart-local  # also bring local gc back up

set -euo pipefail

if [ -t 1 ]; then
    GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'
    DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; DIM=''; BOLD=''; NC=''
fi

PIDFILE="$HOME/.local/state/gascity-docker-runner/supervisor.pid"
LOCAL_CITY="${GC_CITY:-$HOME/gc}"

FORCE=0
RESTART_LOCAL=0
for arg in "$@"; do
    case "$arg" in
        --force)         FORCE=1 ;;
        --restart-local) RESTART_LOCAL=1 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

step() { echo "${BOLD}→${NC} $*"; }
ok()   { echo "  ${GREEN}✓${NC} $*"; }
warn() { echo "  ${YELLOW}!${NC} $*"; }

# --- 1. Kill the tracked pid ----------------------------------------------
KILLED_ANY=0
if [ -f "$PIDFILE" ]; then
    PID="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
        step "stopping backgrounded supervisor (pid $PID)"
        kill -TERM "$PID" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$PID" 2>/dev/null; then
            if [ "$FORCE" -eq 1 ]; then
                kill -KILL "$PID" 2>/dev/null || true
                ok "supervisor killed (SIGKILL)"
            else
                warn "supervisor still alive after 10s — pass --force to SIGKILL"
            fi
        else
            ok "supervisor stopped"
        fi
        KILLED_ANY=1
    else
        ok "no live process at recorded pid"
    fi
    rm -f "$PIDFILE"
else
    ok "no pidfile at $PIDFILE"
fi

# --- 2. Belt-and-braces: kill any stray 'gc supervisor run' ----------------
# Caught by pgrep against the literal string used by gascity-docker-start.sh.
STRAYS="$(pgrep -f 'gc supervisor run' 2>/dev/null || true)"
if [ -n "$STRAYS" ]; then
    step "cleaning up stray gc supervisor processes"
    echo "$STRAYS" | while read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            ok "killed pid $pid"
            KILLED_ANY=1
        fi
    done
fi

if [ "$KILLED_ANY" -eq 0 ]; then
    ok "nothing was running"
fi

# --- 3. Optionally bring local back up -------------------------------------
if [ "$RESTART_LOCAL" -eq 1 ]; then
    step "bringing local supervisor back up against $LOCAL_CITY"
    if [ ! -f "$LOCAL_CITY/city.toml" ]; then
        warn "no local city at $LOCAL_CITY — skipping"
    else
        gc start "$LOCAL_CITY" 2>&1 | sed 's/^/    /'
        ok "local supervisor up"
    fi
fi

echo
echo "${GREEN}done.${NC}"
[ "$RESTART_LOCAL" -eq 0 ] && echo "${DIM}  to bring local back: gc start $LOCAL_CITY${NC}"
[ "$RESTART_LOCAL" -eq 0 ] && echo "${DIM}  or:                  ./gascity-start.sh${NC}"
