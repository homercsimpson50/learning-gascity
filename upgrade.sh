#!/usr/bin/env bash
# upgrade.sh — bring everything up to date.
#
# What this updates:
#   1. The repo itself (git pull on main).
#   2. The host gc / bd / dolt binaries (brew upgrade for gc + dolt;
#      re-runs the bd install script for the latest bd).
#   3. The containerized agent image (rebuilds gascity-agent-runner:claude
#      with --no-cache so the npm-installed Claude Code picks up its
#      latest release).
#   4. Re-installs the shim, wrapper, and workspace launchers so any
#      script changes from the pull take effect.
#
# Re-runnable. Anything already up to date is a no-op.
#
# Usage:
#   ./upgrade.sh            # full upgrade
#   ./upgrade.sh --no-image # skip the docker image rebuild (faster)

set -euo pipefail
cd "$(dirname "$0")"

NO_IMAGE=0
for arg in "$@"; do
    case "$arg" in
        --no-image) NO_IMAGE=1 ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

say()  { printf '\e[1;36m→\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m✓\e[0m %s\n' "$*"; }

# 1. Repo
say "Pulling latest learning-gascity"
git pull --ff-only origin main || {
    echo "  git pull failed (uncommitted changes? wrong branch?). Resolve and re-run." >&2
    exit 1
}
ok "repo up to date ($(git rev-parse --short HEAD))"

# 2. gc / dolt via brew (if installed via brew)
if command -v brew >/dev/null 2>&1; then
    if brew list --formula 2>/dev/null | grep -qx gascity; then
        say "Upgrading gc via Homebrew"
        brew upgrade gastownhall/gascity/gascity 2>&1 | tail -3 || true
        ok "gc: $(gc version | head -1)"
    fi
    if brew list --formula 2>/dev/null | grep -qx dolt; then
        say "Upgrading dolt via Homebrew"
        brew upgrade dolt 2>&1 | tail -3 || true
        ok "dolt: $(dolt version | head -1)"
    fi
fi

# 3. bd via official install script (idempotent, replaces existing)
say "Re-installing bd to pick up the latest"
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash 2>&1 | tail -3 || true
ok "bd: $(bd --version 2>/dev/null | head -1)"

# 4. Containerized: rebuild image + re-install shim/wrapper
if [ "$NO_IMAGE" -eq 1 ]; then
    say "Skipping image rebuild (--no-image); re-installing shim and wrappers only"
    ./containerized/install.sh --no-build --no-verify
else
    say "Rebuilding agent image (no cache) + re-installing shim and wrappers"
    cd containerized
    docker build --no-cache -t gascity-agent-runner:claude agent-runner/ >/dev/null
    ok "image rebuilt"
    ./install.sh --no-build --no-verify
    cd ..
fi

cat <<EOF

\e[1;32m✓ Upgrade complete.\e[0m

   Verify:
       gc version
       bd --version
       docker images gascity-agent-runner   # check latest tag/created time
       cd containerized && ./verify.sh      # 7 isolation probes

   If you were running a workspace, you'll want to swap supervisors so
   the new gc binary is in charge:
       gc-workspace-home.sh   # or gc-workspace-work.sh
EOF
