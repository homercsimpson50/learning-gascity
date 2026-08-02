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
        # Upstream tap prefix no longer required; formula is just `gascity`.
        brew upgrade gascity 2>&1 | tail -3 || true
        ok "gc: $(gc version | head -1)"
    elif command -v gc >/dev/null 2>&1; then
        # gc is on PATH but not from brew (e.g. `go install ~/go/bin/gc`).
        # Upgrade path is manual — just tell the operator; don't clobber.
        warn "gc detected at $(command -v gc) but not installed via brew"
        warn "  to switch to brew (recommended):"
        warn "    rm -f ~/.local/bin/gc     # if symlinked here"
        warn "    brew install gascity"
        warn "  to stay on go install:"
        warn "    GOBIN=~/go/bin go install github.com/gastownhall/gascity/cmd/gc@latest"
    fi
    if brew list --formula 2>/dev/null | grep -qx dolt; then
        say "Upgrading dolt via Homebrew"
        # gc 1.4+ requires dolt ≥ 2.1.0; brew tracks upstream latest.
        brew upgrade dolt 2>&1 | tail -3 || true
        ok "dolt: $(dolt version | head -1)"
    fi
fi

# 3. bd via official install script (idempotent, replaces existing)
say "Re-installing bd to pick up the latest (gc 1.4+ needs ≥ 1.0.4)"
# Canonical URL is now gastownhall/beads; steveyegge/beads still works.
curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | bash 2>&1 | tail -3 || true
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

# v2 broker migration notice — only printed once per machine.
NOTICE_MARK="$HOME/.local/state/gascity-docker-runner/.v2-notice-shown"
if [ ! -f "$NOTICE_MARK" ] && [ -f "$HOME/.config/gascity-docker-runner/config.toml" ]; then
    if ! grep -q '^\[broker\]' "$HOME/.config/gascity-docker-runner/config.toml" 2>/dev/null; then
        cat <<'NOTICE'

──────────────────────────────────────────────────────────────────────────
 v2 credential brokers are available.

 Three sidecar containers now hold credentials so agents authenticate to
 Anthropic and GitHub without host secrets in the agent container.

 To enable:
   1. Add [broker] sections to ~/.config/gascity-docker-runner/config.toml
      (see containerized/shim/config.example.toml for the schema).
   2. Generate or pick an SSH key for the broker; update broker.github_ssh.key_file.
   3. Run: cd containerized && ./install.sh    (rebuilds broker images)
   4. export GH_TOKEN=ghp_…  in your shell, then: gc-docker-start.sh

 Read docs/credential-broker-v2-spec.md §10.2 for the full setup checklist.
 Until you opt in, agents fall back to v1 behavior (no auth in container).
──────────────────────────────────────────────────────────────────────────

NOTICE
        mkdir -p "$(dirname "$NOTICE_MARK")"
        touch "$NOTICE_MARK"
    fi
fi

cat <<EOF

\e[1;32m✓ Upgrade complete.\e[0m

   Verify:
       gc version
       bd --version
       docker images gascity-agent-runner gascity-broker-anthropic gascity-broker-github-api gascity-broker-github-ssh
       cd containerized && ./verify.sh      # v1 probes + v2 broker probes (skips if brokers down)

   If you were running a workspace, you'll want to swap supervisors so
   the new gc binary is in charge:
       gc-workspace-home.sh   # or gc-workspace-work.sh
EOF
