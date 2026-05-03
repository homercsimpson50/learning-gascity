#!/usr/bin/env python3
"""
_gc_feed_tui.py — textual TUI for `gc events` + Claude Code session logs,
with periodic Ollama summary. Wrapper-only — never touches the gc binary.

Layout:
  ┌─ header (city, supervisor, counters) ──────────────────────────┐
  ├─ Rigs (top-left)        │ events log (right top)               │
  │   (all rigs)            │  scrollable, follows the active rig  │
  │   gc (HQ)               │                                      │
  │   foo                   ├─ AI summary (right bottom) ──────────┤
  ├─ Mayor's todos (bot-left)│  rolling, follows the active rig    │
  └────────────────────────────────────────────────────────────────┘

Keys:
  q            quit
  s            toggle AI summary panel
  a            force a summary right now
  r            refresh rigs/todos
  tab          cycle focus  (rigs ↔ events ↔ summary)
  ↑/↓ / j/k    move highlight in the rigs table OR scroll a panel
  enter        switch the right panels to the highlighted rig
  pageup/dn    scroll faster
  home/end     scroll to top / bottom
"""

import asyncio
import json
import os
import shutil
import sys
import textwrap
import time
import urllib.request
from collections import deque
from typing import Optional, List, Dict, Tuple

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


def claude_log_dir(work_dir: str) -> str:
    """Map a session/rig cwd to its Claude Code project log directory."""
    encoded = work_dir.replace("/", "-")
    return os.path.expanduser(f"~/.claude/projects/{encoded}")


# Show everything *except* the explicitly noisy types/prefixes below.
NOISE_ACTORS = {"cache-reconcile"}
NOISE_TYPES = {"controller.heartbeat", "user.prompt"}
NOISE_TYPE_PREFIXES = ("session.",)

SUMMARY_PROMPT = (
    "You are summarizing live activity from a multi-agent coding system "
    "(Gas City). Below are recent events: agent tool calls (Bash, Read, "
    "Edit, Write, etc.), assistant text, and supervisor lifecycle events. "
    "User lines are direction given to the agents, not work. "
    "Write a 2-3 sentence summary of WHAT THE AGENTS ARE DOING right now "
    "(start with 'Mayor is …' or '<agent-name> is …'). "
    "Mention specific files, commands, or topics when present. "
    "Be concrete. No filler, no markdown, never say 'the user'.\n\n"
    "Scope: {scope}\n"
    "Events (oldest to newest):\n{events}\n\nSummary:"
)


# --- event formatting -------------------------------------------------------

# Standard column widths for both gc events and claude events.
# Layout: ts | actor | message | [type]   — type is moved to the right
# so the message gets the prime real estate and the type sits as a
# trailing annotation.
COL_ACTOR = 10

def _fmt_row(ts: str, actor: str, typ: str, msg: str, actor_color: str = "white") -> str:
    return (f"[dim]{ts}[/dim] "
            f"[{actor_color}]{actor:<{COL_ACTOR}}[/{actor_color}] "
            f"{msg} "
            f"[dim cyan]\\[{typ}][/dim cyan]")


def fmt_event(ev: dict) -> str:
    """One-line, rich-markup form of a gc API event. Same column layout
    as fmt_claude_event below so the events log stays aligned."""
    ts = ev.get("ts", "")[11:19]
    typ = ev.get("type", "?")
    actor = ev.get("actor", "?") or "-"
    subject = ev.get("subject", "")
    msg = ev.get("message", "")
    bead = (ev.get("payload") or {}).get("bead") or {}

    extras = []
    if subject:
        extras.append(subject)
    if isinstance(bead, dict):
        title = bead.get("title", "")
        itype = bead.get("issue_type", "")
        state = bead.get("status", "")
        meta = bead.get("metadata") or {}
        sess_state = meta.get("state") if isinstance(meta, dict) else None
        if itype: extras.append(f"[yellow]{itype}[/yellow]")
        if state: extras.append(state)
        if sess_state and sess_state != state: extras.append(f"→{sess_state}")
        if title:  extras.append(f'[italic]"{title}"[/italic]')
    if msg and msg != subject:
        extras.append(f"[dim]({msg})[/dim]")

    return _fmt_row(ts, actor[:COL_ACTOR], typ, " ".join(extras))


def fmt_event_for_prompt(ev: dict) -> str:
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
    typ = ev.get("type", "")
    if typ in NOISE_TYPES:
        return True
    for p in NOISE_TYPE_PREFIXES:
        if typ.startswith(p):
            return True
    return False


def _truncate(s: str, n: int = 80) -> str:
    s = (s or "").replace("\n", " ").strip()
    return s if len(s) <= n else s[: n - 1] + "…"


# --- claude log → event dict -----------------------------------------------

def _block_to_event(ts: str, actor: str, c: dict) -> Optional[dict]:
    if not isinstance(c, dict):
        return None
    ct = c.get("type")
    if ct == "tool_use":
        tool = c.get("name", "tool")
        inp = c.get("input") or {}
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
        elif tool == "Task":
            line = _truncate(inp.get("description", ""), 100)
        else:
            line = ""
            for k, v in (inp or {}).items():
                if isinstance(v, str) and v:
                    line = f"{k}={_truncate(v, 80)}"
                    break
        return {"ts": ts, "actor": actor, "type": f"tool.{tool}",
                "subject": "", "message": line, "_tool": tool, "_input": inp}
    if ct == "text":
        return {"ts": ts, "actor": actor, "type": "assistant.text",
                "subject": "", "message": _truncate(c.get("text", ""), 200)}
    if ct == "thinking":
        text = c.get("thinking", "")
        if not text:
            return None
        return {"ts": ts, "actor": actor, "type": "assistant.thinking",
                "subject": "", "message": _truncate(text, 160)}
    if ct == "tool_result":
        out = c.get("content")
        if isinstance(out, list):
            out = " ".join(
                (x.get("text", "") if isinstance(x, dict) else str(x))
                for x in out
            )
        return {"ts": ts, "actor": "tool", "type": "tool.result",
                "subject": "", "message": _truncate(str(out or ""), 120)}
    return None


def claude_to_events(rec: dict, default_actor: str = "mayor") -> List[dict]:
    typ = rec.get("type")
    ts = rec.get("timestamp", "")
    msg = rec.get("message") or {}
    if not isinstance(msg, dict):
        msg = {}
    role = msg.get("role")

    if typ == "user":
        content = msg.get("content")
        if isinstance(content, str):
            return [{"ts": ts, "actor": "user", "type": "user.prompt",
                     "subject": "", "message": _truncate(content, 200)}]
        if isinstance(content, list):
            out = []
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    out.append({"ts": ts, "actor": "user",
                                "type": "user.prompt", "subject": "",
                                "message": _truncate(c.get("text", ""), 200)})
                else:
                    ev = _block_to_event(ts, "user", c)
                    if ev:
                        out.append(ev)
            return out
        return []

    if typ == "assistant" and role == "assistant":
        content = msg.get("content")
        if not isinstance(content, list):
            return []
        return [e for c in content for e in [_block_to_event(ts, default_actor, c)] if e]

    return []


def fmt_claude_event(ev: dict) -> str:
    ts = ev.get("ts", "")[11:19]
    actor = ev.get("actor", "?") or "-"
    typ = ev.get("type", "?")
    msg = ev.get("message", "")
    color = {
        "mayor": "green",
        "user":  "magenta",
        "tool":  "blue",
    }.get(actor, "white")
    return _fmt_row(ts, actor[:COL_ACTOR], typ, msg, color)


# --- gc helpers ------------------------------------------------------------

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


async def get_rigs() -> List[Dict]:
    out = await run_gc("rig", "list", "--json", timeout=10)
    try:
        data = json.loads(out)
    except Exception:
        return []
    return data.get("rigs") or []


async def ollama_summarize(events: List[dict], scope: str) -> Optional[Tuple[str, float, int]]:
    if not events:
        return None
    lines = [fmt_event_for_prompt(e) for e in events]
    prompt = SUMMARY_PROMPT.format(events="\n".join(lines), scope=scope)

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
        text = (resp.get("response") or "").strip().lstrip("\n").strip()
        secs = resp.get("total_duration", 0) / 1e9
        tokens = resp.get("eval_count", 0)
        return (text, secs, tokens)

    return await asyncio.to_thread(_call)


# --- multi-file claude tailer ----------------------------------------------

class FileTailer:
    """Tracks one .jsonl file: open fp + offset + inode. Yields parsed
    records on each .read_new() call."""
    def __init__(self, path: str):
        self.path = path
        self.fp = open(path, "r", encoding="utf-8", errors="replace")
        self.fp.seek(0, os.SEEK_END)
        end = self.fp.tell()
        # Backfill last ~32KB so a freshly-attached tailer has context.
        self.fp.seek(max(0, end - 32768))
        if end > 32768:
            self.fp.readline()
        self.offset = self.fp.tell()
        try:
            self.inode = os.fstat(self.fp.fileno()).st_ino
        except OSError:
            self.inode = None

    def close(self):
        try:
            self.fp.close()
        except Exception:
            pass

    def read_new(self) -> List[dict]:
        records: List[dict] = []
        try:
            st = os.stat(self.path)
            if st.st_ino != self.inode or st.st_size < self.offset:
                self.fp.close()
                self.fp = open(self.path, "r", encoding="utf-8", errors="replace")
                self.offset = 0
                self.inode = os.fstat(self.fp.fileno()).st_ino
        except OSError:
            return records

        self.fp.seek(self.offset)
        while True:
            line = self.fp.readline()
            if not line:
                break
            if not line.endswith("\n"):
                break
            self.offset = self.fp.tell()
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return records


# --- the app ----------------------------------------------------------------

class GCFeedApp(App):
    CSS = """
    Screen { layout: vertical; }
    #header_status { height: 1; padding: 0 1; background: $boost; }

    #top { height: 1fr; }
    #left  { width: 36%; }
    #right { width: 64%; border-left: solid $accent; }

    #rigs     { height: 50%; }
    #sessions { height: 50%; border-top: solid $accent; }

    #events  { height: 1fr; }
    #summary { height: 12; border-top: solid $warning; }

    DataTable { height: 1fr; }

    .focused { border: heavy $success; }
    """

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("ctrl+c", "quit", "Quit", show=False),
        Binding("s", "toggle_summary", "Toggle AI"),
        Binding("a", "force_summary", "Now"),
        Binding("r", "refresh", "Refresh"),
        Binding("tab", "cycle_focus", "Focus →"),
        Binding("enter", "select_rig", "Pick rig"),
        Binding("up", "scroll_or_move(-1)", show=False),
        Binding("down", "scroll_or_move(1)", show=False),
        Binding("j", "scroll_or_move(1)", show=False),
        Binding("k", "scroll_or_move(-1)", show=False),
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
        self.focused_panel = "rigs"  # rigs | events | summary
        self._bg_tasks: list = []
        self.claude_seen = 0

        # Rig model. None == "(all rigs)" (merge HQ + every rig).
        self.rigs: List[Dict] = []
        self.current_rig_path: Optional[str] = None
        self.current_rig_label: str = "(all rigs)"

        # Active claude tailers, keyed by file path.
        self._tailers: Dict[str, FileTailer] = {}

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield Static(id="header_status")
        with Horizontal(id="top"):
            with Vertical(id="left"):
                yield DataTable(id="rigs", zebra_stripes=True)
                yield DataTable(id="sessions", zebra_stripes=True)
            with Vertical(id="right"):
                yield RichLog(id="events", highlight=False, markup=True,
                              wrap=False, max_lines=2000)
                yield RichLog(id="summary", highlight=False, markup=True,
                              wrap=True, max_lines=400)
        yield Footer()

    async def on_mount(self) -> None:
        self.title = f"gc feed — {os.path.basename(CITY_DIR)}"
        self.sub_title = CITY_DIR

        rigs_t = self.query_one("#rigs", DataTable)
        rigs_t.add_columns("rig", "path")
        rigs_t.cursor_type = "row"
        rigs_t.add_row("(all rigs)", "merged stream")

        sess_t = self.query_one("#sessions", DataTable)
        sess_t.add_columns("session", "agent", "state", "last")
        sess_t.cursor_type = "row"

        summary_w = self.query_one("#summary", RichLog)
        summary_w.write(
            f"[dim]AI summary on. Model={MODEL}, every={EVERY} events / "
            f"{INTERVAL}s. Press 's' to hide, 'a' to summarize now, "
            f"tab to cycle focus, j/k to scroll.[/dim]"
        ) if not DISABLED else summary_w.write(
            "[dim]AI summary disabled (GC_FEED_AI_DISABLE=1)[/dim]")

        self._set_summary_visible(self.show_summary)
        self._update_focus_styles()

        await self._refresh_rigs()
        await self._refresh_state()
        # Default scope = all rigs.
        await self._switch_rig(None, "(all rigs)", flush=False)

        self.set_interval(8.0, lambda: self._spawn(self._refresh_state()))
        self.set_interval(15.0, lambda: self._spawn(self._refresh_rigs()))
        self.set_interval(5.0, lambda: self._spawn(self._refresh_sessions()))
        self.set_interval(0.5,  lambda: self._spawn(self._poll_tailers()))
        if not DISABLED:
            self.set_interval(2.0, self._maybe_summarize_sync)
        self._spawn(self._tail_events())

    # --- tasking --------------------------------------------------------

    def _spawn(self, coro):
        task = asyncio.create_task(coro)
        self._bg_tasks.append(task)
        def _done(t: asyncio.Task) -> None:
            try: self._bg_tasks.remove(t)
            except ValueError: pass
            if t.cancelled(): return
            exc = t.exception()
            if exc is not None:
                try:
                    log = self.query_one("#events", RichLog)
                    log.write(f"[red]task error: {type(exc).__name__}: {exc}[/red]")
                except Exception:
                    pass
        task.add_done_callback(_done)
        return task

    # --- rigs panel & rig selection ------------------------------------

    async def _refresh_rigs(self) -> None:
        try:
            rigs = await get_rigs()
        except Exception as e:
            self._note_err(f"rig list failed: {e}")
            return
        # Preserve current cursor if possible.
        rigs_t = self.query_one("#rigs", DataTable)
        prev_cursor = rigs_t.cursor_row
        rigs_t.clear(columns=False)
        rigs_t.add_row("(all rigs)", "merged stream")
        for r in rigs:
            label = r.get("name", "?")
            if r.get("hq"):
                label = f"{label} (HQ)"
            rigs_t.add_row(label, r.get("path", ""))
        self.rigs = rigs
        # Keep cursor in range.
        if prev_cursor is not None and prev_cursor < rigs_t.row_count:
            rigs_t.move_cursor(row=prev_cursor)

    def _highlighted_rig(self) -> Tuple[Optional[str], str]:
        """Return (path, label) for currently highlighted row in rigs table.
        path == None means '(all rigs)'."""
        rigs_t = self.query_one("#rigs", DataTable)
        idx = rigs_t.cursor_row or 0
        if idx <= 0 or idx > len(self.rigs):
            return None, "(all rigs)"
        r = self.rigs[idx - 1]
        label = r.get("name", "?")
        if r.get("hq"):
            label = f"{label} (HQ)"
        return r.get("path"), label

    async def _switch_rig(self, path: Optional[str], label: str, flush: bool = True) -> None:
        """Re-target right-side panels to scope (path == None means all)."""
        self.current_rig_path = path
        self.current_rig_label = label

        if flush:
            self.event_buf.clear()
            self.events_since_summary = 0
            try:
                self.query_one("#events", RichLog).clear()
                self.query_one("#summary", RichLog).clear()
            except Exception:
                pass
        # Re-scope the sessions table to the new rig.
        self._spawn(self._refresh_sessions())

        # Decide which dirs to watch.
        dirs_to_watch: List[str] = []
        if path is None:
            # All: HQ + every rig path.
            seen = set()
            seen.add(CITY_DIR)
            dirs_to_watch.append(claude_log_dir(CITY_DIR))
            for r in self.rigs:
                p = r.get("path")
                if p and p not in seen:
                    seen.add(p)
                    dirs_to_watch.append(claude_log_dir(p))
        else:
            dirs_to_watch.append(claude_log_dir(path))

        # Close existing tailers and rebuild for the new scope.
        for t in self._tailers.values():
            t.close()
        self._tailers = {}
        self._dirs_to_watch = dirs_to_watch
        log = self.query_one("#events", RichLog)
        log.write(f"[dim]── scope: {label} — watching {len(dirs_to_watch)} log dir(s) ──[/dim]")

    async def _poll_tailers(self) -> None:
        """Discover new .jsonl files in watched dirs and read any new lines."""
        log = self.query_one("#events", RichLog)
        # Discover new files.
        for d in getattr(self, "_dirs_to_watch", []):
            if not os.path.isdir(d):
                continue
            for name in os.listdir(d):
                if not name.endswith(".jsonl"):
                    continue
                p = os.path.join(d, name)
                if p in self._tailers:
                    continue
                try:
                    self._tailers[p] = FileTailer(p)
                    log.write(f"[dim]── tailing {os.path.basename(d)}/{name} ──[/dim]")
                except OSError as e:
                    self._note_err(f"open {p}: {e}")
        # Read new records from each tailer.
        for path, tailer in list(self._tailers.items()):
            try:
                records = tailer.read_new()
            except OSError as e:
                self._note_err(f"read {path}: {e}")
                continue
            for rec in records:
                self.claude_seen += 1
                actor = self._actor_for_path(path)
                for ev in claude_to_events(rec, default_actor=actor):
                    if is_noise(ev):
                        continue
                    log.write(fmt_claude_event(ev))
                    self.event_buf.append(ev)
                    self.events_since_summary += 1

    def _actor_for_path(self, log_file_path: str) -> str:
        """Best-effort: derive a short actor name from the log file's parent
        directory (the encoded cwd). HQ → 'mayor'; otherwise, last segment
        of the cwd."""
        d = os.path.basename(os.path.dirname(log_file_path))  # encoded cwd
        # decode: -Users-foo-gc → /Users/foo/gc
        cwd = d.replace("-", "/")
        if cwd == CITY_DIR or cwd.endswith("/gc"):
            return "mayor"
        # Pick rig name if known.
        for r in self.rigs:
            if r.get("path") == cwd:
                return r.get("name", "agent")
        return os.path.basename(cwd) or "agent"

    # --- actions --------------------------------------------------------

    def action_toggle_summary(self) -> None:
        self.show_summary = not self.show_summary
        if not self.show_summary and self.focused_panel == "summary":
            self.focused_panel = "events"
            self._update_focus_styles()

    def action_refresh(self) -> None:
        self._spawn(self._refresh_state())
        self._spawn(self._refresh_rigs())

    def action_force_summary(self) -> None:
        if not DISABLED and not self.summarizing:
            self._spawn(self._do_summarize())

    def action_cycle_focus(self) -> None:
        order = ["rigs", "events"]
        if self.show_summary:
            order.append("summary")
        try:
            i = order.index(self.focused_panel)
        except ValueError:
            i = 0
        self.focused_panel = order[(i + 1) % len(order)]
        self._update_focus_styles()

    def action_select_rig(self) -> None:
        # Enter still works as an explicit re-select (forces a flush).
        if self.focused_panel != "rigs":
            return
        path, label = self._highlighted_rig()
        self._spawn(self._switch_rig(path, label, flush=True))

    def on_data_table_row_highlighted(self, event) -> None:
        """Auto-switch scope as soon as the cursor lands on a row in the
        rigs table — no Enter required."""
        try:
            if event.data_table.id != "rigs":
                return
        except Exception:
            return
        path, label = self._highlighted_rig()
        # Avoid redundant switches when the highlighted rig hasn't changed.
        if path == self.current_rig_path and label == self.current_rig_label:
            return
        self._spawn(self._switch_rig(path, label, flush=True))

    def action_scroll_or_move(self, direction: int) -> None:
        if self.focused_panel == "rigs":
            t = self.query_one("#rigs", DataTable)
            if direction < 0:
                t.action_cursor_up()
            else:
                t.action_cursor_down()
        else:
            w = self._focused_log()
            if direction < 0: w.scroll_up()
            else: w.scroll_down()

    def action_page_up(self) -> None:
        if self.focused_panel != "rigs":
            self._focused_log().scroll_page_up()

    def action_page_down(self) -> None:
        if self.focused_panel != "rigs":
            self._focused_log().scroll_page_down()

    def action_scroll_home(self) -> None:
        if self.focused_panel != "rigs":
            self._focused_log().scroll_home()

    def action_scroll_end(self) -> None:
        if self.focused_panel != "rigs":
            self._focused_log().scroll_end()

    # --- focus / layout helpers ----------------------------------------

    def _focused_log(self) -> RichLog:
        wid = "events" if self.focused_panel != "summary" else "summary"
        return self.query_one(f"#{wid}", RichLog)

    def _update_focus_styles(self) -> None:
        for name, cls in (("rigs", DataTable), ("events", RichLog), ("summary", RichLog)):
            try:
                w = self.query_one(f"#{name}", cls)
                if name == self.focused_panel:
                    w.add_class("focused")
                else:
                    w.remove_class("focused")
            except Exception:
                pass

    def _set_summary_visible(self, on: bool) -> None:
        try:
            self.query_one("#summary", RichLog).styles.display = "block" if on else "none"
        except Exception:
            pass

    def watch_show_summary(self, on: bool) -> None:
        self._set_summary_visible(on)

    def _note_err(self, msg: str) -> None:
        try:
            self.query_one("#events", RichLog).write(f"[red]{msg}[/red]")
        except Exception:
            pass

    # --- supervisor refresh / header ----------------------------------

    async def _refresh_state(self) -> None:
        try:
            status_out = await run_gc("supervisor", "status")
        except FileNotFoundError:
            return
        self._update_header(status_out)

    def _update_header(self, supervisor_status: str) -> None:
        head = self.query_one("#header_status", Static)
        sup_line = (supervisor_status.strip().split("\n", 1)[0]
                    if supervisor_status else "supervisor: ?")
        ai = "off" if DISABLED else f"on • {MODEL} • every {EVERY}/{INTERVAL}s"
        head.update(
            f"[b cyan]{os.path.basename(CITY_DIR)}[/b cyan]  "
            f"[dim]scope: {self.current_rig_label}[/dim]  │  "
            f"[yellow]{sup_line}[/yellow]  │  "
            f"buf=[b]{len(self.event_buf)}[/b]  pending=[b]{self.events_since_summary}[/b]  "
            f"claude=[b]{self.claude_seen}[/b]  │  "
            f"AI: [magenta]{ai}[/magenta]"
        )

    # --- summary ------------------------------------------------------

    def _maybe_summarize_sync(self) -> None:
        if self.summarizing:
            return
        if self.events_since_summary >= EVERY or (
            self.events_since_summary > 0
            and time.time() - self.last_summary_at >= INTERVAL
        ):
            self._spawn(self._do_summarize())

    def _summary_wrap_width(self) -> int:
        try:
            w = self.query_one("#summary", RichLog).size.width
            if w and w > 10:
                return max(20, w - 2)
        except Exception:
            pass
        return max(40, shutil.get_terminal_size((80, 24)).columns - 50)

    async def _do_summarize(self) -> None:
        if self.summarizing or not self.event_buf:
            return
        self.summarizing = True
        snapshot = list(self.event_buf)
        self.events_since_summary = 0
        self.last_summary_at = time.time()
        summary_w = self.query_one("#summary", RichLog)
        summary_w.write("[dim]summarizing…[/dim]")
        result = await ollama_summarize(snapshot, scope=self.current_rig_label)
        if result:
            text, secs, tokens = result
            ts = time.strftime("%H:%M:%S")
            summary_w.write(
                f"[b yellow]{ts}[/b yellow] [dim]({secs:.1f}s, {tokens}t, "
                f"n={len(snapshot)}, scope={self.current_rig_label})[/dim]"
            )
            width = self._summary_wrap_width()
            for line in (text or "(no response)").splitlines() or [""]:
                wrapped = textwrap.wrap(line, width=width) or [""]
                for w in wrapped:
                    summary_w.write(w)
            summary_w.write("")
        self.summarizing = False

    # --- gc events tail ------------------------------------------------

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

    # --- sessions panel ------------------------------------------------

    async def _refresh_sessions(self) -> None:
        """Populate the sessions table with rows scoped to the current rig.
        Source: `gc session list --json`. When scope is "(all rigs)", show
        every session; otherwise filter by WorkDir == rig path."""
        out = await run_gc("session", "list", "--json", "--state", "all", timeout=10)
        try:
            sessions = json.loads(out) if out.strip() else []
        except Exception:
            sessions = []

        scope_path = self.current_rig_path
        if scope_path is not None:
            sessions = [s for s in sessions if s.get("WorkDir") == scope_path]

        try:
            t = self.query_one("#sessions", DataTable)
        except Exception:
            return
        prev = t.cursor_row
        t.clear(columns=False)
        if not sessions:
            t.add_row("(none)", "", "", "")
        else:
            for s in sessions:
                sid = s.get("ID", "?")
                tmpl = s.get("Template") or s.get("AgentName") or "?"
                state = s.get("State") or "?"
                last = s.get("LastActive", "") or ""
                # last → just HH:MM:SS
                if "T" in last:
                    last = last.split("T", 1)[1][:8]
                t.add_row(sid, tmpl, state, last)
        if prev is not None and prev < t.row_count:
            t.move_cursor(row=prev)

    # --- teardown -----------------------------------------------------

    async def on_unmount(self) -> None:
        if self._tail_proc and self._tail_proc.returncode is None:
            self._tail_proc.terminate()
            try:
                await asyncio.wait_for(self._tail_proc.wait(), timeout=2)
            except asyncio.TimeoutError:
                self._tail_proc.kill()
        for t in self._tailers.values():
            t.close()


if __name__ == "__main__":
    try:
        GCFeedApp().run()
    except KeyboardInterrupt:
        sys.exit(0)
