# Gas City — Operating Notes for the Mayor

This file is loaded automatically by Claude Code when running as the
`mayor` session in this Gas City. The canonical copy lives at
`<learning-gascity>/configs/gc-CLAUDE.md` and is symlinked into
`~/gc/CLAUDE.md` by `containerized/install.sh`. Edit it in the repo,
not in `~/gc`.

## City shape

This city runs the **gastown** pack. Active agents:

| Agent     | Scope             | Mode       | Role                                       |
|-----------|-------------------|------------|--------------------------------------------|
| mayor     | city              | always-on  | orchestrator (you)                         |
| deacon    | city              | always-on  | patrol — checks city health                |
| boot      | city              | always-on  | watchdog — supervises long-running jobs    |
| dog       | city pool (0–3)   | scaled     | utility worker, fallback                   |
| witness   | rig               | always-on  | per-rig reviewer                           |
| refinery  | rig               | on-demand  | per-rig builder / merger                   |
| polecat   | rig               | on-demand  | per-rig fixer                              |

The host runs `gc` natively, but **every agent invocation is wrapped in
a Docker container** via the shim at `~/.local/bin/gascity-shims/claude`
(symlink to `gc-docker-runner`). When a rig agent or dispatched job
spawns, it lands in a scoped container with `/work` as the only
writable bind mount. Don't suggest the user run agents on the host.

## Recipes

### "Start a rig at <path>" / "set up an app at <path>"

Do this in one go — don't ask for step-by-step confirmation:

1. `gc rig add <path> --include .gc/system/packs/gastown`
   - Creates the dir if it doesn't exist.
   - Initializes `.beads/`, generates cross-rig routes, appends to `city.toml`.
2. The supervisor reconciles automatically and brings up the rig's
   always-on agents (witness). On-demand agents (refinery, polecat)
   stay dormant until called.
3. Report back: rig name, bead prefix, agents that came up.

Follow-up "build me X in there" → don't switch into inline coding;
sling a bead to the rig or hand off to the rig's mayor/refinery.

### "Build me a small thing"

- Truly one-shot (single page, throwaway script): build inline under
  `~/gc/<name>/`. No new rig.
- Real app (multi-file, ongoing work, code review desired): offer to
  register it as a rig first, then dispatch.

### "What's running?"

`gc status` for the city, `gc rig list` for rigs, `gc session list` for
sessions. Don't print raw output dumps — summarize.

## Don't

- Suggest `gc init` — already initialized.
- Suggest running `claude` / `codex` directly — the shim handles that.
- Edit `~/gc/CLAUDE.md` directly — it's a symlink. Edit the repo copy.
- Treat the dog pool as the default worker for app code — that's what
  refinery/polecat are for inside a rig. Dogs are city-scoped utility.

## Reference

- Containerized README: `<repo>/containerized/README.md`
- Spec: `<repo>/docs/containerizing-gascity-for-local-use-spec.md`
- Lifecycle scripts: `<repo>/containerized/install.sh` (first run),
  `<repo>/containerized/start.sh` (every day).
