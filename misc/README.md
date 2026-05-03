# `misc/` — relocated, superseded, or never-wired files

Things that used to live elsewhere in the repo but are no longer
referenced by the active install + boot flow. Kept for archaeological
reasons; not deleted in case the user wants to revive any of them.

If you're new and looking for the canonical paths, ignore this dir
entirely:

- **First-time setup:** `bootstrap.sh` (top-level)
- **Daily start (work machine):** `gc-workspace-work.sh` →
  `scripts/gascity-docker-start.sh`
- **Daily start (personal laptop):** `gc-workspace-home.sh` →
  `scripts/gascity-start.sh`
- **Mayor operating prompt:** lives in the city's
  `agents/mayor/prompt.template.md`, not here.

## What's in here

### `start.sh` (was `containerized/start.sh`)

A daily-startup helper for the containerized flow. Superseded by
`scripts/gascity-docker-start.sh` (called by `gc-workspace-work.sh`).

Why moved:

- Calls `gc supervisor start` (the launchd-managed supervisor), which
  doesn't inherit the shim PATH from its invoker — the exact bug
  `gascity-docker-start.sh` was written to work around (it uses
  `nohup gc supervisor run` so the shim PATH is preserved).
- Operates on `~/gc` (the *local* city), not `~/gc-docker` — but
  lives in `containerized/`, which is misleading.
- Still useful as reference for the `--workspace` / `--ai` flag
  shape, which the home/work wrappers don't expose directly.

### `gc-CLAUDE.md` (was `configs/gc-CLAUDE.md`)

A "mayor operating recipe" that was supposed to be auto-symlinked into
`~/gc/CLAUDE.md` by `containerized/install.sh`, so a fresh mayor
session would load it on startup.

Why moved:

- `install.sh` does NOT actually symlink it anywhere. The symlink the
  file claims exists doesn't.
- Contents are partly stale relative to the shipped wiring:
  - Claims "every agent invocation is wrapped in a Docker container"
    via the shim — only true for rig-scoped agents (polecats,
    witness, refinery). City-scoped agents (mayor, deacon, boot) run
    on host through the shim's passthrough mode.
  - References `~/gc` (local city); the actual containerized setup
    uses `~/gc-docker`.
  - Points at `containerized/start.sh` (also moved here) as the
    daily startup script.
- Some content is still useful (the agent-scope table, the "what's
  running?" quick reference, the don't-suggest-`gc init` advice). If
  reviving, freshen it against the current city setup and wire it
  into install.sh's symlink list explicitly.
