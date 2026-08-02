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
BROKER_CONFIG="$HOME/.config/gascity-docker-runner/config.toml"
BROKER_STATE_DIR="$HOME/.local/state/gascity-broker"
BROKER_CREDS_FILE="$BROKER_STATE_DIR/creds.json"

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

# --- Pre-flight: wire start_command into every [[agent]] block -------------
# gc-supervisor invokes `start_command` (set per-agent in pack.toml /
# city.toml) as the absolute path of the executable to spawn. Without
# that, gc falls back to PATH lookup for `claude` and finds the host
# binary at ~/.local/bin/claude — so the shim is bypassed and agents
# run on the host instead of in containers. The wire-shim helper edits
# the city's TOML in place to add the start_command line. Idempotent —
# safe to run on every boot. See containerized/wire-shim.sh.
if [ -x "$SHIM_DIR/wire-shim.sh" ]; then
    "$SHIM_DIR/wire-shim.sh" "$CITY" 2>&1 | sed 's/^/    /'
else
    echo "${YELLOW}    wire-shim helper missing at $SHIM_DIR/wire-shim.sh — re-run containerized/install.sh${NC}" >&2
fi

# --- Step 1: stop any existing supervisor (local launchd OR previous docker) -
# There can only be one supervisor on the machine. Whichever one is up
# right now — local (launchd) or a previous shim-aware backgrounded one —
# must be COMPLETELY gone before we start a fresh shim-aware one. This
# block is paranoid on purpose because earlier versions returned too
# fast and our new supervisor saw "supervisor already running" and
# exited, leaving the OLD (non-shim-aware) supervisor in charge.

# --- toml helper (for [broker.*] config lookup) ---------------------------
# Same shape as the shim's toml_get; duplicated here so the start script
# doesn't depend on the shim being on PATH yet.
toml_get() {
    local section="$1" key="$2" file="${3:-$BROKER_CONFIG}"
    [ -f "$file" ] || { echo ""; return; }
    awk -v s="$section" -v k="$key" '
        $0 ~ "^\\["s"\\]" {inside=1; next}
        inside && $0 ~ "^\\[" {inside=0}
        inside && $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
            sub("^[^=]*=[[:space:]]*\"?", ""); sub("\"?[[:space:]]*$", "");
            print; exit
        }
    ' "$file" 2>/dev/null
}
toml_expand() {
    # Expand a leading ~ to $HOME. NOTE: pattern in ${1#PATTERN} must have
    # ~ escaped (\~) — otherwise bash tilde-expands the pattern to $HOME
    # BEFORE matching, which never matches a literal '~' and leaves the
    # tilde in place. Result was paths like /Users/homer/~/.ssh/id_gc_agent.
    case "$1" in
        '~/'*) printf '%s\n' "$HOME/${1#\~/}" ;;
        '~')   printf '%s\n' "$HOME" ;;
        *)     printf '%s\n' "$1" ;;
    esac
}

# --- v2 brokers: ensure_brokers --------------------------------------------
# Bring up the three credential broker containers. Idempotent — if
# they're already running, we re-use them. See
# docs/credential-broker-v2-spec.md §9.2.
ensure_brokers() {
    local enabled
    enabled="$(toml_get broker enabled)"
    if [ -n "$enabled" ] && [ "$enabled" = "false" ]; then
        echo "${YELLOW}    [broker] enabled=false in $BROKER_CONFIG — skipping broker startup${NC}"
        echo "${YELLOW}    agents will have NO Anthropic / GitHub auth${NC}"
        return 0
    fi

    echo "${GREEN}→${NC} ensuring v2 credential brokers"

    # Networks + volume (idempotent; install.sh creates these too).
    docker network inspect gc-broker-net >/dev/null 2>&1 || \
        docker network create --internal --driver bridge gc-broker-net >/dev/null
    docker network inspect gc-egress-net >/dev/null 2>&1 || \
        docker network create --driver bridge gc-egress-net >/dev/null
    docker volume inspect gc-sshagent-sock >/dev/null 2>&1 || \
        docker volume create gc-sshagent-sock >/dev/null

    # ---- Anthropic broker -------------------------------------------------
    if ! docker ps --format '{{.Names}}' | grep -qx gc-broker-anthropic; then
        # Refresh the credentials file from macOS Keychain. The broker
        # re-reads on each request, so any rotation that happens while
        # the broker is up is picked up — but the file has to exist for
        # the broker to start at all.
        if [ -x "$SHIM_DIR/gc-broker-creds-extract.sh" ]; then
            "$SHIM_DIR/gc-broker-creds-extract.sh" 2>&1 | sed 's/^/    /'
        elif command -v gc-broker-creds-extract.sh >/dev/null 2>&1; then
            gc-broker-creds-extract.sh 2>&1 | sed 's/^/    /'
        else
            echo "${RED}    ✗ gc-broker-creds-extract.sh not found — re-run containerized/install.sh${NC}" >&2
            return 1
        fi
        if [ ! -f "$BROKER_CREDS_FILE" ]; then
            echo "${RED}    ✗ creds extractor did not produce $BROKER_CREDS_FILE${NC}" >&2
            return 1
        fi

        local anth_image
        anth_image="$(toml_get broker.anthropic image)"
        : "${anth_image:=gascity-broker-anthropic:v1}"

        local model_allow
        # Best-effort: parse the array form. Empty/unparseable → no env var.
        model_allow="$(awk '
            /^\[broker\.anthropic\]/ {inside=1; next}
            inside && /^\[/ {inside=0}
            inside && /^[[:space:]]*model_allowlist[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, ""); print; exit
            }
        ' "$BROKER_CONFIG" 2>/dev/null \
          | tr -d '[]" ' | tr ',' '\n' | grep -v '^$' | paste -sd, - || true)"

        docker run -d --rm --name gc-broker-anthropic \
            --network gc-broker-net \
            --user 1000:1000 --read-only \
            --tmpfs /tmp:size=64m,mode=1777 \
            --cap-drop ALL --security-opt no-new-privileges \
            --pids-limit 64 --memory 256m \
            -e "MODEL_ALLOWLIST=$model_allow" \
            -v "$BROKER_CREDS_FILE:/secrets/creds.json:ro" \
            "$anth_image" >/dev/null
        docker network connect gc-egress-net gc-broker-anthropic
        echo "    ✓ gc-broker-anthropic started"
    else
        echo "    ✓ gc-broker-anthropic already running"
    fi

    # ---- GitHub-API broker ------------------------------------------------
    if ! docker ps --format '{{.Names}}' | grep -qx gc-broker-github-api; then
        local gh_token_env_name gh_token_value
        gh_token_env_name="$(toml_get broker.github_api gh_token_env)"
        : "${gh_token_env_name:=GH_TOKEN}"
        gh_token_value="${!gh_token_env_name:-}"
        if [ -z "$gh_token_value" ]; then
            echo "${RED}    ✗ env var $gh_token_env_name is unset — set it before starting the broker${NC}" >&2
            echo "${RED}      e.g. export GH_TOKEN=ghp_...${NC}" >&2
            return 1
        fi

        local gh_image
        gh_image="$(toml_get broker.github_api image)"
        : "${gh_image:=gascity-broker-github-api:v1}"

        local repo_allow
        repo_allow="$(awk '
            /^\[broker\.github_api\]/ {inside=1; next}
            inside && /^\[/ {inside=0}
            inside && /^[[:space:]]*repo_allowlist[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, ""); print; exit
            }
        ' "$BROKER_CONFIG" 2>/dev/null \
          | tr -d '[]" ' | tr ',' '\n' | grep -v '^$' | paste -sd, - || true)"

        docker run -d --rm --name gc-broker-github-api \
            --network gc-broker-net \
            --user 1000:1000 --read-only \
            --tmpfs /tmp:size=64m,mode=1777 \
            --cap-drop ALL --security-opt no-new-privileges \
            --pids-limit 64 --memory 256m \
            -e "GH_TOKEN=$gh_token_value" \
            -e "REPO_ALLOWLIST=$repo_allow" \
            "$gh_image" >/dev/null
        docker network connect gc-egress-net gc-broker-github-api
        echo "    ✓ gc-broker-github-api started"
    else
        echo "    ✓ gc-broker-github-api already running"
    fi

    # ---- GitHub-SSH broker ------------------------------------------------
    if ! docker ps --format '{{.Names}}' | grep -qx gc-broker-github-ssh; then
        local key_file kh_file ssh_image
        key_file="$(toml_expand "$(toml_get broker.github_ssh key_file)")"
        kh_file="$(toml_expand "$(toml_get broker.github_ssh known_hosts_file)")"
        ssh_image="$(toml_get broker.github_ssh image)"
        : "${key_file:=$HOME/.ssh/id_ed25519}"
        : "${kh_file:=$HOME/.ssh/known_hosts}"
        : "${ssh_image:=gascity-broker-github-ssh:v1}"

        if [ ! -f "$key_file" ]; then
            echo "${RED}    ✗ SSH key not found at $key_file${NC}" >&2
            echo "${RED}      generate one (no passphrase recommended) or update broker.github_ssh.key_file in $BROKER_CONFIG${NC}" >&2
            return 1
        fi
        if [ ! -f "$kh_file" ]; then
            echo "${RED}    ✗ known_hosts not found at $kh_file${NC}" >&2
            echo "${RED}      run: ssh-keyscan -H github.com >> $kh_file${NC}" >&2
            return 1
        fi

        # Root + CHOWN cap so the entrypoint can chgrp the socket to gid
        # 1000. Rootfs is --read-only and image carries no shells/curl/wget.
        docker run -d --rm --name gc-broker-github-ssh \
            --network gc-broker-net \
            --user 0:0 --read-only \
            --tmpfs /tmp:size=16m,mode=1777 \
            --cap-drop ALL --cap-add CHOWN \
            --security-opt no-new-privileges \
            --pids-limit 32 --memory 64m \
            -v "$key_file:/secrets/key:ro" \
            -v "$kh_file:/secrets/known_hosts:ro" \
            -v gc-sshagent-sock:/run/sshagent \
            "$ssh_image" >/dev/null
        docker network connect gc-egress-net gc-broker-github-ssh
        echo "    ✓ gc-broker-github-ssh started"
    else
        echo "    ✓ gc-broker-github-ssh already running"
    fi

    # ---- Healthz wait -----------------------------------------------------
    # The broker images carry no curl/wget per spec §6.3, so we use the
    # /tmp/.healthy marker the proxies touch on startup.
    for broker in gc-broker-anthropic gc-broker-github-api gc-broker-github-ssh; do
        local healthy=0
        for _ in $(seq 1 30); do
            if docker exec "$broker" test -f /tmp/.healthy >/dev/null 2>&1; then
                healthy=1; break
            fi
            sleep 0.5
        done
        if [ "$healthy" -eq 1 ]; then
            echo "    ✓ $broker healthy"
        else
            echo "${RED}    ✗ $broker did not become healthy in 15s — see: docker logs $broker${NC}" >&2
            return 1
        fi
    done
}

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

# --- Step 1.5: bring up the v2 credential brokers --------------------------
# Brokers must be up BEFORE the supervisor starts spawning agents — the
# agent network has no internet egress, so an agent that races ahead of
# the brokers will fail at DNS for ANTHROPIC_BASE_URL.
ensure_brokers

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
