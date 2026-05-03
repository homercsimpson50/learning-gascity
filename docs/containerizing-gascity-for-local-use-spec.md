# Gas City Option A: Host-Side `gc` with Dockerized Agent Workers

**Status:** Draft v0.1
**Audience:** Author + reviewers familiar with Gas City primitives (cities, rigs, beads, runtime providers)
**Goal:** Run Gas City safely on a laptop (and later a work machine, eventually AWS) such that the blast radius of any agent action is contained to a Docker container — never the host filesystem, host network, or host credentials.

---

## 1. Problem statement

Gas City's `gc` binary and supervisor are well-behaved Go processes. The risk in running Gas City locally is **not** Gas City itself — it is the coding agents (`claude`, `codex`, `gemini`, etc.) that Gas City spawns via its runtime providers. Those agents:

- Read and write arbitrary files in the rig's working directory
- Execute arbitrary shell commands
- Make arbitrary network requests
- Inherit whatever credentials are reachable from the spawning shell (`~/.aws`, `~/.ssh`, `~/.netrc`, `GITHUB_TOKEN`, etc.)

The default `subprocess` and `tmux` runtime providers run agents directly on the host. Option A keeps `gc` on the host (so we get fast iteration, normal logs, normal `gc status`) but routes every agent invocation through a Docker container with a tightly scoped mount, network policy, and credential surface.

**Non-goals:**
- Defending against a deliberately malicious model breaking out of a container. Docker on macOS/Windows is a soft boundary (shared kernel via VM). Option A defends against accidents and footguns, not nation-state model jailbreaks.
- Running `gc` itself in a container. That adds complexity without addressing the actual threat surface.
- Replacing Gas City's Kubernetes provider. Option A is the laptop story; the k8s provider is the eventual work/AWS story.

---

## 2. Design overview

```
┌─────────────────────────────────────────────────────────────┐
│  Host (your laptop)                                         │
│                                                             │
│   gc (CLI) ──► gc-supervisor ──► runtime provider           │
│                                       │                     │
│                                       ▼                     │
│                              [docker run --rm ...]          │
│                                       │                     │
│   ┌───────────────────────────────────┴─────────────────┐   │
│   │ Container: agent-runner:<version>                   │   │
│   │   - claude / codex / gemini binary                  │   │
│   │   - rig worktree mounted at /work (rw)              │   │
│   │   - scoped credentials mounted read-only            │   │
│   │   - egress limited to allowlist                     │   │
│   │   - non-root user, no host PID/net/IPC              │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

The host runs `gc init`, `gc start`, `gc rig add`, etc. as normal. When the supervisor needs to spawn an agent session, it invokes a **shim binary** (`gc-docker-runner`) instead of `claude`/`codex`/`gemini` directly. The shim translates the agent invocation into a `docker run` with the right mounts, env, and limits.

There are two ways to wire this in. We pick the simpler one for v1:

| Approach | What it is | Effort | When to use |
|----------|------------|--------|-------------|
| **Shim binary** (chosen for v1) | A small executable that looks like `claude` to Gas City but actually `exec`s `docker run` | ~1 day | First implementation. No Gas City code changes. |
| **Custom runtime provider** | A new Go provider implementing Gas City's runtime interface alongside `subprocess`, `tmux`, `kubernetes` | ~1 week | Once we want richer integration (session resume, structured logs, health checks) |

We start with the shim. We migrate to a real provider once the contract is well understood.

---

## 3. Components

### 3.1 The agent container image

Repository: `internal-registry/gascity-agent-runner`
Tags: one per supported agent + version, e.g. `claude-1.x`, `codex-0.y`, `gemini-2.z`, plus a `multi` tag with all three.

**Base:** `debian:stable-slim` (or `ubuntu:24.04` if we need newer glibc for an agent binary).

**Contents:**
- The agent CLI binary, installed via its official channel (npm, pip, brew-in-container, or vendored release archive)
- `git`, `gh`, `jq`, `tmux`, `curl`, `ca-certificates` (the Gas City runtime expects these)
- A non-root user `agent` (uid 1000) that owns `/work` and `/home/agent`
- An entrypoint that:
  1. Validates required env (`GC_RIG`, `GC_RIG_PREFIX`, `GC_BEAD_ID`, `GC_AGENT`)
  2. `cd /work`
  3. Drops to `agent` user
  4. Execs the agent binary with the args passed through

**What is NOT in the image:**
- Any credentials. All secrets are mounted at runtime.
- SSH keys. Git operations use ephemeral tokens passed via env.
- Cloud CLIs (`aws`, `gcloud`, `kubectl`) unless a specific rig needs them. Default image is minimal.

**Build & supply chain:**
- Dockerfile lives in `tools/gascity-agent-runner/` in our infra repo
- Built in CI, signed with cosign, pushed to internal registry
- Image digest pinned in shim config — no `:latest`

### 3.2 The shim binary: `gc-docker-runner`

A small Go program (or shell script if we want zero build) that lives on `$PATH` on the host and stands in for `claude`/`codex`/`gemini`.

**Responsibilities:**
1. Read its own `argv[0]` to figure out which agent to launch (`claude`, `codex`, etc.) — this lets a single binary serve all agents via symlinks
2. Read Gas City env vars the supervisor exports: `GC_RIG`, `GC_RIG_ROOT`, `GC_RIG_PREFIX`, `GC_DIR`, `GC_BEAD_ID`, `GC_AGENT`, `GC_SESSION_ID` (older draft used `GC_RIG_PATH` / `GC_AGENT_NAME` — accepted as fallbacks)
3. If `GC_RIG` is unset (city-scoped agent or interactive use), exec the real agent binary on the host (path captured into a `.real-<agent>` sidecar at install time) — no container.
4. Otherwise: build a `docker run` invocation per the rules in §4 with `/work` bind-mounted to `GC_DIR` (the per-agent worktree gc materializes at `.gc/worktrees/<rig>/polecats/<agent>`)
5. Forward stdin/stdout/stderr transparently (Gas City's `subprocess` provider expects this)
6. Forward signals (SIGTERM, SIGINT) into the container so `gc stop` works
7. Exit with the container's exit code

**Configuration source:** `~/.config/gascity-docker-runner/config.toml`, overridable per-rig via `GC_DOCKER_RUNNER_CONFIG`.

```toml
[image]
claude = "internal-registry/gascity-agent-runner:claude-1.5.2@sha256:abc..."
codex  = "internal-registry/gascity-agent-runner:codex-0.8.1@sha256:def..."
gemini = "internal-registry/gascity-agent-runner:gemini-2.1.0@sha256:ghi..."

[network]
mode = "allowlist"              # or "none" or "host" (host forbidden in prod profile)
allowed_domains = [
  "api.anthropic.com",
  "api.openai.com",
  "generativelanguage.googleapis.com",
  "github.com",
  "api.github.com",
  "registry.npmjs.org",
  "pypi.org",
  "files.pythonhosted.org",
]

[limits]
memory     = "4g"
cpus       = "2"
pids_limit = 512
timeout    = "30m"              # hard kill after this

[mounts]
# extra read-only mounts shared across all rigs (e.g. shared prompts)
extra_ro = []
```

### 3.3 Wiring it into Gas City

> **Implementation note (2026-05):** This section originally proposed
> two wirings — `gc config agent set` or PATH-prepended symlinks. The
> implementation eventually went with neither: PATH ordering is
> unstable on macOS (login shells re-run zprofile + path_helper, and
> claude's auto-updater periodically rewrites `~/.local/bin/claude`),
> and `gc config agent set` isn't a real command. The shipping wiring
> is per-agent `start_command` in `pack.toml` / `city.toml`, automated
> by `containerized/wire-shim.sh` running from `gc-docker-start.sh`.
> See `containerized/README.md` "How an agent invocation flows" for
> the current chain. The argv[0] dispatch (one shim binary serving
> claude/codex/gemini via symlinks within `~/.local/bin/gascity-shims/`)
> is preserved — those symlinks are reached by `start_command`'s
> absolute path, not via PATH lookup.

The original options below are kept for historical context.

~~Per the Gas City docs, custom agent commands are configurable:~~

```sh
gc config agent set claude "gc-docker-runner"   # NOT IMPLEMENTED in gc
gc config agent set codex  "gc-docker-runner"
gc config agent set gemini "gc-docker-runner"
```

~~Or, equivalently, install symlinks earlier on `$PATH` than the real binaries:~~

```sh
# Doesn't work on macOS — see implementation note above.
ln -s /usr/local/bin/gc-docker-runner /usr/local/bin/claude
ln -s /usr/local/bin/gc-docker-runner /usr/local/bin/codex
ln -s /usr/local/bin/gc-docker-runner /usr/local/bin/gemini
```

Current wiring (as shipped):

```toml
# pack.toml or city.toml — wire-shim.sh inserts these automatically
[[agent]]
name = "mayor"
start_command = "$HOME/.local/bin/gascity-shims/claude"

[[agent]]
name = "claude"      # rig polecat
scope = "rig"
dir = "<rig-name>"
start_command = "$HOME/.local/bin/gascity-shims/claude"
```

---

## 4. Container invocation rules

The shim builds a `docker run` with these flags. Every flag has a reason — do not strip "for convenience" without re-evaluating threat model.

```
docker run \
  --rm \                                    # ephemeral
  --name gc-${GC_AGENT}-${GC_BEAD_ID} \
  --user 1000:1000 \                        # never root
  --read-only \                             # rootfs is immutable
  --tmpfs /tmp:size=512m,mode=1777 \
  --tmpfs /home/agent/.cache:size=512m \
  --workdir /work \
  -v ${GC_DIR}:/work:rw,Z \                 # per-agent worktree only
  -v ${SECRETS_DIR}:/run/secrets:ro \       # see §5
  --network gc-agent-net \                  # custom bridge, see §6
  --memory=${LIMITS_MEMORY} \
  --cpus=${LIMITS_CPUS} \
  --pids-limit=${LIMITS_PIDS} \
  --cap-drop=ALL \                          # no capabilities
  --security-opt=no-new-privileges \
  --security-opt=seccomp=default \
  -e GC_RIG -e GC_RIG_ROOT -e GC_RIG_PREFIX \
  -e GC_AGENT -e GC_TEMPLATE -e GC_PROVIDER \
  -e GC_BEAD_ID -e GC_SESSION_ID \
  -e GH_TOKEN -e ANTHROPIC_API_KEY -e OPENAI_API_KEY -e GOOGLE_API_KEY \
  -e CLAUDE_API_KEY \
  ${IMAGE_DIGEST} \
  "$@"
```

> **Implementation note (2026-05):** The original draft used
> `GC_RIG_PATH` as both the docker-mode trigger and the mount source.
> gc actually exports `GC_RIG` (rig name), `GC_RIG_ROOT` (rig source
> dir), and `GC_DIR` (per-agent worktree under
> `.gc/worktrees/<rig>/polecats/<agent>`). The shim triggers on
> `GC_RIG` and mounts `GC_DIR` at `/work`. `GC_RIG_PATH` is still
> accepted as a legacy fallback for both. Likewise `GC_AGENT_NAME` was
> renamed to `GC_AGENT` upstream — the shim accepts both for the
> container-name suffix.

**What's deliberately missing:**
- No `-v $HOME:...` of any kind. Not `~/.aws`, not `~/.ssh`, not `~/.config`. If the agent needs something from there, it's an explicit secret.
- No `--privileged`, no `--cap-add`, no `--device`.
- No `/var/run/docker.sock` mount. Docker-in-Docker is forbidden — an agent with the docker socket has root on the host.
- No `--pid=host`, `--net=host`, `--ipc=host`.

**Per-rig overrides:** A `.gc-runner.toml` in the rig root may relax specific things (e.g. add a domain to the allowlist, raise memory). It cannot grant `--privileged`, mount the docker socket, or escape `/work`. The shim refuses to honor forbidden overrides and logs a warning.

---

## 5. Secrets handling

Agents need API keys (model providers) and a git token (push branches). They must not need anything else.

**Strategy:** the shim reads keys from the host's secret store at invocation time and forwards them as env vars **only**. No secret is ever bind-mounted from the host filesystem.

| Secret | Source on host | Surface in container |
|--------|---------------|----------------------|
| `ANTHROPIC_API_KEY` | macOS Keychain / `pass` / 1Password CLI | env var |
| `OPENAI_API_KEY` | same | env var |
| `GOOGLE_API_KEY` | same | env var |
| `GH_TOKEN` | scoped GitHub App installation token, freshly minted per session, 1-hour TTL | env var |
| Cloud creds (AWS, GCP) | **not forwarded** in v1 | absent |

The GH_TOKEN minting is important: a long-lived PAT in env is a footgun. We use a small host helper that calls the GitHub App API to mint a token scoped to the rig's repo with `contents:write, pull_requests:write` only.

`~/.aws` and similar do not exist in the container. If a rig genuinely needs AWS, that's a separate conversation and a separate, audited image variant.

---

## 6. Network policy

We create a dedicated Docker bridge network `gc-agent-net` with no internet by default. Egress is enforced via a small DNS+proxy sidecar pattern, or — simpler for v1 — by configuring the bridge with a local DNS that only resolves allowlisted domains and an iptables rule on the host that drops traffic from `gc-agent-net` not destined for those resolved IPs.

For v1 we accept a less rigorous control: the container uses Docker's default DNS but we set `--dns` to a local resolver (e.g. `dnsmasq`) configured with the allowlist, and rely on the agent honoring DNS. This is **not** airtight (agents can dial IPs directly) but it catches accidental telemetry, package mirror surprises, and most LLM tool calls to non-allowlisted services.

For v2, switch to a Cilium-style or proxy-based egress policy. Track this in the backlog.

**Forbidden in any profile:** `--network host`.

---

## 7. Lifecycle and observability

### Startup
1. `gc start <city>` — supervisor starts as today
2. Supervisor decides to spawn agent for a bead
3. Supervisor execs `claude` (which is our symlink to `gc-docker-runner`)
4. Shim runs `docker run`; container starts; agent runs
5. Container exits when the agent exits
6. Shim exits with the container's exit code

### Stop
- `gc stop <city>` sends SIGTERM to the supervisor
- Supervisor sends SIGTERM to the shim
- Shim runs `docker stop --time=10 <name>` then exits

### Logs
- Container stdout/stderr stream through the shim into Gas City's normal session logs
- We also tee container logs to `~/.local/state/gascity-docker-runner/logs/<session-id>.log` for postmortems
- The image's entrypoint prints a single-line preamble with image digest, mount list, and env keys (not values) for audit

### Failure modes the shim must handle gracefully
- Docker daemon not running → exit with clear message, do not retry forever
- Image pull failure → exit with clear message, log digest attempted
- Container OOM-killed → exit code 137, surfaced in Gas City as session failure
- Timeout exceeded → `docker kill`, exit 124

---

## 8. Validation plan

Before declaring v1 done, the following must pass on a laptop:

1. **Smoke:** `gc init`, `gc rig add`, create a bead, see Claude open the rig in a container, write a file, exit cleanly. File appears in the host worktree.
2. **Footgun probe:** prompt the agent to `rm -rf $HOME`. Confirm host `$HOME` is untouched. Container's view of `/home/agent` is wiped (it was tmpfs anyway).
3. **Network probe:** prompt the agent to `curl https://example.com`. Confirm it fails (not on allowlist). `curl https://api.anthropic.com` succeeds.
4. **Credential probe:** prompt the agent to `cat ~/.aws/credentials` or `cat /run/secrets/*`. Confirm `~/.aws` does not exist; `/run/secrets` contains only the keys we forwarded.
5. **Escape probe:** prompt the agent to `docker ps`. Confirm Docker is not installed in the image and the socket is not mounted.
6. **Concurrency:** run a Gas Town pack with 5 parallel polecats. Confirm 5 containers, no port collisions, no shared state surprises in `/tmp`.
7. **Restart:** `gc stop` mid-session, `gc start`. Confirm the previous container is gone, supervisor reconciles cleanly.

Each probe goes into a `tests/` directory as a scripted bead so we can re-run after changes.

---

## 9. What this does not give us

Be honest about the limits so we don't oversell internally:

- **Not a security boundary against malicious models.** A determined model + an unpatched container escape = host compromise. Mitigation: defense in depth via Option B (k8s + gVisor) when we move to AWS.
- **Not portable to Windows without WSL2.** Docker Desktop on Windows runs Linux containers in WSL2; the spec works there but pathing in `GC_DIR` needs translation. Mark Windows as best-effort in v1.
- **Performance overhead.** Every agent invocation is a `docker run`. On macOS, that's ~1–2s of latency per session start vs subprocess. Acceptable for orchestration; would be a problem if Gas City spawned containers per tool call (it doesn't).
- **No GPU.** If anyone wants local inference inside the agent container, that's a separate image variant with `--gpus`.

---

## 10. Migration path to Option B (k8s on work machine / EKS)

Option A is deliberately a stepping stone. The artifacts that survive the migration:

- `pack.toml`, `city.toml`, beads, formulas — unchanged
- The agent container image — used as-is by the k8s provider, so the image-build pipeline is reused
- The secrets contract (env vars, no filesystem secrets) — maps cleanly to k8s `Secret` + `envFrom`
- The network allowlist — moves from dnsmasq+iptables to a `NetworkPolicy` (or Cilium policy)

The artifacts that change:
- `gc-docker-runner` shim → replaced by Gas City's built-in Kubernetes runtime provider, configured to use our image and our `PodSpec` template
- Per-rig override TOML → becomes a `values.yaml` for whatever Helm chart we settle on

We should keep the shim's behavior and the future PodSpec aligned so debugging stays portable. Specifically: same env var names, same mount paths (`/work`, `/run/secrets`), same non-root uid.

---

## 11. Open questions

- Do we want the shim to be Go (so we can vendor it with `gc`) or shell (so it has zero build)? Lean Go for type safety on the config parsing.
- How do we want to handle `tmux` sessions? Gas Town's tmux integration assumes long-lived shells. For Option A we run one container per session and rely on Gas City's `subprocess` semantics; we should confirm this doesn't break the Gas Town pack out of the box.
- Beads store: the `bd` provider writes to the rig worktree, which is mounted into the container. Is there a contention story when multiple agents in different containers write to the same bead db? (The default is `flock`-based, which works across the bind mount, but verify.)
- Do we want to force `--read-only` on the rig mount and only allow writes through a specific subdirectory? Probably no for v1 — agents need to edit code — but worth revisiting.

---

## 12. Acceptance criteria for v1

- [ ] `gc-docker-runner` shim binary built, signed, on host `$PATH`
- [ ] Agent container image built and pushed for at least `claude` and `codex`
- [ ] Symlinks installed; `gc init` and `gc start` Just Work with the shim
- [ ] All seven validation probes (§8) pass on macOS and one Linux host
- [ ] README in the infra repo with three commands to set up from scratch
- [ ] Postmortem log location documented and accessible via `gc-docker-runner logs <session-id>`
- [ ] One real bead executed end-to-end against a non-trivial rig (e.g. a small internal repo) with a passing PR