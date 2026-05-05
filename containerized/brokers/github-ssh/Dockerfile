# gc-broker-github-ssh — runs ssh-agent with the host's selected SSH
# key loaded; exposes the agent socket to other containers via a shared
# named volume (mode 0660, gid 1000).
#
# Spec: docs/credential-broker-v2-spec.md §6, §7.3.
#
# This broker is fundamentally different from the HTTP brokers: there's
# no listening port, just a Unix socket on a docker volume that agent
# containers mount read-only.

FROM debian:stable-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openssh-client \
        ca-certificates \
        tini \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Run as root so we can chgrp the socket to gid 1000 (agent uid).
# The broker rootfs is --read-only, has no shells beyond /bin/sh + dash,
# no curl/wget/nc per spec §6.3, so escalation surface is bounded. See
# the README for the rationale and the alternatives considered.
USER 0:0

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
