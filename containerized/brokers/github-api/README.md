# gc-broker-github-api

Reverse proxy that injects `GH_TOKEN` into agent requests bound for
`api.github.com`. Agents reach it via
`GITHUB_API_URL=http://gc-broker-github-api:8080`.

Spec: [`docs/credential-broker-v2-spec.md §7.2`](../../../docs/credential-broker-v2-spec.md).

## Token source

Read **once** at startup from the `GH_TOKEN` env var passed in on
`docker run`. Unlike Anthropic's OAuth, GitHub PATs don't auto-refresh,
so there's no on-disk source to re-read. If you rotate the PAT, restart
the broker.

## Allowlist surface

GET reads on most repo subresources (contents, git, commits, branches,
pulls, issues, actions/runs, plus the repo root). Writes restricted to
issue/PR/comment/review creation and ref creation. PATCH for
issue/PR/ref edits. Searches and `/user`, `/rate_limit` are open
(non-repo-scoped).

Repo-scoped paths are matched against `REPO_ALLOWLIST`
(comma-separated patterns from env). `owner/*` allows any repo under
`owner`; `owner/repo` matches exact. **Empty allowlist denies all
repo-scoped requests** — set this in `config.toml` before any agent
will succeed.

## Hard denylist

`DELETE` of anything; `/user/keys`, `/user/gpg_keys`,
`/user/ssh_signing_keys`, `/user/emails`, `/user/social_accounts`,
`/user/migrations`, `/admin/`, `/enterprises/`, `/applications/`,
`/authorizations/`, `/grants/`, `/orgs/*/admin/`, repo migrations.
These are blocked even if a future allow rule accidentally matches.

## /user trimming

`GET /user` responses are trimmed server-side to `{login, id, type}`.
That's enough for the agent to know who it is (e.g., for `gh auth
status` parity) without leaking your name, email, billing plan, or
plan-purchase history.

## Defense-in-depth checks

- 4 MiB body cap (PR comments and issue bodies don't get larger).
- `X-GitHub-Api-Version: 2022-11-28` injected.
- `Authorization` and `X-GitHub-Token` from agent are stripped.

GitHub's own 5000 req/hour PAT limit is sufficient; broker adds no rate
limit.

## What gh and git see

- `gh`: set `GH_HOST=gc-broker-github-api:8080` won't work (gh expects
  scheme-less hostnames for Enterprise). Set `GITHUB_API_URL` instead;
  recent `gh` honors it. The shim injects this env var into the agent.
- Plain `git push origin main` over HTTPS will hit `github.com`
  directly (which the agent network has no route to). Agents must use
  the SSH path via `gc-broker-github-ssh`.
