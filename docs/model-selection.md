# Model selection per gascity component

A practical guide to picking the cheapest defensible Claude model for
each agent in the city, plus a list of the situations where Opus is
genuinely worth the spend. Forward-looking notes on AWS Bedrock are
at the bottom — once the work-machine cutover happens, the same
mapping applies; only the model identifiers and auth change.

The advice here is qualitative ("tier" instead of $/Mtok). Pricing
moves around; check
<https://www.anthropic.com/pricing> and the AWS Bedrock console
before committing to a budget.

> **Status:** planning doc. As of 2026-05, no per-agent model selection
> is wired up in this repo — every agent runs whatever the city's
> default provider returns. The recipe below is what to build toward.

## TL;DR table

| Agent | Scope | Default tier | Why this tier |
|---|---|---|---|
| **mayor** | city | **Sonnet** | Orchestration + delegation decisions; needs reasoning, rarely needs Opus-grade synthesis. |
| **deacon** | city | **Haiku** | Heartbeat / patrol — same handful of `gc` checks every cycle. |
| **boot** | city | **Haiku** | Watchdog — restart logic + simple state checks. |
| **dog** | city pool | **Haiku** | Maintenance: close stale beads, retry transient failures. |
| **witness** | rig | **Haiku → Sonnet** | Haiku for "did the run succeed?" observability; Sonnet if it actually reviews diffs. |
| **refinery** | rig | **Sonnet** | Integrates work, builds, resolves merge conflicts. |
| **polecat** | rig | **Sonnet** | The actual coding agent; the bulk of token spend. Opus only when you've watched Sonnet thrash on a specific task. |

Tier intuition: relative to Sonnet (the default for "good at code"),
Haiku is roughly an order of magnitude cheaper, and Opus is roughly
several times more expensive. Confirm with the live pricing pages.

## Where Opus IS worth it

Don't default-assign Opus anywhere. Reach for it when one of these is
true:

- **The task requires holding many files in working context at once**
  and reasoning across them — large refactors, new feature spanning
  3+ subsystems, design-doc audits.
- **Sonnet has visibly thrashed twice on the same task** (looped on
  the same fix-fail-fix cycle, kept misreading a constraint). Opus's
  better failure analysis often unsticks these in one shot.
- **The decision is one-shot and load-bearing** — picking a database
  schema, choosing between two architectures, doing a security
  review of a migration. Cost is bounded by "one session".

## Where Opus is NOT worth it

These are common temptations that don't pay off:

- Routine bug-fixing with a clear repro. Sonnet handles them fine.
- Code review on small diffs. Sonnet (or even Haiku for simple
  diffs).
- "Big project so it must need Opus" — size doesn't imply
  difficulty. Many large rigs are mostly boring CRUD; polecats can
  stay on Sonnet.
- Writing tests, migrations, or fixtures from a known schema.

## Where Haiku is plenty

Don't underrate Haiku for any agent whose loop is:

> read state → check N conditions → emit N actions → wait

That describes deacon, boot, dog, and witness in observation mode.
The reasoning depth needed is low; what matters is throughput and
cost. Pushing these to Sonnet wastes budget without changing
outcomes.

## Wiring it up

Two layers to configure:

### 1. Per-agent model in `pack.toml` / `city.toml`

The schema appears to support a `model` field on `[[agent]]` blocks
(seen as a redefinable key in the gc binary's `agent_defaults.model`
log line). Not yet verified in this repo. Try:

```toml
[[agent]]
name = "deacon"
model = "claude-haiku-4-5"     # cheapest tier
start_command = "$HOME/.local/bin/gascity-shims/claude"

[[agent]]
name = "polecat"
scope = "rig"
model = "claude-sonnet-4-6"    # default for coding
start_command = "$HOME/.local/bin/gascity-shims/claude"
```

Confirm with `gc config explain` after `gc reload`.

If the field isn't honored (no `model = …` line in the explain output
for that agent), fall back to layer 2.

### 2. Per-session env var via `start_command` wrapper

Wrap the shim with a tiny script per tier that exports the right
model env var, then exec's the shim. Claude Code reads
`ANTHROPIC_MODEL` (and `ANTHROPIC_DEFAULT_HAIKU_MODEL` /
`ANTHROPIC_DEFAULT_SONNET_MODEL` / `ANTHROPIC_DEFAULT_OPUS_MODEL` for
the auto-tiering features). Example:

```bash
# ~/.local/bin/gascity-shims/claude-haiku
#!/usr/bin/env bash
export ANTHROPIC_MODEL="claude-haiku-4-5"
exec ~/.local/bin/gascity-shims/claude "$@"
```

Then point that agent's `start_command` at `claude-haiku` instead of
`claude`. `wire-shim.sh` would need to be parameterized to write the
right tier per agent — straightforward extension.

## Bedrock cutover

When the host machine moves to AWS Bedrock (work-laptop policy: no
personal Pro/Max allowed, must use Bedrock for billing + auth), the
same agent→tier mapping applies. The wire-up changes:

- **Auth.** Stop using `ANTHROPIC_API_KEY`. Set:
  ```
  CLAUDE_CODE_USE_BEDROCK=1
  AWS_REGION=us-west-2          # or whichever region your account uses
  ```
  Plus standard AWS creds (profile, SSO, or IRSA-style env vars). Do
  NOT bake creds into the image — forward via env from the host.
- **Forward in the shim.** Add `AWS_REGION`,
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`,
  `AWS_PROFILE` to `FORWARD_ENV` in
  `containerized/shim/gc-docker-runner`. Note that `AWS_PROFILE`
  alone won't work inside the container unless `~/.aws/config` is
  also mounted — and the spec forbids mounting `~/.aws/`. So use
  short-lived env-var creds (SSO refresh on the host, forward the
  resulting `AWS_*_KEY_ID` triple) rather than profile names.
- **Model identifiers.** Replace API-flavor model IDs with Bedrock
  inference profile ARNs or model IDs. Format:
  `anthropic.claude-haiku-4-5-<date>-v1:0`,
  `anthropic.claude-sonnet-4-6-<date>-v1:0`,
  `anthropic.claude-opus-4-7-<date>-v1:0`. Cross-region inference
  profiles (`us.anthropic.…`) are usually preferable for
  availability. Check the Bedrock console for what's enabled in your
  account — Opus often requires an explicit access request.
- **Pricing.** Bedrock pricing is comparable to Anthropic API list
  pricing in the same tier; the cost-optimization advice in this
  doc transfers without modification. Bedrock does NOT bill against
  a Claude.ai Pro/Max subscription — every request is metered.
- **Auth contract preserved by the shim.** Keep the existing
  `claude must use claude.ai first-party auth` failure mode in mind:
  with `CLAUDE_CODE_USE_BEDROCK=1` set, claude won't try first-party
  auth, so this is fine. Verify by running a one-off
  `claude --version` inside the container after switching.

A separate doc (`docs/bedrock-setup.md`) will land alongside the
actual rewire. This doc just records the tier choices that survive
the move.

## Open questions

- Is `model` in `[[agent]]` blocks honored in the current gc binary?
  Needs a one-line test in `pack.toml` and a `gc config explain`
  check.
- Does Bedrock support all three tiers in the user's account? Opus
  access is gated; if it isn't enabled, the "Opus is worth it"
  decisions above degrade to "use Sonnet harder" without code
  changes.
- Per-agent token-budget caps? gc has `idle_timeout` but no token
  budget knob in the schema we've seen — would need an upstream
  feature request or a wrapper that watches usage and shuts down
  over budget.
