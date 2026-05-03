# Learning Gas City

A clean, gascity-only setup. Run [Gas City](https://github.com/gastownhall/gascity) —
the orchestration-builder SDK for multi-agent coding workflows — in a
sandboxed Docker container, with no Gas Town legacy and nothing else
mixed in.

```
learning-gascity/
└── containerized/         ← Docker build context. One command brings it up.
    ├── Dockerfile
    ├── docker-compose.yml
    ├── docker-entrypoint.sh
    ├── .env.example
    └── README.md
```

---

## What is Gas City?

> *Orchestration-builder SDK for multi-agent coding workflows.*

Gas City is the SDK underneath Gas Town. Same primitives — runtime
providers, beads-backed work tracking, formulas, molecules, mail,
refinery-style merge gates, controller/supervisor reconciliation — but
exposed as a configurable toolkit instead of a fixed end-product.

Compared to Gas Town, Gas City gives you:

- **A declarative `city.toml`** for shape, not the implicit "Town is what
  `gt install` made."
- **Multiple runtime providers** out of the box: tmux, subprocess, exec,
  ACP, and **Kubernetes**. Same orchestration code, different substrate.
- **Packs and overlays** for sharing config across cities (one
  "carparts" pack imported into multiple cities, for instance).
- **An explicit controller / supervisor reconciliation loop** —
  Kubernetes-style desired-vs-actual instead of implicit-via-daemons.
- **A machine-wide supervisor** that can manage multiple cities on the
  same host from one process.

The CLI is `gc`, not `gt`.

---

## Quick start

```bash
cd containerized/
cp .env.example .env
# edit .env so GIT_USER / GIT_EMAIL aren't "TestUser"

docker compose up -d --build
docker compose exec gascity gc version
docker compose exec gascity gc doctor
```

Then add your code as a rig and start working — full walkthrough in
[`containerized/README.md`](containerized/README.md).

---

## Why containerize?

Gas City agents run with `--dangerously-skip-permissions`. On a personal
laptop, that's fine. On a work machine with corporate VPN, SSH keys, AWS
credentials, browser profiles, and sensitive repos, one rogue agent is
one rogue agent too many. The container locks agents into `/city`
(workspace) and `/city/rigs-host` (your code) and physically blocks
their view of the rest of your home directory.

---

## How it differs from "vendor the gascity repo"

The Dockerfile is a **multi-stage build** — stage 1 clones the gascity
repo at a pinned ref and compiles `gc`; stage 2 is the runtime image
with just the binary plus deps. You get:

- One command (`docker compose up --build`) handles everything; no need
  to clone gascity yourself.
- The image is reproducible from a SHA pin in `.env`
  (`GASCITY_REF=<sha>`), not from "whatever's in your local checkout."
- The runtime image is small — Go toolchain stays in the builder stage.

---

## Pointers

- [`containerized/README.md`](containerized/README.md) — full guide:
  build, bring up, add rigs, volumes, security, troubleshooting.
- [Upstream gascity README](https://github.com/gastownhall/gascity) —
  what `gc` actually does once you're inside the container.
- [Gas City "Coming from Gas Town?"](https://github.com/gastownhall/gascity/blob/main/docs/getting-started/coming-from-gastown.md)
  — the doc whose existence tells you what audience this is for.
