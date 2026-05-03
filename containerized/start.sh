#!/usr/bin/env bash
# start.sh — daily startup for containerized Gas City.
#
# Run this every time you sit down. It is the inverse of nothing
# (use `gc supervisor stop` or `../scripts/gascity-stop.sh` to tear down).
#
# What it does:
#   1. Make sure Docker is running (auto-launches Docker Desktop on macOS).
#   2. Ensure the shim PATH is exported for any child process we spawn.
#   3. Bring the gc supervisor up (idempotent — no-op if already up).
#   4. Make sure the city at ~/gc is registered with the supervisor.
#   5. Wait for the mayor session to be active.
#   6. Optionally attach to mayor (--attach) or open the iTerm2 4-pane
#      workspace layout (--workspace [--ai]).
#
# First-time setup is ./install.sh — run that once, then start.sh forever.
#
# Usage:
#   ./start.sh                  # bring supervisor up; print next steps
#   ./start.sh --attach         # also attach to mayor
#   ./start.sh --workspace      # also open the iTerm2 layout
#   ./start.sh --workspace --ai # workspace + Ollama summary feed pane

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CITY_DIR="${GC_CITY:-$HOME/gc}"
SHIM_BIN_DIR="$HOME/.local/bin/gascity-shims"

ATTACH=0
WORKSPACE=0
WORKSPACE_AI=0
for arg in "$@"; do
    case "$arg" in
        --attach)    ATTACH=1 ;;
        --workspace) WORKSPACE=1 ;;
        --ai)        WORKSPACE_AI=1 ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

if [ -t 1 ]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'
    DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; DIM=''; BOLD=''; NC=''
fi
say()  { echo "${BOLD}→${NC} $*"; }
ok()   { echo "  ${GREEN}✓${NC} $*"; }
warn() { echo "  ${YELLOW}!${NC} $*"; }
err()  { echo "  ${RED}✗${NC} $*"; }

# 1. Docker
if docker info >/dev/null 2>&1; then
    ok "Docker is running"
else
    say "Docker isn't running — starting Docker Desktop"
    if [ "$(uname)" = Darwin ] && [ -d /Applications/Docker.app ]; then
        open -a Docker
        printf '  waiting for Docker'
        for _ in $(seq 1 60); do
            if docker info >/dev/null 2>&1; then echo " ✓"; break; fi
            printf '.'
            sleep 2
        done
        if ! docker info >/dev/null 2>&1; then
            err "Docker still not up after 2 min"; exit 1
        fi
    else
        err "auto-start not supported on this OS — start Docker manually"
        exit 1
    fi
fi

# 2. Shim PATH (export for any child this script spawns)
case ":${PATH:-}:" in
    *":$SHIM_BIN_DIR:"*) ok "shim PATH active" ;;
    *) export PATH="$SHIM_BIN_DIR:$PATH"; ok "shim PATH added for this script" ;;
esac

if [ ! -x "$SHIM_BIN_DIR/claude" ]; then
    err "shim not installed at $SHIM_BIN_DIR — run ./install.sh first"
    exit 1
fi

# 3. Sanity: a city exists
if [ ! -f "$CITY_DIR/city.toml" ]; then
    err "no city at $CITY_DIR — run ./install.sh first"
    exit 1
fi

# 4. Supervisor up
if gc supervisor status >/dev/null 2>&1; then
    ok "supervisor already running"
else
    say "Starting gc supervisor"
    if gc supervisor start 2>&1 | sed 's/^/    /'; then
        ok "supervisor started"
    else
        err "gc supervisor start failed"
        exit 1
    fi
fi

# 5. City registered with supervisor
if grep -q "path = \"$CITY_DIR\"" "$HOME/.gc/cities.toml" 2>/dev/null; then
    ok "city registered: $CITY_DIR"
else
    say "Registering city with supervisor"
    gc start "$CITY_DIR" 2>&1 | sed 's/^/    /' || {
        err "gc start failed"
        exit 1
    }
fi

# 6. Wait for mayor to be active
say "Waiting for mayor session"
deadline=$((SECONDS + 30))
state=
while [ $SECONDS -lt $deadline ]; do
    state=$(cd "$CITY_DIR" && gc session list 2>/dev/null | awk '$2=="mayor"{print $3; exit}')
    if [ "$state" = "active" ]; then
        ok "mayor: active"
        break
    fi
    sleep 1
done
if [ "${state:-}" != "active" ]; then
    warn "mayor is '${state:-unknown}' after 30s (may still be coming up)"
fi

# 7. Optional follow-up
echo
if [ "$WORKSPACE" -eq 1 ]; then
    LAUNCHER="$REPO_DIR/scripts/gascity-workspace.sh"
    if [ ! -x "$LAUNCHER" ]; then
        err "workspace launcher not found at $LAUNCHER"
        exit 1
    fi
    if [ "$WORKSPACE_AI" -eq 1 ]; then
        say "Launching iTerm2 workspace (--ai)"
        "$LAUNCHER" --ai
    else
        say "Launching iTerm2 workspace"
        "$LAUNCHER"
    fi
elif [ "$ATTACH" -eq 1 ]; then
    say "Attaching to mayor session"
    cd "$CITY_DIR" && exec gc session attach mayor
else
    echo "  ${DIM}next: cd $CITY_DIR && gc session attach mayor${NC}"
    echo "  ${DIM}      or: $0 --attach   (--workspace for iTerm2 layout)${NC}"
fi
