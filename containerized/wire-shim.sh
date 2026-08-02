#!/usr/bin/env bash
# wire-shim.sh — ensure every agent in a gc city has `start_command`
# pointed at the shim. gc-supervisor invokes `start_command` as the
# absolute executable for an agent's spawn (instead of doing PATH lookup
# for `claude`). Setting it per-agent is the only way to wire the shim
# durably; PATH-based fixes break on macOS for reasons documented in
# CLAUDE.md.
#
# Handles both layouts:
#
#   1. PackV1 (gc ≤ 1.3): [[agent]] blocks in city.toml / pack.toml.
#      Editing those blocks in place with sed/awk. Idempotent.
#
#   2. 1.4+: agents/<name>/agent.toml with keys at file root (no [agent]
#      wrapper). For each existing agents/<name>/ subdir, patch or
#      create agent.toml with a root-level `start_command`. Always
#      ensures agents/claude/agent.toml exists — that's the polecat
#      pool worker and the whole reason gc-docker mode exists.
#
# Under 1.4, PackV1 [[agent]] blocks in city.toml/pack.toml are HARD-
# rejected by `gc start`. This script does NOT auto-migrate — that's a
# schema translation, out of scope. If it detects PackV1 blocks on a
# 1.4 city, it warns loudly. The right recovery is:
#     rm -rf <city>
#     gc-docker-start.sh       # re-init cleanly on next boot
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

# --- PackV1 handler (pre-1.4): [[agent]] blocks in pack.toml/city.toml -----
#
# Walk a TOML file, find each [[agent]] block, ensure start_command is
# set inside it. A block runs from `[[agent]]` (or `[[agents]]`) to the
# next bracketed section or EOF.
patch_v1_file() {
    local file="$1"
    [ -f "$file" ] || return 0

    if ! grep -qE '^\[\[agents?\]\]' "$file"; then
        return 0  # no PackV1 agent blocks; nothing to do
    fi

    # Loudly warn — 1.4 rejects PackV1 blocks in these files.
    if gc version 2>/dev/null | grep -qE '^1\.[4-9]|^[2-9]'; then
        echo "wire-shim: WARN $file has PackV1 [[agent]] blocks; gc 1.4+ rejects these" >&2
        echo "wire-shim: WARN   fix: rm -rf $CITY && re-run gc-docker-start.sh to re-init cleanly" >&2
    fi

    local tmp
    tmp="$(mktemp -t wire-shim.XXXXXX)"
    trap 'rm -f "$tmp"' RETURN

    awk -v shim="$SHIM" '
        BEGIN { in_block = 0; has_sc = 0; n = 0 }

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
        echo "wire-shim: $file — already wired (PackV1)"
    else
        cp "$file" "$file.wire-shim.bak"
        mv "$tmp" "$file"
        trap - RETURN
        echo "wire-shim: $file — patched (PackV1; backup at $file.wire-shim.bak)"
    fi
}

# --- 1.4 handler: agents/<name>/agent.toml with root-level keys -----------
#
# Files may be:
#   - An agent-template override (root-level keys like prompt_template,
#     provider, start_command). Patch these.
#   - A rig reference (root-level `dir = "..."` and nothing else). Skip —
#     rigs aren't agents; start_command would be nonsense.
patch_v14_agent_file() {
    local file="$1"

    if [ ! -f "$file" ]; then
        return 0
    fi

    # Rig reference heuristic: has a root-level `dir = ...` line.
    # (An agent template can also have `work_dir` — that's fine — but a
    # bare `dir = ...` at root with no other agent-ish keys is a rig ref.)
    if grep -qE '^[[:space:]]*dir[[:space:]]*=' "$file" 2>/dev/null && \
       ! grep -qE '^[[:space:]]*(name|prompt_template|provider|scope)[[:space:]]*=' "$file" 2>/dev/null; then
        return 0  # rig reference; silently skip
    fi

    if grep -qE '^[[:space:]]*start_command[[:space:]]*=' "$file" 2>/dev/null; then
        local current
        current="$(awk '
            /^[[:space:]]*start_command[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*"?/, "")
                sub(/"?[[:space:]]*$/, "")
                print; exit
            }' "$file")"
        if [ "$current" = "$SHIM" ]; then
            echo "wire-shim: $file — already wired"
        else
            echo "wire-shim: $file — has different start_command ($current); leaving alone"
        fi
        return 0
    fi

    cp "$file" "$file.wire-shim.bak"
    # Append at end; ensure a trailing newline first for readability.
    if [ -s "$file" ] && [ "$(tail -c1 "$file" | wc -l | tr -d ' ')" = "0" ]; then
        printf '\n' >> "$file"
    fi
    printf 'start_command = "%s"\n' "$SHIM" >> "$file"
    echo "wire-shim: $file — patched (backup at $file.wire-shim.bak)"
}

# Ensure a specific agent has an override file at agents/<name>/agent.toml
# with start_command set. Creates the file (and dir) if missing.
ensure_v14_agent() {
    local name="$1"
    local dir="$CITY/agents/$name"
    local file="$dir/agent.toml"

    if [ -f "$file" ]; then
        patch_v14_agent_file "$file"
        return 0
    fi

    mkdir -p "$dir"
    cat > "$file" <<EOF
# gc-docker override: routes this agent's spawn through the shim so
# rig-scoped invocations end up in a container. City-scoped agents
# (mayor, etc.) still exec the real claude on the host — the shim
# branches on GC_RIG. Written by containerized/wire-shim.sh.
start_command = "$SHIM"
EOF
    echo "wire-shim: $file — created (1.4 override)"
}

# --- Legacy PackV1 pass ----------------------------------------------------
patch_v1_file "$CITY/pack.toml"
patch_v1_file "$CITY/city.toml"

# --- 1.4 pass --------------------------------------------------------------
# Patch any existing agent.toml files under agents/*/, then ensure the
# polecat "claude" agent has an override file (its base comes from the
# imported core pack; agents/claude/ may not exist in a fresh city).
# Skip "claude" in the walk since ensure_v14_agent handles it.
if [ -d "$CITY/agents" ]; then
    for adir in "$CITY/agents"/*/; do
        [ -d "$adir" ] || continue
        [ -f "$adir/agent.toml" ] || continue
        [ "$(basename "$adir")" = "claude" ] && continue
        patch_v14_agent_file "$adir/agent.toml"
    done
fi
ensure_v14_agent claude
