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
# 2. Build the agent image
# ---------------------------------------------------------------------------
if [ "$DO_BUILD" -eq 1 ]; then
    say "Building gascity-agent-runner:claude (first build takes ~3 min)"
    docker build -t gascity-agent-runner:claude agent-runner/ >/dev/null
    ok "Image built"
else
    if ! docker image inspect gascity-agent-runner:claude >/dev/null 2>&1; then
        warn "image gascity-agent-runner:claude not present — re-run without --no-build"
        exit 1
    fi
    ok "Image already present (build skipped)"
fi

# ---------------------------------------------------------------------------
# 3. Install the shim (NOT on global PATH)
# ---------------------------------------------------------------------------
mkdir -p "$SHIM_BIN_DIR" "$LOG_DIR"
cp shim/gc-docker-runner "$SHIM_BIN_DIR/gc-docker-runner"
chmod +x "$SHIM_BIN_DIR/gc-docker-runner"
ok "Shim installed at $SHIM_BIN_DIR/gc-docker-runner"

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
# 5. claude symlink (only resolves to shim when shim dir is on PATH —
#    which only gc-docker arranges, never your interactive shell)
# ---------------------------------------------------------------------------
ln -sf gc-docker-runner "$SHIM_BIN_DIR/claude"
ok "Symlinked $SHIM_BIN_DIR/claude → gc-docker-runner"

# ---------------------------------------------------------------------------
# 6. Install the gc-docker wrapper (the user-facing entry point)
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$WRAPPER_BIN")"
cp shim/gc-docker "$WRAPPER_BIN"
chmod +x "$WRAPPER_BIN"
ok "Wrapper installed at $WRAPPER_BIN"

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
   Your normal claude and gc are UNCHANGED. To run gc with sandboxed
   agents, type 'gc-docker' instead of 'gc'. Examples:

       gc <anything>             # exactly as before — agents run on host
       gc-docker supervisor run  # foreground supervisor — agents in containers
       gc-docker init ~/test     # any gc subcommand works through the wrapper

   Make sure $(dirname "$WRAPPER_BIN") is on your PATH so 'gc-docker'
   resolves. (It already is if 'gc' resolves, since gc lives in the same
   dir for most installs.)

   Verify:
       which gc-docker           # should print $WRAPPER_BIN
       which claude              # should still be your normal claude

   To remove this setup:  ./uninstall.sh
EOF
