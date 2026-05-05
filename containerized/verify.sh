#!/usr/bin/env bash
# verify.sh — runs the seven validation probes from
# docs/containerizing-gascity-for-local-use-spec.md §8.
#
# Usage:
#   ./verify.sh
#
# Each probe prints PASS or FAIL (non-zero exit on any FAIL).

set -uo pipefail

IMAGE="${IMAGE:-gascity-agent-runner:claude}"
SCRATCH="$(mktemp -d -t gascity-verify-XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0
FAIL=0
report() {
    if [ "$1" = pass ]; then
        echo "  PASS  $2"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $2"
        echo "        $3"
        FAIL=$((FAIL + 1))
    fi
}

# ---------------------------------------------------------------------------
# Setup: a throwaway "rig" worktree the probes write into.
# ---------------------------------------------------------------------------
RIG="$SCRATCH/rig"
mkdir -p "$RIG"
echo "verify rig" > "$RIG/seed.txt"

# Helper that runs a command inside the agent container with a sane scoped
# mount, mirroring what the shim would do.
run_in_container() {
    docker run --rm \
        --user 1000:1000 \
        --read-only \
        --tmpfs /tmp:size=64m,mode=1777 \
        --tmpfs /home/agent/.cache:size=64m \
        -v "$RIG:/work:rw" \
        --network bridge \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --entrypoint /bin/bash \
        "$IMAGE" -c "$1" 2>&1
}

echo "→ verifying $IMAGE"

# ---------------------------------------------------------------------------
# Probe 1: smoke — agent container starts and writes to the rig worktree.
# ---------------------------------------------------------------------------
out="$(run_in_container 'echo hello > /work/probe1.txt && echo OK')"
if [ "$(cat "$RIG/probe1.txt" 2>/dev/null)" = "hello" ] && echo "$out" | grep -q OK; then
    report pass "1. smoke: container writes file into rig worktree"
else
    report fail "1. smoke" "$out"
fi

# ---------------------------------------------------------------------------
# Probe 2: footgun — `rm -rf $HOME` cannot affect host $HOME.
# We simulate the dangerous prompt by trying to wipe /work parent (which
# does not exist in the container's view) and verifying the host $HOME is
# untouched. We also confirm /home/agent contents are tmpfs (ephemeral).
# ---------------------------------------------------------------------------
# Pick whichever sentinel exists on this host; fall back to .zshrc.
HOST_HOME_FILE=""
for candidate in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$candidate" ]; then HOST_HOME_FILE="$candidate"; break; fi
done
hash_before=""
hash_after=""
if [ -n "$HOST_HOME_FILE" ]; then
    hash_before="$(shasum "$HOST_HOME_FILE" 2>/dev/null | awk '{print $1}')"
fi
run_in_container 'rm -rf /home/agent /tmp/* 2>/dev/null; ls /home/agent 2>&1' >/dev/null
if [ -n "$HOST_HOME_FILE" ]; then
    hash_after="$(shasum "$HOST_HOME_FILE" 2>/dev/null | awk '{print $1}')"
fi
if [ -n "$HOST_HOME_FILE" ] && [ "$hash_before" = "$hash_after" ]; then
    report pass "2. footgun: host \$HOME untouched after rm -rf inside container"
else
    report fail "2. footgun" "host file changed during container rm — investigate IMMEDIATELY"
fi

# ---------------------------------------------------------------------------
# Probe 3: network — egress is bounded to whatever the network mode allows.
# v1 uses bridge mode (no allowlist), so we just confirm the container has
# *some* connectivity (proxy for "claude can reach api.anthropic.com").
# When you switch to a real allowlist, replace this probe with two checks:
# allowed domain succeeds, denied domain fails.
# ---------------------------------------------------------------------------
out="$(run_in_container 'curl -s -o /dev/null -w %{http_code} https://api.anthropic.com/ -m 5')"
if echo "$out" | grep -qE '^[0-9]{3}$'; then
    report pass "3. network: container can reach api.anthropic.com (HTTP $out)"
else
    report fail "3. network" "no response from api.anthropic.com — check Docker network: $out"
fi

# ---------------------------------------------------------------------------
# Probe 4: credentials — host secret paths must not exist inside.
# ---------------------------------------------------------------------------
out="$(run_in_container 'for p in /root/.aws /home/agent/.aws /root/.ssh /home/agent/.ssh /run/secrets/host_creds; do test -e "$p" && echo VISIBLE:$p; done; echo DONE')"
if ! echo "$out" | grep -q VISIBLE: && echo "$out" | grep -q DONE; then
    report pass "4. credentials: no host secret paths visible inside container"
else
    report fail "4. credentials" "$out"
fi

# ---------------------------------------------------------------------------
# Probe 5: escape — docker socket must not be present, docker CLI absent.
# ---------------------------------------------------------------------------
out="$(run_in_container 'test -S /var/run/docker.sock && echo SOCK_PRESENT; command -v docker && echo DOCKER_CLI_PRESENT; echo DONE')"
if ! echo "$out" | grep -qE 'SOCK_PRESENT|DOCKER_CLI_PRESENT' && echo "$out" | grep -q DONE; then
    report pass "5. escape: docker socket absent + docker CLI absent inside container"
else
    report fail "5. escape" "$out"
fi

# ---------------------------------------------------------------------------
# Probe 6: concurrency — five containers concurrently, no name collision.
# ---------------------------------------------------------------------------
mkdir -p "$SCRATCH/conc"
seq 1 5 | xargs -I {} -P 5 docker run --rm \
    --name "gascity-verify-conc-{}" \
    --user 1000:1000 \
    --read-only \
    --tmpfs /tmp:size=32m,mode=1777 \
    --tmpfs /home/agent/.cache:size=32m \
    -v "$SCRATCH/conc:/work:rw" \
    --network bridge \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --entrypoint /bin/bash \
    "$IMAGE" -c "echo {} > /work/c{}.txt; sleep 1" >/dev/null 2>&1
WROTE="$(ls "$SCRATCH/conc"/c*.txt 2>/dev/null | wc -l | tr -d ' ')"
if [ "$WROTE" = "5" ]; then
    report pass "6. concurrency: 5 parallel containers wrote 5 files into shared worktree"
else
    report fail "6. concurrency" "expected 5 files, saw $WROTE"
fi

# ---------------------------------------------------------------------------
# Probe 7: restart — `docker stop` cleans up, no zombie containers.
# ---------------------------------------------------------------------------
docker run --rm -d --name gascity-verify-restart \
    --user 1000:1000 --read-only \
    --tmpfs /tmp:size=32m,mode=1777 \
    --tmpfs /home/agent/.cache:size=32m \
    -v "$RIG:/work:rw" \
    --network bridge \
    --cap-drop=ALL --security-opt=no-new-privileges \
    --entrypoint /bin/bash \
    "$IMAGE" -c 'sleep 30' >/dev/null 2>&1
docker stop --time=2 gascity-verify-restart >/dev/null 2>&1
if ! docker ps --filter "name=gascity-verify-restart" --format '{{.Names}}' | grep -q gascity-verify-restart; then
    report pass "7. restart: docker stop cleanly removed the container"
else
    report fail "7. restart" "container survived docker stop"
fi

# ===========================================================================
# v2 credential broker probes (docs/credential-broker-v2-spec.md §11)
# ===========================================================================
#
# These probes only run if the broker containers are up. We don't try to
# start them here — that's gascity-docker-start.sh's job. If the brokers
# aren't running, each probe prints SKIP (not FAIL) so a fresh
# install.sh→verify.sh handoff before first start still passes.

SKIP=0
skip() { echo "  SKIP  $1"; SKIP=$((SKIP + 1)); }
broker_running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

echo
echo "→ v2 broker probes"

# ---------------------------------------------------------------------------
# A. Anthropic broker
# ---------------------------------------------------------------------------
if broker_running gc-broker-anthropic; then
    # A1: reachable from gc-broker-net via container DNS.
    out="$(docker run --rm --network gc-broker-net python:3.12-slim \
        python -c 'import urllib.request,json; \
print(urllib.request.urlopen("http://gc-broker-anthropic:8080/healthz",timeout=5).read().decode())' 2>&1)"
    if echo "$out" | grep -q '"ok": *true'; then
        report pass "A1. anthropic broker reachable from gc-broker-net (/healthz returns ok)"
    else
        report fail "A1. anthropic /healthz" "$out"
    fi

    # A2: NOT reachable from the host (no port published).
    if ! curl -sf --max-time 2 http://localhost:8080/healthz >/dev/null 2>&1; then
        report pass "A2. anthropic broker NOT reachable from host localhost:8080"
    else
        report fail "A2. anthropic broker host exposure" \
            "broker /healthz responded on the host — port should not be published"
    fi

    # A3: path allowlist enforces 403 on a non-allowlisted path.
    code="$(docker run --rm --network gc-broker-net python:3.12-slim \
        python -c '
import urllib.request, urllib.error
try:
    urllib.request.urlopen("http://gc-broker-anthropic:8080/v1/admin/secret", timeout=5)
    print(200)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception as e:
    print("err:" + str(e))
' 2>&1 | tail -1)"
    if [ "$code" = "403" ]; then
        report pass "A3. anthropic path allowlist returns 403 on /v1/admin/secret"
    else
        report fail "A3. anthropic path allowlist" "expected 403, got: $code"
    fi

    # A4: streaming smoke — issue a tiny streaming /v1/messages and verify
    # at least 2 chunks arrive over wire-time (broker is not buffering).
    # Skip if creds.json missing on host.
    if [ -f "$HOME/.local/state/gascity-broker/creds.json" ]; then
        stream_out="$(docker run --rm --network gc-broker-net python:3.12-slim \
            python -c '
import json, time, urllib.request
body = json.dumps({
  "model": "claude-haiku-4-5-20251001",
  "max_tokens": 32,
  "stream": True,
  "messages": [{"role":"user","content":"count to 3"}],
}).encode()
req = urllib.request.Request("http://gc-broker-anthropic:8080/v1/messages",
                             data=body, method="POST",
                             headers={"Content-Type":"application/json"})
chunks = []
t0 = time.time()
with urllib.request.urlopen(req, timeout=30) as r:
    while True:
        c = r.read(64)
        if not c: break
        chunks.append((time.time()-t0, len(c)))
        if len(chunks) >= 4: break
print(len(chunks), chunks[-1][0] if chunks else 0)
' 2>&1 | tail -1)"
        n_chunks="$(echo "$stream_out" | awk '{print $1}')"
        if [ -n "$n_chunks" ] && [ "$n_chunks" -ge 2 ] 2>/dev/null; then
            report pass "A4. anthropic streaming forwards multiple chunks ($n_chunks chunks observed)"
        else
            report fail "A4. anthropic streaming" "got: $stream_out"
        fi
    else
        skip "A4. anthropic streaming — no creds.json (run gc-broker-creds-extract.sh)"
    fi

    # A5: token never appears in broker stdout/env.
    leak="$(docker logs gc-broker-anthropic 2>&1 | grep -cE 'sk-ant-[A-Za-z0-9_-]+|Bearer [A-Za-z0-9._-]+' || true)"
    env_leak="$(docker exec gc-broker-anthropic env 2>/dev/null | grep -cE '^[A-Z_]*BEARER|sk-ant-' || true)"
    if [ "$leak" = "0" ] && [ "$env_leak" = "0" ]; then
        report pass "A5. no bearer token leakage in anthropic logs or env"
    else
        report fail "A5. anthropic token leak" \
            "log matches: $leak  env matches: $env_leak  — INVESTIGATE IMMEDIATELY"
    fi
else
    skip "A1-A5. anthropic broker — not running (start with gc-docker-start.sh)"
fi

# ---------------------------------------------------------------------------
# B. GitHub-SSH broker + agent isolation
# ---------------------------------------------------------------------------
if broker_running gc-broker-github-ssh; then
    # B1: ssh-agent socket reachable from agent network and has a key loaded.
    out="$(docker run --rm --network gc-broker-net \
        -v gc-sshagent-sock:/run/sshagent:ro \
        --user 1000:1000 \
        debian:stable-slim sh -c '
apt-get update -qq >/dev/null 2>&1 && \
DEBIAN_FRONTEND=noninteractive apt-get install -qqy --no-install-recommends openssh-client >/dev/null 2>&1
SSH_AUTH_SOCK=/run/sshagent/gc.sock ssh-add -l 2>&1
' 2>&1)"
    if echo "$out" | grep -qE 'ED25519|RSA|ECDSA'; then
        report pass "B1. github-ssh socket reachable; key is loaded ($(echo "$out" | grep -oE 'ED25519|RSA|ECDSA' | head -1))"
    else
        report fail "B1. github-ssh socket / key" "$out"
    fi

    # B2: actual key bytes never reachable from agent side of volume.
    out="$(docker run --rm --network gc-broker-net \
        -v gc-sshagent-sock:/run/sshagent:ro \
        debian:stable-slim sh -c 'ls -la /run/sshagent/ 2>&1; cat /run/sshagent/key 2>&1' 2>&1)"
    if echo "$out" | grep -q 'No such file' && ! echo "$out" | grep -qE 'BEGIN .* PRIVATE KEY'; then
        report pass "B2. github-ssh key bytes not exposed via shared volume"
    else
        report fail "B2. github-ssh key exposure" "$out"
    fi

    # B4: agent network has no internet egress (DNS or connect must fail).
    out="$(docker run --rm --network gc-broker-net python:3.12-slim \
        python -c '
import socket, sys
try:
    s = socket.create_connection(("api.anthropic.com", 443), timeout=4)
    s.close()
    print("REACHED")
except Exception as e:
    print("blocked:", type(e).__name__)
' 2>&1)"
    if echo "$out" | grep -q '^blocked:'; then
        report pass "B4. agent network blocks direct egress to api.anthropic.com"
    else
        report fail "B4. agent network egress" "agent could reach api.anthropic.com: $out"
    fi
else
    skip "B1-B4. github-ssh broker — not running (start with gc-docker-start.sh)"
fi

# ---------------------------------------------------------------------------
# C. GitHub-API broker
# ---------------------------------------------------------------------------
if broker_running gc-broker-github-api; then
    # C2: DELETE method is hard-denied.
    code="$(docker run --rm --network gc-broker-net python:3.12-slim \
        python -c '
import urllib.request, urllib.error
req = urllib.request.Request("http://gc-broker-github-api:8080/repos/owner/repo",
                             method="DELETE")
try:
    urllib.request.urlopen(req, timeout=5)
    print(200)
except urllib.error.HTTPError as e:
    print(e.code)
' 2>&1 | tail -1)"
    if [ "$code" = "403" ]; then
        report pass "C2. github-api DELETE method denied (403)"
    else
        report fail "C2. github-api DELETE" "expected 403, got: $code"
    fi

    # C3: /user/keys is on the hard denylist.
    code="$(docker run --rm --network gc-broker-net python:3.12-slim \
        python -c '
import urllib.request, urllib.error
try:
    urllib.request.urlopen("http://gc-broker-github-api:8080/user/keys", timeout=5)
    print(200)
except urllib.error.HTTPError as e:
    print(e.code)
' 2>&1 | tail -1)"
    if [ "$code" = "403" ]; then
        report pass "C3. github-api /user/keys denied (403)"
    else
        report fail "C3. github-api /user/keys" "expected 403, got: $code"
    fi

    # C4: repo not on allowlist returns 403 with deny_reason repo-not-in-allowlist.
    body="$(docker run --rm --network gc-broker-net python:3.12-slim \
        python -c '
import urllib.request, urllib.error
try:
    urllib.request.urlopen("http://gc-broker-github-api:8080/repos/strangers/private-repo", timeout=5)
    print("status=200")
except urllib.error.HTTPError as e:
    print("status="+str(e.code))
    print(e.read().decode())
' 2>&1)"
    if echo "$body" | grep -q 'status=403' && echo "$body" | grep -q 'repo-not-in-allowlist'; then
        report pass "C4. github-api repo allowlist denies non-listed repo"
    else
        report fail "C4. github-api repo allowlist" "$body"
    fi

    # C5: token never logged.
    leak="$(docker logs gc-broker-github-api 2>&1 \
        | grep -cE 'gh[opst]_[A-Za-z0-9]{36}|github_pat_|token [A-Za-z0-9]{40,}' || true)"
    if [ "$leak" = "0" ]; then
        report pass "C5. no GH_TOKEN leakage in github-api logs"
    else
        report fail "C5. github-api token leak" "matches: $leak — INVESTIGATE IMMEDIATELY"
    fi
else
    skip "C2-C5. github-api broker — not running (start with gc-docker-start.sh)"
fi

echo
echo "Result: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
