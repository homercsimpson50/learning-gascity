#!/bin/sh
# agent-runner entrypoint.
#
# Contract with the host shim (gc-docker-runner):
#
#   - /work is bind-mounted to the rig's worktree (rw).
#   - GC_RIG_PREFIX, GC_BEAD_ID, GC_AGENT_NAME, GC_SESSION_ID are exported
#     by the supervisor and forwarded by the shim.
#   - API keys (ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.) are forwarded as
#     env vars only — never bind-mounted from the host.
#
# This script:
#   1. Prints a single-line audit preamble (image digest, mount list, env
#      keys — values are NOT printed).
#   2. cd into /work.
#   3. Execs the agent CLI with the args passed to the container CMD.
#
# Reference: docs/containerizing-gascity-for-local-use-spec.md §3.1, §7.

set -eu

# --- 1. Audit preamble -----------------------------------------------------
# Print a single-line summary of what this container looks like, so when a
# user later goes "what was that session?" they have something in the log.
# Image digest is read from the canonical label set by `docker build` (or
# missing during local development).
DIGEST="$(cat /etc/gascity-image-digest 2>/dev/null || echo unknown)"
ENV_KEYS="$(env | awk -F= '{print $1}' | sort | tr '\n' ',' | sed 's/,$//')"
echo "[agent-runner] start image=${DIGEST} rig=${GC_RIG_PREFIX:-?} bead=${GC_BEAD_ID:-?} agent=${GC_AGENT_NAME:-?} session=${GC_SESSION_ID:-?} envkeys=${ENV_KEYS}"

# --- 2. Sanity-check the rig mount -----------------------------------------
if [ ! -d /work ]; then
    echo "[agent-runner] FATAL /work is missing — shim must bind-mount the rig worktree" >&2
    exit 64
fi
cd /work

# --- 3. Apply git identity if the supervisor exported it -------------------
# Optional. Lets agents `git commit` from inside the container without
# manual config. Skipped silently if not provided.
if [ -n "${GC_GIT_USER:-}" ] && [ -n "${GC_GIT_EMAIL:-}" ]; then
    git config --global user.name  "$GC_GIT_USER"  2>/dev/null || true
    git config --global user.email "$GC_GIT_EMAIL" 2>/dev/null || true
fi

# --- 4. Hand off to the agent CLI ------------------------------------------
# CMD ("claude" by default) and any extra args from the shim are in "$@".
exec "$@"
