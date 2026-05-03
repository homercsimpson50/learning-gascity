#!/usr/bin/env bash
# wire-shim.sh — ensure every [[agent]] block in a gc city's
# pack.toml + city.toml has `start_command` pointed at the shim.
#
# gc-supervisor invokes `start_command` as the absolute executable for an
# agent's spawn (instead of doing PATH lookup for `claude`). Setting it
# per-agent is the only way to wire the shim durably; PATH-based fixes
# break on macOS for reasons documented in CLAUDE.md.
#
# This script edits TOML in place with sed/awk — no Python dependency,
# no tomllib needed. Idempotent: re-runs are no-ops if start_command is
# already present in every [[agent]] block.
#
# Usage:
#   wire-shim.sh                # default city: $HOME/gc-docker
#   wire-shim.sh /path/to/city  # explicit city dir

set -euo pipefail

CITY="${1:-$HOME/gc-docker}"
SHIM="${GC_DOCKER_SHIM:-$HOME/.local/bin/gascity-shims/claude}"

if [ ! -x "$SHIM" ]; then
    echo "wire-shim: shim not found or not executable: $SHIM" >&2
    echo "wire-shim: run containerized/install.sh first" >&2
    exit 1
fi

if [ ! -d "$CITY" ]; then
    echo "wire-shim: city dir does not exist: $CITY" >&2
    exit 1
fi

# Walk a TOML file, find each [[agent]] block, ensure start_command is
# set inside it. A block runs from `[[agent]]` (or `[[agents]]`) to the
# next bracketed section or EOF.
patch_file() {
    local file="$1"
    [ -f "$file" ] || return 0

    if ! grep -qE '^\[\[agents?\]\]' "$file"; then
        return 0  # no agent blocks; nothing to do
    fi

    # awk pass: scan blocks, decide which need a start_command line added.
    # Print to stdout; we'll redirect to a tempfile and atomically replace
    # only if the content actually changed.
    local tmp
    tmp="$(mktemp -t wire-shim.XXXXXX)"
    trap 'rm -f "$tmp"' RETURN

    awk -v shim="$SHIM" '
        BEGIN { in_block = 0; has_sc = 0; n = 0 }

        # Flush the buffered agent block. If start_command was missing,
        # insert it just after the last non-blank line so any trailing
        # blank line(s) in the original block are preserved.
        function flush_block(    i, last_nonblank) {
            if (!in_block) return
            if (!has_sc) {
                last_nonblank = 0
                for (i = 1; i <= n; i++) {
                    if (buf[i] !~ /^[[:space:]]*$/) last_nonblank = i
                }
                for (i = 1; i <= last_nonblank; i++) print buf[i]
                print "start_command = \"" shim "\""
                for (i = last_nonblank + 1; i <= n; i++) print buf[i]
            } else {
                for (i = 1; i <= n; i++) print buf[i]
            }
            in_block = 0
            has_sc = 0
            n = 0
        }

        /^\[\[agents?\]\]/ {
            flush_block()
            in_block = 1
            has_sc = 0
            n = 1
            buf[1] = $0
            next
        }

        # Any new bracketed section ends the current agent block.
        /^\[/ {
            flush_block()
            print
            next
        }

        in_block {
            if ($0 ~ /^[[:space:]]*start_command[[:space:]]*=/) has_sc = 1
            n++
            buf[n] = $0
            next
        }

        { print }

        END { flush_block() }
    ' "$file" > "$tmp"

    if cmp -s "$tmp" "$file"; then
        echo "wire-shim: $file — already wired"
    else
        cp "$file" "$file.wire-shim.bak"
        mv "$tmp" "$file"
        trap - RETURN
        echo "wire-shim: $file — patched (backup at $file.wire-shim.bak)"
    fi
}

patch_file "$CITY/pack.toml"
patch_file "$CITY/city.toml"
