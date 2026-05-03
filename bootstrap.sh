#!/usr/bin/env bash
# bootstrap.sh — set up learning-gascity on a brand-new machine.
#
# What this does, in order:
#   1. Verify git + docker are installed (too big to auto-install).
#   2. Install Homebrew (macOS) if missing.
#   3. Install gc (Gas City CLI) via the official Homebrew tap.
#   4. Install bd (Beads) via the official install script.
#   5. Install dolt + flock (Gas City's default beads provider deps).
#   6. Run containerized/install.sh to build the agent image, install
#      the shim, and install the `gc-docker` wrapper.
#
# Re-runnable: every step skips itself if its target is already there.
#
# Usage on a brand-new machine:
#   git clone https://github.com/homercsimpson50/learning-gascity ~/code/learning-gascity
#   cd ~/code/learning-gascity
#   ./bootstrap.sh
#
# When this finishes, you have:
#   - `gc` and `bd` on PATH (host-native gascity, untouched by the shim)
#   - `gc-docker` on PATH (opt-in wrapper that routes agents through Docker)
#   - The agent-runner image built and ready
#   - All 7 isolation probes passing

set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\e[1;36m→\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m✓\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m⚠\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31m✗\e[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Hard prereqs
# ---------------------------------------------------------------------------
command -v git    >/dev/null 2>&1 || die "git is required — install Xcode Command Line Tools (\`xcode-select --install\`) or your OS package manager"
command -v docker >/dev/null 2>&1 || die "docker is required — install Docker Desktop: https://www.docker.com/products/docker-desktop"
ok "git and docker present"

# ---------------------------------------------------------------------------
# 2. Homebrew (macOS only)
# ---------------------------------------------------------------------------
if [ "$(uname)" = Darwin ]; then
    if command -v brew >/dev/null 2>&1; then
        ok "Homebrew present"
    else
        say "Installing Homebrew (one-time)"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # On Apple Silicon, brew lands in /opt/homebrew which isn't on PATH yet
        if [ -x /opt/homebrew/bin/brew ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -x /usr/local/bin/brew ]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        ok "Homebrew installed"
    fi
fi

# ---------------------------------------------------------------------------
# 3. gc (Gas City)
# ---------------------------------------------------------------------------
if command -v gc >/dev/null 2>&1; then
    ok "gc present ($(gc version 2>/dev/null | head -1))"
else
    say "Installing gc via Homebrew tap gastownhall/gascity"
    if [ "$(uname)" != Darwin ]; then
        die "gc auto-install is macOS-only. On Linux, build from source: https://github.com/gastownhall/gascity"
    fi
    brew install gastownhall/gascity/gascity
    ok "gc installed: $(gc version | head -1)"
fi

# ---------------------------------------------------------------------------
# 4. bd (Beads)
# ---------------------------------------------------------------------------
if command -v bd >/dev/null 2>&1; then
    ok "bd present ($(bd --version 2>/dev/null | head -1))"
else
    say "Installing bd via the official install script"
    curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
    ok "bd installed: $(bd --version 2>/dev/null | head -1)"
fi

# ---------------------------------------------------------------------------
# 5. dolt + flock (gc's default beads provider deps)
# ---------------------------------------------------------------------------
if [ "$(uname)" = Darwin ]; then
    for pkg in dolt flock; do
        if brew list --formula 2>/dev/null | grep -qx "$pkg"; then
            ok "$pkg present"
        else
            say "Installing $pkg"
            brew install "$pkg"
            ok "$pkg installed"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 6. Hand off to containerized/install.sh
# ---------------------------------------------------------------------------
say "Running containerized/install.sh"
echo
./containerized/install.sh "$@"

cat <<EOF

\e[1;32m✓ Bootstrap complete.\e[0m

   Your normal claude (if installed) and gc keep working as before.
   To run gc with sandboxed agents, type 'gc-docker' instead of 'gc':

       gc-docker init ~/test-city
       gc-docker supervisor run

   Full guide: containerized/README.md
EOF
