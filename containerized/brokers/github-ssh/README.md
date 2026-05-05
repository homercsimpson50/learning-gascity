# gc-broker-github-ssh

Holds the host's GitHub SSH key inside a long-lived `ssh-agent` and
exposes its Unix socket via a shared docker volume. Agent containers
mount the volume read-only and use it as their `SSH_AUTH_SOCK` —
signing requests go to the broker, the agent never sees the key bytes.

Spec: [`docs/credential-broker-v2-spec.md §7.3`](../../../docs/credential-broker-v2-spec.md).

## What gets mounted

- `~/.ssh/<key>:/secrets/key:ro` — private key (host-selected via
  `[broker.github_ssh] key_file` in `config.toml`).
- `~/.ssh/known_hosts:/secrets/known_hosts:ro` — copied into the volume
  at startup so agents can reach it.
- `gc-sshagent-sock:/run/sshagent` (rw) — the shared volume; agents get
  the same volume `:ro` and find the socket at `/run/sshagent/gc.sock`.

## Why the broker runs as root (and that's OK)

The broker creates the socket and `chgrp`s it to gid 1000 so the agent
container (which runs as uid 1000) can connect. That requires
`CAP_CHOWN`, which we get by running `--user 0:0` and then dropping all
caps except CHOWN.

This is acceptable because:

- The broker rootfs is `--read-only`.
- The broker image carries no shells beyond `/bin/sh` (dash) and no
  general-purpose networking tools (no `curl`, `wget`, `nc`) per spec
  §6.3.
- `--security-opt no-new-privileges` and `--cap-drop ALL` (then
  `--cap-add CHOWN`) bound what root can do.

The cleaner alternative — drop privileges after socket creation — would
require splitting ssh-agent's lifecycle from the privileged setup,
which adds a fork/exec step and more code paths. The spec calls this
out in §7.3 ("simpler alternative: just stay root"); we picked simpler.

## Passphrase handling

The broker won't prompt interactively. Two supported modes:

1. **Unencrypted dedicated key (recommended).** Generate a key
   specifically for the agent and add the public part to GitHub:

   ```
   ssh-keygen -t ed25519 -f ~/.ssh/id_gc_agent -N ""
   cat ~/.ssh/id_gc_agent.pub   # paste into github.com/settings/keys
   ```

   Then point the broker at it:

   ```toml
   [broker.github_ssh]
   key_file = "~/.ssh/id_gc_agent"
   ```

2. **Passphrase file.** If the configured key is encrypted, mount a
   plaintext passphrase file as `/secrets/passphrase` (mode 0400). The
   broker uses `SSH_ASKPASS` to read it once at startup. Not
   recommended for v2; the passphrase ends up on disk in plaintext.

If your configured key is encrypted and no passphrase file is mounted,
the broker exits with a FATAL message pointing at this README.

## What the agent sees

The agent's `ssh_config_gc` (shipped in the runner image at
`/etc/ssh/ssh_config_gc`) sets:

```
Host github.com
  IdentityAgent /run/sshagent/gc.sock
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile /run/sshagent/known_hosts
```

The shim injects `GIT_SSH_COMMAND=ssh -F /etc/ssh/ssh_config_gc` so
`git push`, `git fetch`, `gh repo clone`, etc. all use this config
without the agent having to know about it.

## v2 limitation: account-wide SSH scope

The vanilla ssh-agent protocol doesn't carry the destination repo
through to the signing request, so we can't enforce
`REPO_ALLOWLIST` on `git push` over SSH. The broker only loads keys for
github.com, and the agent network has no route to anywhere else, but
within github.com the agent can push to any repo this key has write
access to.

The repo allowlist still applies to API operations
(`gc-broker-github-api`), where most repo-scoped writes happen (PR
creation, issue updates, comment posting). True repo-scoped SSH push
enforcement is v2.5 work — see spec §7.3 Option B (bare-clone
middleware).
