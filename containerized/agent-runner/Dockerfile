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

ARG CLAUDE_INSTALL_URL=https://claude.ai/install

# Runtime dependencies — Gas City rigs commonly need git, gh, jq, tmux
# and curl for tool calls. ca-certificates is needed for HTTPS.
# tini reaps zombies + handles signals so `docker stop` is clean.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    gh \
    jq \
    tmux \
    curl \
    ca-certificates \
    tini \
    sudo \
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

# Install Claude Code as the agent user so its config + version cache live
# under /home/agent. The official installer drops the binary into
# ~/.local/bin/claude. We then symlink to /usr/local/bin so PATH lookups
# work even if /home/agent gets a tmpfs mount over .local/bin (it doesn't,
# but defence in depth).
USER agent
RUN curl -fsSL "$CLAUDE_INSTALL_URL" | bash || \
    (echo "claude install failed — verify $CLAUDE_INSTALL_URL is reachable from your build network"; exit 1)
USER root
RUN ln -sf /home/agent/.local/bin/claude /usr/local/bin/claude

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
