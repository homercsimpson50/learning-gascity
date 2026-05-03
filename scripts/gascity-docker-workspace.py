#!/usr/bin/env python3
"""
Gas City *Docker* iTerm2 Workspace Launcher (Python API variant).

Sister script to gascity-workspace.py for the work-machine
(containerized) flow. All panes use a desert color scheme so this
workspace is visually distinct from the local one.

Layout:
  ┌──────────┬─────────────────────┐
  │          │ docker-shell        │
  │  docker- │ (cd'd to city)      │
  │  super   ├─────────────────────┤
  │  (tall)  │ docker-feed         │
  │          │ (gc events --follow)│
  └──────────┴─────────────────────┘

Knobs (env vars):
  GC_DOCKER_CITY   path to the city (default: $HOME/gc-docker)
                   auto-init'd via `gc-docker init --provider claude`
                   if it doesn't exist yet.

Usage:
  ./gascity-docker-workspace.py          # plain feed
  ./gascity-docker-workspace.py --ai     # bottom pane runs gc-feed-ai

Requires iTerm2 with Python API enabled:
  iTerm2 → Preferences → General → Magic → Enable Python API
"""

import asyncio
import os
import shutil
import subprocess
import sys

import iterm2

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
USE_AI = "--ai" in sys.argv
CITY = os.environ.get("GC_DOCKER_CITY", os.path.expanduser("~/gc-docker"))

# --- Pre-flight ------------------------------------------------------------
if shutil.which("gc-docker") is None:
    print("error: 'gc-docker' not on PATH", file=sys.stderr)
    print("       run learning-gascity/containerized/install.sh first", file=sys.stderr)
    sys.exit(1)

if USE_AI and not os.access(os.path.join(SCRIPT_DIR, "gc-feed-ai"), os.X_OK):
    print(f"error: {SCRIPT_DIR}/gc-feed-ai not found or not executable", file=sys.stderr)
    sys.exit(1)

# Auto-init the city if missing. Init doesn't spawn agents, safe before
# the supervisor is up.
if not os.path.exists(os.path.join(CITY, "city.toml")):
    print(f"→ initializing city at {CITY} (one-time)")
    subprocess.check_call(
        ["gc-docker", "init", "--provider", "claude",
         "--skip-provider-readiness", CITY]
    )

SUPERVISOR_CMD = f"cd {CITY} && gc-docker supervisor run"
SHELL_CMD = f"cd {CITY}"
FEED_CMD = (
    f"cd {CITY} && {SCRIPT_DIR}/gc-feed-ai"
    if USE_AI
    else f"cd {CITY} && gc events --follow"
)

# Desert color scheme — warm cream on deep coffee. iTerm2 colors are
# (red, green, blue, alpha) where each is 0.0–1.0.
BG = iterm2.Color(40, 30, 20, 255)
FG = iterm2.Color(230, 200, 150, 255)


async def paint_desert(session: "iterm2.Session") -> None:
    """Apply background + foreground color to one session."""
    colors = await session.async_get_profile()
    colors.set_background_color(BG)
    colors.set_foreground_color(FG)
    await session.async_set_profile_properties(colors)


async def main(connection):
    window = await iterm2.Window.async_create(connection)
    left = window.current_tab.current_session
    await left.async_set_name("docker-supervisor")
    await paint_desert(left)

    right_top = await left.async_split_pane(vertical=True)
    await right_top.async_set_name("docker-shell")
    await paint_desert(right_top)

    bottom_right = await right_top.async_split_pane(vertical=False)
    await bottom_right.async_set_name("docker-feed")
    await paint_desert(bottom_right)

    await asyncio.sleep(0.5)

    await left.async_send_text(SUPERVISOR_CMD + "\n")
    await right_top.async_send_text(SHELL_CMD + "\n")
    await asyncio.sleep(0.5)
    await bottom_right.async_send_text(FEED_CMD + "\n")


iterm2.run_until_complete(main)
