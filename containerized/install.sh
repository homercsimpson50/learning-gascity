#!/usr/bin/env bash
# install.sh — opt-in setup. Does NOT touch your shell's PATH.
#
# After this runs, your normal `claude` and `gc` work exactly as before.
# To run gc with sandboxed agents, you explicitly invoke `gc-docker`.
#
# What this does, in order:
#   1. Make sure Docker is running (open Docker Desktop on macOS if needed).
#   2. Build the agent-runner image (gascity-agent-runner:claude).
#   3. Install the shim binary at ~/.local/bin/gascity-shims/.
#       (NOT on your global PATH — only reachable when gc-docker puts it there.)
#   4. Drop a default config at ~/.config/gascity-docker-runner/config.toml.
#   5. Symlink claude → gc-docker-runner inside the shim dir, so when
#      gc-docker prepends that dir to its own PATH, the supervisor sees a
#      claude that goes through the shim.
#   6. Install `gc-docker` wrapper at ~/.local/bin/gc-docker. This is the
#      ONE thing visible to your shell — and it does nothing until you type
#      `gc-docker …` explicitly.
#   7. Run verify.sh to confirm all 7 isolation probes pass.
#
# Re-running is safe — every step is idempotent.
#
# Flags:
#   ./install.sh --no-build     # skip docker build
#   ./install.sh --no-verify    # skip verify.sh

set -euo pipefail
cd "$(dirname "$0")"

SHIM_BIN_DIR="$HOME/.local/bin/gascity-shims"
WRAPPER_BIN="$HOME/.local/bin/gc-docker"
CONFIG_DIR="$HOME/.config/gascity-docker-runner"
LOG_DIR="$HOME/.local/state/gascity-docker-runner/logs"

DO_BUILD=1
DO_VERIFY=1
for arg in "$@"; do
    case "$arg" in
        --no-build)  DO_BUILD=0 ;;
        --no-verify) DO_VERIFY=0 ;;
        -h|--help)
            sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

say() { printf '\e[1;36m→\e[0m %s\n' "$*"; }
ok()  { printf '\e[1;32m✓\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m⚠\e[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Ensure Docker is up
# ---------------------------------------------------------------------------
ensure_docker() {
    if docker info >/dev/null 2>&1; then
        ok "Docker is running"
        return 0
    fi
    say "Docker isn't running — starting Docker Desktop"
    if [ "$(uname)" = Darwin ] && [ -d /Applications/Docker.app ]; then
        open -a Docker
    else
        warn "auto-start not supported on this OS — please start the Docker daemon"
        exit 1
    fi
    printf '  waiting for Docker to come up'
    for _ in $(seq 1 60); do
        if docker info >/dev/null 2>&1; then
            echo " ✓"
            return 0
        fi
        printf '.'
        sleep 2
    done
    echo
    warn "Docker still not responding after 2 minutes — try again once Docker Desktop is ready"
    exit 1
}
ensure_docker

# ---------------------------------------------------------------------------
# 2. Build the agent image + v2 broker images
# ---------------------------------------------------------------------------
if [ "$DO_BUILD" -eq 1 ]; then
    say "Building gascity-agent-runner:claude (first build takes ~3 min)"
    docker build -t gascity-agent-runner:claude agent-runner/ >/dev/null
    ok "Image built"

    for broker in anthropic github-api github-ssh; do
        say "Building gascity-broker-${broker}:v1"
        docker build -t "gascity-broker-${broker}:v1" "brokers/${broker}/" >/dev/null
        ok "broker image: gascity-broker-${broker}:v1"
    done
else
    if ! docker image inspect gascity-agent-runner:claude >/dev/null 2>&1; then
        warn "image gascity-agent-runner:claude not present — re-run without --no-build"
        exit 1
    fi
    ok "Images already present (build skipped)"
fi

# ---------------------------------------------------------------------------
# 2b. v2 networks + ssh-agent socket volume (idempotent)
# ---------------------------------------------------------------------------
# gc-broker-net (--internal): the agent's only network — no internet route.
# gc-egress-net: brokers attach to this too so they can reach upstream.
# gc-sshagent-sock: shared docker volume; SSH broker writes the socket,
#   agent containers mount :ro and connect.
docker network inspect gc-broker-net >/dev/null 2>&1 || \
    docker network create --internal --driver bridge gc-broker-net >/dev/null
ok "Network gc-broker-net (--internal) ready"
docker network inspect gc-egress-net >/dev/null 2>&1 || \
    docker network create --driver bridge gc-egress-net >/dev/null
ok "Network gc-egress-net ready"
docker volume inspect gc-sshagent-sock >/dev/null 2>&1 || \
    docker volume create gc-sshagent-sock >/dev/null
ok "Volume gc-sshagent-sock ready"

# ---------------------------------------------------------------------------
# 3. Install the shim + wire-shim helper (NOT on global PATH)
# ---------------------------------------------------------------------------
mkdir -p "$SHIM_BIN_DIR" "$LOG_DIR"
cp shim/gc-docker-runner "$SHIM_BIN_DIR/gc-docker-runner"
chmod +x "$SHIM_BIN_DIR/gc-docker-runner"
ok "Shim installed at $SHIM_BIN_DIR/gc-docker-runner"

cp wire-shim.sh "$SHIM_BIN_DIR/wire-shim.sh"
chmod +x "$SHIM_BIN_DIR/wire-shim.sh"
ok "Wire-shim helper installed at $SHIM_BIN_DIR/wire-shim.sh"

# ---------------------------------------------------------------------------
# 4. Default config (idempotent)
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.toml" ]; then
    cp shim/config.example.toml "$CONFIG_DIR/config.toml"
    ok "Default config written to $CONFIG_DIR/config.toml"
else
    ok "Existing config preserved at $CONFIG_DIR/config.toml"
fi

# ---------------------------------------------------------------------------
# 5. claude symlink + real-claude sidecar
#
# $SHIM_BIN_DIR/claude → gc-docker-runner is the canonical shim entry point
# (argv[0]=claude lets one shim binary serve multiple agents). Wire gc to it
# by setting `start_command` on each agent in your city's pack.toml — see the
# README "Wiring up start_command" section. That bypasses PATH lookup entirely
# and is durable against claude's auto-updater rewriting ~/.local/bin/claude.
#
# We also capture the real claude binary's resolved path into .real-claude
# for the shim's passthrough mode (when GC_RIG_PATH is unset — e.g., an
# interactive claude session reaches the shim by accident).
# ---------------------------------------------------------------------------
ln -sf gc-docker-runner "$SHIM_BIN_DIR/claude"
ok "Symlinked $SHIM_BIN_DIR/claude → gc-docker-runner"

USER_CLAUDE="$HOME/.local/bin/claude"
REAL_CLAUDE_SIDECAR="$SHIM_BIN_DIR/.real-claude"

capture_real_claude() {
    if [ ! -e "$USER_CLAUDE" ]; then
        warn "$USER_CLAUDE not found — skipping .real-claude capture"
        warn "    install Claude Code first (https://docs.anthropic.com/claude/docs/claude-code), then re-run install.sh"
        return 1
    fi

    # Resolve symlinks fully so we record the actual binary, not a symlink
    # claude's auto-updater may later re-point.
    local resolved
    if readlink -f / >/dev/null 2>&1; then
        resolved="$(readlink -f "$USER_CLAUDE")"
    else
        # macOS readlink doesn't grok -f; chase manually.
        resolved="$USER_CLAUDE"
        while [ -L "$resolved" ]; do
            local next
            next="$(readlink "$resolved")"
            case "$next" in
                /*) resolved="$next" ;;
                *)  resolved="$(cd "$(dirname "$resolved")" && pwd)/$next" ;;
            esac
        done
    fi

    if [ ! -x "$resolved" ]; then
        warn "$USER_CLAUDE resolved to $resolved which is not executable — skipping"
        return 1
    fi

    echo "$resolved" > "$REAL_CLAUDE_SIDECAR"
    ok "Captured real claude binary: $resolved → $REAL_CLAUDE_SIDECAR"
}
capture_real_claude || true

# ---------------------------------------------------------------------------
# 6. Install the gc-docker wrapper (the user-facing entry point)
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$WRAPPER_BIN")"
cp shim/gc-docker "$WRAPPER_BIN"
chmod +x "$WRAPPER_BIN"
ok "Wrapper installed at $WRAPPER_BIN"

# ---------------------------------------------------------------------------
# 6b. Symlink workspace launchers + start/stop scripts into ~/.local/bin/
#     so they're directly invokable from any shell:
#       gc-workspace-home.sh / gc-workspace-work.sh   (mode-swap wrappers)
#       gc-docker-start.sh   / gc-docker-stop.sh      (supervisor-only swap)
#       gc-workspace-home.py / gc-workspace-work.py   (Python API variants)
# ---------------------------------------------------------------------------
# Note: line 28 already did `cd "$(dirname "$0")"`, so cwd is the
# containerized/ dir at this point. `..` = the repo root; `../scripts`
# = the workspace launchers. Don't re-derive from $0 here — that would
# resolve relative to the ORIGINAL caller cwd, not the post-cd one.
SCRIPTS_DIR="$(cd ../scripts && pwd)"
mkdir -p "$HOME/.local/bin"

# Symlink table — source script → name in ~/.local/bin.
# Note: the bare 'gc-workspace.sh' is intentionally NOT linked. With
# explicit home/work wrappers, an unqualified name is ambiguous.
declare -a SYMS=(
    "gascity-docker-start.sh:gc-docker-start.sh"
    "gascity-docker-stop.sh:gc-docker-stop.sh"
    # v2 broker credential extractor (one-shot Keychain → flat file).
    "gc-broker-creds-extract.sh:gc-broker-creds-extract.sh"
    # Mode-swap wrappers — swap supervisors then open the right workspace.
    "gascity-workspace-home.sh:gc-workspace-home.sh"
    "gascity-workspace-work.sh:gc-workspace-work.sh"
    "gascity-workspace-home.py:gc-workspace-home.py"
    "gascity-workspace-work.py:gc-workspace-work.py"
)
for entry in "${SYMS[@]}"; do
    src="${entry%%:*}"
    link_name="${entry##*:}"
    if [ -f "$SCRIPTS_DIR/$src" ]; then
        ln -sf "$SCRIPTS_DIR/$src" "$HOME/.local/bin/$link_name"
        ok "Symlinked ~/.local/bin/$link_name → $SCRIPTS_DIR/$src"
    else
        warn "$SCRIPTS_DIR/$src missing — skipping"
    fi
done

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------
if [ "$DO_VERIFY" -eq 1 ]; then
    say "Running 7 isolation probes (verify.sh)"
    if ./verify.sh; then
        ok "All probes passed"
    else
        warn "Some probes failed — see output above. Install is otherwise complete."
        exit 1
    fi
else
    ok "Skipped verify.sh (--no-verify)"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo
printf '\e[1;32m✓ Ready.\e[0m\n\n'
cat <<EOF
   Your normal claude and gc are UNCHANGED. Cities are auto-wired
   through the shim by gc-docker-start.sh, which calls wire-shim.sh
   ($SHIM_BIN_DIR/wire-shim.sh) before booting the supervisor — that
   helper inserts 'start_command = "$SHIM_BIN_DIR/claude"' into every
   [[agent]] block in the city's pack.toml and city.toml.

   For ad-hoc wiring of any city, run:
       $SHIM_BIN_DIR/wire-shim.sh /path/to/city

   Confirm with 'gc config explain' — each agent should show a
   start_command line. Polecats with GC_RIG_PATH set will hit the
   docker path; city-scoped agents (mayor, deacon, boot) will pass
   through to the host claude binary.

   Examples:
       gc <anything>             # exactly as before — agents run on host
       gc-docker supervisor run  # foreground supervisor — agents in containers
       gc-docker init ~/test     # any gc subcommand works through the wrapper

   For day-to-day use, two single-command wrappers swap supervisors
   AND open the right iTerm2 workspace:

       gc-workspace-work.sh      # ↻ to docker, open desert workspace
       gc-workspace-home.sh      # ↻ to local,  open home  workspace

   Or just swap the supervisor without opening a workspace:

       gc-docker-start.sh                      # ↻ to docker
       gc-docker-stop.sh --restart-local       # ↻ to local

   Make sure $(dirname "$WRAPPER_BIN") is on your PATH so these
   resolve. (It already is if 'gc' resolves, since gc lives in the
   same dir for most installs.)

   Verify:
       which gc-docker             # should print $WRAPPER_BIN
       which gc-workspace-work.sh  # should print $HOME/.local/bin/gc-workspace-work.sh
       which claude                # should still be your normal claude

   To remove this setup:  ./uninstall.sh
EOF
