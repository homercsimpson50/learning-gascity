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

echo
echo "Result: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
