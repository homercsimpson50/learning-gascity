#!/usr/bin/env python3
"""
_gc_feed_tui.py — textual TUI for `gc events`, with periodic Ollama summary.

Wrapper-only — never touches the gc binary. Same behavior the user
previously got by patching gastown's feed (branch feat/agent-observability-tui),
re-implemented as an external process that subscribes to `gc events
--follow` and shells out to Ollama.

Layout:
  ┌─ header (city, supervisor status, buffer counters) ────┐
  ├─ sessions table  ┬─ events log (scrollable)            ┤
  ├─ beads table     │                                     │
  ├──────────────────┼─ AI summary stream (scrollable, ────┤
  │                  │  newest at bottom, focusable)       │
  └──────────────────┴─────────────────────────────────────┘

Keys:
  q quit
  s toggle AI summary panel
  a force a summary right now
  r refresh sessions/beads tables
  tab cycle focus (events ↔ summary)
  ↑/↓/j/k scroll focused panel
"""

import asyncio
import json
import os
import sys
import time
import urllib.request
from collections import deque
from typing import Optional, List

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
BUF_MAX = 80

# Claude Code session log location. Each project gets a directory under
# ~/.claude/projects/ named with the project path encoded as -Users-homer-gc.
# The active session is the JSONL with the newest mtime.
def claude_log_dir(city_dir: str) -> str:
    encoded = city_dir.replace("/", "-")
    return os.path.expanduser(f"~/.claude/projects/{encoded}")


# Actors and event types to skip in the feed (low-signal noise).
NOISE_ACTORS = {"cache-reconcile"}
NOISE_TYPES = {"controller.heartbeat"}

# Prompt copied from the gastown feat/agent-observability-tui branch.
SUMMARY_PROMPT = (
    "Summarize these software agent events in 1-2 SHORT sentences. "
    "Max 30 words. Say WHO is doing WHAT. No filler. No markdown formatting.\n\n"
    "Events:\n{events}\n\nSummary:"
)


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


def fmt_event_for_prompt(ev: dict) -> str:
    """Plain-text event line for the LLM prompt (matches gastown style)."""
    ts = ev.get("ts", "")[11:19]
    actor = ev.get("actor", "?")
    typ = ev.get("type", "?")
    subject = ev.get("subject", "")
    bead = (ev.get("payload") or {}).get("bead") or {}
    title = bead.get("title", "") if isinstance(bead, dict) else ""
    itype = bead.get("issue_type", "") if isinstance(bead, dict) else ""
    msg = ev.get("message", "")
    extra = " ".join(filter(None, [
        f"[{itype}]" if itype else "",
        f'"{title}"' if title else "",
        f"({msg})" if msg and msg != subject and msg != title else "",
    ]))
    return f"{ts} {actor}: {typ} {subject} {extra}".strip()


def is_noise(ev: dict) -> bool:
    if ev.get("actor") in NOISE_ACTORS:
        return True
    if ev.get("type") in NOISE_TYPES:
        return True
    return False


def _truncate(s: str, n: int = 80) -> str:
    s = (s or "").replace("\n", " ").strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def claude_to_event(rec: dict) -> Optional[dict]:
    """Translate a Claude Code session-log record into our event-dict shape so
    it can flow through the same renderer + summary buffer as gc events."""
    typ = rec.get("type")
    ts = rec.get("timestamp", "")
    msg = rec.get("message") or {}
    if not isinstance(msg, dict):
        msg = {}
    role = msg.get("role")

    if typ == "user":
        # user can be either a typed prompt OR a tool_result wrapped as user.
        content = msg.get("content")
        if isinstance(content, str):
            return {
                "ts": ts, "actor": "user", "type": "user.prompt",
                "subject": "", "message": _truncate(content, 160),
            }
        if isinstance(content, list):
            # tool_result: render as such
            for c in content:
                if isinstance(c, dict) and c.get("type") == "tool_result":
                    out = c.get("content")
                    if isinstance(out, list):
                        out = " ".join(
                            (x.get("text", "") if isinstance(x, dict) else str(x))
                            for x in out
                        )
                    return {
                        "ts": ts, "actor": "tool", "type": "tool.result",
                        "subject": "", "message": _truncate(str(out or ""), 120),
                    }
        return None

    if typ == "assistant" and role == "assistant":
        content = msg.get("content")
        if not isinstance(content, list):
            return None
        # One record can contain multiple content blocks; pick the most
        # informative one (tool_use > text > thinking).
        chosen = None
        for c in content:
            if not isinstance(c, dict):
                continue
            ct = c.get("type")
            if ct == "tool_use":
                chosen = c
                break
        if chosen is None:
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    chosen = c
                    break
        if chosen is None:
            for c in content:
                if isinstance(c, dict) and c.get("type") == "thinking":
                    chosen = c
                    break
        if chosen is None:
            return None
        ct = chosen.get("type")
        if ct == "tool_use":
            tool = chosen.get("name", "tool")
            inp = chosen.get("input") or {}
            # Pretty-print common tools the way gastown's summarize.go did.
            if tool == "Bash":
                line = f"$ {_truncate(inp.get('command', ''), 100)}"
            elif tool in ("Read", "Edit", "Write", "MultiEdit"):
                line = inp.get("file_path") or inp.get("path") or ""
                line = _truncate(line, 100)
            elif tool == "Grep":
                line = f"grep {_truncate(inp.get('pattern', ''), 80)}"
            elif tool == "Glob":
                line = _truncate(inp.get("pattern", ""), 100)
            elif tool == "TodoWrite":
                todos = inp.get("todos") or []
                line = f"{len(todos)} todos"
            else:
                # generic — first short input field
                line = ""
                for k, v in (inp or {}).items():
                    if isinstance(v, str) and v:
                        line = f"{k}={_truncate(v, 80)}"
                        break
            return {
                "ts": ts, "actor": "mayor", "type": f"tool.{tool}",
                "subject": "", "message": line,
            }
        if ct == "text":
            text = chosen.get("text", "")
            return {
                "ts": ts, "actor": "mayor", "type": "assistant.text",
                "subject": "", "message": _truncate(text, 160),
            }
        if ct == "thinking":
            return {
                "ts": ts, "actor": "mayor", "type": "assistant.thinking",
                "subject": "",
                "message": _truncate(chosen.get("thinking", ""), 120),
            }
    return None


def fmt_claude_event(ev: dict) -> str:
    """Rich-markup line for an event we got from Claude's log."""
    ts = ev.get("ts", "")[11:19]
    actor = ev.get("actor", "?")
    typ = ev.get("type", "?")
    msg = ev.get("message", "")
    color = {
        "mayor": "green",
        "user": "magenta",
        "tool": "blue",
    }.get(actor, "white")
    return (
        f"[dim]{ts}[/dim] "
        f"[{color}]{actor:<8}[/{color}] "
        f"[cyan]{typ:<22}[/cyan] {msg}"
    )


async def run_gc(*args: str, timeout: float = 10.0) -> str:
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


async def ollama_summarize(events: List[dict]) -> Optional[tuple]:
    """Returns (text, secs, tokens) or None."""
    if not events:
        return None
    lines = [fmt_event_for_prompt(e) for e in events]
    prompt = SUMMARY_PROMPT.format(events="\n".join(lines))

    def _call():
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
        # Strip leading newlines (gastown bug fix carry-over).
        text = text.lstrip("\n").strip()
        secs = resp.get("total_duration", 0) / 1e9
        tokens = resp.get("eval_count", 0)
        return (text, secs, tokens)

    return await asyncio.to_thread(_call)


class GCFeedApp(App):
    CSS = """
    Screen { layout: vertical; }

    #header_status { height: 1; padding: 0 1; background: $boost; }

    #top { height: 1fr; }
    #left { width: 36%; }
    #right { width: 64%; border-left: solid $accent; }

    DataTable { height: 1fr; }
    #sessions { height: 50%; }
    #beads { height: 50%; }

    #events_panel { height: 1fr; }
    #summary_panel { height: 14; border-top: solid $warning; }

    #events { height: 1fr; }
    #summary { height: 1fr; }

    .focused { border: heavy $success; }
    """

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("ctrl+c", "quit", "Quit", show=False),
        Binding("s", "toggle_summary", "Toggle AI"),
        Binding("a", "force_summary", "Now"),
        Binding("r", "refresh", "Refresh"),
        Binding("tab", "cycle_focus", "Focus →"),
        Binding("up", "scroll_up", show=False),
        Binding("down", "scroll_down", show=False),
        Binding("j", "scroll_down", show=False),
        Binding("k", "scroll_up", show=False),
        Binding("pageup", "page_up", show=False),
        Binding("pagedown", "page_down", show=False),
        Binding("home", "scroll_home", show=False),
        Binding("end", "scroll_end", show=False),
    ]

    show_summary: reactive[bool] = reactive(not DISABLED)

    def __init__(self) -> None:
        super().__init__()
        self.event_buf: deque = deque(maxlen=BUF_MAX)
        self.events_since_summary = 0
        self.last_summary_at = time.time()
        self.summarizing = False
        self._tail_proc: Optional[asyncio.subprocess.Process] = None
        self._claude_tail_proc: Optional[asyncio.subprocess.Process] = None
        self._current_claude_log: Optional[str] = None
        self.focused_panel = "events"  # or "summary"

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield Static(id="header_status")
        with Horizontal(id="top"):
            with Vertical(id="left"):
                yield DataTable(id="sessions", zebra_stripes=True)
                yield DataTable(id="beads", zebra_stripes=True)
            with Vertical(id="right"):
                with Vertical(id="events_panel"):
                    yield RichLog(
                        id="events", highlight=False, markup=True,
                        wrap=False, max_lines=2000,
                    )
                with Vertical(id="summary_panel"):
                    yield RichLog(
                        id="summary", highlight=False, markup=True,
                        wrap=True, max_lines=200,
                    )
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

        summary = self.query_one("#summary", RichLog)
        if DISABLED:
            summary.write("[dim]AI summary disabled (GC_FEED_AI_DISABLE=1)[/dim]")
        else:
            summary.write(
                f"[dim]AI summary on. Model={MODEL}, every={EVERY} events / "
                f"{INTERVAL}s. Press 's' to hide, 'a' to summarize now, "
                f"tab to focus this panel, j/k to scroll.[/dim]"
            )

        self._set_summary_visible(self.show_summary)
        self._update_focus_styles()

        await self._refresh_state()
        await self._load_history()
        self.set_interval(8.0, lambda: asyncio.create_task(self._refresh_state()))
        # Re-pick the claude log every 30s so a session restart is picked up.
        self.set_interval(30.0, lambda: asyncio.create_task(self._maybe_repoint_claude_tail()))
        if not DISABLED:
            self.set_interval(2.0, self._maybe_summarize_sync)
        asyncio.create_task(self._tail_events())
        asyncio.create_task(self._tail_claude_log())

    # --- panels ---------------------------------------------------------

    def _set_summary_visible(self, on: bool) -> None:
        try:
            panel = self.query_one("#summary_panel", Vertical)
            panel.styles.display = "block" if on else "none"
        except Exception:
            pass

    def watch_show_summary(self, on: bool) -> None:
        self._set_summary_visible(on)

    def _focused_widget(self):
        wid = "events" if self.focused_panel == "events" else "summary"
        return self.query_one(f"#{wid}", RichLog)

    def _update_focus_styles(self) -> None:
        for name in ("events", "summary"):
            try:
                w = self.query_one(f"#{name}", RichLog)
                if name == self.focused_panel:
                    w.add_class("focused")
                else:
                    w.remove_class("focused")
            except Exception:
                pass

    # --- actions --------------------------------------------------------

    def action_toggle_summary(self) -> None:
        self.show_summary = not self.show_summary
        if not self.show_summary and self.focused_panel == "summary":
            self.focused_panel = "events"
            self._update_focus_styles()

    def action_refresh(self) -> None:
        asyncio.create_task(self._refresh_state())

    def action_force_summary(self) -> None:
        if not DISABLED and not self.summarizing:
            asyncio.create_task(self._do_summarize())

    def action_cycle_focus(self) -> None:
        if self.focused_panel == "events" and self.show_summary:
            self.focused_panel = "summary"
        else:
            self.focused_panel = "events"
        self._update_focus_styles()

    def action_scroll_up(self) -> None:
        self._focused_widget().scroll_up()

    def action_scroll_down(self) -> None:
        self._focused_widget().scroll_down()

    def action_page_up(self) -> None:
        self._focused_widget().scroll_page_up()

    def action_page_down(self) -> None:
        self._focused_widget().scroll_page_down()

    def action_scroll_home(self) -> None:
        self._focused_widget().scroll_home()

    def action_scroll_end(self) -> None:
        self._focused_widget().scroll_end()

    # --- background workers --------------------------------------------

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
        sup_line = (supervisor_status.strip().split("\n", 1)[0]
                    if supervisor_status else "supervisor: ?")
        ai = "off" if DISABLED else (
            f"on • {MODEL} • every {EVERY}/{INTERVAL}s")
        head.update(
            f"[b cyan]{os.path.basename(CITY_DIR)}[/b cyan]  "
            f"[dim]{CITY_DIR}[/dim]  │  [yellow]{sup_line}[/yellow]  │  "
            f"buf=[b]{len(self.event_buf)}[/b]  pending=[b]{self.events_since_summary}[/b]  │  "
            f"AI: [magenta]{ai}[/magenta]"
        )

    def _update_sessions(self, gc_session_list_output: str) -> None:
        sess = self.query_one("#sessions", DataTable)
        sess.clear()
        for line in gc_session_list_output.splitlines()[1:]:
            parts = line.split()
            if len(parts) < 3:
                continue
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
        added = 0
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if is_noise(ev):
                continue
            log.write(fmt_event(ev))
            self.event_buf.append(ev)
            self.events_since_summary += 1
            added += 1
        log.write(f"[dim]── {added} historical events; live follows ──[/dim]")

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
            if is_noise(ev):
                continue
            log.write(fmt_event(ev))
            self.event_buf.append(ev)
            self.events_since_summary += 1

    def _newest_claude_log(self) -> Optional[str]:
        d = claude_log_dir(CITY_DIR)
        if not os.path.isdir(d):
            return None
        candidates = []
        for name in os.listdir(d):
            if name.endswith(".jsonl"):
                p = os.path.join(d, name)
                try:
                    candidates.append((os.path.getmtime(p), p))
                except OSError:
                    pass
        if not candidates:
            return None
        candidates.sort(reverse=True)
        return candidates[0][1]

    async def _tail_claude_log(self) -> None:
        path = self._newest_claude_log()
        if not path:
            log = self.query_one("#events", RichLog)
            log.write(f"[dim]── no claude log at {claude_log_dir(CITY_DIR)} (yet) ──[/dim]")
            return
        await self._start_claude_tail(path)

    async def _start_claude_tail(self, path: str) -> None:
        if self._claude_tail_proc and self._claude_tail_proc.returncode is None:
            self._claude_tail_proc.terminate()
            try:
                await asyncio.wait_for(self._claude_tail_proc.wait(), 1)
            except asyncio.TimeoutError:
                self._claude_tail_proc.kill()
        self._current_claude_log = path
        log = self.query_one("#events", RichLog)
        log.write(f"[dim]── tailing claude log: {os.path.basename(path)} ──[/dim]")
        # tail -n 20 = show last few records as warm-up; -F follows rotation.
        self._claude_tail_proc = await asyncio.create_subprocess_exec(
            "tail", "-n", "20", "-F", path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        assert self._claude_tail_proc.stdout is not None
        async for raw in self._claude_tail_proc.stdout:
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            ev = claude_to_event(rec)
            if not ev:
                continue
            log.write(fmt_claude_event(ev))
            self.event_buf.append(ev)
            self.events_since_summary += 1

    async def _maybe_repoint_claude_tail(self) -> None:
        """If a newer log file has appeared (session restart), retarget."""
        latest = self._newest_claude_log()
        if latest and latest != self._current_claude_log:
            asyncio.create_task(self._start_claude_tail(latest))

    async def _do_summarize(self) -> None:
        if self.summarizing or not self.event_buf:
            return
        self.summarizing = True
        snapshot = list(self.event_buf)
        self.events_since_summary = 0
        self.last_summary_at = time.time()
        summary_w = self.query_one("#summary", RichLog)
        summary_w.write("[dim]summarizing…[/dim]")
        result = await ollama_summarize(snapshot)
        if result:
            text, secs, tokens = result
            ts = time.strftime("%H:%M:%S")
            summary_w.write(
                f"[b yellow]{ts}[/b yellow] [dim]({secs:.1f}s, {tokens}t, n={len(snapshot)})[/dim]"
            )
            summary_w.write(text or "(no response)")
            summary_w.write("")  # spacer
        self.summarizing = False

    async def on_unmount(self) -> None:
        for proc in (self._tail_proc, self._claude_tail_proc):
            if proc and proc.returncode is None:
                proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), timeout=2)
                except asyncio.TimeoutError:
                    proc.kill()


if __name__ == "__main__":
    try:
        GCFeedApp().run()
    except KeyboardInterrupt:
        sys.exit(0)
