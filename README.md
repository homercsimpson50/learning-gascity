# Learning Gas City

A harness for [Gas City](https://github.com/gastownhall/gascity) — Steve
Yegge's orchestration-builder SDK for multi-agent coding workflows. Two
ways to run it on this machine, plus the spec and chronicle that explain
why this repo is shaped the way it is.

```
learning-gascity/
├── README.md                                            ← you are here
├── containerized/                                       ← Option A: host gc + agents in scoped containers
│   ├── agent-runner/   (image: minimal Debian + claude CLI)
│   ├── shim/           (gc-docker-runner — wraps `claude` → `docker run`)
│   ├── install.sh
│   └── verify.sh
├── scripts/                                             ← local launcher
│   ├── gascity-workspace.sh / .py   (4-pane iTerm2 layout against ~/gc)
│   ├── gascity-start.sh / -stop.sh  (city lifecycle helpers)
│   └── gc-feed-ai                   (streams events with periodic Ollama summary)
├── docs/
│   └── containerizing-gascity-for-local-use-spec.md     ← the spec containerized/ implements
└── CLAUDE.md
```

---

## What is Gas City?

> *Orchestration-builder SDK for multi-agent coding workflows.*

Gas City is the SDK underneath Gas Town: same primitives — runtime
providers, beads-backed work tracking, formulas, molecules, mail,
refinery-style merge gates, controller/supervisor reconciliation — but
exposed as a configurable toolkit instead of a fixed end-product. CLI is
`gc`, not `gt`.

What Gas City adds over Gas Town:

- **Declarative `city.toml`** for shape, instead of "the Town is what
  `gt install` made."
- **Multiple runtime providers**: tmux, subprocess, exec, ACP, **Kubernetes**.
  Same orchestration code, different substrate.
- **Packs and overlays** for sharing config across cities.
- **Explicit controller/supervisor reconciliation loop** —
  Kubernetes-style desired-vs-actual instead of implicit-via-daemons.
- **Machine-wide supervisor** that manages multiple cities on the same
  host from one process.

---

## Two ways to run it

### 1. `containerized/` — Option A: scoped agent containers

The serious-laptop / work-machine path. Gas City's `gc` and supervisor
run normally on the host (no virtualization overhead, native logs,
launchd integration), but **every agent invocation is wrapped in a
Docker container** scoped to a single rig worktree. No host SSH keys,
AWS creds, or `~/.config` are reachable from inside.

The implementation follows
[`docs/containerizing-gascity-for-local-use-spec.md`](docs/containerizing-gascity-for-local-use-spec.md):
a small **`gc-docker-runner` shim** stands in for `claude`/`codex`/`gemini`
on `PATH` and translates each agent invocation into a hardened
`docker run` against `gascity-agent-runner:<agent>`.

```bash
cd containerized/
./install.sh                      # build agent image, install shim, set up symlinks, drop default config
export PATH="$HOME/.local/bin/gascity-shims:$PATH"   # then add to your shell rc
./verify.sh                       # 7 isolation probes from the spec §8
gc init ~/my-city && cd ~/my-city
gc rig add ~/code/some-repo && bd create "do a thing" && gc start
```

Full guide: [`containerized/README.md`](containerized/README.md).

### 2. `scripts/` — local install, no isolation

The personal-laptop path. `gc` runs natively, agents run as host
subprocesses (full host access — fine on a throwaway machine). Comes
with a 4-pane iTerm2 workspace layout against `~/gc` modeled after
the gastown layout at `~/gt`.

```bash
./scripts/gascity-workspace.sh      # opens iTerm2 layout
./scripts/gascity-workspace.sh --ai # same, but feed pane uses Ollama summary
```

---

## Why two paths?

Different threat models. Containerized is for machines where one rogue
agent is one rogue agent too many — work laptops, machines with cloud
credentials in the env, anything with shared SSH access. Local is for a
machine you'd anyway hand a stranger a shell on.

Same upstream, same `gc` CLI, same beads — the only difference is
whether agent invocations go through a `docker run` boundary.

---

## Pointers

- [`docs/containerizing-gascity-for-local-use-spec.md`](docs/containerizing-gascity-for-local-use-spec.md) — the design doc that drives `containerized/`.
- [`containerized/README.md`](containerized/README.md) — full operational guide for Option A.
- [`CLAUDE.md`](CLAUDE.md) — guidance for Claude Code when working in this repo.
- Upstream Gas City: <https://github.com/gastownhall/gascity>.
- Sibling repo for Gas Town: <https://github.com/homercsimpson50/learning-gastown>.
