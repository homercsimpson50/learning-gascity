# How-To: Gas City on a work machine (sandboxed in Docker)

For machines where one rogue agent is one rogue agent too many — work
laptops, anything with corporate VPN / SSH keys / cloud credentials in
env. Agents run inside scoped Docker containers; your host filesystem,
credentials, and network are out of reach.

If this is a personal machine you don't mind agents having full host
access to, use [`personal-laptop.md`](personal-laptop.md) instead.

---

## What you'll have when this finishes

- `gc`, `bd` on PATH (the gascity CLI, untouched).
- `gc-docker` on PATH — opt-in wrapper. Type this instead of `gc` when
  you want sandboxed agents. Your normal `gc` and `claude` still work.
- The agent-runner image (`gascity-agent-runner:claude`) built locally.
- A shim at `~/.local/bin/gascity-shims/` that translates each agent
  invocation into a hardened `docker run` with no host credentials,
  no host filesystem access outside the rig worktree, and no docker
  socket.

---

## Prereqs

Three things, all one-time:

1. **Git** — `xcode-select --install` on macOS gives you Git + the rest of CLT.
2. **Docker Desktop** — <https://www.docker.com/products/docker-desktop>. Doesn't need to be running yet; `bootstrap.sh` will start it.
3. **iTerm2** — <https://iterm2.com>. The workspace launcher is iTerm2-only (uses AppleScript or its Python API).

That's it. Homebrew, gc, bd, dolt, flock are auto-installed.

---

## Setup (~5 minutes)

```bash
git clone https://github.com/homercsimpson50/learning-gascity ~/code/learning-gascity
cd ~/code/learning-gascity
./bootstrap.sh
```

`bootstrap.sh` runs through, in order:

1. Verifies git + docker are present.
2. Installs Homebrew if missing (macOS).
3. `brew install gascity` (skips if `gc` already on PATH). *(Upstream tap prefix no longer required as of 1.4.)*
4. The official `bd` install script (skips if `bd` already on PATH).
5. `brew install dolt flock` (gc's beads-provider deps).
6. Hands off to `containerized/install.sh`, which:
   - Starts Docker Desktop if not running.
   - Builds `gascity-agent-runner:claude` from `containerized/agent-runner/`.
   - Installs the shim at `~/.local/bin/gascity-shims/gc-docker-runner`.
   - Drops the default config at `~/.config/gascity-docker-runner/config.toml`.
   - Symlinks `claude` → `gc-docker-runner` inside the shim dir. The shim is one binary that serves multiple agents; it reads `argv[0]` to decide which one (so `claude`, `codex`, `gemini` symlinks all point at the same binary).
   - Installs the `gc-docker` wrapper at `~/.local/bin/gc-docker`.
   - Installs `wire-shim.sh` at `~/.local/bin/gascity-shims/wire-shim.sh`. `gc-docker-start.sh` runs it as a pre-flight on every boot to insert `start_command = "$HOME/.local/bin/gascity-shims/claude"` into every `[[agent]]` block in your city's `pack.toml`/`city.toml`. That's how gc-supervisor reaches the shim — by absolute path via `start_command`, not via PATH lookup. Idempotent.
   - Runs `verify.sh` — the seven isolation probes from the spec §8.

Re-running `bootstrap.sh` is safe — every step skips itself if its
target is already present.

---

## Verify the install didn't pollute anything

```bash
which claude         # → /Users/you/.local/bin/claude       (your real claude — UNCHANGED)
which gc             # → /Users/you/.local/bin/gc           (your real gc — UNCHANGED)
which gc-docker      # → /Users/you/.local/bin/gc-docker    (the new wrapper)

# zshrc has zero learning-gascity lines
grep learning-gascity ~/.zshrc || echo "(clean)"
```

`gc-docker` is the only thing visible to your interactive shell.

---

## Daily use

One command (`install.sh` symlinks all of these into `~/.local/bin/`):

```bash
gc-workspace-work.sh         # ↻ swap to docker supervisor + open desert iTerm2 layout
gc-workspace-work.sh --raw   # same, but bottom pane is raw `gc events --follow`
                              # (default is gc-feed-ai TUI — readable, with optional Ollama summary)
```

Opens an iTerm2 window with three panes, all painted in a desert color
scheme so you can't mistake it for the local workspace:

| Pane | What it runs |
|---|---|
| Left tall | `gascity-docker-start.sh && gc session attach mayor` — auto-stops the local supervisor first if running, brings the shim-aware backgrounded supervisor up, then attaches you to mayor |
| Top right | blank shell, cd'd to the city — type `bd create "…"`, `gc-docker rig add …`, etc. here |
| Bottom right | `gc-feed-ai` (TUI by default) or `gc events --follow` (with `--raw`) |

The first time you run it, the script auto-initializes a city at
`$HOME/gc-docker` (override with `GC_DOCKER_CITY=…`). On subsequent
runs it just reuses what's there.

### Watching agent activity

When the supervisor spawns an agent, a container appears in `docker ps`
named `gc-<agent>-<bead>`. When the agent exits, the container is
removed (we use `docker run --rm`). Session logs are teed by the shim
to `~/.local/state/gascity-docker-runner/logs/<session-id>.log`.

### Stopping cleanly

```bash
gc-docker-stop.sh                  # graceful stop of the Docker supervisor
gc-docker-stop.sh --force          # SIGKILL after 10s if it won't exit
gc-docker-stop.sh --restart-local  # ...and bring your local supervisor back up
```

Ctrl-C in the supervisor pane works too, but `gc-docker-stop.sh` is
idempotent and the cleanest swap-back path.

### Swapping between local and docker

You can only run one supervisor at a time per machine. Two
single-command wrappers do the swap *and* open the right workspace:

```bash
gc-workspace-work.sh    # ↻ swap to docker, open docker workspace (desert)
gc-workspace-home.sh    # ↻ swap to local,  open local  workspace
```

Each one auto-stops the other supervisor first, brings its own up,
waits for the mayor session, and then opens its iTerm2 layout. Idempotent.

If you just want the swap without opening a workspace:

```bash
gc-docker-start.sh                       # ↻ to docker (auto-stops local)
gc-docker-stop.sh --restart-local        # ↻ to local
```

### Bare commands (no workspace)

```bash
gc-docker init ~/work-city          # any path
cd ~/work-city
gc-docker rig add ~/code/some-repo  # add a rig
bd create "do a thing"              # bd is on PATH directly — no wrapper needed
gc-docker supervisor run            # foreground supervisor

# Anything outside gc:
gc <anything>                       # normal local gc — agents on host (rare on a work machine)
claude --continue                   # your normal claude, untouched
```

---

## What you get (and don't)

| Concern | How it's handled |
|---|---|
| Agent reads `~/.aws/credentials`, `~/.ssh`, `~/.netrc` | Paths don't exist in container; nothing from `$HOME` is mounted. |
| Agent runs `rm -rf $HOME` | `$HOME` inside container is a tmpfs that vanishes on exit; host home is untouched. |
| Agent runs `docker ps` to escape | Docker CLI not installed in image; `/var/run/docker.sock` not mounted. |
| Agent forks 5,000 processes | `--pids-limit 512` cuts it off. |
| Agent allocates 64 GB RAM | `--memory 4g` triggers OOM kill. |
| Agent writes outside the rig | `/work` is the *only* rw bind mount. Rootfs is `--read-only`. |
| Agent escalates privileges | `--cap-drop ALL --security-opt no-new-privileges`. |
| Agent gets stuck forever | `timeout` field in config kills the container. |

What this **doesn't** give you — be honest about the limit:

- **Not a hard boundary against a deliberately malicious model.** Docker on macOS uses a shared kernel via the Linux VM; a kernel-level escape compromises the host. The eventual answer for that threat model is k8s + gVisor + NetworkPolicy ([spec §10](containerizing-gascity-for-local-use-spec.md#10-migration-path-to-option-b-k8s-on-work-machine--eks)).
- **v2 credential brokers now handle Anthropic + GitHub auth without host secrets in the agent container.** See "Auth setup" below. The v1 forwarding of `ANTHROPIC_API_KEY` / `GH_TOKEN` env vars is gone.
- **Agent-side egress is broker-only.** Agent containers sit on `gc-broker-net` which is `--internal` (no route off Docker's private network). Direct connects from the agent to `api.anthropic.com`, `api.github.com`, or `github.com:22` fail at DNS. All auth traffic flows through the broker sidecars.

---

## Auth setup (v2 credential brokers)

Three sidecar containers hold credentials so agents authenticate without
those credentials being present in the agent container at all. Overview
in [`docs/credential-broker-v2-spec.md`](credential-broker-v2-spec.md);
current rollout state + test results in
[`docs/credential-broker-v2-status.md`](credential-broker-v2-status.md).

Before `gc-workspace-work.sh` will bring the brokers up cleanly, do
this one-time setup:

```bash
# 1. Generate an UNENCRYPTED SSH key dedicated to the agent broker.
#    (Broker refuses passphrase-protected keys — it can't prompt.)
ssh-keygen -t ed25519 -f ~/.ssh/id_gc_agent -N ""
gh ssh-key add ~/.ssh/id_gc_agent.pub --title "gc-broker"

# 2. Point the broker at that key. Edit ~/.config/gascity-docker-runner/config.toml
#    (the file is created by ./bootstrap.sh / containerized/install.sh):
#        [broker.github_ssh]
#        key_file = "~/.ssh/id_gc_agent"
#    and set the repo allowlist for both API + SSH brokers:
#        [broker.github_api]
#        repo_allowlist = ["yourhandle/*", "yourorg/some-repo"]
#        [broker.github_ssh]
#        repo_allowlist = ["yourhandle/*", "yourorg/some-repo"]

# 3. Ensure GH_TOKEN is exported in the shell that runs gc-workspace-work.sh
echo 'export GH_TOKEN="$(gh auth token)"' >> ~/.zshrc
export GH_TOKEN="$(gh auth token)"

# 4. First time only: verify the Anthropic OAuth token extractor works
#    (on macOS the OAuth lives in Keychain, not a flat file; the extractor
#    pulls it out atomically to a mode-0600 file the broker mounts).
gc-broker-creds-extract.sh
```

After that, `gc-workspace-work.sh` extracts creds → starts the three
brokers → starts the shim-aware supervisor.

**Note on cities upgraded from ≤ 1.3:** if `~/gc-docker/` predates gc
1.4, it may contain `[[agent]]` PackV1 blocks that 1.4 rejects at
startup. Cleanest fix: `rm -rf ~/gc-docker` and let
`gc-workspace-work.sh` re-init on next run. `wire-shim.sh` handles the
new `agents/<name>/agent.toml` layout automatically.

---

## Updating later

To pick up new gascity releases, new bd, or refresh the agent image
with the latest Claude Code:

```bash
cd ~/code/learning-gascity
./upgrade.sh                 # full: repo + gc + bd + dolt + image rebuild + shim re-install
./upgrade.sh --no-image      # skip the docker image rebuild (fast)
```

`upgrade.sh` is a no-op for anything already current, so you can run it
whenever you suspect you're behind. After a successful upgrade, swap
the supervisor so the new `gc` is in charge:

```bash
gc-workspace-work.sh         # picks up the new supervisor + reopens workspace
```

What `upgrade.sh` does, in order:

1. `git pull --ff-only` on this repo (stops if you have uncommitted changes).
2. `brew upgrade gascity` (if `gc` was installed via brew; upstream tap prefix no longer needed).
3. `brew upgrade dolt`.
4. Re-runs the upstream `bd` install script — replaces `bd` with the latest.
5. Rebuilds `gascity-agent-runner:claude` with `--no-cache` (so the
   `npm install -g @anthropic-ai/claude-code` step picks up the latest
   release at registry.npmjs.org).
6. Re-runs `containerized/install.sh --no-build --no-verify` to refresh
   the shim, wrapper, and workspace symlinks in `~/.local/bin/` against
   any script changes from the pull.

---

## Verifying isolation (any time)

```bash
cd ~/code/learning-gascity/containerized
./verify.sh
```

Runs the seven probes from spec §8: smoke, footgun (`rm -rf $HOME`),
network, credentials (host secret paths absent), escape (no docker
socket / CLI), concurrency (5 parallel containers), restart cleanup.
Run after any change in the `containerized/` directory.

---

## Configuration

The default config lives at `~/.config/gascity-docker-runner/config.toml`.
Things you might tune:

- **Memory / CPU limits** — bump `[limits]` if real agent work hits them.
- **Image pin** — once you push the image to a registry, set `[image]
  claude = "registry/...@sha256:..."` for reproducibility.
- **Add agents** — uncomment the `codex` / `gemini` lines after building
  their images (one Dockerfile per agent under `containerized/agent-runner/`).

---

## Uninstall

```bash
cd ~/code/learning-gascity/containerized
./uninstall.sh
```

Removes the shim, the `gc-docker` wrapper, and any leftover marker-
fenced PATH lines from older versions of the installer. Preserves the
agent image, your config, and session logs (commands to delete those
print at the end).

---

## Troubleshooting

**`gc-docker: shim missing at ~/.local/bin/gascity-shims/gc-docker-runner`**
You ran `gc-docker` before the install completed (or after `uninstall.sh`).
Re-run `containerized/install.sh`.

**`[gc-docker-runner] FATAL image not present: gascity-agent-runner:claude`**
The image was pruned. Rebuild: `cd ~/code/learning-gascity/containerized && docker build -t gascity-agent-runner:claude agent-runner/`.

**Agent container exits immediately with `exec: claude: not found`**
The image build didn't install Claude Code. Rebuild with `--no-cache`:
`docker build --no-cache -t gascity-agent-runner:claude agent-runner/`.

**One of the verify.sh probes fails**
Check the printed reason. Probes 4 and 5 (credentials / escape) failing
is a security regression — investigate before using.

---

## Reference

- [Architecture spec](containerizing-gascity-for-local-use-spec.md) — the design doc behind this setup.
- [`containerized/README.md`](../containerized/README.md) — directory contents reference.
