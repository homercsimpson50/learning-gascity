#!/usr/bin/env bash
# install.sh — set up Option A on this host.
#
# Three steps, each independently re-runnable:
#   1. Build the agent-runner image (gascity-agent-runner:claude).
#   2. Install the shim binary at ${SHIM_BIN_DIR}/gc-docker-runner.
#   3. Drop a config file at ~/.config/gascity-docker-runner/config.toml.
#   4. Symlink ${SHIM_BIN_DIR}/claude → gc-docker-runner so PATH lookups
#      from gc-supervisor route through the shim.
#
# Usage:
#   ./install.sh                  # full install
#   ./install.sh --no-build       # skip docker build (re-use existing image)
#   ./install.sh --no-symlink     # skip the claude symlink (manual wiring)
#   ./install.sh --uninstall      # remove shim + symlinks (image untouched)

set -euo pipefail

cd "$(dirname "$0")"

SHIM_BIN_DIR="${SHIM_BIN_DIR:-$HOME/.local/bin/gascity-shims}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/gascity-docker-runner}"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/gascity-docker-runner/logs}"

DO_BUILD=1
DO_SYMLINK=1
ACTION=install

for arg in "$@"; do
    case "$arg" in
        --no-build)   DO_BUILD=0 ;;
        --no-symlink) DO_SYMLINK=0 ;;
        --uninstall)  ACTION=uninstall ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [ "$ACTION" = uninstall ]; then
    echo "→ removing shim and symlinks (image and logs preserved)"
    rm -f "$SHIM_BIN_DIR/gc-docker-runner" \
          "$SHIM_BIN_DIR/claude" \
          "$SHIM_BIN_DIR/codex" \
          "$SHIM_BIN_DIR/gemini"
    rmdir "$SHIM_BIN_DIR" 2>/dev/null || true
    echo "  note: config left at $CONFIG_DIR (delete by hand if desired)"
    echo "  note: agent-runner image left in place (docker rmi gascity-agent-runner:claude to remove)"
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Build agent image
# ---------------------------------------------------------------------------
if [ "$DO_BUILD" -eq 1 ]; then
    echo "→ building gascity-agent-runner:claude"
    docker build -t gascity-agent-runner:claude agent-runner/
else
    echo "→ skipping docker build (--no-build)"
    if ! docker image inspect gascity-agent-runner:claude >/dev/null 2>&1; then
        echo "  ⚠ image gascity-agent-runner:claude not present — re-run without --no-build"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 2. Install shim
# ---------------------------------------------------------------------------
echo "→ installing shim to $SHIM_BIN_DIR/gc-docker-runner"
mkdir -p "$SHIM_BIN_DIR"
cp shim/gc-docker-runner "$SHIM_BIN_DIR/gc-docker-runner"
chmod +x "$SHIM_BIN_DIR/gc-docker-runner"

# ---------------------------------------------------------------------------
# 3. Config
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR" "$LOG_DIR"
if [ ! -f "$CONFIG_DIR/config.toml" ]; then
    echo "→ writing default config to $CONFIG_DIR/config.toml"
    cp shim/config.example.toml "$CONFIG_DIR/config.toml"
else
    echo "→ config already exists at $CONFIG_DIR/config.toml (leaving it alone)"
fi

# ---------------------------------------------------------------------------
# 4. Symlinks (claude → shim)
# ---------------------------------------------------------------------------
if [ "$DO_SYMLINK" -eq 1 ]; then
    echo "→ symlinking $SHIM_BIN_DIR/claude → gc-docker-runner"
    ln -sf gc-docker-runner "$SHIM_BIN_DIR/claude"
else
    echo "→ skipping claude symlink (--no-symlink)"
fi

# ---------------------------------------------------------------------------
# PATH advice
# ---------------------------------------------------------------------------
case ":$PATH:" in
    *":$SHIM_BIN_DIR:"*)
        echo "  ✓ $SHIM_BIN_DIR is already on PATH"
        ;;
    *)
        cat <<EOF

  ⚠ $SHIM_BIN_DIR is NOT on your PATH yet. Add this to your shell rc and
    re-source it so 'gc' (and any other tool that looks up 'claude' on
    PATH) finds the shim before /usr/local/bin/claude:

      export PATH="$SHIM_BIN_DIR:\$PATH"

    Verify with:  which claude    # should print $SHIM_BIN_DIR/claude
EOF
        ;;
esac

cat <<EOF

→ install complete.

   Next:
     1. Make sure $SHIM_BIN_DIR is first on your PATH (see note above).
     2. Edit ~/.config/gascity-docker-runner/config.toml if you need to
        tweak limits or pin a different image.
     3. Run ./verify.sh to confirm the 7 isolation probes pass.
     4. Use Gas City normally — gc init / gc rig add / gc start. The shim
        sits between gc-supervisor and the agent CLI; nothing else changes.
EOF
