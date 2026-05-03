# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is (and isn't)

This repo is a **harness** for upstream
[gastownhall/gascity](https://github.com/gastownhall/gascity). Gas City source
lives upstream — never vendored here. There is no Go/Python/JS code to lint
or test. Two ways to run it, side by side:

- **`containerized/`** — Docker setup. The Dockerfile clones gascity at a
  pinned ref and compiles `gc` in-image. Used when you want gascity isolated
  from your host (corporate laptop, untrusted agents, repeatable builds).
- **`scripts/`** — local launcher. The `gascity-workspace.{sh,py}` scripts
  open an iTerm2 layout against a **local** city at `~/gc`, mirroring the
  layout used for gastown at `~/gt`. Used when you want gascity native on the
  host.

When the user asks to "fix gascity behavior X," check whether X lives in this
harness (Dockerfile/compose, entrypoint, workspace script) or upstream (the
`gc` CLI itself, formulas, beads, runtime providers). Upstream fixes need a
`GASCITY_REF` bump in `.env` for the container, or a `gc` binary upgrade for
the local install — not edits here.

## Common commands

### Containerized (`containerized/`)

```bash
./start.sh              # build (if needed), bring up, smoke test
./start.sh --rebuild    # force --no-cache rebuild
./start.sh --shell      # bring up + drop into shell
./start.sh --down       # stop, preserve volumes
./start.sh --wipe       # stop + delete all volumes (full reset, prompts to confirm)

docker compose exec gascity bash                    # shell into running container
docker compose exec gascity gc version              # smoke test
docker compose exec gascity bash -c 'cd /city && gc doctor'   # health check (warnings OK)
docker compose logs -f gascity                      # tail logs
```

### Local (`~/gc` city, `scripts/`)

```bash
./scripts/gascity-workspace.sh        # AppleScript: opens 4-pane iTerm2 layout
./scripts/gascity-workspace.py        # iTerm2 Python API equivalent

cd ~/gc && gc doctor                  # health check
cd ~/gc && gc status                  # city + sessions
cd ~/gc && gc session attach mayor    # attach to mayor (also what the workspace's left pane runs)
cd ~/gc && gc events --follow         # live event stream (the "feed" pane)
gc supervisor status                  # is the machine-wide supervisor up?
```

There are no unit tests. Validation is: `start.sh` (or the local supervisor)
runs clean, `gc version` returns, `gc doctor` reports no errors (warnings OK).

## Architecture

### Local install layout (`~/gc`, `~/.gc`, `scripts/`)

The local setup mirrors the gastown convention (`~/gt`):

- `~/gc/` — the **city directory**. Created by `gc init --provider claude .`
  (note: local `gc` v1.0.1 names the provider `claude`, not `claude-code`
  like the container default). Contains `city.toml`, `pack.toml`, `.gc/`
  runtime, `.beads/` dolt-backed bead store, and the `agents/`, `formulas/`,
  `orders/`, `overlays/` subdirs.
- `~/.gc/` — the **machine-wide supervisor state**: `cities.toml` (registry
  of all local cities), `supervisor.log`, `supervisor.lock`, `events.jsonl`.
  Don't confuse this with `~/gc/.gc/` — the latter is the city's own runtime.
- `~/Library/LaunchAgents/com.gascity.supervisor.plist` — launchd autostart,
  installed by `gc start` / `gc init`. Survives reboots.

`gc init` is interactive by default; pass `--provider claude` to
non-interactively scaffold + register + bring up the city in one shot.

**bd version gotcha**: gascity v1.0.1 expects `bd` ≥ 1.0.3. Older `bd`
(1.0.0) silently rejects the city's custom issue types (`session`, `agent`,
`molecule`, etc.) with `validation failed for issue : invalid issue type:
session`, which surfaces as the supervisor's mayor session staying in
`reserved-unmaterialized`. Fix: re-run the `bd` install script
(`curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash`).
This had to be done once on this host.

### iTerm2 workspace layout (`scripts/gascity-workspace.{sh,py}`)

Cloned from `~/code/learning-gastown/scripts/gastown-workspace.{sh,py}` with
gascity commands substituted:

- Left tall pane: `cd ~/gc && gc supervisor start; gc session attach mayor`
- Top-mid pane: `docker compose exec gascity gc session attach mayor` (the
  containerized city — only useful if `containerized/` is also up)
- Top-right pane: plain shell at `~/code`
- Bottom wide pane: `gc events --follow` (replaces gastown's `gt feed`; gc
  emits JSON-Lines, not a TUI)

Both scripts produce the same layout — `.sh` uses AppleScript via
`osascript`, `.py` uses the iTerm2 Python API (which must be enabled in
iTerm2 → Preferences → General → Magic).

### Two-stage Docker build (`containerized/Dockerfile`)

1. **`builder`** (`golang:1.25-bookworm`): `git clone` of `${GASCITY_REPO}` at
   `${GASCITY_REF}`, then `make build`. Produces just the `gc` binary.
2. **`runtime`** (`docker/sandbox-templates:claude-code` base): installs
   gascity's runtime deps (`tmux`, `jq`, `procps`, `lsof`, `util-linux`,
   `dbus` + `gnome-keyring` + `libsecret-1-0`), plus `bd` and `dolt` for the
   default beads provider. The `gc` binary is `COPY --from=builder`ed in.

The `GASCITY_REPO` / `GASCITY_REF` build args are forwarded from `.env` by
`docker-compose.yml`. To rebuild against a different upstream version, edit
`.env` and re-run `./start.sh --rebuild`.

### Container CMD: `gc supervisor run`, not `gc start`

On a host, `gc start` registers a launchd/systemd service. Inside a container
that is itself a single managed process, that's pointless — so the container's
`CMD` is the foreground equivalent, `gc supervisor run`. Don't change this to
`gc start`.

### Entrypoint flow (`containerized/docker-entrypoint.sh`)

Runs on every container start, in this order:

1. Apply `GIT_USER` / `GIT_EMAIL` to git + dolt config (idempotent).
2. Launch D-Bus + GNOME Keyring so Claude Code's libsecret-backed credential
   storage works on Linux (otherwise it re-prompts every boot).
3. **Sync host `~/.claude` → container `~/.claude`**: the host config is
   bind-mounted **read-only** at `/home/agent/.claude-host`; the entrypoint
   copies just `settings.json`, `settings.local.json`, `.credentials.json`,
   and the `projects/` dir into the writable `claude-data` volume. The
   read-only/writable split is deliberate — agents inherit your auth without
   getting write access to host config.
4. Same pattern for `~/.config/gh/hosts.yml` so agents can `git push`.
5. **First-run only**: `gc init --provider $GC_PROVIDER /city` to materialize
   the city scaffold. Subsequent starts skip this.
6. `exec` the CMD.

### Volume layout (`containerized/docker-compose.yml`)

| Volume | Mount | Why |
|---|---|---|
| `city-workspace` | `/city` | City scaffold (`city.toml`, `.gc/`, formulas). |
| `dolt-data` | `/city/.dolt-data` | **Must be a Docker volume, never a bind mount on macOS.** VirtioFS fsync semantics corrupt the dolt journal. |
| `claude-data`, `claude-state`, `claude-share` | `/home/agent/.claude{,-state,-share}` | Claude Code credentials, runtime state, shared assets. |
| bind rw | `${GCC_CODE_DIR:-~/code}` → `/city/rigs-host` | Host code; rigs added from subdirs here. |
| bind ro | `~/.claude` → `/home/agent/.claude-host` | Read-only staging; entrypoint syncs into writable volume. |
| bind ro | `~/.config/gh` → `/home/agent/.config/gh-host` | Same pattern for `gh` CLI. |

### Security posture

- `cap_drop: [ALL]` plus only `CHOWN`, `SETUID`, `SETGID` (needed for keyring
  + process bookkeeping).
- `no-new-privileges:true`, `pids: 512`, `memory: 4G`, `cpus: 4`.
- Host SSH keys, AWS creds, browser profiles, and the rest of `~/.config` are
  **deliberately not mounted**. Don't add them — the whole point of the
  container is that gascity agents run with `--dangerously-skip-permissions`
  and need to be physically blocked from reading host secrets.
- `IS_SANDBOX=1` is set so Claude Code knows it's sandboxed.

## When editing

- Changes to `Dockerfile`, `docker-entrypoint.sh`, or installed packages
  require `./start.sh --rebuild` to take effect.
- Changes to `docker-compose.yml` (volumes, env, caps) take effect on the next
  `docker compose up -d` — no rebuild needed.
- Adding host directories to mounts: weigh against the security posture above.
  If a host file is needed, prefer the read-only-staging-plus-entrypoint-copy
  pattern already used for `~/.claude` and `~/.config/gh`, not a direct
  read-write mount.
- `gc doctor` exits non-zero on warnings — `start.sh` already tolerates this
  (`set +e` around the smoke test). Don't "fix" the smoke test by suppressing
  exit codes elsewhere.
