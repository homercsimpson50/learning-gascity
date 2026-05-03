# Gas City — clean container image, built from upstream source at build time.
#
# Build context is THIS directory (no need to clone gascity-src first).
# A multi-stage build clones gascity at the pinned ref, compiles `gc`, then
# copies just the binary into the runtime image. Override the version with
# --build-arg GASCITY_REF=<tag-or-sha>.
#
# Build:
#   docker build -t gascity:latest containerized/
#
# Or via compose, which forwards build args from .env:
#   docker compose build

# ---------------------------------------------------------------------------
# Stage 1 — builder: clone the gascity repo and compile `gc`.
# ---------------------------------------------------------------------------
FROM golang:1.25-bookworm AS builder

ARG GASCITY_REPO=https://github.com/gastownhall/gascity.git
ARG GASCITY_REF=main

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates make \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone "$GASCITY_REPO" gascity \
    && cd gascity \
    && git checkout "$GASCITY_REF" \
    && echo "Built from gascity ref: $(git rev-parse HEAD)"

WORKDIR /src/gascity
RUN make build && cp bin/gc /out-gc \
    && /out-gc version

# ---------------------------------------------------------------------------
# Stage 2 — runtime: minimal image with `gc`, `bd`, `dolt`, and Claude Code.
# ---------------------------------------------------------------------------
FROM docker/sandbox-templates:claude-code AS runtime

USER root

# Gas City runtime dependencies. Reference: gascity README "Prerequisites" —
#   tmux, git, jq, pgrep (procps), lsof, flock (util-linux),
#   plus dolt + bd for the default beads provider.
# dbus + gnome-keyring + libsecret-1-0: needed by Claude Code's libsecret
# credential storage on Linux.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    sqlite3 \
    tmux \
    curl \
    jq \
    procps \
    lsof \
    util-linux \
    ripgrep \
    zsh \
    gh \
    netcat-openbsd \
    tini \
    vim \
    dbus dbus-x11 \
    gnome-keyring \
    libsecret-1-0 \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# `bd` (beads) and `dolt`. Both are required by the default `bd` beads
# provider; gascity's `gc init` will refuse `gc start` without them.
RUN curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash \
    && curl -fsSL https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash

# `gc` from the builder stage. Single static Go binary.
COPY --from=builder /out-gc /usr/local/bin/gc
RUN chmod +x /usr/local/bin/gc

# Workspace + dolt data directory. Keep dolt data on its own subpath so the
# compose file can mount it on a Docker volume separately, avoiding
# VirtioFS journal corruption when running on macOS.
RUN mkdir -p /city /city/.gc /city/.dolt-data \
    && chown -R agent:agent /city

# Pre-create /home/agent/.config so the bind mount of ~/.config/gh doesn't
# create the parent dir as root (which would block the entrypoint from
# writing /home/agent/.config/gh/hosts.yml). Same for .local subpaths the
# Claude Code state volumes mount under.
RUN mkdir -p /home/agent/.config \
            /home/agent/.local/state/claude \
            /home/agent/.local/share/claude \
    && chown -R agent:agent /home/agent/.config /home/agent/.local

# PATH + terminal env for both shells (so `gc` works in interactive `exec`
# sessions without sourcing anything).
RUN echo 'export PATH="/usr/local/bin:$PATH"' >> /etc/profile.d/gascity.sh && \
    echo 'export PATH="/usr/local/bin:$PATH"' >> /etc/zsh/zshenv && \
    echo 'export COLORTERM="truecolor"'      >> /etc/profile.d/colorterm.sh && \
    echo 'export COLORTERM="truecolor"'      >> /etc/zsh/zshenv && \
    echo 'export TERM="xterm-256color"'      >> /etc/profile.d/term.sh && \
    echo 'export TERM="xterm-256color"'      >> /etc/zsh/zshenv

# Entrypoint extracted to its own file (kept under containerized/ for diff
# review independent of the Dockerfile).
COPY --chown=agent:agent docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER agent
WORKDIR /city

ENTRYPOINT ["tini", "--", "/usr/local/bin/docker-entrypoint.sh"]

# Default: foreground supervisor (the in-container equivalent of `gc start`,
# which on the host registers a launchd/systemd service — pointless inside
# a container that's already a single managed process). Override for shells:
#   docker compose run --rm gascity bash
CMD ["gc", "supervisor", "run"]
