#!/usr/bin/env python3
"""gc-broker-github-api — reverse proxy for api.github.com.

Holds GH_TOKEN (read once at startup), forwards agent requests against a
method+path+repo allowlist, hard-denies dangerous endpoints, never logs
the token.

Spec: docs/credential-broker-v2-spec.md §7.2.
"""
import json
import os
import re
import sys
import time
from pathlib import Path

import aiohttp
from aiohttp import web

UPSTREAM = os.environ.get("GITHUB_UPSTREAM", "https://api.github.com")
LISTEN = os.environ.get("LISTEN_ADDR", "0.0.0.0:8080")
GH_TOKEN = os.environ.get("GH_TOKEN", "").strip()
REPO_ALLOWLIST = [
    r.strip() for r in os.environ.get("REPO_ALLOWLIST", "").split(",") if r.strip()
]
MAX_BODY = 4 * 1024 * 1024

# (method, regex, repo_scoped). regex captures owner/repo when scoped.
ALLOW_RULES = [
    ("GET",   r"^/repos/([^/]+)/([^/]+)/?$",                              True),
    ("GET",   r"^/repos/([^/]+)/([^/]+)/contents(/.*)?$",                 True),
    ("GET",   r"^/repos/([^/]+)/([^/]+)/git(/.*)?$",                      True),
    ("GET",   r"^/repos/([^/]+)/([^/]+)/commits(/.*)?$",                  True),
    ("GET",   r"^/repos/([^/]+)/([^/]+)/branches(/.*)?$",                 True),
    ("GET",   r"^/repos/([^/]+)/([^/]+)/pulls(/.*)?$",                    True),
    ("GET",   r"^/repos/([^/]+)/([^/]+)/issues(/.*)?$",                   True),
    ("GET",   r"^/repos/([^/]+)/([^/]+)/actions/runs(/.*)?$",             True),
    ("POST",  r"^/repos/([^/]+)/([^/]+)/issues/?$",                       True),
    ("POST",  r"^/repos/([^/]+)/([^/]+)/issues/[^/]+/comments/?$",        True),
    ("POST",  r"^/repos/([^/]+)/([^/]+)/pulls/?$",                        True),
    ("POST",  r"^/repos/([^/]+)/([^/]+)/pulls/[^/]+/comments/?$",         True),
    ("POST",  r"^/repos/([^/]+)/([^/]+)/pulls/[^/]+/reviews/?$",          True),
    ("POST",  r"^/repos/([^/]+)/([^/]+)/git/refs/?$",                     True),
    ("PATCH", r"^/repos/([^/]+)/([^/]+)/issues/[^/]+/?$",                 True),
    ("PATCH", r"^/repos/([^/]+)/([^/]+)/pulls/[^/]+/?$",                  True),
    ("PATCH", r"^/repos/([^/]+)/([^/]+)/git/refs/.*$",                    True),
    ("GET",   r"^/search/repositories$",                                  False),
    ("GET",   r"^/search/issues$",                                        False),
    ("GET",   r"^/search/code$",                                          False),
    ("GET",   r"^/user/?$",                                               False),
    ("GET",   r"^/rate_limit/?$",                                         False),
]

# Hard denylist — wins even if a future allow rule accidentally matches.
DENY_PREFIXES = (
    "/user/keys",
    "/user/gpg_keys",
    "/user/ssh_signing_keys",
    "/user/emails",
    "/user/social_accounts",
    "/user/migrations",
    "/admin/",
    "/enterprises/",
    "/applications/",
    "/authorizations/",
    "/grants/",
)
DENY_REGEXES = (
    re.compile(r"^/orgs/[^/]+/admin/"),
    re.compile(r"^/repos/[^/]+/[^/]+/migrations(/|$)"),
)

STRIP_REQ_HEADERS = {"authorization", "x-github-token", "host", "content-length"}
STRIP_RESP_HEADERS = {"set-cookie", "transfer-encoding", "content-length", "connection"}


def _now():
    t = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + f".{int((t % 1) * 1000):03d}Z"


def _emit(record):
    print(json.dumps(record), flush=True)


def repo_allowed(owner, repo):
    if not REPO_ALLOWLIST:
        return False
    for pat in REPO_ALLOWLIST:
        if "/" not in pat:
            continue
        po, pr = pat.split("/", 1)
        if po != owner:
            continue
        if pr == "*" or pr == repo:
            return True
    return False


def classify(method, path):
    """Return (decision, reason, repo_or_none)."""
    if method == "DELETE":
        return "deny", "method-not-allowed", None
    for prefix in DENY_PREFIXES:
        if path.startswith(prefix):
            return "deny", "denylisted-path", None
    for rx in DENY_REGEXES:
        if rx.match(path):
            return "deny", "denylisted-path", None
    for rmethod, rpat, scoped in ALLOW_RULES:
        if rmethod != method:
            continue
        m = re.match(rpat, path)
        if not m:
            continue
        if scoped:
            owner, repo = m.group(1), m.group(2)
            if not repo_allowed(owner, repo):
                return "deny", "repo-not-in-allowlist", (owner, repo)
            return "allow", None, (owner, repo)
        return "allow", None, None
    return "deny", "path-not-in-allowlist", None


async def healthz(request):
    return web.json_response({"ok": True})


async def proxy(request):
    method = request.method
    path = request.path
    started = time.time()
    decision, reason, repo = classify(method, path)
    log = {
        "ts": _now(),
        "broker": "github-api",
        "src_ip": request.remote,
        "method": method,
        "path": path,
    }
    if repo:
        log["repo"] = "/".join(repo)

    if decision == "deny":
        log["status"] = 403
        log["decision"] = "deny"
        log["deny_reason"] = reason
        _emit(log)
        return web.json_response(
            {"error": {"type": "broker_denied",
                       "deny_reason": reason,
                       "method": method, "path": path}},
            status=403,
        )

    body = await request.read()
    if len(body) > MAX_BODY:
        log["status"] = 413
        log["decision"] = "deny"
        log["deny_reason"] = "body-too-large"
        _emit(log)
        return web.json_response(
            {"error": {"type": "broker_denied", "message": "body exceeds 4 MiB"}},
            status=413,
        )

    headers = {}
    for k, v in request.headers.items():
        if k.lower() in STRIP_REQ_HEADERS:
            continue
        headers[k] = v
    headers["Authorization"] = f"token {GH_TOKEN}"
    headers.setdefault("Accept", "application/vnd.github+json")
    headers["X-GitHub-Api-Version"] = "2022-11-28"
    headers["User-Agent"] = (
        f"gc-broker-github-api/1.0 {request.headers.get('User-Agent', '')}".strip()
    )

    timeout = aiohttp.ClientTimeout(total=120, sock_connect=10)
    try:
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.request(
                method, f"{UPSTREAM}{path}",
                data=body if body else None,
                headers=headers,
                params=request.rel_url.query,
            ) as upstream:
                resp_headers = {
                    k: v for k, v in upstream.headers.items()
                    if k.lower() not in STRIP_RESP_HEADERS
                }
                content = await upstream.read()
                log["status"] = upstream.status
    except aiohttp.ClientError as e:
        log["status"] = 502
        log["decision"] = "deny"
        log["deny_reason"] = f"upstream-error:{type(e).__name__}"
        _emit(log)
        return web.json_response(
            {"error": {"type": "broker_internal", "message": "upstream unreachable"}},
            status=502,
        )

    # Per spec §7.2: trim /user response to identity-only fields.
    if path.rstrip("/") == "/user" and method == "GET" and log["status"] == 200:
        try:
            full = json.loads(content)
            content = json.dumps(
                {k: full[k] for k in ("login", "id", "type") if k in full}
            ).encode()
            resp_headers["Content-Type"] = "application/json"
        except (json.JSONDecodeError, KeyError):
            pass

    log["duration_ms"] = int((time.time() - started) * 1000)
    log["decision"] = "allow"
    _emit(log)
    return web.Response(status=log["status"], headers=resp_headers, body=content)


async def _on_startup(app):
    Path("/tmp/.healthy").touch()


def main():
    if not GH_TOKEN:
        sys.stderr.write("FATAL GH_TOKEN env var is empty or unset\n")
        sys.exit(1)
    app = web.Application(client_max_size=MAX_BODY)
    app.router.add_get("/healthz", healthz)
    app.router.add_route("*", "/{tail:.*}", proxy)
    app.on_startup.append(_on_startup)
    host, port = LISTEN.split(":")
    web.run_app(app, host=host, port=int(port), print=None, access_log=None)


if __name__ == "__main__":
    main()
