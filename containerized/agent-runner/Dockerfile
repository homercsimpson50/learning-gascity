# gascity-agent-runner — minimal image that runs ONE coding agent against ONE
# rig worktree mounted at /work. Spawned by the host-side shim
# (`gc-docker-runner`) every time Gas City needs an agent session.
#
# Reference: docs/containerizing-gascity-for-local-use-spec.md §3.1
#
# Build:
#   docker build -t gascity-agent-runner:claude agent-runner/
#
# Adding more agents (codex, gemini, etc.) is one new build target each —
# follow the same pattern: install the agent's CLI, expose its name via
# the entrypoint argv. Keep one agent per image to minimize attack surface.

FROM debian:stable-slim

# Runtime dependencies — Gas City rigs commonly need git, gh, jq, tmux
# and curl for tool calls. ca-certificates is needed for HTTPS.
# tini reaps zombies + handles signals so `docker stop` is clean.
# nodejs + npm are needed because Claude Code is distributed as the
# npm package @anthropic-ai/claude-code; the install.sh script at
# claude.ai/install is Cloudflare-gated and isn't fetchable from CI.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    gh \
    jq \
    tmux \
    curl \
    ca-certificates \
    tini \
    sudo \
    gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Non-root user. uid 1000 matches the typical first user on Linux hosts so
# files written into the bind-mounted /work end up owned correctly when the
# host user is also uid 1000. macOS hosts use Docker Desktop's user-mapping
# which makes the uid less significant.
RUN groupadd --gid 1000 agent \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash agent

# /work is the only mutable host-bound path. /tmp and /home/agent/.cache are
# tmpfs-mounted by the shim so the rootfs can stay --read-only.
RUN mkdir -p /work && chown agent:agent /work

# Install Claude Code globally via npm. The official npm package name is
# @anthropic-ai/claude-code and it ships a `claude` bin shim. Install as
# root so it lands on a system PATH (/usr/bin/claude); agent runs claude
# read-only.
ARG CLAUDE_VERSION=latest
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
    && claude --version

# Entrypoint validates the env contract from the shim, drops to agent, and
# execs the CLI. Kept in its own file (not a heredoc) for grep-ability.
COPY --chown=root:root entrypoint.sh /usr/local/bin/agent-entrypoint.sh
RUN chmod +x /usr/local/bin/agent-entrypoint.sh

USER agent
WORKDIR /work

# tini is PID 1 so SIGTERM from `docker stop` reaches the agent cleanly.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agent-entrypoint.sh"]

# Default CMD launches claude. The shim overrides this if invoked under a
# different agent symlink (e.g. codex, gemini), and forwards extra args.
CMD ["claude"]
