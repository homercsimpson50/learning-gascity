#!/usr/bin/env bash
#
# gc-broker-creds-extract.sh — pull Claude Code's OAuth credential from
# macOS Keychain and write it to a flat JSON file the Anthropic broker
# can mount.
#
# Why: current Claude Code on macOS stores the OAuth token in the
# Keychain (Generic Password named "Claude Code-credentials"), not in
# ~/.claude/.credentials.json — so the broker can't read it directly via
# bind mount. This extractor decrypts the Keychain item once, writes the
# JSON to a state file with mode 0600, and exits.
#
# Called by gascity-docker-start.sh before brokers come up. Safe to run
# any time to refresh the file (e.g., if you got a 401 from the broker).
#
# Output: $HOME/.local/state/gascity-broker/creds.json (0600)
#
# This script does NOT auto-refresh on a timer. The broker re-reads the
# file on every request so OAuth rotations on the host (via `claude` CLI
# usage) are picked up — but only after this extractor runs again. If
# you want automatic refresh, schedule this script via launchd or cron.

set -euo pipefail

KEYCHAIN_SERVICE="${GC_BROKER_KEYCHAIN_SERVICE:-Claude Code-credentials}"
OUT_DIR="${GC_BROKER_STATE_DIR:-$HOME/.local/state/gascity-broker}"
OUT_FILE="$OUT_DIR/creds.json"

if [ "$(uname)" != "Darwin" ]; then
    echo "gc-broker-creds-extract: this extractor only runs on macOS" >&2
    echo "  on Linux the broker should bind-mount ~/.claude/.credentials.json directly." >&2
    exit 1
fi

if ! command -v security >/dev/null 2>&1; then
    echo "gc-broker-creds-extract: 'security' tool not found (macOS only)" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
chmod 0700 "$OUT_DIR"

# `security find-generic-password -s <service> -w` writes the raw
# password (here: a JSON blob) to stdout. Use a temp file + atomic rename
# so a partial read never lands at the broker mount path.
TMP="$(mktemp "$OUT_DIR/.creds.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

if ! security find-generic-password -s "$KEYCHAIN_SERVICE" -w > "$TMP" 2>/dev/null; then
    echo "gc-broker-creds-extract: keychain item '$KEYCHAIN_SERVICE' not found" >&2
    echo "  log into Claude Code on the host (run \`claude\` once), then re-run this." >&2
    exit 1
fi

# Sanity: the JSON must contain claudeAiOauth.accessToken.
if ! python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
oauth = d.get("claudeAiOauth") or {}
if not oauth.get("accessToken"):
    sys.exit(1)
' "$TMP" 2>/dev/null; then
    echo "gc-broker-creds-extract: keychain item parsed but no claudeAiOauth.accessToken" >&2
    echo "  the credentials format may have changed; please file an issue." >&2
    exit 1
fi

chmod 0600 "$TMP"
mv "$TMP" "$OUT_FILE"
trap - EXIT

echo "gc-broker-creds-extract: wrote $OUT_FILE"
