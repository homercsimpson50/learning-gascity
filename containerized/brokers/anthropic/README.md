# gc-broker-anthropic

Reverse proxy that injects the host's Anthropic OAuth bearer token into
agent requests bound for `api.anthropic.com`. Agents reach it via
`ANTHROPIC_BASE_URL=http://gc-broker-anthropic:8080` on `gc-broker-net`.

Spec: [`docs/credential-broker-v2-spec.md §7.1`](../../../docs/credential-broker-v2-spec.md).

## What gets mounted

- `~/.local/state/gascity-broker/creds.json:/secrets/creds.json:ro`

The host file is **not** `~/.claude/.credentials.json` — current Claude
Code on macOS stores OAuth in the Keychain, not a flat file. The
host-side extractor (`scripts/gc-broker-creds-extract.sh`) runs once at
broker-start time and writes the JSON to that state path with mode 0600.

## What gets injected vs stripped

Per request the broker:

- Strips agent-supplied `Authorization`, `X-Api-Key`, `Host`,
  `Content-Length`.
- Adds `Authorization: Bearer <token from creds.json>` (re-read every
  request to handle host-side OAuth refresh).
- Adds `anthropic-version: 2023-06-01` if missing.
- Prepends `gc-broker-anthropic/1.0` to `User-Agent`.

The bearer token never appears in stdout logs (only the redacted JSON
log line is emitted).

## Allowlist

| Method | Path |
|---|---|
| POST | `/v1/messages`, `/v1/messages/count_tokens`, `/v1/messages/batches` |
| GET | `/v1/messages/batches/*`, `/v1/models`, `/v1/models/*` |
| GET | `/healthz` (broker-local) |

Anything else: 403 with `{"error":{"type":"broker_denied",...}}`.

## Defense-in-depth checks

- 16 MiB body cap (laptop-DoS guard, not Anthropic's actual limit).
- `max_tokens > 200000` → 400 (runaway-loop guard).
- Optional model allowlist via `MODEL_ALLOWLIST` env (comma-separated).

No cost cap, no rate limit (per spec §1).

## Streaming

`POST /v1/messages` with `"stream": true` returns SSE. The broker uses
`aiohttp.web.StreamResponse` and forwards chunks via `iter_any()` with
no buffering. Verify probe A4 confirms multiple chunks arrive separated
in time.

## Failure modes

- `creds.json` missing or unparseable at start: broker exits 1
  (`docker logs gc-broker-anthropic` shows the FATAL line).
- Token expired (Anthropic returns 401): broker forwards the 401 to the
  agent. Refresh via `gc-docker-start.sh` (which re-runs the extractor)
  or run `claude --version` on the host to refresh and re-run start.
- Upstream unreachable: broker returns 502.
