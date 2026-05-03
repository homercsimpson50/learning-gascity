#!/usr/bin/env python3
"""
Gas City iTerm2 Workspace Launcher

Layout (matches the gastown layout, but with gascity):
  ┌──────────┬──────────┬──────────┐
  │          │ gc       │ shell    │
  │  local   │ mayor    │ ~/code   │
  │  mayor   │ (cont)   │          │
  │  (tall)  ├──────────┴──────────┤
  │          │ gc events --follow  │
  │          │ (wide)              │
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
CONTAINER_DIR = os.path.expanduser("~/code/learning-gascity/containerized")

USE_AI = "--ai" in sys.argv

LOCAL_MAYOR = (
    'cd ~/gc && echo "Starting local Gas City..." '
    '&& gc supervisor start 2>/dev/null; gc session attach mayor'
)
CONTAINER_MAYOR = (
    f'cd {CONTAINER_DIR} && docker compose exec gascity gc session attach mayor'
)
CODE_SHELL = 'cd ~/code'
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

    # Split left vertically → right half
    right_top = await left.async_split_pane(vertical=True)
    await right_top.async_set_name("gc-mayor")

    # Split right-top vertically → top-right (shell)
    top_right = await right_top.async_split_pane(vertical=True)
    await top_right.async_set_name("code")

    # Split right-top horizontally down → bottom-right (feed, wide)
    bottom_right = await right_top.async_split_pane(vertical=False)
    await bottom_right.async_set_name("feed")

    await asyncio.sleep(0.5)

    # Send commands
    await left.async_send_text(LOCAL_MAYOR + '\n')
    await right_top.async_send_text(CONTAINER_MAYOR + '\n')
    await top_right.async_send_text(CODE_SHELL + '\n')
    await asyncio.sleep(1)
    await bottom_right.async_send_text(EVENT_FEED + '\n')


iterm2.run_until_complete(main)
