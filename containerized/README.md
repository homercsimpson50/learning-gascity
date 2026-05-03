# Containerized Gas City — Option A (host `gc`, agents in scoped containers)

This directory implements **Option A** from
[`docs/containerizing-gascity-for-local-use-spec.md`](../docs/containerizing-gascity-for-local-use-spec.md):

- **`gc` (the supervisor + CLI) runs on your host**, unchanged. You get
  fast iteration, native `gc status`, normal logs, the launchd service.
- **Every agent invocation goes through a Docker container**, scoped to a
  single rig worktree, with no host credentials and no host filesystem
  access outside `/work`.

The container is the smallest blast radius around the actual risk:
the coding agent (`claude`, `codex`, `gemini`, ...) — *not* `gc` itself.

```
containerized/
├── README.md              ← you are here
├── agent-runner/          ← image: minimal Debian + agent CLI + entrypoint
│   ├── Dockerfile
│   └── entrypoint.sh
├── shim/
│   ├── gc-docker-runner   ← bash; converts `claude …` → `docker run …`
│   ├── gc-docker          ← user-facing wrapper: `gc-docker <gc subcommand>`
│   └── config.example.toml
├── install.sh             ← docker check, build, install shim + wrapper, verify
├── uninstall.sh           ← reverse install.sh
└── verify.sh              ← runs the seven isolation probes from the spec §8
```

> **No global PATH change.** `install.sh` does **not** touch your
> `~/.zshrc`. Your normal `claude` and `gc` keep working exactly as
> before. To run gc with sandboxed agents, you explicitly type
> **`gc-docker`** instead of `gc`. Everything else flows through.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Host (your laptop)                                         │
│                                                             │
│   You type:  gc-docker supervisor run                       │
│                  │                                          │
│                  │  prepends shim dir to its OWN PATH       │
│                  ▼  then exec gc supervisor run             │
│   gc-supervisor ──► runtime provider                        │
│                          │                                  │
│                          ▼  exec("claude" …)                │
│             ~/.local/bin/gascity-shims/claude  ← shim       │
│                          │   (only on PATH because          │
│                          │    gc-docker put it there;       │
│                          │    your interactive shell is     │
│                          │    completely untouched)         │
│                          ▼  docker run …                    │
│   ┌──────────────────────┴──────────────────────────────┐   │
│   │ Container: gascity-agent-runner:claude              │   │
│   │   - claude CLI                                      │   │
│   │   - rig worktree at /work (rw)                      │   │
│   │   - --read-only rootfs, tmpfs /tmp + ~/.cache       │   │
│   │   - --user 1000:1000, cap_drop ALL                  │   │
│   │   - --memory 4g --cpus 2 --pids-limit 512           │   │
│   │   - secrets only via -e env vars                    │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

Spec reference: [§2 design overview](../docs/containerizing-gascity-for-local-use-spec.md#2-design-overview).

---

## Quick start

### Brand-new machine

Use the top-level bootstrap, which installs gc / bd / dolt / flock for
you (via Homebrew + the official tap) before running `install.sh`:

```bash
git clone https://github.com/homercsimpson50/learning-gascity ~/code/learning-gascity
cd ~/code/learning-gascity
./bootstrap.sh
```

Prereqs: **git** and **Docker Desktop** (anything else is auto-installed).

### Already-set-up machine

If `gc` is already on your PATH, just run `install.sh` directly:

```bash
./install.sh
```

That installs the shim, the `gc-docker` wrapper, the default config,
builds the agent image, and runs `verify.sh`. **It does not touch your
shell's PATH.** Your `claude` and `gc` keep working exactly as before.

### Use it

```bash
# Normal local gc — agents run on the host:
gc init ~/my-city
gc start

# Containerized — agents run inside Docker:
gc-docker init ~/test-city          # any gc subcommand works through the wrapper
gc-docker supervisor run            # foreground supervisor with sandboxed agents
```

Verify nothing was changed:

```bash
which claude       # → /Users/you/.local/bin/claude  (your normal claude)
which gc           # → /Users/you/.local/bin/gc      (your normal gc)
which gc-docker    # → /Users/you/.local/bin/gc-docker  (the new wrapper)
```

### Uninstall

`./uninstall.sh` removes the shim, the wrapper, and any leftover PATH
lines from older versions of `install.sh`. The image, your config, and
session logs are preserved (instructions to delete them are printed).

### How the wrapper works

`gc-docker` does exactly two things, in this order:

1. Prepends `~/.local/bin/gascity-shims` to its *own* PATH.
2. `exec`s `gc "$@"`.

`gc` and its child supervisor inherit that PATH. When the supervisor
later does `exec("claude", …)`, the shim wins the PATH lookup and
translates the call into a hardened `docker run` against
`gascity-agent-runner:claude`. Your interactive shell never sees the
shim — only `gc-docker`'s child processes do.

---

## What you get

| Concern | How Option A handles it |
|---|---|
| Agent reads `~/.aws/credentials` | Path doesn't exist in container; no `~/.aws` is mounted. |
| Agent runs `rm -rf $HOME` | `$HOME` inside container is a tmpfs that disappears on container exit; host home untouched. |
| Agent reads `~/.ssh` | Same as above — not mounted. |
| Agent runs `docker ps` to escape | Docker CLI not installed in image; `/var/run/docker.sock` not mounted. |
| Agent forks 5,000 procs | `--pids-limit 512` cuts it off. |
| Agent allocates 64 GB RAM | `--memory 4g` triggers OOM kill. |
| Agent writes outside the rig | `/work` is the *only* rw bind mount. Rootfs is `--read-only`. |
| Agent escalates privileges | `--cap-drop ALL --security-opt no-new-privileges`. |
| Agent gets stuck forever | `timeout` field in config kills the container. |

What it deliberately **doesn't** give you (be honest about the limit):

- **Not a hard boundary against a malicious model.** Docker on macOS uses
  a shared kernel via the Linux VM; a kernel-level escape compromises
  the host. Spec §9 covers this; Option B (k8s + gVisor + NetworkPolicy)
  is the eventual answer for that threat model.
- **v1 has no egress allowlist.** The container uses Docker's default
  bridge with full internet. The spec §6 outlines a dnsmasq+iptables
  allowlist — landing that is a v2 task.

---

## Configuration

`install.sh` drops a default config at `~/.config/gascity-docker-runner/config.toml`.
Edit it to:

- **Pin a digest** once you push the image to a registry: `claude = "registry/...@sha256:…"`.
- **Tune limits** — bump `memory` or `cpus` if real agent work hits them.
- **Add agents** — uncomment the `codex`/`gemini` lines after building
  their images (one Dockerfile per agent under `agent-runner/`).

Override location per-invocation via `GC_DOCKER_RUNNER_CONFIG=/path/to/cfg`
in the supervisor's environment.

### Per-rig overrides (planned)

The spec §4 allows a `.gc-runner.toml` in the rig root to relax specific
things (extra allowlisted domain, raised memory). Not implemented in v1
of the shim — track in the backlog.

---

## Verifying isolation

`./verify.sh` runs the seven probes from the spec §8:

1. **Smoke** — container starts, writes file into rig worktree.
2. **Footgun** — `rm -rf $HOME` inside doesn't touch host `$HOME`.
3. **Network** — container can reach `api.anthropic.com` (proxy for "agent works"). When you wire an allowlist, replace with two checks.
4. **Credentials** — `/root/.aws`, `/home/agent/.aws`, `/run/secrets` not visible.
5. **Escape** — Docker socket not mounted, Docker CLI not installed.
6. **Concurrency** — 5 parallel containers, no name collisions, all 5 write to the shared worktree cleanly.
7. **Restart** — `docker stop` cleans up the container.

Run after every config change. CI should run it on PRs that touch this
directory.

---

## Logs

Each shim invocation tees the agent's stdio to
`~/.local/state/gascity-docker-runner/logs/<session-id>.log`, with a
preamble line listing image, rig, bead, and forwarded env keys (no values).

Useful when a session misbehaves and you want a postmortem without
re-running.

---

## Wiring (how the symlink works)

The shim lives at `~/.local/bin/gascity-shims/gc-docker-runner`. The
install script symlinks `claude → gc-docker-runner` in the same directory.

When `gc-supervisor` (running as your user, possibly under launchd)
spawns an agent, it does roughly `exec("claude", args…)`. Your shell's
`$PATH` decides which `claude` runs:

```
PATH="$HOME/.local/bin/gascity-shims:$PATH"  ← shim wins
PATH="/usr/local/bin:$PATH"                   ← real claude wins (no isolation)
```

So **the only behavior change required** is making `~/.local/bin/gascity-shims`
come first on the PATH that `gc-supervisor` sees. `install.sh` prints the
exact line to add to `~/.zshrc` (or `~/.bashrc`).

If you only want isolation when running gascity (and not when running
`claude` directly elsewhere), point `gc-supervisor` at the shim
explicitly via launchd's `EnvironmentVariables.PATH` and leave your
interactive shell alone. That's a per-host preference; default install
keeps things simple and global.

---

## Uninstall

```bash
./uninstall.sh
```

Removes the shim binary, the symlinks, and the PATH lines from your
shell rc. Leaves the agent image, your config under
`~/.config/gascity-docker-runner/`, and session logs under
`~/.local/state/gascity-docker-runner/` so re-install doesn't lose
tweaks. The script prints the exact commands to delete those if you
want a full wipe.

---

## Migration to Option B (k8s)

Spec §10. The agent image and the env-var secrets contract carry over
unchanged. The shim is replaced by Gas City's built-in Kubernetes
runtime provider, configured to use this same image and our PodSpec
template. Per-rig TOML overrides become Helm values.

Keeping the shim's mount paths (`/work`, `/run/secrets`), env names, and
non-root uid stable is the deal — debugging stays portable.

---

## Reference

- Full spec: [`../docs/containerizing-gascity-for-local-use-spec.md`](../docs/containerizing-gascity-for-local-use-spec.md)
- Upstream: <https://github.com/gastownhall/gascity>
