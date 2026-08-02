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

Three things, all one-time:

1. **Git** — `xcode-select --install` on macOS gives you Git + the rest of CLT.
2. **A working Claude Code login** on the host — `claude --version` should print, and `claude auth login` should be done.
3. **iTerm2** — <https://iterm2.com>. The workspace launcher is iTerm2-only (uses AppleScript or its Python API).

That's it. No Docker, no Homebrew yet (we'll install Brew if it's missing).

---

## Setup (~3 minutes)

### 1. Install gascity + its deps

```bash
# Homebrew if you don't have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# gc, dolt, flock — all via brew (gc's upstream tap prefix no longer needed)
brew install gascity dolt flock

# bd (beads) — via the upstream install script
# (Canonical repo is gastownhall/beads; steveyegge/beads still works as a mirror.)
curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | bash
```

Verify:

```bash
gc version       # → 1.4.0 or newer
bd --version     # → 1.0.4 or newer (gc 1.4+ hard-refuses older)
dolt version     # → 2.1.0 or newer (gc 1.4+ requires this)
```

> **bd version floor:** gc 1.4+ prints
> `missing required dependencies: bd (found vX, need v1.0.4+)` and
> refuses to start on older bd. gc 1.0.x had the same requirement but
> failed *silently* — mayor session stuck in `reserved-unmaterialized`.
> If either shows up, re-run the bd install script above.

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

If you've ever installed the work-machine flow on this same laptop,
you already have the explicit wrapper at `~/.local/bin/`:

```bash
gc-workspace-home.sh         # ↻ swap to local supervisor + open home iTerm2 layout
gc-workspace-home.sh --ai    # same, with Ollama summary feed in the bottom pane
```

If you only ever use the local flow, the underlying script works too —
it does the same thing minus the supervisor swap:

```bash
~/code/learning-gascity/scripts/gascity-workspace.sh
~/code/learning-gascity/scripts/gascity-workspace.sh --ai
```

Opens a 3-pane layout:
- **Left tall** — mayor session (`gc session attach mayor`).
- **Top right** — interactive shell.
- **Bottom right** — live event stream (`gc events --follow`).

`gc-feed-ai` (with `--ai`) auto-starts Ollama with `qwen2.5:3b`,
summarizes every 8 events / 15 seconds, and stops Ollama on exit so
you don't lose RAM to it overnight.

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
([work-machine.md](work-machine.md)) on this same machine, two
single-command wrappers do the swap *and* open the right workspace:

```bash
gc-workspace-home.sh    # ↻ swap to local,  open local  workspace
gc-workspace-work.sh    # ↻ swap to docker, open docker workspace (desert)
```

Each one auto-stops the other supervisor first, brings its own up,
waits for the mayor session, and then opens its iTerm2 layout. Idempotent.

If you just want the supervisor swap without opening a workspace:

```bash
gc-docker-start.sh                       # ↻ to docker (auto-stops local)
gc-docker-stop.sh --restart-local        # ↻ to local
```

---

## Updating later

To pick up new gascity / bd / dolt releases:

```bash
cd ~/code/learning-gascity
./upgrade.sh --no-image      # local flow doesn't use the agent image, so skip its rebuild
```

`upgrade.sh` will:
1. `git pull` this repo.
2. `brew upgrade` gascity and dolt (if installed via brew).
3. Re-run the upstream `bd` install script.
4. Refresh the workspace launcher symlinks.

After upgrade, restart the supervisor so the new `gc` is in charge:

```bash
~/code/learning-gascity/scripts/gascity-stop.sh
~/code/learning-gascity/scripts/gascity-start.sh
```

---

## Troubleshooting

**`gc doctor` says `custom-types:city` failed**
Run `gc doctor --fix`. Adds the `session` / `spec` / `convergence`
custom bead types the city expects.

**`gc start` reports "missing required dependencies: bd (found vX, need v1.0.4+)"**
Straightforward — upgrade bd: re-run the install script above, then
`gc supervisor stop --wait && gc start`.

**Mayor session shows `reserved-unmaterialized` and never starts (gc 1.0.x)**
Silent-failure mode of the same bd version issue. gc 1.4+ turned this
into the hard-check above; if you're seeing this, you're on gc 1.0.x —
upgrade both gc and bd.

**`gc start: PackV1 config surfaces are no longer supported` after upgrading to 1.4**
Some registered city has pre-1.3 `[[agent]]` blocks in city.toml/pack.toml
and blocks startup for *all* cities. Fix: `gc doctor --fix` inside the
offender, or `gc unregister <stale-city>` if you don't need it (city
files stay on disk).

**"pending-notice" metrics prompt after upgrading to 1.4**
1.4 introduced anonymous command-usage metrics; the first interactive
`gc` command shows a disclosure. Preempt with `gc metrics off` or
`export DO_NOT_TRACK=1` in your shell rc.

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
