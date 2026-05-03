# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is (and isn't)

This repo is a **harness** for upstream
[gastownhall/gascity](https://github.com/gastownhall/gascity). Gas City source
lives upstream — never vendored here. There is no Go/Python/JS code to lint
or test.

### Wrapper-only invariant — DO NOT BREAK

Everything here is a wrapper on top of upstream binaries:

- **`gc`** is installed via `brew install gastownhall/gascity/gascity` (host) or pulled in during the agent image build.
- **`bd`** is installed via the official Steve Yegge install script.
- **Claude Code** in the agent image is installed via `npm install -g @anthropic-ai/claude-code`.

When fixing problems, **never patch upstream source**. Don't vendor
gascity. Don't fork it. Don't write a Go `replace` directive. If
something is broken in `gc` itself, the fix lands upstream and we pick
it up via `./upgrade.sh`. What lives HERE is: install scripts,
container recipes, shims that wrap (not modify) the upstream binary,
and workspace launchers.

This invariant is what makes `./bootstrap.sh` clean — a brand-new
machine gets upstream binaries plus our wrapper layer, with zero
modifications to anyone else's code.

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
- [`docs/model-selection.md`](docs/model-selection.md) — per-agent model tier choices (Haiku/Sonnet/Opus), where Opus is worth it, and Bedrock-cutover wiring notes.
- [`containerized/README.md`](containerized/README.md) — directory reference for `containerized/` (architecture, hard rules, config knobs, v1 limitations).
- [`bootstrap.sh`](bootstrap.sh) — brand-new-machine entry for the work-machine path. Installs gc/bd/dolt/flock then hands off to `containerized/install.sh`.
- [`upgrade.sh`](upgrade.sh) — bring everything up to date. Pulls the repo, upgrades `gc` / `bd` / `dolt` from upstream, rebuilds the agent image, refreshes the shim + workspace launchers. Idempotent.
- [`misc/README.md`](misc/README.md) — relocated / superseded files kept for reference (former `containerized/start.sh`, former `configs/gc-CLAUDE.md`). Not part of the active install/boot flow.
- This file — guidance for editing the repo, not for using gascity.

## Common commands (cheat sheet)

For full flows see the how-tos above. Quick reference:

### Brand-new machine / upgrade

```bash
./bootstrap.sh           # one-shot setup. idempotent.
./upgrade.sh             # pull + upgrade gc/bd/dolt + rebuild image + reinstall shim
./upgrade.sh --no-image  # skip the docker image rebuild (faster)
```

### One-shot workspace launchers (PATH-installed shortcuts)

`scripts/gascity-workspace-{home,work}.{sh,py}` are the user-facing
entry points. They're symlinked into `~/.local/bin/` as `gc-workspace-*`,
so they work from any cwd:

```bash
gc-workspace-home.sh           # ↻ stop docker supervisor (if up), start local,
                               #   open iTerm2 layout against ~/gc
gc-workspace-home.sh --ai      # same, feed pane runs gc-feed-ai (Ollama)
gc-workspace-work.sh           # ↻ stop local supervisor (if up), start docker,
                               #   open iTerm2 layout against the gc-docker stack
```

Each "-home"/"-work" wrapper auto-swaps the supervisor before opening
its layout, so you never have both running. `.py` variants exist for
both and use the iTerm2 Python API (Magic must be enabled).

### Containerized (work-machine path)

```bash
cd containerized && ./install.sh        # already-set-up machine (just the container piece)
cd containerized && ./verify.sh         # 7 isolation probes from spec §8
cd containerized && ./uninstall.sh      # reverse install.sh
gc-docker supervisor run                # foreground supervisor with sandboxed agents
gc-docker-start.sh / gc-docker-stop.sh  # symmetric lifecycle for the docker supervisor
ls ~/.local/state/gascity-docker-runner/logs/   # session logs (teed by the shim)
```

### Local (personal-laptop path)

```bash
gascity-start.sh / gascity-stop.sh    # symmetric lifecycle for the local supervisor
                                      # (start.sh auto-stops the docker supervisor first)
gc doctor / gc status / gc cities     # standard gc commands
gc session attach mayor               # talk to the mayor (also what -home opens)
gc events --follow                    # live JSON event stream
./scripts/gc-feed-ai                  # rich textual TUI: rigs/sessions panes,
                                      # events log, periodic Ollama summary
./scripts/gc-feed-ai --simple         # stdlib-only streaming fallback
```

There are no unit tests. Validation is `containerized/verify.sh` for
the work-machine path and (manually) `gc doctor` reporting clean for
the personal-laptop path.

## Architecture

### Filesystem layout (where things actually live)

```
~/gc/                                 the city (`gc init` output) — city.toml,
                                      pack.toml, agents/, formulas/, orders/,
                                      overlays/, .gc/ runtime, .beads/ store.
~/.gc/                                machine-wide supervisor state:
                                      cities.toml registry, supervisor.log,
                                      supervisor.lock, events.jsonl.
                                      (NOT the same as ~/gc/.gc/)
~/Library/LaunchAgents/
  com.gascity.supervisor.plist        launchd autostart for the local supervisor.

~/.local/bin/                         user-PATH dir; everything below is on PATH:
  gc-docker                           opt-in wrapper: PATH=$shims:$PATH gc "$@"
  gc-docker-start.sh →                the docker supervisor lifecycle
  gc-docker-stop.sh  →                  (symlinks back to scripts/)
  gc-workspace-home.{sh,py} →         iTerm2 launchers for each path
  gc-workspace-work.{sh,py} →           (symlinks back to scripts/)
  claude                              user's normal claude — UNTOUCHED by
                                      install.sh. gc reaches the shim by
                                      absolute path via per-agent
                                      start_command in pack.toml; no PATH
                                      lookup is involved. (See "Wiring up
                                      start_command" below.)
  gascity-shims/                      NOT on the global PATH:
    gc-docker-runner                  the actual shim (built by install.sh)
    claude → gc-docker-runner         shim is selected by argv[0]
    .real-claude                      sidecar holding absolute path to the
                                      real Claude Code binary; the shim's
                                      passthrough mode (GC_RIG unset) execs
                                      this for city-scoped agents (mayor,
                                      deacon, boot) and for any accidental
                                      invocation outside the gc spawn path
~/.config/gascity-docker-runner/
  config.toml                         shim config: image map, network, limits
~/.local/state/gascity-docker-runner/
  supervisor.pid                      pidfile used by gascity-{,docker-}start.sh
                                      to detect the "other" supervisor for swap
  logs/<session-id>.log               teed agent session logs
```

`gc init` is interactive by default; pass `--provider claude` to
non-interactively scaffold + register + bring up the city in one shot.
Local `gc` names the provider `claude`, not `claude-code`.

**bd version gotcha**: gascity v1.0.1 expects `bd` ≥ 1.0.3. Older `bd`
(1.0.0) silently rejects the city's custom issue types (`session`, `agent`,
`molecule`, etc.) with `validation failed for issue : invalid issue type:
session`, which surfaces as the supervisor's mayor session staying in
`reserved-unmaterialized`. Fix: re-run the `bd` install script
(`curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash`).

### iTerm2 workspace layouts (`scripts/`)

The repo ships **two** iTerm2 layouts — one per machine path — plus a
shared "switcher" pair that wraps them with auto-swap of the supervisor:

| Script | Purpose | PATH alias |
|---|---|---|
| `gascity-workspace.{sh,py}` | bare local layout against `~/gc` | — |
| `gascity-docker-workspace.{sh,py}` | bare docker layout (desert palette) | — |
| `gascity-workspace-home.{sh,py}` | stop docker → start local → open local layout | `gc-workspace-home.{sh,py}` |
| `gascity-workspace-work.{sh,py}` | stop local → start docker → open docker layout | `gc-workspace-work.{sh,py}` |

Both layouts produce three panes: left tall = mayor session, top-right =
blank shell, bottom-right wide = events feed (`gc events --follow` or
`gc-feed-ai` with `--ai`). The `.sh` variants drive iTerm2 via AppleScript
(`osascript`); the `.py` variants use the iTerm2 Python API (requires
"Enable Python API" in iTerm2 → Settings → General → Magic).

**Auto-swap mechanics:** `gascity-start.sh` checks for a Docker-supervisor
pidfile at `~/.local/state/gascity-docker-runner/supervisor.pid` before
starting the local one and stops the docker side first if needed. The
docker side has the symmetric check via `gascity-docker-start.sh`. So the
`-home`/`-work` switchers never need to know about the other path —
`gascity-{,docker-}start.sh` handle the handoff transparently.

**`SCRIPT_DIR` resolution**: the `.sh` files use `${BASH_SOURCE[0]}`
(not `$0`) so they resolve correctly when invoked via the symlinks in
`~/.local/bin/` or when accidentally sourced. Earlier revisions used
`$0` and silently broke on sourcing.

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
├── install.sh              build image + install shim + capture .real-claude sidecar + drop default config
└── verify.sh               7 isolation probes from spec §8
```

#### Wiring up `start_command`

The shim only runs if gc-supervisor actually invokes it. Originally the
plan was PATH-based: put `~/.local/bin/gascity-shims/` ahead of
`~/.local/bin/` and let the supervisor find `claude` → shim. That
**doesn't work** on macOS for two reasons:

1. The user's `~/.zprofile` prepends `~/.local/bin` to PATH, and gc
   normalizes/rebuilds PATH for spawned tmux sessions, so
   `~/.local/bin` ends up ahead of `gascity-shims/` no matter what the
   supervisor's own PATH looks like.
2. Putting the shim *at* `~/.local/bin/claude` (winning by sitting in
   the same dir) gets clobbered: claude's auto-updater rewrites that
   symlink to point at the host binary on every full launch.

The robust wiring is to bypass PATH lookup entirely by setting
`start_command` per-agent in the city's `pack.toml` / `city.toml`:

```toml
[[agent]]
name = "mayor"
prompt_template = "agents/mayor/prompt.template.md"
start_command = "$HOME/.local/bin/gascity-shims/claude"  # absolute path required
```

`gascity-docker-start.sh` automates this. Before bringing up the
supervisor it invokes `containerized/wire-shim.sh` (installed at
`~/.local/bin/gascity-shims/wire-shim.sh`), which walks `pack.toml` and
`city.toml` in the city dir and inserts a `start_command = "$HOME/.local/bin/gascity-shims/claude"`
line into every `[[agent]]` block that doesn't already have one.
Idempotent — re-runs are no-ops; one `.wire-shim.bak` backup is written
the first time a file is patched.

You can run it ad-hoc against any city:

```bash
~/.local/bin/gascity-shims/wire-shim.sh /path/to/city
```

Confirm a city is wired with `gc config explain`: every agent should
show a `start_command = …` line. Behaviorally, the supervisor's tmux
spawn for an agent should end with `… /Users/<you>/.local/bin/gascity-shims/claude`
directly (rather than a `sh -c '… exec claude …'` PATH-lookup chain).

Mayor, deacon, boot, etc. don't have `GC_RIG` set (they're city-scoped,
not rig-scoped), so the shim's passthrough mode runs the real claude
binary on the host. Polecats and other rig-scoped agents that DO have
`GC_RIG` set go through the docker-run path, with `GC_DIR` (the
per-agent worktree gc materialized at
`.gc/worktrees/<rig>/polecats/<agent>`) bind-mounted at `/work`. Both
behaviors are correct. (An older spec draft used `GC_RIG_PATH` for the
trigger and the mount target; the shim still accepts that name as a
fallback.)

`gc` rejects `[agent_defaults] start_command = …` as an unknown field, so
a single workspace-level default isn't possible — wire-shim is the
substitute.

#### How an agent invocation flows

1. `gc-supervisor` decides to spawn an agent for a bead.
2. It execs the agent's `start_command` (set in `pack.toml` /
   `city.toml`) — for the gc-docker city this is
   `$HOME/.local/bin/gascity-shims/claude`, a symlink to
   `gc-docker-runner`. `GC_RIG`, `GC_RIG_ROOT`, `GC_DIR`, `GC_AGENT`,
   `GC_TEMPLATE`, `GC_BEAD_ID`, `GC_SESSION_ID` are exported in the
   spawn env (subset depending on agent scope).
3. argv[0] is `claude` (from the symlink name), telling the shim which
   agent it's standing in for.
4. The shim, if `GC_RIG` is unset, exec's the real claude binary (path
   captured into `.real-claude` at install time) and exits — the agent
   runs on the host. This is the right behavior for city-scoped agents
   (mayor, deacon, boot) which don't have a worktree to mount.
5. If `GC_RIG` IS set (rig-scoped agents like polecats), the shim:
   - Reads `~/.config/gascity-docker-runner/config.toml` for the image
     mapping, network mode, and limits.
   - Builds a `docker run` with `/work` bind-mounted to `GC_DIR` (the
     per-agent worktree at `.gc/worktrees/<rig>/polecats/<agent>`),
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
