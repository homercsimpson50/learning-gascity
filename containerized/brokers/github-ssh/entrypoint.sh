#!/bin/sh
# gc-broker-github-ssh entrypoint.
#
# Starts an ssh-agent on a Unix socket inside a shared docker volume,
# loads the host-mounted SSH private key into it, makes the socket
# group-readable by gid 1000 (the agent uid), and stays in the
# foreground so `docker logs` works and `docker stop` is clean.
#
# Spec: docs/credential-broker-v2-spec.md §7.3.
#
# Required mounts:
#   /secrets/key         (ro) — private key file
#   /secrets/known_hosts (ro) — host's known_hosts (copied to volume)
#   /run/sshagent        (rw) — shared volume, agents mount this :ro

set -eu

KEY=${KEY_PATH:-/secrets/key}
SOCK=${SOCK_PATH:-/run/sshagent/gc.sock}
KH_SRC=/secrets/known_hosts
KH_DST=/run/sshagent/known_hosts
PASSPHRASE_FILE=${KEY_PASSPHRASE_FILE:-/secrets/passphrase}

[ -f "$KEY" ]    || { echo "[gc-broker-github-ssh] FATAL no key at $KEY" >&2; exit 1; }
[ -f "$KH_SRC" ] || { echo "[gc-broker-github-ssh] FATAL no known_hosts at $KH_SRC" >&2; exit 1; }

# Best-effort detect: a passphrase-protected key has the encoded header.
# OpenSSH ed25519 / rsa keys flag this with the "ENCRYPTED" marker on
# legacy PEM keys, or in the bcrypt-derived key data on new format keys.
# `ssh-keygen -y` succeeds without a passphrase only if the key is
# unencrypted. Use that as the truth check.
if ! ssh-keygen -y -P "" -f "$KEY" >/dev/null 2>&1; then
    if [ ! -f "$PASSPHRASE_FILE" ]; then
        cat >&2 <<EOF
[gc-broker-github-ssh] FATAL key at $KEY appears to be passphrase-protected.

This broker doesn't auto-prompt for passphrases. Either:
  1. Generate a dedicated unencrypted key for the agent broker
     (recommended; see docs/work-machine.md "Auth setup"):
         ssh-keygen -t ed25519 -f ~/.ssh/id_gc_agent -N ""
     and update [broker.github_ssh] key_file in
     ~/.config/gascity-docker-runner/config.toml.
  2. Mount a passphrase file at $PASSPHRASE_FILE (mode 0400) — the
     broker will use it via SSH_ASKPASS. Not recommended: the
     passphrase ends up on disk in plaintext while the broker runs.
EOF
        exit 1
    fi
fi

mkdir -p /run/sshagent
chmod 0700 /run/sshagent

# Copy known_hosts into the volume so agents can reach it via
# /run/sshagent/known_hosts (the agent's ssh_config_gc points there).
cp "$KH_SRC" "$KH_DST"
chmod 0644 "$KH_DST"

# Start ssh-agent in the foreground (-d) on a fixed socket path. tini is
# our PID 1; ssh-agent runs as PID 2 and we wait on it below.
ssh-agent -a "$SOCK" -d &
AGENT_PID=$!

# Wait for the socket to appear (3 seconds max).
i=0
while [ $i -lt 30 ]; do
    [ -S "$SOCK" ] && break
    i=$((i + 1))
    sleep 0.1
done
if [ ! -S "$SOCK" ]; then
    echo "[gc-broker-github-ssh] FATAL ssh-agent did not create $SOCK" >&2
    kill $AGENT_PID 2>/dev/null || true
    exit 1
fi

# Load the key. With a passphrase file mounted, use SSH_ASKPASS.
if [ -f "$PASSPHRASE_FILE" ]; then
    ASKPASS=$(mktemp)
    printf '#!/bin/sh\ncat %s\n' "$PASSPHRASE_FILE" > "$ASKPASS"
    chmod 0700 "$ASKPASS"
    DISPLAY=:0 SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
        SSH_AUTH_SOCK="$SOCK" ssh-add "$KEY" </dev/null
    rm -f "$ASKPASS"
else
    SSH_AUTH_SOCK="$SOCK" ssh-add "$KEY"
fi

# Make the socket connectable by uid 1000 (the agent user) without
# giving the agent write access to /run/sshagent/.
chgrp 1000 "$SOCK"
chmod 0660 "$SOCK"

echo "[gc-broker-github-ssh] ready key=$(basename "$KEY") sock=$SOCK"
touch /tmp/.healthy

# Wait on ssh-agent. tini will reap and forward SIGTERM cleanly.
wait $AGENT_PID
