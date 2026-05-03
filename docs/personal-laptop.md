# How-To: Gas City on a personal laptop (local, no containers)

For a machine you trust enough to run AI agents directly against your
home directory — your own laptop with a throwaway repo here and there.
Agents have full host access; setup is the simplest possible.

If you want agents sandboxed in containers (work machine, anything with
sensitive credentials in env), see [`work-machine.md`](work-machine.md)
instead.

---

## What you'll have when this finishes

- `gc`, `bd` on PATH (the gascity CLI + beads issue tracker).
- A city at `~/gc/` registered with the machine-wide supervisor.
- Launchd autostart so the supervisor survives reboots.
- An iTerm2 4-pane workspace launcher (mayor / shell / events feed).

---

## Prereqs

Two things, both one-time:

1. **Git** — `xcode-select --install` on macOS gives you Git + the rest of CLT.
2. **A working Claude Code login** on the host — `claude --version` should print, and `claude auth login` should be done.

That's it. No Docker, no Homebrew yet (we'll install Brew if it's missing).

---

## Setup (~3 minutes)

### 1. Install gascity + its deps

```bash
# Homebrew if you don't have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# gc, dolt, flock — all via brew
brew install gastownhall/gascity/gascity dolt flock

# bd (beads) — via the upstream install script
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
```

Verify:

```bash
gc version       # → 1.0.1
bd --version     # → 1.0.3 or newer
dolt version     # → 1.86.1 or newer
```

> **bd version gotcha:** gascity v1.0.1 needs `bd` ≥ 1.0.3. Older `bd`
> silently rejects gascity's custom issue types and the supervisor sits
> in `reserved-unmaterialized`. If `bd --version` shows 1.0.0, re-run
> the install script above.

### 2. Initialize your city

```bash
gc init --provider claude ~/gc
```

That single command:
- Creates the city scaffold at `~/gc/` (`city.toml`, `.gc/`, `agents/`, `formulas/`, `orders/`, `overlays/`).
- Initializes a beads database under `~/gc/.beads/`.
- Registers the city with the machine-wide supervisor at `~/.gc/cities.toml`.
- Installs the launchd autostart at `~/Library/LaunchAgents/com.gascity.supervisor.plist`.

### 3. Bring the supervisor up

```bash
gc start
```

The supervisor is now running and will restart automatically across reboots.

### 4. Verify

```bash
cd ~/gc && gc doctor    # most checks green; one warning is normal
gc cities               # → city  /Users/you/gc
gc supervisor status    # → running
gc session attach mayor # talk to the mayor (Ctrl-b d to detach)
```

---

## Daily use

### iTerm2 workspace

```bash
~/code/learning-gascity/scripts/gascity-workspace.sh
```

Opens a 4-pane layout:
- **Left** — mayor session (`gc session attach mayor`).
- **Top right** — interactive shell.
- **Bottom right** — live event stream (`gc events --follow`).

Add `--ai` to run the bottom-right pane through `gc-feed-ai`, which
adds a periodic Ollama summary on top of the raw event stream:

```bash
~/code/learning-gascity/scripts/gascity-workspace.sh --ai
```

`gc-feed-ai` auto-starts Ollama with `qwen2.5:3b`, summarizes every 8
events / 15 seconds, and stops Ollama on exit so you don't lose RAM
to it overnight.

### Bare commands (no workspace)

```bash
gc cities                       # registered cities
gc rig add ~/code/some-repo     # add a project as a rig
bd create "do a thing"          # create a bead
gc bd ready                     # what's ready to dispatch
gc events --follow              # live event stream (pure JSON)
gc session attach mayor         # talk to the mayor
gc supervisor status            # is the supervisor up?
gc supervisor stop              # stop everything
```

### Stop / start helpers

```bash
~/code/learning-gascity/scripts/gascity-stop.sh         # clean stop
~/code/learning-gascity/scripts/gascity-start.sh        # bring back up
```

### Swapping with the work-machine (Docker) flow on the same laptop

If you're occasionally testing the containerized setup
([work-machine.md](work-machine.md)) on this same machine, the start
scripts know about each other and will swap cleanly:

```bash
# Sitting in local mode, want to test docker:
gc-docker-start.sh                       # auto-stops local first, then brings docker up

# Done with docker, want local back:
gc-docker-stop.sh --restart-local        # one command, both halves
# or:
~/code/learning-gascity/scripts/gascity-start.sh   # also auto-stops docker first
```

---

## Troubleshooting

**`gc doctor` says `custom-types:city` failed**
Run `gc doctor --fix`. Adds the `session` / `spec` / `convergence`
custom bead types the city expects.

**Mayor session shows `reserved-unmaterialized` and never starts**
Almost always a `bd` version mismatch (need ≥ 1.0.3). Re-run the bd
install script and `gc supervisor stop && gc start`.

**Workspace script can't find iTerm2 panes**
The Python variant (`scripts/gascity-workspace.py`) needs iTerm2's
Python API enabled: iTerm2 → Preferences → General → Magic →
"Enable Python API". The shell variant (`gascity-workspace.sh`) uses
AppleScript and works without that.

**Supervisor isn't restarting on reboot**
Check the plist: `launchctl list | grep gascity`. If missing, re-run
`gc start ~/gc` to re-register.

---

## What this does NOT give you

Agents have full host access — they can read `~/.aws`, `~/.ssh`,
your browser cookies, anything your shell can reach. That's why this
path is for personal/throwaway machines only. For corporate laptops,
machines with cloud credentials, or anything with shared SSH access,
use the containerized path: [`work-machine.md`](work-machine.md).
