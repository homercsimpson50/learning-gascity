#!/usr/bin/env bash
# install.sh — one-shot setup for Option A.
#
# After this runs successfully, you can use gascity normally and every
# agent invocation will be wrapped in a scoped Docker container.
#
# What this does, in order:
#   1. Make sure Docker is running (open Docker Desktop on macOS if needed).
#   2. Build the agent-runner image (gascity-agent-runner:claude).
#   3. Install the shim binary at ~/.local/bin/gascity-shims/.
#   4. Drop a default config at ~/.config/gascity-docker-runner/config.toml.
#   5. Symlink claude → gc-docker-runner so the supervisor's PATH lookup
#      hits the shim before the real binary.
#   6. Add the shim dir to your shell rc's PATH (idempotent).
#   7. Run verify.sh to confirm all 7 isolation probes pass.
#
# Re-running is safe — every step is idempotent.
#
# Flags (rarely needed):
#   ./install.sh --no-build     # skip docker build
#   ./install.sh --no-verify    # skip verify.sh at the end

set -euo pipefail
cd "$(dirname "$0")"

SHIM_BIN_DIR="$HOME/.local/bin/gascity-shims"
CONFIG_DIR="$HOME/.config/gascity-docker-runner"
LOG_DIR="$HOME/.local/state/gascity-docker-runner/logs"

DO_BUILD=1
DO_VERIFY=1
for arg in "$@"; do
    case "$arg" in
        --no-build)  DO_BUILD=0 ;;
        --no-verify) DO_VERIFY=0 ;;
        -h|--help)
            sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
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
# 3. Install the shim
# ---------------------------------------------------------------------------
mkdir -p "$SHIM_BIN_DIR" "$LOG_DIR"
cp shim/gc-docker-runner "$SHIM_BIN_DIR/gc-docker-runner"
chmod +x "$SHIM_BIN_DIR/gc-docker-runner"
ok "Shim installed at $SHIM_BIN_DIR/gc-docker-runner"

# ---------------------------------------------------------------------------
# 4. Default config (idempotent — never clobbers an existing config)
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.toml" ]; then
    cp shim/config.example.toml "$CONFIG_DIR/config.toml"
    ok "Default config written to $CONFIG_DIR/config.toml"
else
    ok "Existing config preserved at $CONFIG_DIR/config.toml"
fi

# ---------------------------------------------------------------------------
# 5. claude symlink
# ---------------------------------------------------------------------------
ln -sf gc-docker-runner "$SHIM_BIN_DIR/claude"
ok "Symlinked $SHIM_BIN_DIR/claude → gc-docker-runner"

# ---------------------------------------------------------------------------
# 6. Add to shell PATH (idempotent, marker-fenced for clean removal)
# ---------------------------------------------------------------------------
detect_rc() {
    case "${SHELL##*/}" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash) [ -f "$HOME/.bashrc" ] && echo "$HOME/.bashrc" || echo "$HOME/.bash_profile" ;;
        *)    echo "$HOME/.profile" ;;
    esac
}
RC="$(detect_rc)"
MARKER_BEGIN='# >>> learning-gascity shim PATH (managed by install.sh)'
MARKER_END='# <<< learning-gascity shim PATH'

if [ -f "$RC" ] && grep -qF "$MARKER_BEGIN" "$RC"; then
    ok "Shim PATH already in $RC"
else
    {
        echo
        echo "$MARKER_BEGIN"
        echo 'export PATH="$HOME/.local/bin/gascity-shims:$PATH"'
        echo "$MARKER_END"
    } >> "$RC"
    ok "Added shim PATH to $RC"
fi

# Make this PATH active for verify.sh + any subsequent commands in this shell.
case ":${PATH:-}:" in
    *":$SHIM_BIN_DIR:"*) ;;
    *) export PATH="$SHIM_BIN_DIR:$PATH" ;;
esac

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
   Open a new terminal (or run: source $RC) to pick up the PATH change,
   then use Gas City as normal:

       gc init ~/my-city
       cd ~/my-city
       gc rig add ~/code/some-repo
       bd create "do a thing"
       gc start

   Agents the supervisor spawns will run inside scoped Docker containers
   automatically. Logs at: $LOG_DIR

   To remove this setup:  ./uninstall.sh
EOF
