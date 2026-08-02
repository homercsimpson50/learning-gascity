#!/usr/bin/env python3
"""gc-broker-anthropic — reverse proxy for api.anthropic.com.

Reads the OAuth bearer token from /secrets/creds.json on every request
(handles host-side rotation). Path-allowlists the API surface, streams
SSE responses without buffering, never logs the token.

Spec: docs/credential-broker-v2-spec.md §7.1.
"""
import json
import os
import sys
import time
from pathlib import Path

import aiohttp
from aiohttp import web

UPSTREAM = os.environ.get("ANTHROPIC_UPSTREAM", "https://api.anthropic.com")
LISTEN = os.environ.get("LISTEN_ADDR", "0.0.0.0:8080")
CREDS_PATH = Path(os.environ.get("CREDS_PATH", "/secrets/creds.json"))
MODEL_ALLOWLIST = [m.strip() for m in os.environ.get("MODEL_ALLOWLIST", "").split(",") if m.strip()]
MAX_BODY = 16 * 1024 * 1024
MAX_TOKENS_CAP = 200000

ALLOWED_EXACT = {
    ("POST", "/v1/messages"),
    ("POST", "/v1/messages/count_tokens"),
    ("POST", "/v1/messages/batches"),
    ("GET", "/v1/models"),
    # Claude Code startup connectivity ping — hits this before anything
    # else and treats a non-2xx as "cannot reach Anthropic services",
    # which aborts the whole boot. Not in the v2 spec; added after
    # observing crash-loops on real polecats spawns (v2.1.220).
    ("HEAD", "/api/hello"),
    ("GET",  "/api/hello"),
}
ALLOWED_PREFIXES = (
    ("GET", "/v1/messages/batches/"),
    ("GET", "/v1/models/"),
)

STRIP_REQ_HEADERS = {"authorization", "x-api-key", "host", "content-length"}
STRIP_RESP_HEADERS = {"set-cookie", "transfer-encoding", "content-length", "connection"}


def _now():
    t = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + f".{int((t % 1) * 1000):03d}Z"


def _emit(record):
    print(json.dumps(record), flush=True)


def load_token():
    """Re-read on every request so host-side OAuth refresh is picked up."""
    data = json.loads(CREDS_PATH.read_text())
    oauth = data.get("claudeAiOauth") or {}
    token = oauth.get("accessToken")
    if not token:
        raise RuntimeError("creds.json missing claudeAiOauth.accessToken")
    return token, oauth.get("expiresAt")


def is_allowed(method, path):
    if (method, path) in ALLOWED_EXACT:
        return True
    return any(method == m and path.startswith(p) for m, p in ALLOWED_PREFIXES)


async def healthz(request):
    return web.json_response({"ok": True})


async def proxy(request):
    method = request.method
    path = request.path
    started = time.time()
    log = {
        "ts": _now(),
        "broker": "anthropic",
        "src_ip": request.remote,
        "method": method,
        "path": path,
    }

    if not is_allowed(method, path):
        log["status"] = 403
        log["decision"] = "deny"
        log["deny_reason"] = "path-not-in-allowlist"
        _emit(log)
        return web.json_response(
            {"error": {"type": "broker_denied", "message": "path not in allowlist"}},
            status=403,
        )

    body = await request.read()
    if len(body) > MAX_BODY:
        log["status"] = 413
        log["decision"] = "deny"
        log["deny_reason"] = "body-too-large"
        _emit(log)
        return web.json_response(
            {"error": {"type": "broker_denied", "message": "request body exceeds 16 MiB"}},
            status=413,
        )

    if body and path in ("/v1/messages", "/v1/messages/batches"):
        try:
            parsed = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            parsed = None
        if isinstance(parsed, dict):
            mt = parsed.get("max_tokens")
            if isinstance(mt, int) and mt > MAX_TOKENS_CAP:
                log["status"] = 400
                log["decision"] = "deny"
                log["deny_reason"] = "max_tokens-too-large"
                _emit(log)
                return web.json_response(
                    {"error": {"type": "broker_denied",
                               "message": f"max_tokens > {MAX_TOKENS_CAP}"}},
                    status=400,
                )
            model = parsed.get("model")
            if isinstance(model, str):
                log["model"] = model
                if MODEL_ALLOWLIST and model not in MODEL_ALLOWLIST:
                    log["status"] = 403
                    log["decision"] = "deny"
                    log["deny_reason"] = "model-not-in-allowlist"
                    _emit(log)
                    return web.json_response(
                        {"error": {"type": "broker_denied",
                                   "message": "model not in broker allowlist"}},
                        status=403,
                    )

    try:
        token, _expires = load_token()
    except Exception:
        log["status"] = 500
        log["decision"] = "deny"
        log["deny_reason"] = "creds-unreadable"
        _emit(log)
        return web.json_response(
            {"error": {"type": "broker_internal",
                       "message": "broker cannot read host credentials"}},
            status=500,
        )

    headers = {}
    for k, v in request.headers.items():
        if k.lower() in STRIP_REQ_HEADERS:
            continue
        headers[k] = v
    headers["Authorization"] = f"Bearer {token}"
    headers.setdefault("anthropic-version", "2023-06-01")
    headers["User-Agent"] = (
        f"gc-broker-anthropic/1.0 {request.headers.get('User-Agent', '')}".strip()
    )

    timeout = aiohttp.ClientTimeout(total=None, sock_connect=10, sock_read=None)
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
                resp = web.StreamResponse(status=upstream.status, headers=resp_headers)
                await resp.prepare(request)
                async for chunk in upstream.content.iter_any():
                    await resp.write(chunk)
                await resp.write_eof()
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

    log["duration_ms"] = int((time.time() - started) * 1000)
    log["decision"] = "allow"
    _emit(log)
    return resp


async def _on_startup(app):
    Path("/tmp/.healthy").touch()


def main():
    try:
        load_token()
    except FileNotFoundError:
        sys.stderr.write(f"FATAL creds file missing at {CREDS_PATH}\n")
        sys.exit(1)
    except Exception as e:
        sys.stderr.write(f"FATAL creds file unparseable: {e}\n")
        sys.exit(1)

    app = web.Application(client_max_size=MAX_BODY)
    app.router.add_get("/healthz", healthz)
    app.router.add_route("*", "/{tail:.*}", proxy)
    app.on_startup.append(_on_startup)

    host, port = LISTEN.split(":")
    web.run_app(app, host=host, port=int(port), print=None, access_log=None)


if __name__ == "__main__":
    main()
