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
├── shim/                  ← host-side wrapper invoked by the supervisor
│   ├── gc-docker-runner   ← bash; converts `claude …` → `docker run …`
│   └── config.example.toml
├── install.sh             ← one-shot: docker check, build, shim, symlink, PATH, verify
├── uninstall.sh           ← reverse install.sh
└── verify.sh              ← runs the seven isolation probes from the spec §8
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Host (your laptop)                                         │
│                                                             │
│   gc (CLI) ──► gc-supervisor ──► runtime provider           │
│                                       │                     │
│                                       ▼  exec("claude" …)   │
│                          ~/.local/bin/gascity-shims/claude  │
│                                       │                     │
│                                       ▼  docker run …       │
│   ┌───────────────────────────────────┴─────────────────┐   │
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

You only need Docker installed. If Docker isn't running, `install.sh`
will start Docker Desktop on macOS and wait for it.

```bash
./install.sh
```

That single command:

1. Makes sure Docker is up (auto-launches Docker Desktop on macOS).
2. Builds `gascity-agent-runner:claude` from `agent-runner/`.
3. Installs the shim at `~/.local/bin/gascity-shims/gc-docker-runner`.
4. Drops a default config at `~/.config/gascity-docker-runner/config.toml`
   (preserves any existing config).
5. Symlinks `claude` → `gc-docker-runner` in the same directory.
6. Adds `~/.local/bin/gascity-shims` to your shell rc's PATH (idempotent,
   marker-fenced).
7. Runs `verify.sh` — the seven isolation probes from spec §8.

When it finishes: open a new terminal (or `source ~/.zshrc`) and use Gas
City normally. Agents the supervisor spawns will run in scoped containers
automatically.

```bash
gc init ~/my-city
cd ~/my-city
gc rig add ~/code/some-repo
bd create "do a thing"
gc start
```

To remove everything: `./uninstall.sh`. The image, your config, and
session logs are preserved (instructions to delete them are printed).

When `gc-supervisor` execs `claude`, your shell's PATH lookup hits
`~/.local/bin/gascity-shims/claude` first, which is a symlink to
`gc-docker-runner`. The shim forwards stdio + signals into the container
and exits with the container's exit code. Gas City sees a normal
process — it has no idea it just talked to a container.

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
