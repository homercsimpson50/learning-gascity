#!/usr/bin/env python3
"""
_gc_feed_ai.py — stdin = `gc events --follow` JSON Lines, stdout = pretty
event lines plus periodic AI summaries via Ollama.

Invoked by `gc-feed-ai`; not meant to be called directly. Stdlib only.

Behavior:
  - For every event line on stdin, print one human-readable line.
  - Every GC_FEED_AI_EVERY events OR every GC_FEED_AI_INTERVAL seconds
    (whichever first), call Ollama with the buffered events and print a
    2-3 sentence summary block.
  - GC_FEED_AI_DISABLE=1 skips Ollama entirely (plain pass-through with
    nicer formatting than raw JSON).
"""

import json
import os
import sys
import time
import threading
import urllib.request
from collections import deque
from typing import Optional, Tuple, List

MODEL = os.environ.get("GC_FEED_AI_MODEL", "qwen2.5:3b")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
EVERY = int(os.environ.get("GC_FEED_AI_EVERY", "8"))
INTERVAL = int(os.environ.get("GC_FEED_AI_INTERVAL", "45"))
DISABLED = os.environ.get("GC_FEED_AI_DISABLE", "0") == "1"
BUF_MAX = 40

ISATTY = sys.stdout.isatty()
DIM = "\033[2m" if ISATTY else ""
BOLD = "\033[1m" if ISATTY else ""
CYAN = "\033[36m" if ISATTY else ""
YELLOW = "\033[33m" if ISATTY else ""
GREEN = "\033[32m" if ISATTY else ""
NC = "\033[0m" if ISATTY else ""


def fmt_event(ev: dict) -> str:
    """One-line human form of a gc API event. Mirrors gtc's feed style."""
    ts = ev.get("ts", "")[11:19]  # HH:MM:SS from RFC3339
    typ = ev.get("type", "?")
    actor = ev.get("actor", "?")
    subject = ev.get("subject", "")
    msg = ev.get("message", "")

    payload = ev.get("payload") or {}
    bead = payload.get("bead") if isinstance(payload, dict) else None
    extra = ""
    if isinstance(bead, dict):
        title = bead.get("title", "")
        itype = bead.get("issue_type", "")
        state = bead.get("status", "")
        meta = bead.get("metadata") or {}
        sess_state = meta.get("state") if isinstance(meta, dict) else None
        bits = []
        if itype:
            bits.append(itype)
        if state:
            bits.append(state)
        if sess_state and sess_state != state:
            bits.append(f"→{sess_state}")
        if title:
            bits.append(f'"{title}"')
        if bits:
            extra = " " + " ".join(bits)

    head = f"{DIM}{ts}{NC} {CYAN}{typ:<22}{NC} {actor:<14}"
    tail = f" {subject}" if subject else ""
    if msg and msg != subject:
        tail += f" {DIM}({msg}){NC}"
    return head + tail + extra


def summarize(events: List[dict]) -> Optional[Tuple[str, float, int]]:
    """Send a batch of events to Ollama. Returns (summary, secs, tokens)."""
    if not events:
        return None
    lines = [fmt_event_plain(e) for e in events]
    prompt = (
        "You are an AI agent activity summarizer. Given these recent events "
        "from a multi-agent coding system (Gas City), write a 2-3 sentence "
        "summary of what is happening right now. Be concise and specific. "
        "Mention agents, sessions, or beads by name when relevant. Focus on "
        "what work is being done and the current state.\n\n"
        "Events:\n" + "\n".join(lines) + "\n\nSummary:"
    )
    body = json.dumps(
        {"model": MODEL, "prompt": prompt, "stream": False}
    ).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/generate",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            resp = json.loads(r.read().decode())
    except Exception as e:
        return (f"(ollama error: {e})", 0.0, 0)
    text = (resp.get("response") or "").strip()
    secs = resp.get("total_duration", 0) / 1e9
    tokens = resp.get("eval_count", 0)
    return text, secs, tokens


def fmt_event_plain(ev: dict) -> str:
    ts = ev.get("ts", "")[11:19]
    typ = ev.get("type", "?")
    actor = ev.get("actor", "?")
    subject = ev.get("subject", "")
    msg = ev.get("message", "")
    bead = (ev.get("payload") or {}).get("bead") or {}
    title = bead.get("title", "") if isinstance(bead, dict) else ""
    itype = bead.get("issue_type", "") if isinstance(bead, dict) else ""
    bits = [ts, typ, actor]
    if subject:
        bits.append(subject)
    if itype:
        bits.append(f"[{itype}]")
    if title:
        bits.append(f'"{title}"')
    if msg and msg != subject and msg != title:
        bits.append(f"({msg})")
    return " ".join(bits)


def render_summary(text: str, secs: float, tokens: int) -> None:
    bar = "─" * 60
    print(f"\n{YELLOW}{bar}{NC}")
    print(f"{BOLD}{YELLOW}AI summary{NC} {DIM}(model={MODEL}, {secs:.1f}s, {tokens}t){NC}")
    print(text)
    print(f"{YELLOW}{bar}{NC}\n", flush=True)


class State:
    def __init__(self):
        self.buf = deque(maxlen=BUF_MAX)  # type: deque
        self.lock = threading.Lock()
        self.last_summary_at = time.time()
        self.events_since_summary = 0
        self.summarizing = False


def time_keeper(state: State):
    while True:
        time.sleep(5)
        if DISABLED or state.summarizing:
            continue
        with state.lock:
            if state.events_since_summary == 0:
                continue
            elapsed = time.time() - state.last_summary_at
            if elapsed >= INTERVAL:
                trigger_summary(state)


def trigger_summary(state: State):
    """Caller must hold state.lock OR set summarizing=True themselves."""
    if state.summarizing:
        return
    state.summarizing = True
    snapshot = list(state.buf)
    state.events_since_summary = 0
    state.last_summary_at = time.time()
    threading.Thread(
        target=_run_summary, args=(state, snapshot), daemon=True
    ).start()


def _run_summary(state: State, snapshot: List[dict]):
    try:
        result = summarize(snapshot)
        if result:
            render_summary(*result)
    finally:
        state.summarizing = False


def main():
    state = State()

    if not DISABLED:
        threading.Thread(target=time_keeper, args=(state,), daemon=True).start()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            print(line, flush=True)
            continue

        print(fmt_event(ev), flush=True)

        if DISABLED:
            continue

        with state.lock:
            state.buf.append(ev)
            state.events_since_summary += 1
            if state.events_since_summary >= EVERY:
                trigger_summary(state)

    # stdin closed (gc events exited or test fixture finished).
    # Flush any pending events as a final summary, and wait for any
    # in-flight summary thread so the user sees its output before we exit.
    if not DISABLED:
        with state.lock:
            if state.events_since_summary > 0:
                trigger_summary(state)
        deadline = time.time() + 120
        while state.summarizing and time.time() < deadline:
            time.sleep(0.2)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
