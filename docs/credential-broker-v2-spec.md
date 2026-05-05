# Gas City Containerized Agents — v2: Credential Broker Sidecars

**Status:** Spec, ready for implementation
**Audience:** Implementer (assume no prior conversation context — read this end to end before writing code)
**Predecessor:** [`containerizing-gascity-for-local-use-spec.md`](containerizing-gascity-for-local-use-spec.md) (v1, the shell-shim implementation already deployed in `containerized/`).
**Repo invariant:** Wrapper-only. **Do not** patch upstream `gc`, `bd`, `claude`, `gh`, or `git`. All changes land in `containerized/` and `scripts/` of *this* repo.

---

## 0. How to read this document

You are implementing this spec from scratch. You have access to the repo and to nothing else. Before you write any code:

1. Read [`docs/work-machine.md`](work-machine.md) to understand the user-facing flow.
2. Read [`docs/containerizing-gascity-for-local-use-spec.md`](containerizing-gascity-for-local-use-spec.md) sections 3–5 and 8 — that is v1 architecture. v2 is built on top of it; you will not understand v2 without v1.
3. Read [`containerized/shim/gc-docker-runner`](../containerized/shim/gc-docker-runner) end to end. You will modify this file in §8.
4. Read [`containerized/install.sh`](../containerized/install.sh) and [`containerized/verify.sh`](../containerized/verify.sh) end to end.

When you have done that, return here and start at §1. Reference earlier sections by number rather than re-deriving prior context.

This spec is intentionally specific about **interfaces** (file paths, env var names, CLI shapes) and intentionally permissive about **implementation language**. The Anthropic and GitHub-API brokers can be Python (aiohttp), Go (net/http), nginx+Lua, or mitmproxy+addon — pick one and stay consistent. The SSH broker uses OpenSSH and bash, not your choice. Justify any deviation in the PR description.

---

## 1. Goal

Today (v1), agent containers run with `--cap-drop ALL`, `--read-only`, no host mounts other than the rig worktree, and no host credentials. That keeps a misbehaving agent boxed in but means **the agents can't authenticate to anything**:

- Claude Code in the container has no `~/.claude/`, so OAuth state is unreachable. Without an `ANTHROPIC_API_KEY` env var on the host shell that started the supervisor, the in-container `claude` cannot reach Anthropic at all.
- The GitHub HTTPS API requires `GH_TOKEN`, which v1 forwards if set in the host env. That works but exposes the full-scope token directly to the agent.
- `git push` over HTTPS requires the same token; over SSH it requires a key, and v1 has neither.

The goal of v2 is to give agents authenticated access to Anthropic and GitHub **without ever placing a host credential inside an agent container**. We do this by introducing three long-lived **broker** containers that each hold one type of credential and expose a narrow, audited interface to the agents.

| Broker | Holds | Exposes to agent | Agent reaches it via |
|---|---|---|---|
| `gc-broker-anthropic` | `~/.claude/.credentials.json` (OAuth token) | HTTPS reverse proxy on port 8080 | `ANTHROPIC_BASE_URL=http://gc-broker-anthropic:8080` |
| `gc-broker-github-api` | `GH_TOKEN` from host env | HTTPS reverse proxy on port 8080 | `GITHUB_API_URL=http://gc-broker-github-api:8080` |
| `gc-broker-github-ssh` | Selected `~/.ssh/<key>` from host (read-only) | `ssh-agent` Unix socket on a shared volume | `SSH_AUTH_SOCK=/run/sshagent/gc.sock` |

After v2 ships, agents can call `claude -p ...`, `gh pr create`, `git push origin main` — and none of those operations expose the underlying credential to the agent's process, filesystem, environment, or network.

**Cost is not a goal.** The user has a Pro Max plan via OAuth and is not trying to limit token spend. The brokers therefore do not implement rate limits, model allowlists, or budget caps unless they are useful as defense-in-depth (and where they are, this is called out explicitly).

**Reproducibility is not a goal.** Image-digest pinning is deferred to a separate change.

---

## 2. Non-goals

- Defending against a deliberately malicious model breaking out of the agent container. The kernel is shared via Docker Desktop's VM. v1's threat model — and v2's — is footgun containment, not nation-state sandbox escape.
- Defending against a compromised broker. The brokers are high-value targets. The hardening rules in §6 are designed to make compromise unlikely, not impossible.
- Replacing OAuth refresh logic. Claude Code's CLI on the host writes/refreshes `~/.claude/.credentials.json` as part of its normal lifecycle. The Anthropic broker reads that file on each request; it does not implement OAuth client logic of its own.
- Multi-user. This is a single-user laptop setup. Brokers run as the host user; no user multiplexing.
- Egress allowlisting at the *agent* container level beyond denying direct internet access. The brokers are the only legal egress; agents that try to reach `api.anthropic.com` directly will fail at DNS resolution because the agent's docker network has no internet route. That is the whole egress story for v2.

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Host (your laptop)                                                       │
│                                                                          │
│   gc-supervisor (PATH includes shim dir)                                 │
│        │                                                                 │
│        │ spawns agents via $HOME/.local/bin/gascity-shims/claude         │
│        ▼                                                                 │
│   gc-docker-runner (the v1 shim, modified per §8)                        │
│        │                                                                 │
│        │ docker run --network gc-broker-net ...                          │
│        ▼                                                                 │
│   ┌────────────────────────┐         ┌────────────────────────────┐      │
│   │ docker net: gc-broker- │         │ docker net: gc-egress-net  │      │
│   │ net (internal=true,    │         │ (default bridge, internet) │      │
│   │ no internet)           │         │                            │      │
│   ├────────────────────────┤         ├────────────────────────────┤      │
│   │                        │         │                            │      │
│   │  agent container ──┐   │         │       (brokers reach       │      │
│   │  (claude/codex)    │   │         │        api.anthropic.com,  │      │
│   │                    │   │         │        api.github.com,     │      │
│   │  ┌─────────────────┴─┐ │         │   ┌──  github.com:22)      │      │
│   │  │ gc-broker-anthropic│─┼────────────│                        │      │
│   │  │ port 8080         │ │         │   │                        │      │
│   │  └────────────────────┘ │         │   │                        │      │
│   │                         │         │   │                        │      │
│   │  ┌────────────────────┐ │         │   │                        │      │
│   │  │ gc-broker-github-  │─┼────────────│                        │      │
│   │  │ api  port 8080     │ │         │   │                        │      │
│   │  └────────────────────┘ │         │   │                        │      │
│   │                         │         │   │                        │      │
│   │  ┌────────────────────┐ │         │   │                        │      │
│   │  │ gc-broker-github-  │─┼────────────┘                         │      │
│   │  │ ssh  ssh-agent sock│ │         │                            │      │
│   │  └────────────────────┘ │         │                            │      │
│   └─────────────────────────┘         └────────────────────────────┘     │
│                                                                          │
│   Read-only host mounts (broker side ONLY, never agent side):            │
│     gc-broker-anthropic     ←── ~/.claude/.credentials.json (ro)         │
│     gc-broker-github-ssh    ←── ~/.ssh/<configured key>     (ro)         │
│                              ←── ~/.ssh/known_hosts          (ro)         │
│     gc-broker-github-api    ←── GH_TOKEN env var (no fs mount)           │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

Key invariants:

- **Two docker networks.** `gc-broker-net` is `--internal` (no host bridge to the internet). `gc-egress-net` is the default bridge. Agent containers are attached *only* to `gc-broker-net`. Brokers are attached to *both*.
- **Brokers are long-lived.** They start with the supervisor and stop with the supervisor. They survive across many agent container lifecycles.
- **Brokers are addressable by container name.** Docker's embedded DNS resolves `gc-broker-anthropic` and `gc-broker-github-api` to the broker IP within `gc-broker-net`. No port publication to the host.
- **Brokers have host fs mounts; agents do not.** The credential mounts are confined to broker containers. An agent container has only `-v $RIG_PATH:/work:rw,Z` and tmpfs, exactly as in v1.

---

## 4. Threat model

**Defends against:**

- An agent reading the OAuth token, GitHub PAT, or SSH private key from its filesystem, environment, or memory. None of those are present in the agent container.
- An agent extracting a credential by inspecting outbound network traffic. Outbound HTTPS from the agent to the broker is plain HTTP on a private docker network; the agent never sees the broker's outbound TLS to Anthropic or GitHub.
- An agent escaping its container and reaching the credentials by remounting `/proc` or scanning the host. Brokers run with `--cap-drop ALL`, `--read-only`, and `--security-opt no-new-privileges`, same as the agent. The agent cannot reach the broker's namespaces.
- An agent issuing GitHub API operations the user did not authorize for the agent (e.g., `DELETE /repos/...`, `PATCH /user`). The GitHub-API broker's path/method allowlist blocks these.
- An agent using `git push` to land code in a repo the user did not allowlist. Enforced at the SSH broker via the agent-policy filter (§7.6).

**Does not defend against:**

- An agent writing whatever it wants to `/work`, including malicious code that you might later run on the host. Code review on agent commits is the answer to that, not the broker.
- A compromised broker. If the Anthropic broker is exploited, the OAuth token leaks. If the SSH broker is exploited, the SSH key file (or at minimum the ability to sign anything) leaks.
- The OAuth token's underlying scope. The token in `~/.claude/.credentials.json` has whatever scopes Anthropic granted. The broker's path allowlist is a *defense layer*; it does not change the token itself. If Anthropic adds new endpoints in the future and the broker's allowlist is not updated, the limitation only holds for endpoints the implementer thought to block.
- Side-channel inference. An agent can ask Claude questions whose answers reveal information about the broker's configuration. This is bounded by what the broker exposes via its responses, which is "Anthropic API output."

---

## 5. Network topology

### 5.1 Networks

Two docker networks, both created by `containerized/install.sh` (idempotent):

```bash
docker network inspect gc-broker-net >/dev/null 2>&1 || \
    docker network create --internal --driver bridge gc-broker-net
docker network inspect gc-egress-net >/dev/null 2>&1 || \
    docker network create --driver bridge gc-egress-net
```

`--internal` means containers on `gc-broker-net` have no NAT to the host; they can talk to each other but not to the wider internet. This is the *core* of the v2 isolation story for agents.

### 5.2 Container network attachments

| Container | `gc-broker-net` | `gc-egress-net` |
|---|---|---|
| `gc-broker-anthropic` | yes (DNS-discoverable) | yes (talks to api.anthropic.com) |
| `gc-broker-github-api` | yes (DNS-discoverable) | yes (talks to api.github.com) |
| `gc-broker-github-ssh` | yes (Unix socket on volume; no listening port) | yes (talks to github.com:22) |
| agent containers | yes | **no** |

Concretely, brokers must be attached to both networks. `docker run` only takes `--network` once; the second network is attached via `docker network connect <net> <container>` after the container is created. The broker's startup script (or `docker compose`, if you choose to use it) handles this.

### 5.3 DNS

Within `gc-broker-net`, docker's embedded resolver gives each container its name. Agents reach brokers via:

- `http://gc-broker-anthropic:8080`
- `http://gc-broker-github-api:8080`
- `unix:///run/sshagent/gc.sock` (via shared volume, not network)

No host-side port publication. `docker port gc-broker-anthropic` returns nothing. The broker is invisible from the host's localhost.

---

## 6. Common broker rules

These apply to **every** broker container.

### 6.1 Image base

`debian:stable-slim` (matches the agent runner). Minimal apt install set. No build tools, no shell utilities the agent might exploit if the broker is compromised.

### 6.2 User and capabilities

```
--user 1000:1000 \
--read-only \
--tmpfs /tmp:size=64m,mode=1777 \
--cap-drop ALL \
--security-opt no-new-privileges \
--pids-limit 64 \
--memory 256m
```

The broker is small. 256 MB of memory and 64 PIDs are generous. Tighten further only if it doesn't break Python's startup.

### 6.3 No shell, no curl

Broker images must not contain `bash`, `sh` other than dash (which is dpkg's default), `curl`, `wget`, `nc`, or any general-purpose networking tool. The only thing in the image is the proxy implementation and its language runtime (Python 3.12 + aiohttp; or a static Go binary; or nginx+Lua).

### 6.4 No persistent storage

Brokers are stateless across restarts. Logs are written to stdout/stderr; docker's log driver collects them. Rate-limit counters, if any, live in process memory. After `docker restart`, counters reset — this is fine for v2.

### 6.5 Logging contract

Every broker writes structured JSON lines to stdout, one line per request. Required fields:

```json
{
  "ts": "2026-05-04T18:23:11.482Z",
  "broker": "anthropic",
  "src_container": "gc-claude-gd-7bz",
  "src_ip": "172.21.0.5",
  "method": "POST",
  "path": "/v1/messages",
  "model": "claude-sonnet-4-6",
  "status": 200,
  "duration_ms": 4321,
  "input_tokens": 1240,
  "output_tokens": 887,
  "decision": "allow"
}
```

For denied requests:

```json
{
  "ts": "2026-05-04T18:23:11.482Z",
  "broker": "github-api",
  "src_container": "gc-codex-gd-7bz",
  "src_ip": "172.21.0.6",
  "method": "DELETE",
  "path": "/repos/owner/secret-repo",
  "status": 403,
  "decision": "deny",
  "deny_reason": "method-not-allowed"
}
```

**Never** log:
- The Authorization header (redact at the source — write log lines from the request handler before constructing the upstream request, not after).
- Request or response bodies.
- The OAuth token, the GH_TOKEN, the SSH key, or anything derived from them.

A test in `verify.sh` (§11) greps the broker's logs for `Bearer ` and fails if it finds a hit.

### 6.6 Health endpoint

Every broker exposes `GET /healthz` (HTTP brokers) or sends `SSH_AGENT_RC == 0` (SSH broker — it's running if its socket file exists). Used by `gc-docker-start.sh` to wait for brokers before letting agents spawn.

### 6.7 Startup ordering

```
docker network create gc-broker-net (--internal)
docker network create gc-egress-net
docker run gc-broker-anthropic     -d --network gc-broker-net
docker network connect gc-egress-net gc-broker-anthropic
docker run gc-broker-github-api    -d --network gc-broker-net
docker network connect gc-egress-net gc-broker-github-api
docker run gc-broker-github-ssh    -d --network gc-broker-net
docker network connect gc-egress-net gc-broker-github-ssh
# Wait for /healthz on each (timeout 30s)
gc supervisor run &
```

Agents are spawned by the supervisor. By the time the first agent is spawned, the brokers are ready.

---

## 7. Per-broker specifications

### 7.1 `gc-broker-anthropic`

**Image:** `gascity-broker-anthropic:v1`. Built from `containerized/brokers/anthropic/Dockerfile`.

**Mounts:**
- `~/.claude/.credentials.json:/secrets/creds.json:ro`

**Environment (set at `docker run`):**
- `ANTHROPIC_UPSTREAM=https://api.anthropic.com`
- `LISTEN_ADDR=0.0.0.0:8080`
- `MODEL_ALLOWLIST=` (empty = allow all; see §7.1.5)

**Startup:** read `/secrets/creds.json` once to validate parseability, then re-read on every request (handles host-side OAuth token refresh).

**Token extraction.** The credentials JSON file structure on macOS for a current Claude Code install is approximately:

```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-…",
    "refreshToken": "…",
    "expiresAt": 1735689600000,
    "scopes": ["user:inference", "user:profile"]
  }
}
```

Implementation must:
1. Parse the file on each request (cheap; it's ~1 KB).
2. Use `claudeAiOauth.accessToken` as the bearer token.
3. If `expiresAt` is in the past, log a warning and forward anyway — the host's Claude Code is responsible for refreshing; the broker is not. (Forwarding an expired token will result in a 401 from Anthropic, which the agent will see. That is the correct failure mode.)

**Path allowlist.** Forward only the following:

| Method | Path pattern | Notes |
|---|---|---|
| POST | `/v1/messages` | Main inference. Must support streaming (SSE). |
| POST | `/v1/messages/count_tokens` | Token counting. |
| POST | `/v1/messages/batches` | Batch requests. |
| GET | `/v1/messages/batches/*` | Batch status/results. |
| GET | `/v1/models` | Model list. |
| GET | `/v1/models/*` | Specific model metadata. |

Everything else: respond `403` with body `{"error": {"type": "broker_denied", "message": "path not in allowlist"}}`.

**Streaming.** `POST /v1/messages` with `"stream": true` returns Server-Sent Events. The broker must:
- Use chunked transfer encoding back to the agent.
- Pass through the upstream's `text/event-stream` content-type.
- Forward bytes as they arrive (no buffering; this is what `aiohttp.web.StreamResponse` does, or in Go `http.Flusher.Flush()` per chunk).

A non-streaming implementation will appear to work for short responses and break for long ones. **Test streaming explicitly** — see verify probe §11.A4.

**Header handling.**
- Strip incoming `Authorization`, `X-Api-Key`, `Anthropic-*` headers from the agent's request (don't trust agent-provided auth).
- Add `Authorization: Bearer <token from creds.json>`.
- Add `anthropic-version: 2023-06-01` if not present (matches Claude Code's default).
- Forward `User-Agent` if present, prepend `gc-broker-anthropic/1.0`.
- Pass through `Accept`, `Content-Type`.
- On the response side: pass through everything except `Set-Cookie` (strip).

**Defense-in-depth checks:**

- **Body size cap:** reject requests with `Content-Length > 16 MiB` with 413. Anthropic's own limits are higher; this is laptop-DoS protection.
- **`max_tokens` sanity:** if the JSON body parses and contains `max_tokens > 200000`, reject with 400. This is not a cost cap (user explicitly waived); it's a runaway-loop guard.
- **`MODEL_ALLOWLIST`:** if set in env (comma-separated), reject requests with `model` not in the list. If unset, allow all. Default in `config.toml`: unset.

**No cost cap, no rate limit.** Per goals (§1).

### 7.2 `gc-broker-github-api`

**Image:** `gascity-broker-github-api:v1`. Built from `containerized/brokers/github-api/Dockerfile`.

**Mounts:** none.

**Environment (set at `docker run`):**
- `GH_TOKEN=<value forwarded from host env>`
- `GITHUB_UPSTREAM=https://api.github.com`
- `LISTEN_ADDR=0.0.0.0:8080`
- `REPO_ALLOWLIST=knail1/*,homercsimpson50/*` (from `config.toml`; comma-separated `owner/repo` patterns; `*` for "any repo under owner")

**Token source.** Read `GH_TOKEN` once at startup. Do not re-read; broker must restart to pick up a new value. (Unlike Anthropic's OAuth, GitHub PATs don't auto-refresh.)

**Path × method allowlist.** Forward only:

| Method | Path pattern | Repo-allowlist enforced? |
|---|---|---|
| GET | `/repos/{owner}/{repo}` | yes |
| GET | `/repos/{owner}/{repo}/contents/*` | yes |
| GET | `/repos/{owner}/{repo}/git/*` | yes |
| GET | `/repos/{owner}/{repo}/commits/*` | yes |
| GET | `/repos/{owner}/{repo}/branches` | yes |
| GET | `/repos/{owner}/{repo}/branches/*` | yes |
| GET | `/repos/{owner}/{repo}/pulls` | yes |
| GET | `/repos/{owner}/{repo}/pulls/*` | yes |
| GET | `/repos/{owner}/{repo}/issues` | yes |
| GET | `/repos/{owner}/{repo}/issues/*` | yes |
| GET | `/repos/{owner}/{repo}/actions/runs/*` | yes |
| POST | `/repos/{owner}/{repo}/issues` | yes |
| POST | `/repos/{owner}/{repo}/issues/*/comments` | yes |
| POST | `/repos/{owner}/{repo}/pulls` | yes |
| POST | `/repos/{owner}/{repo}/pulls/*/comments` | yes |
| POST | `/repos/{owner}/{repo}/pulls/*/reviews` | yes |
| POST | `/repos/{owner}/{repo}/git/refs` | yes (for branch creation) |
| PATCH | `/repos/{owner}/{repo}/issues/*` | yes (close, edit) |
| PATCH | `/repos/{owner}/{repo}/pulls/*` | yes (close, edit) |
| PATCH | `/repos/{owner}/{repo}/git/refs/*` | yes |
| GET | `/search/repositories` | no (read-only search) |
| GET | `/search/issues` | no |
| GET | `/search/code` | no |
| GET | `/user` | yes — only for identity. Strip response down to `{login, id, type}` fields. |
| GET | `/rate_limit` | no |

**Explicit denylist** (these MUST be rejected even if a future change accidentally adds a matching pattern):

- Any `DELETE` method anywhere.
- Any path under `/user/keys`, `/user/gpg_keys`, `/user/ssh_signing_keys`, `/user/emails`, `/user/social_accounts`.
- Any path under `/admin/`, `/enterprises/`, `/orgs/*/admin/`.
- Any path under `/applications/`, `/authorizations/`, `/grants/`.
- Any path under `/user/migrations/`, `/repos/*/migrations/`.

**Repo allowlist enforcement.** Parse `{owner}/{repo}` out of the path. Match against `REPO_ALLOWLIST` patterns. `owner/*` matches any repo under `owner`. `owner/repo` matches exact. Reject non-matches with 403 and `deny_reason: "repo-not-in-allowlist"`.

**Header handling.**
- Strip `Authorization`, `X-GitHub-Token` from agent's request.
- Add `Authorization: token <GH_TOKEN>`.
- Add `Accept: application/vnd.github+json` if not present.
- Add `X-GitHub-Api-Version: 2022-11-28`.
- Pass through `If-None-Match`, `If-Modified-Since`.

**Body size cap:** 4 MiB. PR comments and issue bodies don't get bigger.

**No rate limit beyond what GitHub itself enforces.** GitHub's own 5000 req/hour limit on PATs is sufficient.

### 7.3 `gc-broker-github-ssh`

**Image:** `gascity-broker-github-ssh:v1`. Built from `containerized/brokers/github-ssh/Dockerfile`.

This broker is fundamentally different from the two HTTP brokers. It exposes an `ssh-agent` Unix socket to agent containers via a shared docker volume. Agents use it as their `SSH_AUTH_SOCK`; signing requests go to the broker; the broker's loaded key signs without ever exposing the key bytes.

**Mounts:**
- `~/.ssh/<configured-key>:/secrets/key:ro`
- `~/.ssh/<configured-key>.pub:/secrets/key.pub:ro` (optional, for verification logging)
- `~/.ssh/known_hosts:/secrets/known_hosts:ro`
- Volume `gc-sshagent-sock` mounted at `/run/sshagent/` (read-write for the broker; read-only for agents — see §8.4)

**Environment:**
- `KEY_PATH=/secrets/key`
- `KEY_PASSPHRASE_FILE=/secrets/passphrase` (optional; see below)
- `SOCK_PATH=/run/sshagent/gc.sock`
- `ALLOWED_HOST=github.com`
- `REPO_ALLOWLIST=knail1/*,homercsimpson50/*` (same syntax as §7.2)

**Configured key.** Default: `~/.ssh/id_ed25519`. Configurable via `[broker.github_ssh] key_file` in `config.toml`.

**Passphrase handling.** If the configured key is passphrase-protected, the broker needs the passphrase to load it into ssh-agent. Two supported modes:

1. **Unencrypted key (recommended for v2).** User generates a dedicated `~/.ssh/id_gc_agent` (no passphrase) used solely by the broker. Document this in `docs/work-machine.md` v2 section. The user adds the *public* part of this key to GitHub.
2. **Interactive prompt at supervisor start.** `gc-docker-start.sh` checks if the key is encrypted (parse the file header for `ENCRYPTED`), and if so, prompts the user for the passphrase. The passphrase is written to a tmpfs file `~/.local/state/gascity-docker-runner/sshagent-passphrase` (mode 0600), bind-mounted into the broker as `/secrets/passphrase:ro`, used once at startup, then unlinked from the host. The broker uses `ssh-add` with `SSH_ASKPASS` pointing at a script that cats the passphrase file.

**Startup sequence.**

```bash
# Inside the broker container:
mkdir -p /run/sshagent
chmod 0700 /run/sshagent
exec ssh-agent -a /run/sshagent/gc.sock -d &   # foreground for `docker logs`
SSH_AUTH_SOCK=/run/sshagent/gc.sock ssh-add /secrets/key
chmod 0660 /run/sshagent/gc.sock
chgrp 1000 /run/sshagent/gc.sock   # so agents (uid 1000) can use it
wait   # block on the agent process
```

**Repo allowlist enforcement.** This is the hard part. The vanilla ssh-agent has no concept of "what is being signed for what destination repo." Two approaches:

#### Option A (v2 default): policy-filtering ssh-agent wrapper

Replace the bare `ssh-agent` invocation with a small wrapper that listens on `gc.sock`, speaks the SSH agent protocol, and forwards each `SSH_AGENTC_SIGN_REQUEST` to a backend `ssh-agent` running on a private socket — but only after inspecting the *session context* attached to the signing request and confirming the SSH session is connecting to `github.com` for an allowlisted repo path.

Concretely: the SSH agent protocol's signing requests don't carry the destination host. **But** the agent's job is to sign challenges, and the SSH client connecting through the socket has already negotiated which host it's talking to. We can't inspect that from the agent socket.

Therefore Option A enforces a weaker but still useful invariant: **the broker is the only thing the agent can SSH to GitHub through, and the broker only loads keys for github.com.** The agent's `~/.ssh/config` (provisioned by the agent-runner image) specifies:

```
Host github.com
  IdentityAgent /run/sshagent/gc.sock
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile /run/sshagent/known_hosts
```

`/run/sshagent/known_hosts` is provided by the broker (writes the host's `~/.ssh/known_hosts` content there at startup).

For *any other host* the agent has no `IdentityAgent` configured, so SSH to a non-github host falls back to no agent and fails immediately. The repo allowlist for SSH is then enforced **at the network level**: the agent's docker network has no route to anywhere except brokers, and the SSH broker only allows outbound TCP to `github.com:22` (via its egress-net firewall, see §7.5).

Result: agents can SSH **only to github.com**, can't pull keys out of the agent, but **can** push to any repo their key has access to. This is a deliberate, documented gap in v2.

#### Option B (deferred): bare-clone middleware

The broker hosts a bare clone of every allowlisted repo at `/var/git/<owner>/<repo>.git`. Agents push to `git@gc-broker-github-ssh:<owner>/<repo>.git` (via the SSH socket). The broker validates the push (allowlist, branch protection rules, optional commit signing), then pushes to the real github.com using its own credentials.

This is the cleanest answer but requires implementing a git-receive-pack hook and managing N bare clones. **Spec it as v2.5 future work, not v2.**

#### Decision for v2: implement Option A.

Document the limitation in `docs/work-machine.md` so the user knows the SSH broker has *account-wide* GitHub scope, not repo-scoped. The HTTPS API broker compensates for this on the API side, where most repo-scoped operations actually happen (PR creation, issue updates, etc.).

**Egress restriction on the SSH broker.** The broker's `gc-egress-net` attachment must be limited to outbound `github.com:22`. Use `iptables` inside the broker container *or* a custom egress network with a CNI plugin. Simplest: install `iptables-nft` in the broker image, set rules in entrypoint:

```bash
iptables -P OUTPUT DROP
iptables -A OUTPUT -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -m string --string "github.com" --algo bm -j ACCEPT
# (string match is fragile; use DNS-resolution-pinned IPs at startup as fallback)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT   # for DNS resolution
```

Or simpler and probably fine: skip iptables, rely on the documented "the only thing this broker reaches is github.com:22" by virtue of its purpose, and accept that a compromised broker could reach other hosts. This is consistent with v2's "compromised broker is out of scope."

Implementer choice: pick one and document it in the broker README. The verify probe (§11.B5) tests that the broker can reach `github.com:22` and not, e.g., `8.8.8.8:80`.

### 7.4 Optional broker: future work

This spec does **not** include brokers for AWS, GCP, Slack, Linear, npm publish, or others. Those use the same pattern; add them as separate specs once the v2 trio is solid.

---

## 8. Shim changes (`containerized/shim/gc-docker-runner`)

Modify the v1 shim. Do not introduce a v2 shim — keep one entry point.

### 8.1 New env injection

The shim must inject these env vars into every agent container (additive to the existing `FORWARD_ENV`):

```bash
INJECT_ENV=(
    "ANTHROPIC_BASE_URL=http://gc-broker-anthropic:8080"
    "GITHUB_API_URL=http://gc-broker-github-api:8080"
    "SSH_AUTH_SOCK=/run/sshagent/gc.sock"
    "GIT_SSH_COMMAND=ssh -F /etc/ssh/ssh_config_gc"
)
```

Add as `-e KEY=VALUE` flags in `exec_docker()`.

### 8.2 Remove `ANTHROPIC_API_KEY` and `GH_TOKEN` from `FORWARD_ENV`

These are no longer forwarded. The brokers are the single source of those credentials. Leaving them in the whitelist would mean a host that has both `ANTHROPIC_API_KEY` set *and* the broker running would forward both, and the agent would prefer the env var (which is what claude-code does by default), bypassing the broker.

Concretely: delete `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, `CLAUDE_API_KEY`, `GH_TOKEN` from `FORWARD_ENV`.

If this breaks someone's workflow, the migration path (§12) covers it.

### 8.3 Network attachment

Replace:
```bash
--network "$NETWORK" \
```
with:
```bash
--network gc-broker-net \
```

`NETWORK` from the v1 config is still read but ignored if it's `bridge`. If it's something else, log a warning that v2 forces `gc-broker-net`. (We deliberately don't make this configurable; the entire isolation story depends on it.)

### 8.4 ssh-agent socket mount

Add to `exec_docker()`:
```bash
-v gc-sshagent-sock:/run/sshagent:ro \
```

This is a docker named volume, not a bind mount. The volume is created by `containerized/install.sh` (idempotent: `docker volume create gc-sshagent-sock`). The SSH broker mounts it `rw`, agents mount it `ro`. The socket file inside the volume has mode 0660 with group 1000, so agents (uid 1000, gid 1000) can connect as a client without needing write permission to the socket file's *directory*.

### 8.5 ssh_config injection into the agent runner image

The agent runner image (`containerized/agent-runner/Dockerfile`) needs an `/etc/ssh/ssh_config_gc` file shipped in:

```
# /etc/ssh/ssh_config_gc — used via GIT_SSH_COMMAND=ssh -F ...
Host github.com
  IdentityAgent /run/sshagent/gc.sock
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile /run/sshagent/known_hosts
```

Add `COPY ssh_config_gc /etc/ssh/ssh_config_gc` to the Dockerfile and write the file under `containerized/agent-runner/`.

### 8.6 Image rebuild

Adding `ssh_config_gc` to the runner image requires `./containerized/install.sh` to rebuild it. This is a non-issue — `install.sh` already does that on every run unless `--no-build` is passed.

---

## 9. Lifecycle: install / start / stop changes

### 9.1 `containerized/install.sh`

Add steps after the existing image-build step:

```bash
# Build broker images
for broker in anthropic github-api github-ssh; do
    say "Building gascity-broker-${broker}:v1"
    docker build -t "gascity-broker-${broker}:v1" "brokers/${broker}/"
done

# Create networks (idempotent)
docker network inspect gc-broker-net >/dev/null 2>&1 || \
    docker network create --internal --driver bridge gc-broker-net
docker network inspect gc-egress-net >/dev/null 2>&1 || \
    docker network create --driver bridge gc-egress-net

# Create the ssh-agent socket volume
docker volume inspect gc-sshagent-sock >/dev/null 2>&1 || \
    docker volume create gc-sshagent-sock
```

Default `~/.config/gascity-docker-runner/config.toml` gets new sections (only written if not already present):

```toml
[broker]
enabled = true

[broker.anthropic]
image = "gascity-broker-anthropic:v1"
credentials_file = "~/.claude/.credentials.json"
model_allowlist = []  # empty = allow all

[broker.github_api]
image = "gascity-broker-github-api:v1"
gh_token_env = "GH_TOKEN"  # name of the host env var to forward at broker start
repo_allowlist = ["knail1/*", "homercsimpson50/*"]

[broker.github_ssh]
image = "gascity-broker-github-ssh:v1"
key_file = "~/.ssh/id_ed25519"
known_hosts_file = "~/.ssh/known_hosts"
allowed_host = "github.com"
repo_allowlist = ["knail1/*", "homercsimpson50/*"]
```

### 9.2 `scripts/gascity-docker-start.sh`

Insert a new step *between* "stop existing supervisor" and "start shim-aware supervisor": **start the brokers**.

```bash
ensure_brokers() {
    # Anthropic
    if ! docker ps --format '{{.Names}}' | grep -qx gc-broker-anthropic; then
        docker run -d --rm --name gc-broker-anthropic \
            --network gc-broker-net \
            --user 1000:1000 --read-only \
            --tmpfs /tmp:size=64m \
            --cap-drop ALL --security-opt no-new-privileges \
            --pids-limit 64 --memory 256m \
            -v "$HOME/.claude/.credentials.json:/secrets/creds.json:ro" \
            gascity-broker-anthropic:v1
        docker network connect gc-egress-net gc-broker-anthropic
    fi
    # github-api
    if ! docker ps --format '{{.Names}}' | grep -qx gc-broker-github-api; then
        : "${GH_TOKEN:?GH_TOKEN must be set on the host shell to start the github-api broker}"
        docker run -d --rm --name gc-broker-github-api \
            --network gc-broker-net \
            --user 1000:1000 --read-only \
            --tmpfs /tmp:size=64m \
            --cap-drop ALL --security-opt no-new-privileges \
            --pids-limit 64 --memory 256m \
            -e GH_TOKEN="$GH_TOKEN" \
            gascity-broker-github-api:v1
        docker network connect gc-egress-net gc-broker-github-api
    fi
    # github-ssh
    if ! docker ps --format '{{.Names}}' | grep -qx gc-broker-github-ssh; then
        # Resolve key file from config.toml (default ~/.ssh/id_ed25519)
        local key_file=$(grep -E '^key_file' "$HOME/.config/gascity-docker-runner/config.toml" \
                          | head -1 | sed 's/.*= *"\(.*\)"/\1/' | sed "s|~|$HOME|")
        : "${key_file:?could not resolve key_file from config.toml}"
        [ -f "$key_file" ] || { echo "key file $key_file missing" >&2; return 1; }
        docker run -d --rm --name gc-broker-github-ssh \
            --network gc-broker-net \
            --user 0:0 --read-only \
            --tmpfs /tmp:size=64m --tmpfs /run/sshagent:size=4m,mode=0700 \
            --cap-drop ALL --cap-add CHOWN --security-opt no-new-privileges \
            --pids-limit 64 --memory 256m \
            -v "${key_file}:/secrets/key:ro" \
            -v "$HOME/.ssh/known_hosts:/secrets/known_hosts:ro" \
            -v gc-sshagent-sock:/run/sshagent \
            gascity-broker-github-ssh:v1
        docker network connect gc-egress-net gc-broker-github-ssh
    fi
    # Wait for /healthz
    for broker in gc-broker-anthropic gc-broker-github-api; do
        for _ in $(seq 1 30); do
            if docker exec "$broker" sh -c 'wget -qO- http://127.0.0.1:8080/healthz' \
                >/dev/null 2>&1; then
                echo "    ✓ $broker healthy"
                break
            fi
            sleep 1
        done
    done
    # SSH broker is healthy when its socket exists
    for _ in $(seq 1 30); do
        if docker exec gc-broker-github-ssh test -S /run/sshagent/gc.sock; then
            echo "    ✓ gc-broker-github-ssh healthy"
            break
        fi
        sleep 1
    done
}
```

The SSH broker temporarily needs `--user 0:0 --cap-add CHOWN` because it `chgrp`s the socket to gid 1000. Could drop privileges after socket creation; document if so. Note: `wget` is not in the broker images per §6.3 — replace the healthz check with `python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/healthz")'` or have the broker process touch a `/tmp/.healthy` file once ready and check via `docker exec ... test -f /tmp/.healthy`.

### 9.3 `scripts/gascity-docker-stop.sh`

After stopping the supervisor, also stop the brokers:

```bash
for broker in gc-broker-anthropic gc-broker-github-api gc-broker-github-ssh; do
    docker stop "$broker" 2>/dev/null || true
done
```

This goes near the existing stop logic. Brokers are `--rm` so stopping deletes them.

### 9.4 `containerized/uninstall.sh`

Add cleanup:

```bash
docker network rm gc-broker-net gc-egress-net 2>/dev/null || true
docker volume rm gc-sshagent-sock 2>/dev/null || true
docker image rm gascity-broker-anthropic:v1 gascity-broker-github-api:v1 \
                gascity-broker-github-ssh:v1 2>/dev/null || true
```

---

## 10. Configuration reference

### 10.1 `config.toml` schema additions

See §9.1 for default content. Field semantics:

- `broker.enabled` — master switch. If `false`, shim falls back to v1 behavior (no broker, agents have no auth). Default `true`. Useful for quick-debugging without brokers in the loop.
- `broker.anthropic.credentials_file` — path on host (tilde-expanded by start script). Must exist before brokers start.
- `broker.github_api.gh_token_env` — name of the env var on the host shell that the start script reads at broker startup. The token is passed as `-e GH_TOKEN=...` to the broker; not stored anywhere on disk.
- `broker.github_api.repo_allowlist` — list of `owner/repo` patterns. Each broker reads this at startup; updates require broker restart.
- `broker.github_ssh.key_file` — host path to private key. Read-only mount.
- `broker.github_ssh.known_hosts_file` — host path; usually `~/.ssh/known_hosts`. Read-only mount.

### 10.2 First-time setup checklist (for a user adopting v2)

This goes into `docs/work-machine.md` as a new section. Implementer adds it.

```
1. Generate a dedicated key (no passphrase) for the agent SSH broker:
       ssh-keygen -t ed25519 -f ~/.ssh/id_gc_agent -N ""
2. Add the public key to your GitHub account at https://github.com/settings/keys.
3. Verify: ssh -i ~/.ssh/id_gc_agent -T git@github.com
   Should print: "Hi knail1! You've successfully authenticated..."
4. Update ~/.config/gascity-docker-runner/config.toml:
       [broker.github_ssh]
       key_file = "~/.ssh/id_gc_agent"
5. Set GH_TOKEN in your shell:
       export GH_TOKEN=ghp_...
       (only the shell that runs gc-docker-start.sh needs it)
6. Edit repo_allowlist in config.toml to include the GitHub repos you want
   the agent to be able to push to / open PRs against.
7. gc-docker-start.sh
```

---

## 11. Verification probes (`containerized/verify.sh` additions)

The existing 7 probes must continue to pass. Add the following. Mark each with the same PASS/FAIL line format as v1.

### 11.A Anthropic broker probes

**A1. Broker is reachable from the agent network.**
```
docker run --rm --network gc-broker-net debian:stable-slim \
    sh -c 'apt-get update -qq && apt-get install -qqy curl >/dev/null && \
           curl -sf http://gc-broker-anthropic:8080/healthz'
```
Expect HTTP 200 with body `{"ok":true}`.

**A2. Broker is NOT reachable from the host.**
```
curl -sf --max-time 2 http://localhost:8080/ | grep -q anthropic && fail || pass
```
There must be no port published.

**A3. Path allowlist enforced.**
```
docker run --rm --network gc-broker-net curlimages/curl:latest \
    -sw '%{http_code}' -o /dev/null \
    http://gc-broker-anthropic:8080/v1/admin/secret
```
Expect 403.

**A4. Streaming works end-to-end.**
Compose a minimal `POST /v1/messages` with `"stream": true` and a tiny prompt. Read the response with a streaming client. Verify at least 2 SSE chunks arrive separated by >100 ms each (i.e., the broker is not buffering the full response). Skip if no `~/.claude/.credentials.json` is present (CI case).

**A5. Token never leaks into agent's view.**
```
docker exec gc-broker-anthropic sh -c 'env | grep -i bearer' | wc -l   # must be 0
docker logs gc-broker-anthropic 2>&1 | grep -E 'sk-ant-|Bearer ' | wc -l  # must be 0
```

### 11.B GitHub-SSH broker probes

**B1. Socket exists and is connectable from agent network.**
```
docker run --rm --network gc-broker-net \
    -v gc-sshagent-sock:/run/sshagent:ro \
    debian:stable-slim sh -c 'apt-get install -qqy openssh-client >/dev/null && \
                              SSH_AUTH_SOCK=/run/sshagent/gc.sock ssh-add -l' \
    | grep -q ED25519
```

**B2. Key cannot be extracted.**
```
docker run --rm --network gc-broker-net \
    -v gc-sshagent-sock:/run/sshagent:ro \
    debian:stable-slim sh -c 'cat /run/sshagent/key 2>&1' | grep -q "No such file"
```
Only the socket exists; the actual key file is in the broker container at `/secrets/key` and not in the volume.

**B3. Agent can SSH to github.com via the broker.**
```
docker run --rm --network gc-broker-net \
    -v gc-sshagent-sock:/run/sshagent:ro \
    gascity-agent-runner:claude bash -c \
    'GIT_SSH_COMMAND="ssh -F /etc/ssh/ssh_config_gc" \
     ssh -T git@github.com 2>&1' | grep -q "successfully authenticated"
```

**B4. Agent CANNOT reach api.anthropic.com directly (only via broker).**
```
docker run --rm --network gc-broker-net debian:stable-slim \
    sh -c 'apt-get install -qqy curl >/dev/null && \
           curl -sf --max-time 5 https://api.anthropic.com/v1/models'
```
Expect non-zero exit (DNS or connect refused). The agent network has no internet egress.

### 11.C GitHub-API broker probes

**C1. Allowed path returns 200.** `GET /repos/<allowlisted-repo>` returns the repo metadata.

**C2. Denied method returns 403.** `DELETE /repos/<allowlisted-repo>` returns 403 with `deny_reason: "method-not-allowed"`.

**C3. Denied path returns 403.** `GET /user/keys` returns 403.

**C4. Repo allowlist enforced.** `GET /repos/strangers/private-repo` returns 403 with `deny_reason: "repo-not-in-allowlist"`.

**C5. Token never logged.** `docker logs gc-broker-github-api 2>&1 | grep -E 'ghp_[A-Za-z0-9]{36}|token [A-Za-z0-9]{40,}' | wc -l` must be 0.

### 11.D Integration

**D1. End-to-end claude call from agent.**
```
docker run --rm --network gc-broker-net \
    -v gc-sshagent-sock:/run/sshagent:ro \
    -e ANTHROPIC_BASE_URL=http://gc-broker-anthropic:8080 \
    gascity-agent-runner:claude \
    claude -p "say 'broker test' and nothing else" --model claude-sonnet-4-6
```
Expect output containing "broker test". Skip if no creds.json present.

---

## 12. Migration from v1

A user upgrading from v1 to v2 runs `./upgrade.sh`. The upgrade must be backward-compatible at the level of "v1 cities continue to work" but introduces new requirements:

- The shim no longer forwards `ANTHROPIC_API_KEY`. If the user was relying on that, agents will fail with 401. Document this clearly in `docs/work-machine.md`.
- The shim no longer forwards `GH_TOKEN`. The token is now consumed by the github-api broker at start time.
- A user who has not generated an SSH agent key and added it to GitHub will see SSH auth failures from agents. Document the §10.2 first-time-setup steps in the upgrade notes.
- `broker.enabled = false` in `config.toml` keeps v1 behavior. Useful as an escape hatch for users who don't want to set up the brokers immediately.

`upgrade.sh` does not auto-flip `broker.enabled` to `true` for existing installs. Instead, it prints a one-time "v2 brokers available; see docs/credential-broker-v2-spec.md §10.2 to enable" message.

---

## 13. Open questions / future work

These are explicitly out of scope for v2 but should be considered when the trio is deployed and stable.

1. **OAuth refresh inside the broker.** Today the host's claude-code CLI is the only thing refreshing the OAuth token. If the user doesn't run claude on the host for weeks, the token expires. The broker could detect a 401 from upstream, surface a clear error to the agent ("host claude session needs to be refreshed"), and log to the host so the user notices.
2. **GitHub fine-grained PAT minting.** Spec §5 of the v1 doc mentions GitHub App tokens. A GitHub App owned by the user could mint short-lived per-session tokens scoped to one repo. Replaces both the broad `GH_TOKEN` and the SSH key for v3.
3. **Bare-clone middleware for SSH push.** Option B from §7.3. The cleanest path to true repo allowlisting for `git push`. Implement when account-wide SSH scope becomes a real problem.
4. **mTLS between agents and brokers.** Today the agent → broker traffic is plain HTTP on a private docker network. Adding mTLS doesn't change the threat model (the network is already private) but would defend against `gc-broker-net` accidentally being reconfigured non-internal. Low value, modest cost.
5. **Per-bead audit join.** The broker logs include `src_container`. The supervisor knows `(container_name → bead_id, agent_role, session_id)`. Joining these gives "what did agent X working on bead Y do externally?" — useful for postmortems.
6. **Cost cap.** Trivial to add to the Anthropic broker if/when the user wants it. Token counts are already in the log lines.
7. **Image digest pinning.** Separate change. Pin all four images (agent runner + 3 brokers) by sha256 in `config.toml`.

---

## 14. Implementation phasing

A fresh agent picking this up should land changes in this order. Each phase should be a separate commit; each phase has its own acceptance criteria.

### Phase 1: Anthropic broker (smallest blast radius)

**Deliverables:**
- `containerized/brokers/anthropic/Dockerfile`
- `containerized/brokers/anthropic/proxy.py` (or whatever language you chose)
- `containerized/brokers/anthropic/README.md`
- Modify `containerized/install.sh` to build broker image, create `gc-broker-net`, `gc-egress-net`.
- Modify `scripts/gascity-docker-start.sh` to start the broker.
- Modify `scripts/gascity-docker-stop.sh` to stop it.
- Modify `containerized/shim/gc-docker-runner` to inject `ANTHROPIC_BASE_URL` and use `gc-broker-net`. Remove `ANTHROPIC_API_KEY` from forwarded env.
- Add probes A1–A5 to `verify.sh`.

**Acceptance:**
- `./bootstrap.sh` on a fresh machine completes with the broker built and running.
- All 7 v1 probes still pass.
- All 5 A-probes pass.
- `gc-docker supervisor run` brings the supervisor up; spawning a polecat agent and pasting "say hi" results in a Claude response. Verify in the broker logs that the request was forwarded.
- `docker logs gc-broker-anthropic` contains zero matches for `Bearer ` or `sk-ant-`.

### Phase 2: GitHub-API broker

**Deliverables:**
- `containerized/brokers/github-api/Dockerfile`
- `containerized/brokers/github-api/proxy.py`
- `containerized/brokers/github-api/README.md`
- Update `install.sh`, `gascity-docker-start.sh`, `gascity-docker-stop.sh`.
- Update shim: inject `GITHUB_API_URL`, remove `GH_TOKEN` from forwarded env.
- Add probes C1–C5 to `verify.sh`.

**Acceptance:**
- Agent in container can list issues for an allowlisted repo via `gh issue list` (set `gh` to use `GITHUB_API_URL` — `gh` reads `GH_HOST` and `GITHUB_API_URL`; verify with `gh api repos/owner/repo`).
- Agent cannot delete a repo, list user keys, or hit a non-allowlisted repo.
- All v1 + A-probes still pass.

### Phase 3: GitHub-SSH broker

**Deliverables:**
- `containerized/brokers/github-ssh/Dockerfile`
- `containerized/brokers/github-ssh/entrypoint.sh`
- `containerized/brokers/github-ssh/README.md`
- Modify `containerized/agent-runner/Dockerfile` to ship `ssh_config_gc`.
- `containerized/agent-runner/ssh_config_gc` (the file).
- Update `install.sh`: create `gc-sshagent-sock` volume.
- Update `gascity-docker-start.sh`: start the SSH broker, mount the volume.
- Update shim: mount `gc-sshagent-sock` ro, inject `SSH_AUTH_SOCK`, `GIT_SSH_COMMAND`.
- Add probes B1–B4 + D1 to `verify.sh`.
- Add §10.2 first-time-setup section to `docs/work-machine.md`.

**Acceptance:**
- `ssh -T git@github.com` from inside an agent container authenticates as the user.
- The agent has no `~/.ssh/`, no env vars containing the key, no key file accessible.
- `git clone git@github.com:<allowlisted>/repo.git /work/test && cd /work/test && touch x && git add . && git commit -m test && git push origin HEAD:test-branch` works from inside an agent.
- All previous probes still pass.

### Phase 4: docs + migration

**Deliverables:**
- Update `docs/work-machine.md`:
  - "What you'll have when this finishes" gains brokers.
  - New "Auth setup" section with the §10.2 checklist.
  - "What you get and don't" table updated for v2.
- Update `CLAUDE.md` to reference this spec under "Source-of-truth files".
- Update `containerized/README.md` to list the broker subdirs.

**Acceptance:**
- `docs/work-machine.md` end-to-end is followable on a fresh laptop.
- `./upgrade.sh` on an existing v1 install prints the migration notice (§12).

---

## 15. Appendix: skeleton implementations

These are illustrative. Implementer should write production-quality code, but the shape below is the contract.

### 15.1 `containerized/brokers/anthropic/proxy.py`

```python
# Minimal aiohttp reverse proxy. ~120 LOC complete; sketch follows.
import json
import logging
import os
import sys
import time
from pathlib import Path

import aiohttp
from aiohttp import web

UPSTREAM = os.environ["ANTHROPIC_UPSTREAM"]
LISTEN  = os.environ.get("LISTEN_ADDR", "0.0.0.0:8080")
CREDS   = Path("/secrets/creds.json")
ALLOWED_PATHS = {
    ("POST", "/v1/messages"),
    ("POST", "/v1/messages/count_tokens"),
    ("POST", "/v1/messages/batches"),
    ("GET",  "/v1/models"),
}
ALLOWED_PREFIXES = [
    ("GET",  "/v1/messages/batches/"),
    ("GET",  "/v1/models/"),
]

def load_token():
    data = json.loads(CREDS.read_text())
    return data["claudeAiOauth"]["accessToken"]

def is_allowed(method, path):
    if (method, path) in ALLOWED_PATHS:
        return True
    return any(method == m and path.startswith(p) for m, p in ALLOWED_PREFIXES)

async def healthz(request):
    return web.json_response({"ok": True})

async def proxy(request):
    method, path = request.method, request.path
    src = request.remote
    log = {"ts": time.time(), "broker": "anthropic", "src_ip": src,
           "method": method, "path": path}

    if not is_allowed(method, path):
        log["status"] = 403; log["decision"] = "deny"
        log["deny_reason"] = "path-not-in-allowlist"
        print(json.dumps(log)); sys.stdout.flush()
        return web.json_response(
            {"error": {"type": "broker_denied", "message": "path not allowlisted"}},
            status=403)

    body = await request.read()
    if len(body) > 16 * 1024 * 1024:
        log["status"] = 413; log["decision"] = "deny"
        log["deny_reason"] = "body-too-large"
        print(json.dumps(log)); sys.stdout.flush()
        return web.Response(status=413)

    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in {"authorization", "x-api-key", "host",
                                    "content-length"}}
    headers["Authorization"] = f"Bearer {load_token()}"
    headers.setdefault("anthropic-version", "2023-06-01")
    headers["User-Agent"] = (f"gc-broker-anthropic/1.0 "
                             f"{request.headers.get('User-Agent','')}").strip()

    t0 = time.time()
    async with aiohttp.ClientSession() as session:
        async with session.request(method, f"{UPSTREAM}{path}",
                                   data=body, headers=headers,
                                   params=request.query) as upstream:
            resp = web.StreamResponse(
                status=upstream.status,
                headers={k: v for k, v in upstream.headers.items()
                         if k.lower() not in {"set-cookie", "transfer-encoding",
                                              "content-length"}})
            await resp.prepare(request)
            async for chunk in upstream.content.iter_any():
                await resp.write(chunk)
            await resp.write_eof()

    log["status"] = upstream.status
    log["duration_ms"] = int((time.time() - t0) * 1000)
    log["decision"] = "allow"
    print(json.dumps(log)); sys.stdout.flush()
    return resp

def main():
    app = web.Application(client_max_size=16 * 1024 * 1024)
    app.router.add_get("/healthz", healthz)
    app.router.add_route("*", "/{tail:.*}", proxy)
    host, port = LISTEN.split(":")
    web.run_app(app, host=host, port=int(port), print=None,
                access_log=None)

if __name__ == "__main__":
    main()
```

### 15.2 `containerized/brokers/github-ssh/entrypoint.sh`

```sh
#!/bin/sh
set -eu

KEY=${KEY_PATH:-/secrets/key}
SOCK=${SOCK_PATH:-/run/sshagent/gc.sock}
KH_SRC=/secrets/known_hosts
KH_DST=/run/sshagent/known_hosts

[ -f "$KEY"    ] || { echo "no key at $KEY" >&2; exit 1; }
[ -f "$KH_SRC" ] || { echo "no known_hosts at $KH_SRC" >&2; exit 1; }

mkdir -p /run/sshagent
cp "$KH_SRC" "$KH_DST"
chmod 0644 "$KH_DST"

# Start agent on a fixed socket path. -d = foreground.
ssh-agent -a "$SOCK" -d &
PID=$!

# Wait for socket to appear
for _ in $(seq 1 30); do
    [ -S "$SOCK" ] && break
    sleep 0.1
done

# Load the key. If passphrase-protected and a passphrase file is mounted,
# use SSH_ASKPASS.
if [ -f /secrets/passphrase ]; then
    SSH_ASKPASS_HELPER=$(mktemp)
    printf '#!/bin/sh\ncat /secrets/passphrase\n' > "$SSH_ASKPASS_HELPER"
    chmod +x "$SSH_ASKPASS_HELPER"
    DISPLAY=:0 SSH_ASKPASS="$SSH_ASKPASS_HELPER" SSH_ASKPASS_REQUIRE=force \
        SSH_AUTH_SOCK="$SOCK" ssh-add "$KEY" </dev/null
else
    SSH_AUTH_SOCK="$SOCK" ssh-add "$KEY"
fi

# Make socket connectable by uid 1000 (the agent user)
chgrp 1000 "$SOCK"
chmod 0660 "$SOCK"

# Drop CHOWN cap by re-execing as a non-root user that already has it open.
# (Simpler alternative: just stay root inside the broker — its rootfs is
# read-only and it has no other capabilities. Document the choice.)

# Indicate ready
touch /tmp/.healthy

wait $PID
```

### 15.3 `containerized/brokers/anthropic/Dockerfile`

```dockerfile
FROM python:3.12-slim

RUN pip install --no-cache-dir aiohttp==3.9.* && \
    apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY proxy.py /app/proxy.py
WORKDIR /app
USER 1000:1000
CMD ["python3", "proxy.py"]
```

---

## 16. Definition of done

v2 is shipped when:

1. `bootstrap.sh` on a clean macOS install ends with all three brokers built and ready.
2. `gc-docker-start.sh` brings supervisor + brokers up cleanly; `gc-docker-stop.sh` brings them all down.
3. `verify.sh` passes the original 7 v1 probes plus all v2 probes (A1–A5, B1–B4, C1–C5, D1).
4. From inside a polecat agent: `claude -p "hello"` succeeds, `gh issue list -R <allowlisted>` succeeds, `git clone git@github.com:<allowlisted>/x.git && touch /work/x/y && git -C /work/x add . && git -C /work/x commit -m wip && git -C /work/x push -u origin test-v2` succeeds.
5. From inside a polecat agent: `gh issue list -R strangers/private` returns a 403, `git clone git@github.com:strangers/private.git` fails or is denied, `claude --api-key fake -p "x"` cannot reach Anthropic by any means.
6. `docker logs` for each broker contains zero credential leakage as measured by §11 probes.
7. `docs/work-machine.md` is updated with the v2 setup flow and migration notes.
8. `CLAUDE.md` is updated to list this spec as a source-of-truth file.
