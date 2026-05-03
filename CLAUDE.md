# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is (and isn't)

This repo is a **harness** for upstream
[gastownhall/gascity](https://github.com/gastownhall/gascity). Gas City source
lives upstream — never vendored here. There is no Go/Python/JS code to lint
or test.

**Two user-facing paths, each with its own how-to:**

- [`docs/personal-laptop.md`](docs/personal-laptop.md) — local install, `gc` and agents both on host. The `scripts/` directory holds the helpers (iTerm2 workspace, gc-feed-ai). Use when the user is on a throwaway / personal machine.
- [`docs/work-machine.md`](docs/work-machine.md) — containerized agents. `gc` on host; agents in scoped Docker containers via the shim + `gc-docker` wrapper in `containerized/`. Use when the user is on a corporate / shared machine.

**When the user asks for help, identify which path they're on first.**
The two how-tos are the source of truth for user-visible flow. Don't
duplicate that content in answers — point at the relevant doc and add
only what's not there.

When the user asks to "fix gascity behavior X," check whether X lives in this
harness (shim, agent image entrypoint, install/bootstrap script, workspace
script) or upstream (the `gc` CLI itself, formulas, beads, runtime providers).
Upstream fixes need a `gc` binary upgrade — not edits here.

## Source-of-truth files

- [`docs/personal-laptop.md`](docs/personal-laptop.md) — user how-to: local install, daily commands, troubleshooting.
- [`docs/work-machine.md`](docs/work-machine.md) — user how-to: containerized install, daily commands, troubleshooting.
- [`docs/containerizing-gascity-for-local-use-spec.md`](docs/containerizing-gascity-for-local-use-spec.md) — design spec the containerized path implements.
- [`containerized/README.md`](containerized/README.md) — directory reference for `containerized/` (architecture, hard rules, config knobs, v1 limitations).
- [`bootstrap.sh`](bootstrap.sh) — brand-new-machine entry for the work-machine path. Installs gc/bd/dolt/flock then hands off to `containerized/install.sh`.
- This file — guidance for editing the repo, not for using gascity.

## Common commands (cheat sheet)

For full flows see the how-tos above. Quick reference:

### Containerized

```bash
./bootstrap.sh                          # brand-new machine (installs everything)
cd containerized && ./install.sh        # already-set-up machine (just the container piece)
cd containerized && ./verify.sh         # 7 isolation probes from spec §8
cd containerized && ./uninstall.sh      # reverse install.sh
gc-docker supervisor run                # foreground supervisor with sandboxed agents
ls ~/.local/state/gascity-docker-runner/logs/   # session logs (teed by the shim)
```

### Local

```bash
./scripts/gascity-workspace.sh        # AppleScript: opens 4-pane iTerm2 layout
./scripts/gascity-workspace.sh --ai   # same, feed pane uses Ollama summary
./scripts/gascity-workspace.py        # iTerm2 Python API equivalent (--ai works)
gc doctor / gc status / gc cities     # standard gc commands
gc session attach mayor               # talk to the mayor
gc events --follow                    # live JSON event stream
./scripts/gc-feed-ai                  # rich TUI on top of gc events --follow
./scripts/gc-feed-ai --simple         # stdlib-only streaming fallback
```

There are no unit tests. Validation is `containerized/verify.sh` for
the work-machine path and (manually) `gc doctor` reporting clean for
the personal-laptop path.

## Architecture

### Local install layout (`~/gc`, `~/.gc`, `scripts/`)

The local setup mirrors the gastown convention (`~/gt`):

- `~/gc/` — the **city directory**. Created by `gc init --provider claude .`
  (note: local `gc` v1.0.1 names the provider `claude`, not `claude-code`).
  Contains `city.toml`, `pack.toml`, `.gc/` runtime, `.beads/` dolt-backed
  bead store, and the `agents/`, `formulas/`, `orders/`, `overlays/`
  subdirs.
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

### iTerm2 workspace layout (`scripts/gascity-workspace.{sh,py}`)

Three panes, simpler than the gastown 4-pane original:

- Left tall pane: `cd ~/gc && gc supervisor start; gc session attach mayor`
- Top-right pane: blank interactive shell — no command sent
- Bottom-right pane: `gc events --follow` (or `gc-feed-ai` with `--ai`)

Both scripts produce the same layout — `.sh` uses AppleScript via
`osascript`, `.py` uses the iTerm2 Python API (which must be enabled in
iTerm2 → Preferences → General → Magic). Both accept `--ai`.

**`SCRIPT_DIR` resolution**: the `.sh` deliberately uses `${BASH_SOURCE[0]}`
not `$0`, so it works even if accidentally sourced (when sourced, `$0` is
the parent shell's argv[0] and `dirname` gives a wrong dir, which produced
a silent path bug in an earlier revision).

### `scripts/gc-feed-ai` (the "--ai" feed)

`gc events --follow` is JSON-Lines, not a TUI like `gt feed`. To recover
the gastown `gtc feed --ai` UX (which the user previously got by patching
gastown source on branch `feat/agent-observability-tui`), this repo ships
a wrapper trio. **No upstream gascity binary is touched or rebuilt.**

- `scripts/gc-feed-ai` — bash entry point. Ensures Ollama is installed,
  running, and has the model pulled (`qwen2.5:3b` by default). Then either
  launches the textual TUI (default) or falls back to the streaming
  summarizer (`--simple`). Stops Ollama via `brew services stop` on exit
  to free RAM (matches gtc lifecycle hygiene).
- `scripts/_gc_feed_tui.py` — textual TUI (default). Layout: header strip
  on top; left column with sessions and beads tables (refreshed every 8s
  via `gc session list` + `gc bd ready`); right column with a scrollable
  events log (history pre-loaded via `gc events --since 1h`, then
  `gc events --follow`) and a scrollable summary panel that accumulates
  Ollama summaries newest-at-bottom. Keys: q quit, s toggle summary,
  a force-summarize-now, r refresh, tab cycle focus, j/k/↑/↓ scroll.
  Requires `pip3 install --user textual`.
- `scripts/_gc_feed_ai.py` — stdlib-only streaming fallback (`--simple`).
  Pretty-prints each event one line at a time and prints periodic summary
  blocks inline. Used when textual isn't available.

Knobs (env or `~/.gc-feed-ai.conf`): `GC_FEED_AI_MODEL`, `GC_FEED_AI_EVERY`
(default 8 events), `GC_FEED_AI_INTERVAL` (default 15s),
`GC_FEED_AI_HISTORY` (default `1h`, controls `gc events --since` on
startup), `OLLAMA_URL`, `GC_FEED_AI_DISABLE=1`.

The TUI's summary prompt and rolling-history pattern are copied verbatim
from the gastown branch — same "Max 30 words. Say WHO is doing WHAT. No
filler" prompt, same newest-last summary stream. Only difference: there
the logic lived in Go inside `internal/tui/feed/summary.go`; here it lives
in Python outside `gc`.

### Option A architecture (`containerized/`)

The design doc is [`docs/containerizing-gascity-for-local-use-spec.md`](docs/containerizing-gascity-for-local-use-spec.md).
This implementation is the v1 shell-shim version described in §3.

#### Components

```
containerized/
├── agent-runner/
│   ├── Dockerfile          debian-slim + claude CLI + entrypoint
│   └── entrypoint.sh       validates env contract, drops to agent user, execs CLI
├── shim/
│   ├── gc-docker-runner    bash; reads argv[0] to pick agent, builds docker run, forwards stdio + signals
│   └── config.example.toml image map, network mode, limits
├── install.sh              build image + install shim + symlink claude → shim + drop default config
└── verify.sh               7 isolation probes from spec §8
```

#### How an agent invocation flows

1. `gc-supervisor` decides to spawn an agent for a bead.
2. It execs `claude <args>` with `GC_RIG_PATH`, `GC_BEAD_ID`, `GC_AGENT_NAME`,
   `GC_SESSION_ID` exported.
3. PATH lookup hits `~/.local/bin/gascity-shims/claude` first
   (a symlink to `gc-docker-runner`).
4. The shim:
   - Reads `~/.config/gascity-docker-runner/config.toml` for the image
     mapping, network mode, and limits.
   - Builds a `docker run` with `/work` bind-mounted to `GC_RIG_PATH`,
     `--read-only` rootfs, tmpfs for `/tmp` + `~/.cache`, `--user 1000:1000`,
     `--cap-drop ALL`, `--security-opt no-new-privileges`, `--memory`,
     `--cpus`, `--pids-limit`, and only the whitelisted env vars
     (model API keys + `GC_*` + `GH_TOKEN`).
   - Forwards stdio + SIGTERM/SIGINT to the container.
   - Tees the session to
     `~/.local/state/gascity-docker-runner/logs/<session-id>.log`.
   - Exits with the container's exit code.

#### Hard rules (do not relax without reading the spec §4)

- **Never** mount `$HOME`, `~/.aws`, `~/.ssh`, `~/.config` (other than
  what's explicitly in the env whitelist).
- **Never** mount `/var/run/docker.sock`. Docker-in-Docker = root on host.
- **Never** add `--privileged`, `--cap-add`, `--device`, `--pid=host`,
  `--net=host`, `--ipc=host`.
- **Never** drop `--cap-drop=ALL` or `--security-opt=no-new-privileges`.
- **Never** drop `--user 1000:1000` (running as root in the container is
  one container-escape away from root on host).
- **Never** drop the rootfs `--read-only` flag — agents must write to
  `/work` (the rig) or tmpfs (`/tmp`, `~/.cache`).

If a probe in `verify.sh` fails after a change here, that's a security
regression — fix the change, not the test.

#### v1 limitations (tracked for v2)

- No egress allowlist — uses Docker's default bridge with full internet
  reachability. Spec §6 outlines a dnsmasq + iptables approach.
- No GitHub App token minting — `GH_TOKEN` is forwarded as-is from the
  host environment if set. Spec §5 calls for fresh per-session tokens.
- No per-rig override TOML (`.gc-runner.toml` in the rig root) yet.
- One image per agent (`claude` only by default). Building `codex` /
  `gemini` images is one Dockerfile each under `agent-runner/`.

## When editing

- Changes to `containerized/agent-runner/` require `./install.sh` (or
  `./install.sh --no-symlink` if you've already wired the symlink) to
  rebuild the image.
- Changes to `containerized/shim/gc-docker-runner` take effect on the next
  agent invocation — re-run `./install.sh --no-build` to copy the updated
  shim into `~/.local/bin/gascity-shims/`.
- Changes to `containerized/shim/config.example.toml` do **not**
  automatically propagate — `install.sh` only writes the user's config
  on first run. Edit `~/.config/gascity-docker-runner/config.toml`
  directly when iterating, then update the example for new installs.
- Adding host directories to the shim's `docker run` flags: weigh against
  the hard rules above. If genuinely needed, the secrets contract (env
  forward, no filesystem mount) is the right pattern — extend
  `FORWARD_ENV` in the shim, don't add a new `-v`.
- After any change to `containerized/`, run `./verify.sh`. The seven
  probes are the contract.
