# Learning Gas City

Two ways to run [Gas City](https://github.com/gastownhall/gascity) on
this machine — pick the one that matches **this** machine, not your
preference. Each how-to is self-contained.

| Machine | How-to | Agents run… |
|---|---|---|
| **Personal laptop** (throwaway repos, OK if agents have full host access) | [`docs/personal-laptop.md`](docs/personal-laptop.md) | …directly on the host. Simplest setup, full access. |
| **Work machine** (sensitive creds, corporate VPN, shared SSH) | [`docs/work-machine.md`](docs/work-machine.md) | …in scoped Docker containers. No host filesystem, no host creds. |

Both how-tos start from "brand-new machine," walk through prereqs,
install, and daily use. Pick one and follow it.

---

## What is Gas City?

> *Orchestration-builder SDK for multi-agent coding workflows.*

Gas City is the SDK underneath Gas Town: same primitives — runtime
providers, beads-backed work tracking, formulas, molecules, mail,
refinery-style merge gates, controller/supervisor reconciliation —
exposed as a configurable toolkit instead of a fixed end-product.
CLI is `gc`, not `gt`.

What Gas City adds over Gas Town:

- **Declarative `city.toml`** instead of "the Town is what `gt install` made."
- **Multiple runtime providers**: tmux, subprocess, exec, ACP, **Kubernetes**.
- **Packs and overlays** for sharing config across cities.
- **Explicit controller/supervisor reconciliation loop** — Kubernetes-style desired-vs-actual.
- **Machine-wide supervisor** managing multiple cities from one process.

---

## Repo layout

```
learning-gascity/
├── README.md
├── docs/
│   ├── personal-laptop.md                            ← how-to: local install, no isolation
│   ├── work-machine.md                               ← how-to: containerized agents
│   └── containerizing-gascity-for-local-use-spec.md  ← design doc behind the containerized path
├── bootstrap.sh                                      ← brand-new-machine entry for the work-machine path
├── containerized/                                    ← the containerized implementation
│   ├── agent-runner/   (image: minimal Debian + claude CLI)
│   ├── shim/           (gc-docker-runner + gc-docker wrapper)
│   ├── install.sh
│   ├── uninstall.sh
│   └── verify.sh       (7 isolation probes from the spec §8)
├── scripts/                                          ← workspace launchers + lifecycle helpers
│   ├── gascity-workspace-home.sh / .py     ← ↻ swap to local + open home iTerm2 layout
│   ├── gascity-workspace-work.sh / .py     ← ↻ swap to docker + open desert iTerm2 layout
│   ├── gascity-workspace.sh / .py          ← underlying local layout (no swap)
│   ├── gascity-docker-workspace.sh / .py   ← underlying docker layout (no swap)
│   ├── gascity-start.sh / -stop.sh         ← local supervisor lifecycle
│   ├── gascity-docker-start.sh / -stop.sh  ← docker supervisor lifecycle
│   └── gc-feed-ai                          ← textual TUI on top of `gc events --follow`
├── configs/
│   └── gc-CLAUDE.md    (mayor operating recipe)
└── CLAUDE.md           (guidance for Claude Code editing this repo)
```

---

## Pointers

- Upstream Gas City: <https://github.com/gastownhall/gascity>
- Sibling repo for Gas Town: <https://github.com/homercsimpson50/learning-gastown>
- Spec: [`docs/containerizing-gascity-for-local-use-spec.md`](docs/containerizing-gascity-for-local-use-spec.md)
- Editing this repo with Claude Code: [`CLAUDE.md`](CLAUDE.md)
