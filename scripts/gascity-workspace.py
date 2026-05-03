#!/usr/bin/env python3
"""
Gas City iTerm2 Workspace Launcher

Layout:
  ┌──────────┬─────────────────────┐
  │          │ shell (interactive) │
  │  local   │                     │
  │  mayor   │                     │
  │  (tall)  ├─────────────────────┤
  │          │ feed (wide)         │
  │          │                     │
  └──────────┴─────────────────────┘

Usage:
  ./gascity-workspace.py          # Plain feed in the bottom pane
  ./gascity-workspace.py --ai     # Bottom pane runs gc-feed-ai (Ollama summary)

Requires iTerm2 with Python API enabled:
  iTerm2 → Preferences → General → Magic → Enable Python API
"""

import iterm2
import asyncio
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

USE_AI = "--ai" in sys.argv

if USE_AI and not os.access(os.path.join(SCRIPT_DIR, "gc-feed-ai"), os.X_OK):
    print(f"error: {SCRIPT_DIR}/gc-feed-ai not found or not executable", file=sys.stderr)
    sys.exit(1)

LOCAL_MAYOR = (
    'cd ~/gc && echo "Starting local Gas City..." '
    '&& gc supervisor start 2>/dev/null; gc session attach mayor'
)
EVENT_FEED = (
    f'cd ~/gc && {SCRIPT_DIR}/gc-feed-ai'
    if USE_AI
    else 'cd ~/gc && gc events --follow'
)


async def main(connection):
    app = await iterm2.async_get_app(connection)

    # Create window — starts as single pane (local mayor)
    window = await iterm2.Window.async_create(connection)
    left = window.current_tab.current_session
    await left.async_set_name("local-mayor")

    # Split left vertically → right top (shell)
    right_top = await left.async_split_pane(vertical=True)
    await right_top.async_set_name("shell")

    # Split right-top horizontally down → bottom-right (feed, wide)
    bottom_right = await right_top.async_split_pane(vertical=False)
    await bottom_right.async_set_name("feed")

    await asyncio.sleep(0.5)

    # Top-right pane is left blank (just an open shell).
    await left.async_send_text(LOCAL_MAYOR + '\n')
    await asyncio.sleep(0.5)
    await bottom_right.async_send_text(EVENT_FEED + '\n')


iterm2.run_until_complete(main)
