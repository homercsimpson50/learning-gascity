#!/usr/bin/env python3
"""
_gc_feed_tui.py — textual TUI for `gc events`, with periodic Ollama summary.

Layout:
  ┌─ Gas City — gc @ ~/gc ─────────────────────────────┐
  │ Sessions / Beads (left)  │ Event stream (right)    │
  │                          │                         │
  │                          ├─────────────────────────┤
  │                          │ AI summary (toggle 's') │
  └────────────────────────────────────────────────────┘
  q quit │ s toggle summary │ r refresh │ ↑/↓ scroll

Invoked by `gc-feed-ai` (TUI mode). Stdlib + textual.
"""

import asyncio
import json
import os
import subprocess
import sys
import time
import urllib.request
from collections import deque
from typing import Optional

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.reactive import reactive
from textual.widgets import DataTable, Footer, Header, RichLog, Static

CITY_DIR = os.environ.get("GC_CITY", os.path.expanduser("~/gc"))
MODEL = os.environ.get("GC_FEED_AI_MODEL", "qwen2.5:3b")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
EVERY = int(os.environ.get("GC_FEED_AI_EVERY", "8"))
INTERVAL = int(os.environ.get("GC_FEED_AI_INTERVAL", "15"))
DISABLED = os.environ.get("GC_FEED_AI_DISABLE", "0") == "1"
HISTORY_SINCE = os.environ.get("GC_FEED_AI_HISTORY", "1h")
BUF_MAX = 60


def fmt_event(ev: dict) -> str:
    """One-line, rich-markup form of a gc API event."""
    ts = ev.get("ts", "")[11:19]
    typ = ev.get("type", "?")
    actor = ev.get("actor", "?")
    subject = ev.get("subject", "")
    msg = ev.get("message", "")
    bead = (ev.get("payload") or {}).get("bead") or {}

    bits = [f"[dim]{ts}[/dim]", f"[cyan]{typ:<22}[/cyan]", f"{actor:<14}"]
    if subject:
        bits.append(subject)
    if isinstance(bead, dict):
        title = bead.get("title", "")
        itype = bead.get("issue_type", "")
        state = bead.get("status", "")
        meta = bead.get("metadata") or {}
        sess_state = meta.get("state") if isinstance(meta, dict) else None
        if itype:
            bits.append(f"[yellow]{itype}[/yellow]")
        if state:
            bits.append(state)
        if sess_state and sess_state != state:
            bits.append(f"→{sess_state}")
        if title:
            bits.append(f'[italic]"{title}"[/italic]')
    if msg and msg != subject:
        bits.append(f"[dim]({msg})[/dim]")
    return " ".join(bits)


def fmt_event_plain(ev: dict) -> str:
    ts = ev.get("ts", "")[11:19]
    typ = ev.get("type", "?")
    actor = ev.get("actor", "?")
    subject = ev.get("subject", "")
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
    return " ".join(bits)


async def run_gc(*args: str, timeout: float = 10.0) -> str:
    """Run `gc <args>` in CITY_DIR and return stdout (str)."""
    proc = await asyncio.create_subprocess_exec(
        "gc", *args,
        cwd=CITY_DIR,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return stdout.decode("utf-8", errors="replace")
    except asyncio.TimeoutError:
        proc.kill()
        return ""


async def ollama_summarize(events: list) -> Optional[str]:
    if not events:
        return None
    lines = [fmt_event_plain(e) for e in events]
    prompt = (
        "You are an AI agent activity summarizer. Given these recent events "
        "from a multi-agent coding system (Gas City), write a 2-3 sentence "
        "summary of what is happening right now. Be concise and specific. "
        "Mention agents, sessions, or beads by name when relevant.\n\n"
        "Events:\n" + "\n".join(lines) + "\n\nSummary:"
    )

    def _call() -> Optional[str]:
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
            return f"(ollama error: {e})"
        return (resp.get("response") or "").strip()

    return await asyncio.to_thread(_call)


class GCFeedApp(App):
    CSS = """
    Screen { layout: vertical; }

    #top { height: 1fr; }
    #left { width: 38%; border-right: solid $accent; }
    #right { width: 62%; }

    #header_status { height: auto; padding: 0 1; background: $boost; }

    DataTable { height: 1fr; }
    #sessions { height: 50%; }
    #beads { height: 50%; }

    #events { height: 70%; border-top: solid $accent; }
    #summary { height: 30%; padding: 1; border-top: solid $warning; }

    .label { color: $accent; text-style: bold; }
    """

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("s", "toggle_summary", "Toggle AI"),
        Binding("r", "refresh", "Refresh"),
        Binding("a", "force_summary", "Now"),
    ]

    show_summary: reactive[bool] = reactive(not DISABLED)

    def __init__(self) -> None:
        super().__init__()
        self.event_buf: deque = deque(maxlen=BUF_MAX)
        self.events_since_summary = 0
        self.last_summary_at = time.time()
        self.summarizing = False
        self._tail_proc: Optional[asyncio.subprocess.Process] = None

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield Static(id="header_status")
        with Horizontal(id="top"):
            with Vertical(id="left"):
                yield DataTable(id="sessions", zebra_stripes=True)
                yield DataTable(id="beads", zebra_stripes=True)
            with Vertical(id="right"):
                yield RichLog(id="events", highlight=False, markup=True, wrap=False, max_lines=2000)
                yield Static(id="summary", markup=True)
        yield Footer()

    async def on_mount(self) -> None:
        self.title = f"gc feed — {os.path.basename(CITY_DIR)}"
        self.sub_title = CITY_DIR

        sess = self.query_one("#sessions", DataTable)
        sess.add_columns("session", "state", "last")
        sess.cursor_type = "row"

        beads = self.query_one("#beads", DataTable)
        beads.add_columns("id", "type", "status", "title")
        beads.cursor_type = "row"

        summary = self.query_one("#summary", Static)
        if DISABLED:
            summary.update("[dim]AI summary disabled (GC_FEED_AI_DISABLE=1)[/dim]")
        else:
            summary.update(f"[dim]AI summary on. Model={MODEL}, every={EVERY} events / {INTERVAL}s. Press 's' to hide, 'a' to summarize now.[/dim]")
        self._set_summary_visible(self.show_summary)

        # Kick off background tasks.
        await self._refresh_state()
        await self._load_history()
        self.set_interval(8.0, self._refresh_state_sync)
        if not DISABLED:
            self.set_interval(2.0, self._maybe_summarize_sync)
        asyncio.create_task(self._tail_events())

    def _set_summary_visible(self, on: bool) -> None:
        try:
            w = self.query_one("#summary", Static)
            w.styles.display = "block" if on else "none"
        except Exception:
            pass

    def watch_show_summary(self, on: bool) -> None:
        self._set_summary_visible(on)

    def action_toggle_summary(self) -> None:
        self.show_summary = not self.show_summary

    def action_refresh(self) -> None:
        asyncio.create_task(self._refresh_state())

    def action_force_summary(self) -> None:
        if not DISABLED and not self.summarizing:
            asyncio.create_task(self._do_summarize())

    # --- background workers ---------------------------------------------

    def _refresh_state_sync(self) -> None:
        asyncio.create_task(self._refresh_state())

    def _maybe_summarize_sync(self) -> None:
        if self.summarizing:
            return
        if self.events_since_summary >= EVERY or (
            self.events_since_summary > 0
            and time.time() - self.last_summary_at >= INTERVAL
        ):
            asyncio.create_task(self._do_summarize())

    async def _refresh_state(self) -> None:
        try:
            sess_out = await run_gc("session", "list")
            beads_out = await run_gc("bd", "ready")
            status_out = await run_gc("supervisor", "status")
        except FileNotFoundError:
            return

        self._update_header(status_out)
        self._update_sessions(sess_out)
        self._update_beads(beads_out)

    def _update_header(self, supervisor_status: str) -> None:
        head = self.query_one("#header_status", Static)
        sup = supervisor_status.strip().split("\n")[0] if supervisor_status else "supervisor: ?"
        head.update(
            f"[b cyan]{os.path.basename(CITY_DIR)}[/b cyan]  "
            f"[dim]{CITY_DIR}[/dim]  │  [yellow]{sup}[/yellow]  │  "
            f"buffered=[b]{len(self.event_buf)}[/b]  pending=[b]{self.events_since_summary}[/b]"
        )

    def _update_sessions(self, gc_session_list_output: str) -> None:
        sess = self.query_one("#sessions", DataTable)
        sess.clear()
        for line in gc_session_list_output.splitlines()[1:]:
            parts = line.split()
            if len(parts) < 3:
                continue
            # ID TEMPLATE STATE [REASON] [TARGET] [TITLE] [AGE] [LAST ACTIVE]
            sid, tmpl, state = parts[0], parts[1], parts[2]
            last = " ".join(parts[-2:]) if len(parts) >= 5 else ""
            sess.add_row(f"{tmpl} ({sid})", state, last)

    def _update_beads(self, gc_bd_ready_output: str) -> None:
        beads = self.query_one("#beads", DataTable)
        beads.clear()
        for line in gc_bd_ready_output.splitlines():
            line = line.rstrip()
            if not line:
                continue
            # bd ready output: "  o gc-XXX ● P? title…"
            stripped = line.lstrip(" o●*")
            parts = stripped.split(maxsplit=2)
            if not parts:
                continue
            bid = parts[0]
            rest = parts[1] if len(parts) > 1 else ""
            title = parts[2] if len(parts) > 2 else ""
            beads.add_row(bid, "", rest, title[:60])

    async def _load_history(self) -> None:
        out = await run_gc("events", "--since", HISTORY_SINCE, timeout=15)
        log = self.query_one("#events", RichLog)
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            log.write(fmt_event(ev))
            self.event_buf.append(ev)
            self.events_since_summary += 1
        log.write(f"[dim]── live events follow ──[/dim]")

    async def _tail_events(self) -> None:
        self._tail_proc = await asyncio.create_subprocess_exec(
            "gc", "events", "--follow",
            cwd=CITY_DIR,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        log = self.query_one("#events", RichLog)
        assert self._tail_proc.stdout is not None
        async for raw in self._tail_proc.stdout:
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                log.write(line)
                continue
            log.write(fmt_event(ev))
            self.event_buf.append(ev)
            self.events_since_summary += 1

    async def _do_summarize(self) -> None:
        if self.summarizing or not self.event_buf:
            return
        self.summarizing = True
        snapshot = list(self.event_buf)
        self.events_since_summary = 0
        self.last_summary_at = time.time()
        summary_w = self.query_one("#summary", Static)
        summary_w.update("[dim]summarizing…[/dim]")
        t0 = time.time()
        text = await ollama_summarize(snapshot)
        secs = time.time() - t0
        ts = time.strftime("%H:%M:%S")
        summary_w.update(
            f"[b yellow]AI summary[/b yellow] [dim]({ts}, {secs:.1f}s, model={MODEL}, n={len(snapshot)})[/dim]\n"
            f"{text or '(no response)'}"
        )
        self.summarizing = False

    async def on_unmount(self) -> None:
        if self._tail_proc and self._tail_proc.returncode is None:
            self._tail_proc.terminate()
            try:
                await asyncio.wait_for(self._tail_proc.wait(), timeout=2)
            except asyncio.TimeoutError:
                self._tail_proc.kill()


if __name__ == "__main__":
    try:
        GCFeedApp().run()
    except KeyboardInterrupt:
        sys.exit(0)
