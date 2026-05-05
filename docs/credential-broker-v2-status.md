# v2 broker rollout — current status

**Last updated:** 2026-05-05 (commit `6d96fd8`).
**Spec:** [`credential-broker-v2-spec.md`](credential-broker-v2-spec.md).
**Purpose of this file:** scratchpad so a fresh Claude / a second machine
can pick up the rollout without re-tracing the conversation. Delete it
once v2 is fully validated end-to-end.

## What is built and merged

All four phases in spec §14 are landed:

- [x] **Phase 1** — Anthropic broker (`containerized/brokers/anthropic/`).
  - Python 3.12 + aiohttp; reads `/secrets/creds.json` on every request.
  - Path allowlist, 16 MiB body cap, `max_tokens > 200000` guard,
    optional `MODEL_ALLOWLIST`, streaming via `iter_any()`, structured
    JSON logs to stdout.
- [x] **Phase 2** — GitHub-API broker (`containerized/brokers/github-api/`).
  - GH_TOKEN read once at startup; method+path+repo allowlist; hard
    denylist of `/user/keys`, `/admin/`, etc.; `/user` response trimmed
    to `{login,id,type}`.
- [x] **Phase 3** — GitHub-SSH broker (`containerized/brokers/github-ssh/`).
  - debian-slim + openssh-client + tini.
  - Loads key via `ssh-add` (refuses passphrase-protected keys unless
    `/secrets/passphrase` is mounted).
  - Socket on shared volume `gc-sshagent-sock`; `chgrp 1000 → 0660` so
    agents (uid 1000) can connect without write access to the dir.
  - Agent runner image now ships `/etc/ssh/ssh_config_gc` pinned at the
    broker socket and the broker's copy of `known_hosts`.
- [x] **Phase 4** — shim + verify + docs.
  - `gc-docker-runner`: dropped `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
    `GOOGLE_API_KEY`, `CLAUDE_API_KEY`, `GH_TOKEN` from `FORWARD_ENV`;
    added `INJECT_ENV` array with the broker base URLs +
    `SSH_AUTH_SOCK` + `GIT_SSH_COMMAND`; forces `--network gc-broker-net`
    and mounts `gc-sshagent-sock:/run/sshagent:ro`.
  - `install.sh`: builds three broker images, creates
    `gc-broker-net (--internal)` + `gc-egress-net` + volume, all
    idempotent.
  - `gascity-docker-start.sh`: new `ensure_brokers()` runs the keychain
    extractor, starts the three brokers wired to both networks, waits
    for the `/tmp/.healthy` marker each broker touches.
  - `gascity-docker-stop.sh`: stops broker containers (networks +
    volume preserved).
  - `uninstall.sh`: tears down broker containers, networks, volume.
  - `verify.sh`: adds A/B/C probe suites that skip cleanly if brokers
    aren't running.
  - `upgrade.sh`: prints a one-time v2 migration notice when a v1
    config is detected without `[broker]` sections.
  - `CLAUDE.md` + `containerized/README.md` reference the spec.

## Macos-specific deviation from the spec

Spec §7.1 assumes `~/.claude/.credentials.json` exists on the host.
Recent Claude Code on macOS stores OAuth in **Keychain**, not a flat
file. We bridged this with:

- `scripts/gc-broker-creds-extract.sh` — runs `security
  find-generic-password -s "Claude Code-credentials" -w` and writes the
  JSON to `~/.local/state/gascity-broker/creds.json` (mode 0600,
  atomic).
- The Anthropic broker's `credentials_file` default in
  `config.example.toml` points at that state path instead of
  `~/.claude/.credentials.json`.
- `gascity-docker-start.sh` invokes the extractor before starting the
  Anthropic broker.

Linux hosts (which DO have the flat file) can override
`broker.anthropic.credentials_file` directly to `~/.claude/.credentials.json`.

## Test results — passing

Run from `~/code/learning-gascity` on this machine on 2026-05-05:

| Suite | Result | Notes |
|---|---|---|
| **A1** broker images present | ✓ | 4 images built; `gc-broker-net.internal=true` |
| **A3** syntax | ✓ | All 10 modified scripts pass `bash -n` / `py_compile` |
| **B1+B2** keychain extract | ✓ | mode 0600, idempotent, `claudeAiOauth.accessToken` present |
| **C1–C7** anthropic | 7/7 ✓ | streaming returned 19 chunks; logs are clean structured JSON |
| **D1–D6** github-api | 6/6 ✓ | DELETE/`/user/keys`/non-allowlisted repo all 403; `/user` trimmed to `{id,login,type}` |
| **E** network isolation | ✓ | gc-broker-net blocks DNS for `api.anthropic.com` and `api.github.com` |
| **F** shim env injection | 6/6 ✓ | broker URLs injected; secrets NOT forwarded; ssh_config_gc shipped; broker reachable from agent; direct egress blocked |

## Pending (blocked on user-provided SSH key)

The github-ssh broker can't start without an unencrypted key file. The
user is expected to generate one (we agreed not to auto-generate). When
ready, run:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/id_gc_agent -N ""
gh ssh-key add ~/.ssh/id_gc_agent.pub --title "gc-broker"
export GH_TOKEN="$(gh auth token)"
gc-docker-start.sh                        # brings supervisor + brokers up
cd ~/code/learning-gascity/containerized && ./verify.sh
```

That unblocks:

- **B1** ssh-add -l from gc-broker-net shows the loaded key
- **B3** `ssh -T -F /etc/ssh/ssh_config_gc git@github.com` authenticates
- **D1** end-to-end `claude -p "hello"` from a polecat agent (spec §11.D1)
- end-to-end `gh issue list -R homercsimpson50/learning-gascity` from inside the agent
- end-to-end `git push` to an allowlisted repo from inside the agent

## User's local config additions

The user's `~/.config/gascity-docker-runner/config.toml` was hand-edited
to add the `[broker.*]` sections during testing, since `install.sh`
preserves an existing config. The schema is in
`containerized/shim/config.example.toml`. Their `repo_allowlist` is set
to `["knail1/*", "homercsimpson50/*"]` for both github_api and
github_ssh. The default in `config.example.toml` is empty by intent
(per user request) — `install.sh` won't overwrite an existing config.

## How to fully exercise on another machine

1. `git pull` to commit `6d96fd8` or later.
2. `./bootstrap.sh` if it's a fresh machine; otherwise
   `cd containerized && ./install.sh`.
3. Edit `~/.config/gascity-docker-runner/config.toml` to add `[broker.*]`
   sections (copy from `containerized/shim/config.example.toml`,
   uncomment the `repo_allowlist` examples, set `key_file` to whatever
   key you'll use).
4. Generate the agent SSH key (see "Pending" above) — or set
   `[broker] enabled = false` to skip broker setup entirely and fall
   back to v1 behavior.
5. `export GH_TOKEN=$(gh auth token)`.
6. `gc-docker-start.sh`.
7. `cd containerized && ./verify.sh`.

## Known follow-ups (out of scope for this rollout)

- `docs/work-machine.md` does not yet have the v2 setup section called
  for in spec §10.2. Phase 4 deliverable list mentions it but the user
  prioritized testing first; treat it as the next doc PR.
- Image digest pinning (spec §13.7) deferred.
- Bare-clone middleware for true repo-scoped SSH (spec §7.3 Option B)
  deferred.
- Periodic Keychain refresh (a launchd LaunchAgent on macOS) deferred —
  for now, `gc-docker-start.sh` re-extracts on each invocation; if the
  user gets 401s after a long pause, re-running `gc-docker-start.sh`
  refreshes.
