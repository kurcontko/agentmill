#!/usr/bin/env python3
"""Codex Engine Dashboard — multi-agent grid TUI-style preview server with SSE streaming."""
from __future__ import annotations

import argparse
import json
import queue
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


# ---------------------------------------------------------------------------
# SSE file-watch broadcaster
# ---------------------------------------------------------------------------

class FileWatcher:
    """Watch agent state files and broadcast changes via SSE."""

    def __init__(self, root: Path, interval: float = 0.8):
        self.root = root
        self.interval = interval
        self.subscribers: list[queue.Queue] = []
        self.lock = threading.Lock()
        self._hashes: dict[str, str] = {}
        self._running = True
        self._thread = threading.Thread(target=self._poll_loop, daemon=True)
        self._thread.start()

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=64)
        with self.lock:
            self.subscribers.append(q)
        return q

    def unsubscribe(self, q: queue.Queue) -> None:
        with self.lock:
            try:
                self.subscribers.remove(q)
            except ValueError:
                pass

    def _broadcast(self, event: str, data: str) -> None:
        msg = f"event: {event}\ndata: {data}\n\n"
        with self.lock:
            dead: list[queue.Queue] = []
            for q in self.subscribers:
                try:
                    q.put_nowait(msg)
                except queue.Full:
                    dead.append(q)
            for q in dead:
                self.subscribers.remove(q)

    def _read_safe(self, path: Path) -> str:
        try:
            return path.read_text(encoding="utf-8")
        except OSError:
            return ""

    def _poll_loop(self) -> None:
        while self._running:
            try:
                self._poll_once()
            except Exception:
                pass
            time.sleep(self.interval)

    def _poll_once(self) -> None:
        agents = sorted(p.name for p in self.root.glob("agent-*") if p.is_dir())
        agents_key = json.dumps(agents)
        if self._hashes.get("__agents__") != agents_key:
            self._hashes["__agents__"] = agents_key
            self._broadcast("agents", json.dumps({"agents": agents}))

        for agent_name in agents:
            agent_dir = self.root / agent_name

            status_path = agent_dir / "status.json"
            status_text = self._read_safe(status_path)
            status_hash_key = f"{agent_name}:status"
            if status_text and self._hashes.get(status_hash_key) != status_text:
                self._hashes[status_hash_key] = status_text
                self._broadcast("status", json.dumps({"agent": agent_name, "data": json.loads(status_text)}))

            events_path = agent_dir / "recent-events.json"
            events_text = self._read_safe(events_path)
            events_hash_key = f"{agent_name}:events"
            if events_text and self._hashes.get(events_hash_key) != events_text:
                self._hashes[events_hash_key] = events_text
                self._broadcast("events", json.dumps({"agent": agent_name, "data": json.loads(events_text)}))

            diff_path = agent_dir / "diff-stat.txt"
            diff_text = self._read_safe(diff_path)
            diff_hash_key = f"{agent_name}:diff"
            if self._hashes.get(diff_hash_key) != diff_text:
                self._hashes[diff_hash_key] = diff_text
                self._broadcast("diff", json.dumps({"agent": agent_name, "data": diff_text}))

            # Scan iteration run files for history
            runs_dir = agent_dir / "runs"
            if runs_dir.is_dir():
                runs = sorted(runs_dir.glob("*.jsonl"))
                history = []
                for rp in runs:
                    name = rp.stem  # e.g. 20260309_001746_iter1
                    parts = name.split("_iter")
                    ts_part = parts[0] if parts else name
                    iter_part = parts[1] if len(parts) > 1 else "?"
                    history.append({"file": rp.name, "ts": ts_part, "iter": iter_part})
                hist_key = json.dumps(history)
                hist_hash_key = f"{agent_name}:history"
                if self._hashes.get(hist_hash_key) != hist_key:
                    self._hashes[hist_hash_key] = hist_key
                    self._broadcast("history", json.dumps({"agent": agent_name, "data": history}))


# ---------------------------------------------------------------------------
# Dashboard HTML — multi-agent grid TUI-style
# ---------------------------------------------------------------------------

INDEX_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Codex Engine</title>
<script src="https://cdn.jsdelivr.net/npm/marked@15/marked.min.js"></script>
<style>
:root {
  --bg:       #0a0a0a;
  --bg-1:     #111111;
  --bg-2:     #181818;
  --bg-3:     #222222;
  --bg-card:  #0f0f0f;
  --border:   #1e1e1e;
  --border-h: #333333;
  --t1:       #e8e8e8;
  --t2:       #a0a0a0;
  --t3:       #5a5a5a;
  --blue:     #7aa2f7;
  --green:    #9ece6a;
  --amber:    #e0af68;
  --red:      #f7768e;
  --cyan:     #73daca;
  --purple:   #bb9af7;
  --mono: 'SF Mono','Cascadia Code','JetBrains Mono','Fira Code',ui-monospace,monospace;
  --sans: -apple-system,'Inter','Segoe UI',sans-serif;
  --content-max: 720px;
  --ease-out-expo: cubic-bezier(.16,1,.3,1);
  --ease-spring: cubic-bezier(.34,1.56,.64,1);
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}

html,body{
  height:100%;
  overflow:hidden;
  font-family:var(--mono);
  background:var(--bg);
  color:var(--t1);
  font-size:12px;
  line-height:1.6;
  -webkit-font-smoothing:antialiased;
  -moz-osx-font-smoothing:grayscale;
}

/* ── Global top bar ─────────────────────────────────────── */
.topbar{
  display:flex;
  align-items:center;
  gap:12px;
  padding:0 16px;
  border-bottom:1px solid var(--border);
  background:var(--bg-1);
  height:36px;
  flex-shrink:0;
}

.logo{
  color:var(--t1);
  font-weight:700;
  font-size:12px;
  white-space:nowrap;
  letter-spacing:-.02em;
}

.logo::before{
  content:'◈ ';
  color:var(--blue);
  font-size:11px;
}

.spacer{flex:1}

.conn{
  display:flex;
  align-items:center;
  gap:5px;
  font-size:10px;
  color:var(--t3);
}

.conn-dot{
  width:6px;height:6px;
  border-radius:50%;
  background:var(--green);
  box-shadow:0 0 6px rgba(158,206,106,.4);
  transition:all .3s ease;
}
.conn-dot.off{background:var(--red);box-shadow:0 0 6px rgba(247,118,142,.4)}

.agent-count{
  font-size:10px;
  color:var(--t3);
  padding:2px 8px;
  background:var(--bg-2);
  border:1px solid var(--border);
  border-radius:4px;
  font-variant-numeric:tabular-nums;
}

/* ── Grid container ─────────────────────────────────────── */
.grid-wrap{
  display:flex;
  flex:1;
  overflow:hidden;
  height:calc(100vh - 36px);
}

.grid{
  display:grid;
  flex:1;
  overflow:hidden;
  gap:1px;
  background:var(--border);
}

/* Adaptive columns based on agent count (set via JS) */
.grid.cols-1{grid-template-columns:1fr}
.grid.cols-2{grid-template-columns:1fr 1fr}
.grid.cols-3{grid-template-columns:1fr 1fr 1fr}
.grid.cols-4{grid-template-columns:1fr 1fr}
.grid.cols-5{grid-template-columns:1fr 1fr 1fr}
.grid.cols-6{grid-template-columns:1fr 1fr 1fr}
.grid.cols-7{grid-template-columns:1fr 1fr 1fr 1fr}
.grid.cols-8{grid-template-columns:1fr 1fr 1fr 1fr}

/* ── Agent pane ─────────────────────────────────────────── */
.pane{
  display:flex;
  flex-direction:column;
  background:var(--bg);
  overflow:hidden;
  min-width:0;
  position:relative;
  animation:pane-in .4s var(--ease-out-expo);
}

@keyframes pane-in{
  from{opacity:0;transform:scale(.98)}
  to{opacity:1;transform:scale(1)}
}

/* Selection color */
::selection{background:rgba(122,162,247,.2);color:var(--t1)}

/* ── Pane header ────────────────────────────────────────── */
.pane-head{
  display:flex;
  align-items:center;
  gap:8px;
  padding:6px 12px;
  background:var(--bg-1);
  border-bottom:1px solid var(--border);
  flex-shrink:0;
  min-height:32px;
}

/* When single pane is wide, give chrome some breathing room */
.grid.cols-1 .pane-head{
  padding-left:max(12px, calc((100% - var(--content-max)) / 2));
  padding-right:max(12px, calc((100% - var(--content-max)) / 2));
}

.grid.cols-1 .pane-diff-toggle{
  max-width:var(--content-max);
  margin:0 auto;
}

.grid.cols-1 .diff-code{
  max-width:var(--content-max);
  margin:0 auto;
}

.pane-name{
  font-size:11px;
  font-weight:700;
  color:var(--blue);
  white-space:nowrap;
  overflow:hidden;
  text-overflow:ellipsis;
  letter-spacing:-.01em;
}

.pane-state{
  font-size:9px;
  font-weight:600;
  padding:1px 6px;
  border-radius:4px;
  white-space:nowrap;
  letter-spacing:.02em;
  text-transform:uppercase;
  transition:all .2s ease;
}

.pane-state.s-run{color:var(--amber);background:rgba(224,175,104,.1);border:1px solid rgba(224,175,104,.15)}
.pane-state.s-ok{color:var(--green);background:rgba(158,206,106,.1);border:1px solid rgba(158,206,106,.15)}
.pane-state.s-fail{color:var(--red);background:rgba(247,118,142,.1);border:1px solid rgba(247,118,142,.15)}

.pane-iter{
  font-size:10px;
  color:var(--t3);
  font-variant-numeric:tabular-nums;
}

.pane-spinner{
  display:inline-block;
  width:10px;
  height:10px;
  border:1.5px solid var(--border-h);
  border-top-color:var(--amber);
  border-radius:50%;
  animation:lspin .7s linear infinite;
  flex-shrink:0;
}

.pane-spinner.done{border-color:var(--green);border-top-color:var(--green);animation:none}
.pane-spinner.fail{border-color:var(--red);border-top-color:var(--red);animation:none}

@keyframes lspin{to{transform:rotate(360deg)}}

.pane-spacer{flex:1}

.pane-files{
  font-size:9px;
  color:var(--t3);
  font-variant-numeric:tabular-nums;
}

.pane-task{
  font-size:9px;
  color:var(--t3);
  overflow:hidden;
  text-overflow:ellipsis;
  white-space:nowrap;
  max-width:160px;
}

.pane-stop{
  font-family:var(--mono);
  font-size:9px;
  font-weight:600;
  padding:2px 8px;
  border:1px solid var(--border-h);
  border-radius:4px;
  background:transparent;
  color:var(--t3);
  cursor:pointer;
  transition:all .15s ease;
  flex-shrink:0;
  letter-spacing:.02em;
}

.pane-stop:hover{
  color:var(--red);
  border-color:rgba(247,118,142,.4);
  background:rgba(247,118,142,.06);
}

.pane-stop:active{transform:scale(.96)}

.pane-stop.confirming{
  color:#fff;
  border-color:var(--red);
  background:rgba(247,118,142,.2);
  animation:confirm-pulse 1s ease-in-out infinite;
}

@keyframes confirm-pulse{
  0%,100%{background:rgba(247,118,142,.2)}
  50%{background:rgba(247,118,142,.12)}
}

/* ── Pane status strip (compact) ────────────────────────── */
.pane-strip{
  display:flex;
  gap:1px;
  background:var(--border);
  flex-shrink:0;
}

.ps-cell{
  flex:1;
  padding:3px 8px;
  background:var(--bg-1);
  min-width:0;
}

.ps-label{
  font-size:8px;
  color:var(--t3);
  text-transform:uppercase;
  letter-spacing:.06em;
  opacity:.7;
}

.ps-val{
  font-size:10px;
  color:var(--t2);
  white-space:nowrap;
  overflow:hidden;
  text-overflow:ellipsis;
  font-variant-numeric:tabular-nums;
}

/* ── Pane feed (scrollable) ─────────────────────────────── */
.pane-feed{
  flex:1;
  overflow-y:auto;
  overflow-x:hidden;
  padding:6px 0 96px;
}

/* Constrain feed content to readable width, centered */
.pane-feed>.fi,
.pane-feed>.tool-group,
.pane-feed>.thinking,
.pane-feed>.empty{
  max-width:var(--content-max);
  margin-left:auto;
  margin-right:auto;
}

/* ── Feed item base ──────────────────────────────────────── */
.fi{
  border-bottom:1px solid var(--border);
  animation:fi-in .25s var(--ease-out-expo);
}

@keyframes fi-in{
  from{opacity:0;transform:translateY(-4px)}
  to{opacity:1;transform:translateY(0)}
}

/* ── Agent message ───────────────────────────────────────── */
.fi-msg{
  padding:8px 12px;
}

.fi-msg-head{
  display:flex;
  align-items:center;
  gap:6px;
  margin-bottom:4px;
}

.fi-role{
  font-size:9px;
  font-weight:700;
  color:var(--blue);
  text-transform:uppercase;
  letter-spacing:.04em;
}

.fi-ts{
  font-size:9px;
  color:var(--t3);
  font-variant-numeric:tabular-nums;
  margin-left:auto;
  opacity:.7;
}

.fi-body{
  font-size:12px;
  color:var(--t2);
  line-height:1.65;
  white-space:pre-wrap;
  word-break:break-word;
}

.fi.latest .fi-body{color:var(--t1)}

/* ── Tool group ──────────────────────────────────────────── */
.tool-group{
  border-bottom:1px solid var(--border);
  animation:fi-in .25s var(--ease-out-expo);
  transition:border-color .3s ease;
}

/* Active tool group — open and pulsing while agent is working */
.tool-group.active{
  border-left:2px solid var(--amber);
  border-bottom-color:var(--border-h);
  background:rgba(224,175,104,.015);
}

.tool-group.active>.tg-head>.tool-chevron{transform:rotate(90deg)}

.tg-head{
  display:flex;
  align-items:center;
  gap:6px;
  padding:4px 12px;
  cursor:pointer;
  user-select:none;
  font-size:10px;
  color:var(--t3);
  transition:color .15s ease, background .15s ease;
}

.tg-head:hover{color:var(--t2);background:rgba(255,255,255,.015)}

.tool-chevron{
  display:inline-block;
  width:10px;
  height:10px;
  color:var(--t3);
  transition:transform .2s var(--ease-out-expo);
  flex-shrink:0;
}

.tool-group.open>.tg-head>.tool-chevron{transform:rotate(90deg)}

.tg-icon{
  font-size:8px;
  font-weight:700;
  padding:1px 4px;
  border-radius:3px;
  flex-shrink:0;
  background:rgba(158,206,106,.08);
  color:var(--green);
  letter-spacing:.02em;
}

.tg-icon.has-err{background:rgba(247,118,142,.08);color:var(--red)}

.tg-summary{
  flex:1;
  min-width:0;
  overflow:hidden;
  text-overflow:ellipsis;
  white-space:nowrap;
  color:var(--t3);
}

.tg-count{
  font-size:9px;
  color:var(--t3);
  padding:1px 5px;
  border-radius:3px;
  background:var(--bg-2);
  border:1px solid var(--border);
  font-variant-numeric:tabular-nums;
}

.tg-ts{
  font-size:9px;
  color:var(--t3);
  font-variant-numeric:tabular-nums;
  opacity:.7;
}

.tg-body{
  display:none;
}

.tool-group.open>.tg-body,
.tool-group.active>.tg-body{
  display:block;
}

/* ── Tool row ────────────────────────────────────────────── */
.trow{
  display:flex;
  align-items:flex-start;
  gap:6px;
  padding:3px 12px 3px 26px;
  font-size:10px;
  color:var(--t3);
  border-top:1px solid var(--border);
  cursor:pointer;
  user-select:none;
  transition:background .1s ease;
}

.trow:hover{background:rgba(255,255,255,.02)}

.trow-icon{
  font-size:8px;
  font-weight:700;
  padding:1px 4px;
  border-radius:3px;
  flex-shrink:0;
  margin-top:1px;
  letter-spacing:.02em;
}

.trow-icon.cmd{background:rgba(158,206,106,.06);color:var(--green)}
.trow-icon.tool{background:rgba(115,218,202,.06);color:var(--cyan)}
.trow-icon.err{background:rgba(247,118,142,.06);color:var(--red)}
.trow-icon.misc{background:rgba(224,175,104,.06);color:var(--amber)}

.trow-cmd{
  flex:1;
  min-width:0;
  overflow:hidden;
  text-overflow:ellipsis;
  white-space:nowrap;
}

.trow-st{font-size:8px;font-weight:600;letter-spacing:.02em}
.trow-st.ok{color:var(--green)}
.trow-st.running{color:var(--amber)}
.trow-st.fail{color:var(--red)}

.trow-ts{
  font-size:8px;
  color:var(--t3);
  font-variant-numeric:tabular-nums;
  flex-shrink:0;
  opacity:.6;
}

/* ── Tool detail panel ───────────────────────────────────── */
.trow-detail{
  display:none;
  padding:4px 12px 6px 36px;
  overflow:auto;
  max-height:400px;
}

.trow-detail.open{
  display:block;
  animation:detail-in .2s var(--ease-out-expo);
}

@keyframes detail-in{
  from{opacity:0;transform:translateY(-2px)}
  to{opacity:1;transform:translateY(0)}
}

.td-section{margin-bottom:4px}

.td-label{
  font-size:8px;
  font-weight:700;
  text-transform:uppercase;
  letter-spacing:.08em;
  color:var(--t3);
  margin-bottom:2px;
  opacity:.8;
}

.td-code{
  font-size:10px;
  line-height:1.5;
  color:var(--t3);
  white-space:pre-wrap;
  word-break:break-word;
  background:var(--bg);
  border:1px solid var(--border);
  border-radius:4px;
  padding:6px 8px;
  max-height:200px;
  overflow:auto;
}

.td-exit{font-size:9px;margin-top:2px;font-weight:600}
.td-exit .ok{color:var(--green)}
.td-exit .fail{color:var(--red)}

/* ── System / divider event ───────────────────────────────── */
.fi-sys{
  padding:3px 12px;
  font-size:9px;
  color:var(--t3);
  display:flex;
  align-items:center;
  gap:8px;
  opacity:.7;
}

.fi-sys::before,.fi-sys::after{
  content:'';
  flex:1;
  height:1px;
  background:var(--border);
}

/* ── Turn separator — prominent visual break ─────────────── */
.fi-turn{
  display:flex;
  align-items:center;
  gap:10px;
  padding:10px 12px;
  margin:2px 0;
}

.fi-turn::before,.fi-turn::after{
  content:'';
  flex:1;
  height:1px;
}

.fi-turn.turn-start::before,.fi-turn.turn-start::after{
  background:linear-gradient(90deg,transparent 0%,rgba(122,162,247,.35) 50%,transparent 100%);
}

.fi-turn.turn-end::before,.fi-turn.turn-end::after{
  background:linear-gradient(90deg,transparent 0%,rgba(158,206,106,.35) 50%,transparent 100%);
}

.fi-turn.turn-fail::before,.fi-turn.turn-fail::after{
  background:linear-gradient(90deg,transparent 0%,rgba(247,118,142,.35) 50%,transparent 100%);
}

.fi-turn-badge{
  font-size:9px;
  font-weight:700;
  padding:2px 10px;
  border-radius:4px;
  white-space:nowrap;
  letter-spacing:.04em;
  text-transform:uppercase;
}

.turn-start .fi-turn-badge{
  color:var(--blue);
  background:rgba(122,162,247,.08);
  border:1px solid rgba(122,162,247,.18);
}

.turn-end .fi-turn-badge{
  color:var(--green);
  background:rgba(158,206,106,.08);
  border:1px solid rgba(158,206,106,.18);
}

.turn-fail .fi-turn-badge{
  color:var(--red);
  background:rgba(247,118,142,.08);
  border:1px solid rgba(247,118,142,.18);
}

.fi-turn-ts{
  font-size:8px;
  color:var(--t3);
  font-variant-numeric:tabular-nums;
  opacity:.6;
}

/* ── Thread start — subtle header ────────────────────────── */
.fi-thread{
  display:flex;
  align-items:center;
  gap:8px;
  padding:6px 12px;
  margin:2px 0;
  font-size:9px;
  color:var(--t3);
}

.fi-thread::before,.fi-thread::after{
  content:'';
  flex:1;
  height:1px;
  background:var(--border-h);
}

.fi-thread-badge{
  font-size:8px;
  font-weight:700;
  padding:2px 8px;
  border-radius:3px;
  color:var(--cyan);
  background:rgba(115,218,202,.06);
  border:1px solid rgba(115,218,202,.12);
  letter-spacing:.05em;
  text-transform:uppercase;
}

/* ── Pane diff bar ───────────────────────────────────────── */
.pane-diff{
  border-top:1px solid var(--border);
  background:var(--bg-1);
  flex-shrink:0;
}

.pane-diff-toggle{
  display:flex;
  align-items:center;
  gap:8px;
  padding:4px 12px;
  cursor:pointer;
  user-select:none;
  font-size:10px;
  color:var(--t3);
  transition:color .15s ease, background .15s ease;
}

.pane-diff-toggle:hover{color:var(--t2);background:rgba(255,255,255,.015)}
.pane-diff-toggle .tool-chevron{width:10px;height:10px}
.pane-diff.open .pane-diff-toggle .tool-chevron{transform:rotate(90deg)}

.pane-diff-body{
  max-height:0;
  overflow:hidden;
  transition:max-height .3s var(--ease-out-expo);
}

.pane-diff.open .pane-diff-body{
  max-height:240px;
  overflow:auto;
}

.diff-code{
  font-size:10px;
  line-height:1.5;
  padding:6px 12px;
  color:var(--t2);
  white-space:pre-wrap;
  word-break:break-word;
}

.diff-code .df{color:var(--blue)}
.diff-code .da{color:var(--green)}
.diff-code .dd{color:var(--red)}

/* ── Jump pill (per-pane) ────────────────────────────────── */
.jump-pill{
  position:absolute;
  bottom:12px;
  left:50%;
  transform:translateX(-50%) translateY(40px);
  padding:4px 12px;
  font-family:var(--mono);
  font-size:9px;
  font-weight:600;
  color:var(--t2);
  background:var(--bg-2);
  border:1px solid var(--border-h);
  border-radius:14px;
  cursor:pointer;
  z-index:20;
  opacity:0;
  pointer-events:none;
  transition:transform .25s var(--ease-spring), opacity .2s ease;
  box-shadow:0 4px 16px rgba(0,0,0,.5);
  user-select:none;
  white-space:nowrap;
  backdrop-filter:blur(8px);
  -webkit-backdrop-filter:blur(8px);
}

.jump-pill:hover{color:var(--t1);border-color:var(--blue);box-shadow:0 4px 16px rgba(0,0,0,.5),0 0 0 1px var(--blue)}
.jump-pill:active{transform:translateX(-50%) scale(.96)}

.jump-pill.show{
  opacity:1;
  pointer-events:auto;
  transform:translateX(-50%) translateY(0);
}

.jp-count{
  display:inline-block;
  min-width:14px;
  text-align:center;
  padding:0 4px;
  margin-left:5px;
  font-size:9px;
  font-weight:700;
  color:var(--bg);
  background:var(--blue);
  border-radius:7px;
}

/* ── Streaming cursor ────────────────────────────────────── */
.fi-msg.streaming .fi-body::after{
  content:'';
  display:inline-block;
  width:2px;
  height:14px;
  background:var(--blue);
  margin-left:2px;
  vertical-align:text-bottom;
  border-radius:1px;
  animation:cursor-blink .8s ease-in-out infinite;
}

@keyframes cursor-blink{
  0%,100%{opacity:1}
  50%{opacity:.2}
}

/* ── Reasoning block ──────────────────────────────────────── */
.fi-reasoning{
  padding:8px 12px;
  border-left:2px solid var(--purple);
  animation:fi-in .25s var(--ease-out-expo);
  background:rgba(187,154,247,.015);
}

.fi-reasoning-head{
  display:flex;
  align-items:center;
  gap:6px;
  margin-bottom:4px;
  cursor:pointer;
  user-select:none;
  transition:opacity .15s ease;
}

.fi-reasoning-head:hover{opacity:.8}

.fi-reasoning-icon{
  font-size:8px;
  font-weight:700;
  padding:1px 5px;
  border-radius:3px;
  background:rgba(187,154,247,.08);
  color:var(--purple);
  letter-spacing:.02em;
}

.fi-reasoning-label{
  font-size:10px;
  color:var(--purple);
  font-weight:600;
  letter-spacing:.01em;
}

.fi-reasoning-timer{
  font-size:9px;
  color:var(--t3);
  font-variant-numeric:tabular-nums;
  margin-left:auto;
  opacity:.7;
}

.fi-reasoning-body{
  font-size:11px;
  color:var(--t3);
  line-height:1.6;
  white-space:pre-wrap;
  word-break:break-word;
  display:none;
  max-height:600px;
  overflow:auto;
  padding-top:2px;
}

.fi-reasoning.open .fi-reasoning-body{
  display:block;
  animation:detail-in .2s var(--ease-out-expo);
}

/* Active reasoning — pulsing while model is thinking */
.fi-reasoning.active{
  animation:reasoning-pulse 2.5s ease-in-out infinite;
}

@keyframes reasoning-pulse{
  0%,100%{border-left-color:var(--purple);background:rgba(187,154,247,.015)}
  50%{border-left-color:rgba(187,154,247,.35);background:rgba(187,154,247,.03)}
}



/* ── Thinking indicator (inline at bottom of feed) ───────── */
.thinking{
  display:flex;
  align-items:center;
  gap:8px;
  padding:8px 12px;
  font-size:10px;
  color:var(--t3);
  border-bottom:1px solid var(--border);
  animation:fi-in .25s var(--ease-out-expo);
  max-width:var(--content-max);
  margin:0 auto;
}

.thinking-dots{
  display:flex;
  gap:3px;
}

.thinking-dots span{
  width:4px;
  height:4px;
  border-radius:50%;
  background:var(--amber);
  animation:tdot 1.4s ease-in-out infinite;
}

.thinking-dots span:nth-child(2){animation-delay:.15s}
.thinking-dots span:nth-child(3){animation-delay:.3s}

@keyframes tdot{
  0%,80%,100%{opacity:.15;transform:scale(.7)}
  40%{opacity:1;transform:scale(1.15)}
}

.thinking-timer{
  font-variant-numeric:tabular-nums;
  color:var(--t3);
  margin-left:auto;
  font-size:9px;
  opacity:.7;
}

/* ── Tool row active pulse ───────────────────────────────── */
.trow.in-progress{
  background:rgba(224,175,104,.02);
}

.trow.in-progress .trow-st{
  animation:stpulse 1.8s ease-in-out infinite;
}

@keyframes stpulse{
  0%,100%{opacity:1}
  50%{opacity:.3}
}

/* ── Markdown ────────────────────────────────────────────── */
.fi-body p{margin:0 0 6px}
.fi-body p:last-child{margin-bottom:0}
.fi-body code{
  font-family:var(--mono);
  font-size:10px;
  padding:1px 4px;
  background:var(--bg-2);
  border:1px solid var(--border);
  border-radius:3px;
  color:var(--cyan);
}
.fi-body pre{
  background:var(--bg);
  border:1px solid var(--border);
  border-radius:4px;
  padding:8px 10px;
  margin:6px 0;
  overflow-x:auto;
  font-size:10px;
  line-height:1.5;
}
.fi-body pre code{padding:0;background:none;border:none;color:var(--t2)}
.fi-body ul,.fi-body ol{margin:4px 0 4px 18px;font-size:11px}
.fi-body li{margin-bottom:2px}
.fi-body strong{color:var(--t1);font-weight:600}
.fi-body em{color:var(--t2);font-style:italic}
.fi-body a{color:var(--blue);text-decoration:none;border-bottom:1px solid rgba(122,162,247,.2);transition:border-color .15s}
.fi-body a:hover{border-bottom-color:var(--blue)}
.fi-body h1,.fi-body h2,.fi-body h3{font-size:12px;color:var(--t1);margin:8px 0 4px;font-weight:700;letter-spacing:-.01em}
.fi-body blockquote{border-left:2px solid var(--border-h);padding-left:10px;margin:4px 0;color:var(--t3)}
.fi-body hr{border:none;border-top:1px solid var(--border);margin:8px 0}
.fi-body table{border-collapse:collapse;font-size:10px;margin:4px 0}
.fi-body th,.fi-body td{border:1px solid var(--border);padding:3px 8px;text-align:left}
.fi-body th{background:var(--bg-2);font-weight:600;color:var(--t1)}

/* ── Empty state ─────────────────────────────────────────── */
.empty{
  padding:48px 12px;
  text-align:center;
  color:var(--t3);
  font-size:11px;
}

.empty-icon{
  font-size:24px;
  margin-bottom:8px;
  opacity:.12;
  animation:empty-pulse 3s ease-in-out infinite;
}

@keyframes empty-pulse{
  0%,100%{opacity:.12;transform:scale(1)}
  50%{opacity:.2;transform:scale(1.05)}
}

.no-agents{
  display:flex;
  align-items:center;
  justify-content:center;
  height:100%;
  color:var(--t3);
  font-size:12px;
  flex-direction:column;
  gap:10px;
  letter-spacing:.01em;
}

.no-agents-icon{
  font-size:36px;
  opacity:.1;
  animation:empty-pulse 3s ease-in-out infinite;
}

/* ── Focus / keyboard ────────────────────────────────────── */
:focus-visible{
  outline:1px solid var(--blue);
  outline-offset:1px;
}

button:focus-visible{
  outline:1px solid var(--blue);
  outline-offset:1px;
}

/* ── Scrollbar ───────────────────────────────────────────── */
::-webkit-scrollbar{width:5px;height:5px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:var(--bg-3);border-radius:3px}
::-webkit-scrollbar-thumb:hover{background:var(--t3)}

/* ── Responsive adjustments ──────────────────────────────── */
@media (max-width:600px){
  :root{--content-max:100%}
  .pane-head{gap:4px;padding:4px 8px}
  .pane-task{display:none}
  .pane-files{display:none}
  .ps-label{font-size:7px}
  .ps-val{font-size:9px}
  .fi-msg{padding:6px 8px}
  .tg-head{padding:3px 8px}
  .trow{padding:2px 8px 2px 20px}
}
</style>
</head>
<body>

<!-- Global top bar -->
<div class="topbar">
  <span class="logo">codex engine</span>
  <span class="spacer"></span>
  <span class="agent-count" id="agent-count">0 agents</span>
  <div class="conn">
    <span class="conn-dot" id="conn-dot"></span>
    <span id="conn-txt">connecting</span>
  </div>
</div>

<!-- Grid of agent panes -->
<div class="grid-wrap">
  <div class="grid cols-1" id="grid">
    <div class="no-agents" id="no-agents">
      <div class="no-agents-icon">&#9671;</div>
      Waiting for agents...
    </div>
  </div>
</div>

<script>
(()=>{
"use strict";
const $=id=>document.getElementById(id);
const chevronSvg='<svg class="tool-chevron" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2"><path d="M6 4l4 4-4 4"/></svg>';

/* ── State ─────────────────────────────────────────────── */
const S={
  agents:[], status:{}, events:{}, diff:{}, history:{},
  connected:false,
  // per-agent DOM + feed state
  panes:{},    // agentName -> {el, feed, diffBar, diffCode, jumpPill, jpCount}
  cursor:{},
  tailGroup:{},
  tailGroupBody:{},
  tailGroupCount:{},
  pinned:{},   // per-agent scroll pin
  missed:{},   // per-agent missed count
};

/* ── Helpers ───────────────────────────────────────────── */
function esc(s){const d=document.createElement("div");d.textContent=s;return d.innerHTML}
function fmtTime(iso){
  if(!iso) return "--";
  try{return new Date(iso).toLocaleTimeString([],{hour:"2-digit",minute:"2-digit",second:"2-digit"})}
  catch{return iso}
}
function stCls(s){
  if(!s) return "";
  if(s.includes("running")) return "s-run";
  if(s.includes("complete")) return "s-ok";
  if(s.includes("failed")||s.includes("fail")||s==="stopped") return "s-fail";
  return "";
}
function stLabel(s){
  return {running:"running",iteration_complete:"complete",iteration_failed:"failed",stopped:"stopped"}[s]||s||"--";
}
function shortCmd(cmd){
  let c=cmd.replace(/^\/bin\/(?:ba)?sh\s+-\w+\s+/,"").replace(/^['"]|['"]$/g,"");
  if(c.length>80) c=c.substring(0,80)+"...";
  return c;
}
function renderMd(text){
  if(typeof marked!=="undefined"&&marked.parse){
    try{return marked.parse(text,{breaks:true,gfm:true})}catch{}
  }
  return esc(text).replace(/\n/g,"<br>");
}

/* ── Classify event ────────────────────────────────────── */
function classify(ev){
  const label=ev.label||"",kind=ev.kind||"";
  if(kind==="command"){
    const st=ev.status||"unknown",cmd=ev.command||label.replace(/^command[^:]*:\s*/,"");
    return {kind:"tool",icon:"$",iconCls:"cmd",text:shortCmd(cmd),fullCmd:cmd,output:ev.output||"",exitCode:ev.exit_code,status:st,statusCls:st==="completed"?"ok":st==="in_progress"?"running":"fail"};
  }
  if(kind==="message") return {kind:"msg",text:ev.text||label.replace(/^agent_message:\s*/,"")};
  if(kind==="reasoning") return {kind:"reasoning",text:ev.text||"",status:ev.status||""};
  if(kind==="tool") return {kind:"tool",icon:"fn",iconCls:"tool",text:label,fullCmd:"",output:"",status:ev.status||"",statusCls:ev.status==="completed"?"ok":"misc"};
  if(kind==="system"||label.startsWith("thread.")||label.startsWith("turn.")){
    if(label.includes("error")||label.includes("failed")) return {kind:"turn",variant:"fail",text:label};
    if(label==="turn.started") return {kind:"turn",variant:"start",text:"turn started"};
    if(label==="turn.completed") return {kind:"turn",variant:"end",text:"turn completed"};
    if(label==="thread.started") return {kind:"thread",text:"thread started"};
    return {kind:"divider",text:label};
  }
  // Legacy
  if(label.startsWith("command")){
    const m=label.match(/^command \((\w+)\):\s*(.*)/);
    const st=m?m[1]:"unknown",cmd=m?m[2]:label;
    return {kind:"tool",icon:"$",iconCls:"cmd",text:shortCmd(cmd),fullCmd:cmd,output:"",status:st,statusCls:st==="completed"?"ok":st==="in_progress"?"running":"fail"};
  }
  if(label.startsWith("agent_message:")) return {kind:"msg",text:label.replace(/^agent_message:\s*/,"")};
  if(label.startsWith("reasoning:")) return {kind:"reasoning",text:label.replace(/^reasoning:\s*/,""),status:""};
  if(label.includes("error")||label.includes("failed")) return {kind:"turn",variant:"fail",text:label};
  if(label==="turn.started") return {kind:"turn",variant:"start",text:"turn started"};
  if(label==="turn.completed") return {kind:"turn",variant:"end",text:"turn completed"};
  if(label==="thread.started") return {kind:"thread",text:"thread started"};
  if(label.startsWith("thread.")||label.startsWith("turn.")) return {kind:"divider",text:label};
  return {kind:"sys",icon:"SYS",iconCls:"misc",text:label};
}

/* ── Create pane DOM ───────────────────────────────────── */
function createPane(agentName){
  const pane=document.createElement("div");
  pane.className="pane";
  pane.dataset.agent=agentName;

  // Header
  const head=document.createElement("div");
  head.className="pane-head";
  head.innerHTML=
    `<span class="pane-spinner" data-r="spinner"></span>`+
    `<span class="pane-name">${esc(agentName)}</span>`+
    `<span class="pane-state" data-r="state">--</span>`+
    `<span class="pane-iter" data-r="iter"></span>`+
    `<span class="pane-spacer"></span>`+
    `<span class="pane-task" data-r="task"></span>`+
    `<span class="pane-files" data-r="files"></span>`+
    `<button class="pane-stop" data-r="stop" title="Stop agent">stop</button>`;
  pane.appendChild(head);

  // Stop button — requires double-click (confirm pattern)
  const stopBtn=head.querySelector('[data-r="stop"]');
  let stopTimer=null;
  stopBtn.addEventListener("click",()=>{
    if(stopBtn.classList.contains("confirming")){
      // Second click — actually stop
      clearTimeout(stopTimer);
      stopBtn.classList.remove("confirming");
      stopBtn.textContent="stopping...";
      stopBtn.disabled=true;
      fetch(`/api/stop?agent=${encodeURIComponent(agentName)}`,{method:"POST"})
        .then(r=>r.json())
        .then(()=>{stopBtn.textContent="stopped"})
        .catch(()=>{stopBtn.textContent="stop";stopBtn.disabled=false});
    } else {
      // First click — enter confirm state
      stopBtn.classList.add("confirming");
      stopBtn.textContent="confirm?";
      stopTimer=setTimeout(()=>{
        stopBtn.classList.remove("confirming");
        stopBtn.textContent="stop";
      },3000);
    }
  });

  // Strip
  const strip=document.createElement("div");
  strip.className="pane-strip";
  strip.innerHTML=
    `<div class="ps-cell"><div class="ps-label">branch</div><div class="ps-val" data-r="branch">--</div></div>`+
    `<div class="ps-cell"><div class="ps-label">commit</div><div class="ps-val" data-r="commit">--</div></div>`+
    `<div class="ps-cell"><div class="ps-label">updated</div><div class="ps-val" data-r="updated">--</div></div>`;
  pane.appendChild(strip);

  // Feed
  const feed=document.createElement("div");
  feed.className="pane-feed";
  feed.innerHTML='<div class="empty"><div class="empty-icon">&#9671;</div>Waiting for events...</div>';
  pane.appendChild(feed);

  // Jump pill
  const pill=document.createElement("div");
  pill.className="jump-pill";
  pill.innerHTML='new <span class="jp-count">0</span>';
  pill.addEventListener("click",()=>{
    S.pinned[agentName]=true;
    S.missed[agentName]=0;
    pill.classList.remove("show");
    feed.scrollTo({top:feed.scrollHeight,behavior:"smooth"});
  });
  pane.appendChild(pill);

  // Diff bar
  const diffBar=document.createElement("div");
  diffBar.className="pane-diff";
  diffBar.style.display="none";
  diffBar.innerHTML=
    `<div class="pane-diff-toggle">`+
      chevronSvg+
      `<span>diff</span>`+
      `<span data-r="diff-files" style="margin-left:auto;font-size:9px;color:var(--t3)"></span>`+
    `</div>`+
    `<div class="pane-diff-body"><div class="diff-code" data-r="diff-code">No diff.</div></div>`;
  diffBar.querySelector(".pane-diff-toggle").addEventListener("click",()=> diffBar.classList.toggle("open"));
  pane.appendChild(diffBar);

  // Scroll handling per-pane
  S.pinned[agentName]=true;
  S.missed[agentName]=0;
  let scrollTick=false;
  feed.addEventListener("scroll",()=>{
    if(scrollTick) return;
    scrollTick=true;
    requestAnimationFrame(()=>{
      scrollTick=false;
      const ab=(feed.scrollTop+feed.clientHeight)>=feed.scrollHeight-60;
      if(ab&&!S.pinned[agentName]){S.pinned[agentName]=true;S.missed[agentName]=0;pill.classList.remove("show")}
      else if(!ab&&S.pinned[agentName]){S.pinned[agentName]=false}
    });
  },{passive:true});

  // Query helper
  const q=(sel)=>pane.querySelector(`[data-r="${sel}"]`);

  S.panes[agentName]={el:pane,feed,diffBar,pill,q};
  S.cursor[agentName]=0;
  S.tailGroup[agentName]=null;
  S.tailGroupBody[agentName]=null;
  S.tailGroupCount[agentName]=0;

  return pane;
}

/* ── Rebuild grid ──────────────────────────────────────── */
function rebuildGrid(){
  const grid=$("grid");
  const n=S.agents.length;

  if(n===0){
    grid.innerHTML='<div class="no-agents" id="no-agents"><div class="no-agents-icon">&#9671;</div>Waiting for agents...</div>';
    grid.className="grid cols-1";
    $("agent-count").textContent="0 agents";
    return;
  }

  $("agent-count").textContent=`${n} agent${n!==1?"s":""}`;

  // Determine which panes need creating
  const existing=new Set(Object.keys(S.panes));
  const needed=new Set(S.agents);

  // Remove panes for agents that no longer exist
  for(const a of existing){
    if(!needed.has(a)){
      S.panes[a].el.remove();
      delete S.panes[a];
      delete S.cursor[a];
      delete S.tailGroup[a];
      delete S.tailGroupBody[a];
      delete S.tailGroupCount[a];
      delete S.pinned[a];
      delete S.missed[a];
    }
  }

  // Add new panes
  // First remove the no-agents placeholder if present
  const placeholder=grid.querySelector(".no-agents");
  if(placeholder) placeholder.remove();

  for(const a of S.agents){
    if(!S.panes[a]){
      grid.appendChild(createPane(a));
    }
  }

  // Set column class
  const cols=Math.min(n,8);
  grid.className=`grid cols-${cols}`;
}

/* ── Render pane header/strip ──────────────────────────── */
function renderPaneStatus(agentName){
  const p=S.panes[agentName]; if(!p) return;
  const s=S.status[agentName]; if(!s) return;
  const q=p.q;

  const cls=stCls(s.state);
  const spin=q("spinner");
  if(spin) spin.className="pane-spinner"+(cls==="s-ok"?" done":cls==="s-fail"?" fail":"");

  const stateEl=q("state");
  if(stateEl){stateEl.textContent=stLabel(s.state);stateEl.className="pane-state "+cls}

  const maxI=typeof s.max_iterations==="number"&&s.max_iterations>0?s.max_iterations:null;
  const iter=s.iteration||1;
  const iterEl=q("iter");
  if(iterEl) iterEl.textContent=maxI?`${iter}/${maxI}`:`#${iter}`;

  const taskEl=q("task");
  if(taskEl){taskEl.textContent=s.current_task||"";taskEl.title=s.current_task||""}

  const filesEl=q("files");
  if(filesEl) filesEl.textContent=(s.files_changed??0)>0?`${s.files_changed} files`:"";

  const branchEl=q("branch");
  if(branchEl) branchEl.textContent=s.branch||"--";

  const commitEl=q("commit");
  if(commitEl) commitEl.textContent=s.commit||"--";

  const updatedEl=q("updated");
  if(updatedEl) updatedEl.textContent=fmtTime(s.updated_at);
}

/* ── Tool row builder ──────────────────────────────────── */
function buildToolRow(ev,c){
  const frag=document.createDocumentFragment();

  const row=document.createElement("div");
  row.className="trow"+(c.statusCls==="running"?" in-progress":"");
  row.innerHTML=
    `<span class="trow-icon ${esc(c.iconCls||"cmd")}">${esc(c.icon||"$")}</span>`+
    `<span class="trow-cmd">${esc(c.text)}</span>`+
    (c.status?`<span class="trow-st ${esc(c.statusCls||"")}">${esc(c.status)}</span>`:"")+
    `<span class="trow-ts">${fmtTime(ev.at)}</span>`;
  frag.appendChild(row);

  const detail=document.createElement("div");
  detail.className="trow-detail";
  let dh="";
  if(c.fullCmd) dh+=`<div class="td-section"><div class="td-label">command</div><div class="td-code">${esc(c.fullCmd)}</div></div>`;
  if(c.output) dh+=`<div class="td-section"><div class="td-label">output</div><div class="td-code">${esc(c.output)}</div></div>`;
  if(c.exitCode!==undefined&&c.exitCode!==null) dh+=`<div class="td-exit">exit <span class="${c.exitCode===0?"ok":"fail"}">${c.exitCode}</span></div>`;
  if(!dh) dh=`<div class="td-code">${esc(c.text)}</div>`;
  detail.innerHTML=dh;
  frag.appendChild(detail);

  // Click row to toggle its detail panel (closure ref — always reliable)
  row.addEventListener("click",(e)=>{
    e.stopPropagation();
    detail.classList.toggle("open");
  });

  return frag;
}

/* ── Update tool-group header (no innerHTML — update in place) */
function updateGroupHeader(grpEl,count,hasErr,lastTs,firstText){
  const head=grpEl.querySelector(".tg-head");
  if(!head) return;
  const summary=count===1?firstText:firstText+` (+${count-1} more)`;
  // Update existing spans by data-role instead of replacing innerHTML
  let sumEl=head.querySelector("[data-role=summary]");
  let cntEl=head.querySelector("[data-role=count]");
  let tsEl=head.querySelector("[data-role=ts]");
  let iconEl=head.querySelector("[data-role=icon]");
  if(!sumEl){
    // First time — build all children once
    head.innerHTML=
      chevronSvg+
      `<span class="tg-icon" data-role="icon">$</span>`+
      `<span class="tg-summary" data-role="summary"></span>`+
      `<span class="tg-count" data-role="count" style="display:none"></span>`+
      `<span class="tg-ts" data-role="ts"></span>`;
    sumEl=head.querySelector("[data-role=summary]");
    cntEl=head.querySelector("[data-role=count]");
    tsEl=head.querySelector("[data-role=ts]");
    iconEl=head.querySelector("[data-role=icon]");
  }
  sumEl.textContent=summary;
  iconEl.className="tg-icon"+(hasErr?" has-err":"");
  if(count>1){cntEl.textContent=String(count);cntEl.style.display=""}
  else{cntEl.style.display="none"}
  tsEl.textContent=fmtTime(lastTs);
}

/* ── Dedup ─────────────────────────────────────────────── */
function dedup(events){
  const done=new Set();
  events.forEach(ev=>{if(ev.id&&ev.type==="item.completed") done.add(ev.id)});
  return events.filter(ev=>!(ev.id&&ev.type==="item.started"&&done.has(ev.id)));
}

/* ── Per-pane onNew ────────────────────────────────────── */
function onNew(agentName){
  const p=S.panes[agentName]; if(!p) return;
  if(S.pinned[agentName]){
    requestAnimationFrame(()=>p.feed.scrollTo({top:p.feed.scrollHeight,behavior:"smooth"}));
  } else {
    S.missed[agentName]=(S.missed[agentName]||0)+1;
    const cnt=p.pill.querySelector(".jp-count");
    if(cnt) cnt.textContent=String(S.missed[agentName]);
    p.pill.classList.add("show");
  }
}

/* ── Seal active tool group (close + remove active) ────── */
function sealGroup(agentName){
  const grp=S.tailGroup[agentName];
  if(grp){
    grp.classList.remove("active");
    // Collapse it (CSS handles via removing .active which auto-opens)
  }
  S.tailGroup[agentName]=null;
  S.tailGroupBody[agentName]=null;
  S.tailGroupCount[agentName]=0;
}

/* ── Thinking indicator with elapsed timer ─────────────── */
const thinkingTimers={};

function ensureThinking(feed,agentName,show){
  let th=feed.querySelector(".thinking");
  if(show&&!th){
    th=document.createElement("div");
    th.className="thinking";
    th.innerHTML=
      '<div class="thinking-dots"><span></span><span></span><span></span></div>'+
      '<span>thinking...</span>'+
      '<span class="thinking-timer">0s</span>';
    feed.appendChild(th);
    const start=Date.now();
    if(thinkingTimers[agentName]) clearInterval(thinkingTimers[agentName]);
    thinkingTimers[agentName]=setInterval(()=>{
      const el=feed.querySelector(".thinking-timer");
      if(!el){clearInterval(thinkingTimers[agentName]);return}
      const sec=Math.floor((Date.now()-start)/1000);
      el.textContent=sec<60?`${sec}s`:`${Math.floor(sec/60)}m ${sec%60}s`;
    },1000);
  } else if(!show&&th){
    th.remove();
    if(thinkingTimers[agentName]){clearInterval(thinkingTimers[agentName]);delete thinkingTimers[agentName]}
  }
}

/* ── Seal active reasoning block ───────────────────────── */
function sealReasoning(agentName){
  const p=S.panes[agentName]; if(!p) return;
  const active=p.feed.querySelector(".fi-reasoning.active");
  if(active) active.classList.remove("active");
}

/* ── Render feed for one agent ─────────────────────────── */
function renderFeed(agentName){
  const p=S.panes[agentName]; if(!p) return;
  const raw=S.events[agentName]||[];
  if(raw.length===0) return;

  const events=dedup(raw);
  let cur=S.cursor[agentName]||0;

  // Detect if the source array was replaced or shrunk (new iteration, etc.)
  // Compare a fingerprint of the first event to catch resets
  const fp=events.length>0?JSON.stringify(events[0]):"";
  const prevFp=S.feedFingerprint&&S.feedFingerprint[agentName];
  if(cur>events.length || (cur>0 && fp!==prevFp)){
    // Source changed underneath us — full reset
    cur=0;
    S.cursor[agentName]=0;
    S.tailGroup[agentName]=null;
    S.tailGroupBody[agentName]=null;
    S.tailGroupCount[agentName]=0;
    p.feed.innerHTML="";
  }
  if(!S.feedFingerprint) S.feedFingerprint={};
  S.feedFingerprint[agentName]=fp;
  if(!S.turnCount) S.turnCount={};
  if(cur===0) S.turnCount[agentName]=0;

  if(cur>=events.length) return;

  const feed=p.feed;
  // Remove thinking indicator before appending (we'll re-add if needed)
  ensureThinking(feed,agentName,false);

  if(cur===0) feed.innerHTML="";

  const isRunning=!!(S.status[agentName]&&S.status[agentName].state==="running");
  let appended=false;

  const prevStream=feed.querySelector(".fi-msg.streaming");
  if(prevStream) prevStream.classList.remove("streaming");

  for(let i=cur;i<events.length;i++){
    const ev=events[i];
    const c=classify(ev);

    if(c.kind==="tool"||c.kind==="sys"){
      // Seal any active reasoning
      sealReasoning(agentName);

      let grp=S.tailGroup[agentName];
      let body=S.tailGroupBody[agentName];
      if(!grp){
        grp=document.createElement("div");
        grp.className="tool-group active";
        grp.dataset.firstText=c.text;
        grp.dataset.hasErr="";
        const head=document.createElement("div");
        head.className="tg-head";
        head.addEventListener("click",(e)=>{
          e.stopPropagation();
          const wasActive=grp.classList.contains("active");
          if(wasActive){
            // Clicking while active: deactivate and collapse
            grp.classList.remove("active");
            grp.classList.remove("open");
          } else {
            grp.classList.toggle("open");
          }
        });
        grp.appendChild(head);
        body=document.createElement("div");
        body.className="tg-body";
        grp.appendChild(body);
        feed.appendChild(grp);
        S.tailGroup[agentName]=grp;
        S.tailGroupBody[agentName]=body;
        S.tailGroupCount[agentName]=0;
      }

      body.appendChild(buildToolRow(ev,c));
      S.tailGroupCount[agentName]++;
      if(c.statusCls==="fail"||c.iconCls==="err") grp.dataset.hasErr="1";
      updateGroupHeader(grp,S.tailGroupCount[agentName],!!grp.dataset.hasErr,ev.at,grp.dataset.firstText);
      appended=true;

    } else if(c.kind==="reasoning"){
      // Seal tool group and previous reasoning
      sealGroup(agentName);
      sealReasoning(agentName);

      const el=document.createElement("div");
      const isCompleted=ev.type==="item.completed"||c.status==="completed";
      el.className="fi fi-reasoning"+(isCompleted?"":" active open");
      const hasText=!!(c.text&&c.text.trim());
      el.innerHTML=
        `<div class="fi-reasoning-head">`+
          `<span class="fi-reasoning-icon">&#9671;</span>`+
          `<span class="fi-reasoning-label">reasoning</span>`+
          `<span class="fi-reasoning-timer">${fmtTime(ev.at)}</span>`+
        `</div>`+
        (hasText?`<div class="fi-reasoning-body">${esc(c.text)}</div>`:`<div class="fi-reasoning-body">thinking...</div>`);
      el.querySelector(".fi-reasoning-head").addEventListener("click",()=> el.classList.toggle("open"));
      feed.appendChild(el);
      appended=true;

    } else {
      // Seal active tool group and reasoning
      sealGroup(agentName);
      sealReasoning(agentName);

      if(c.kind==="msg"){
        const el=document.createElement("div");
        const isLast=i===events.length-1;
        el.className="fi fi-msg"+(isLast&&isRunning?" streaming":"");
        el.innerHTML=
          `<div class="fi-msg-head"><span class="fi-role">agent</span><span class="fi-ts">${fmtTime(ev.at)}</span></div>`+
          `<div class="fi-body">${renderMd(c.text)}</div>`;
        feed.appendChild(el);
        appended=true;
      } else if(c.kind==="turn"){
        if(c.variant==="start") S.turnCount[agentName]=(S.turnCount[agentName]||0)+1;
        const tn=S.turnCount[agentName]||1;
        const el=document.createElement("div");
        el.className="fi fi-turn turn-"+(c.variant||"start");
        const label=c.variant==="start"?`turn ${tn}`:`turn ${tn} ${c.variant==="end"?"complete":"failed"}`;
        el.innerHTML=
          `<span class="fi-turn-badge">${esc(label)}</span>`+
          `<span class="fi-turn-ts">${fmtTime(ev.at)}</span>`;
        feed.appendChild(el);
      } else if(c.kind==="thread"){
        const el=document.createElement("div");
        el.className="fi fi-thread";
        el.innerHTML=`<span class="fi-thread-badge">${esc(c.text)}</span>`;
        feed.appendChild(el);
      } else if(c.kind==="divider"){
        const el=document.createElement("div");
        el.className="fi fi-sys";
        el.textContent=c.text;
        feed.appendChild(el);
      }
    }
  }

  S.cursor[agentName]=events.length;

  const msgs=feed.querySelectorAll(".fi-msg");
  msgs.forEach(m=>m.classList.remove("latest"));
  if(msgs.length) msgs[msgs.length-1].classList.add("latest");

  // Show thinking indicator when running with no active tool group or reasoning
  if(isRunning){
    const lastEv=events[events.length-1];
    const lastC=classify(lastEv);
    const hasActiveReasoning=!!feed.querySelector(".fi-reasoning.active");
    if(!S.tailGroup[agentName] && !hasActiveReasoning && lastC.kind!=="divider" && lastC.kind!=="turn"){
      ensureThinking(feed,agentName,true);
    }
  }

  if(appended) onNew(agentName);
}

/* ── Render diff for one agent ─────────────────────────── */
function renderDiff(agentName){
  const p=S.panes[agentName]; if(!p) return;
  const diff=S.diff[agentName]||"";
  const s=S.status[agentName];
  const files=s?(s.files_changed??0):0;

  if(!diff.trim()&&files===0){p.diffBar.style.display="none";return}
  p.diffBar.style.display="block";

  const filesEl=p.diffBar.querySelector('[data-r="diff-files"]');
  if(filesEl) filesEl.textContent=`${files} file${files!==1?"s":""}`;

  const codeEl=p.diffBar.querySelector('[data-r="diff-code"]');
  if(codeEl){
    codeEl.innerHTML=diff.split("\n").map(line=>{
      const t=line.trimStart();
      if(/^\d+ files? changed/.test(t)) return `<span class="df">${esc(line)}</span>`;
      if(/\|/.test(line)) return `<span class="df">${esc(line)}</span>`;
      return esc(line);
    }).join("\n");
  }
}

/* ── Top bar ───────────────────────────────────────────── */
function renderTopBar(){
  $("conn-dot").className=S.connected?"conn-dot":"conn-dot off";
  $("conn-txt").textContent=S.connected?"live":"reconnecting";
}

/* ── SSE with reconnect + stale detection ──────────────── */
let es=null, lastDataAt=0, reconnectTimer=null;

function onSseData(){lastDataAt=Date.now()}

function connect(){
  if(es){try{es.close()}catch{}}
  if(reconnectTimer){clearTimeout(reconnectTimer);reconnectTimer=null}
  es=new EventSource("/api/stream");

  es.onopen=()=>{
    S.connected=true;
    lastDataAt=Date.now();
    renderTopBar();
  };

  es.onerror=()=>{
    S.connected=false;
    renderTopBar();
    // EventSource auto-reconnects, but if it keeps failing, force reconnect
    if(reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer=setTimeout(()=>{
      if(!S.connected) connect();
    },5000);
  };

  es.addEventListener("agents",e=>{
    onSseData();
    const d=JSON.parse(e.data);
    const prev=S.agents.join(",");
    S.agents=d.agents;
    if(S.agents.join(",")!==prev) rebuildGrid();
    renderTopBar();
  });

  es.addEventListener("status",e=>{
    onSseData();
    const d=JSON.parse(e.data);
    S.status[d.agent]=d.data;
    if(!S.agents.includes(d.agent)){S.agents.push(d.agent);rebuildGrid()}
    renderPaneStatus(d.agent);
  });

  es.addEventListener("events",e=>{
    onSseData();
    const d=JSON.parse(e.data);
    S.events[d.agent]=d.data;
    if(!S.panes[d.agent]){S.agents.push(d.agent);rebuildGrid()}
    renderFeed(d.agent);
  });

  es.addEventListener("diff",e=>{
    onSseData();
    const d=JSON.parse(e.data);
    S.diff[d.agent]=d.data;
    renderDiff(d.agent);
  });

  es.addEventListener("history",e=>{
    onSseData();
    const d=JSON.parse(e.data);
    S.history[d.agent]=d.data;
  });
}

/* ── Poll fallback ─────────────────────────────────────── */
async function poll(){
  try{
    const ar=await fetch("/api/agents",{cache:"no-store"});
    if(ar.ok){
      const ad=await ar.json();
      const prev=S.agents.join(",");
      S.agents=ad.agents||[];
      if(S.agents.join(",")!==prev) rebuildGrid();
    }
    for(const a of S.agents){
      if(!S.panes[a]) continue;
      const [sr,er,dr]=await Promise.all([
        fetch(`/api/status?agent=${a}`,{cache:"no-store"}),
        fetch(`/api/events?agent=${a}`,{cache:"no-store"}),
        fetch(`/api/diff-stat?agent=${a}`,{cache:"no-store"}),
      ]);
      if(sr.ok) S.status[a]=await sr.json();
      if(er.ok) S.events[a]=await er.json();
      if(dr.ok) S.diff[a]=await dr.text();
      renderPaneStatus(a);
      renderFeed(a);
      renderDiff(a);
    }
  }catch{}
}

/* ── Stale SSE watchdog ────────────────────────────────── */
// If SSE says connected but no data for 20s, force reconnect + poll
setInterval(()=>{
  if(S.connected && lastDataAt && (Date.now()-lastDataAt)>20000){
    S.connected=false;
    renderTopBar();
    connect();
    poll();
  }
},5000);

/* ── Init ──────────────────────────────────────────────── */
connect();poll();
// Poll as fallback every 3s when disconnected, every 10s as background sync
setInterval(()=>{
  if(!S.connected) poll();
},3000);
setInterval(poll,10000);
})();
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

def select_agent(root: Path, requested: str | None) -> Path | None:
    if requested:
        candidate = root / requested
        if candidate.is_dir():
            return candidate
        return None

    agents = sorted(path for path in root.glob("agent-*") if path.is_dir())
    if not agents:
        return None
    return agents[0]


class PreviewHandler(BaseHTTPRequestHandler):
    root = Path("/workspace/logs/codex-preview")
    watcher: FileWatcher | None = None

    def _send_json(self, payload: object, status: int = HTTPStatus.OK) -> None:
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, body: str, content_type: str = "text/plain; charset=utf-8", status: int = HTTPStatus.OK) -> None:
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        agent_dir = select_agent(self.root, query.get("agent", [None])[0])

        if parsed.path == "/":
            self._send_text(INDEX_HTML, content_type="text/html; charset=utf-8")
            return

        if parsed.path == "/api/stream":
            self._handle_sse()
            return

        if parsed.path == "/api/agents":
            agents = [path.name for path in sorted(self.root.glob("agent-*")) if path.is_dir()]
            self._send_json({"agents": agents})
            return

        if agent_dir is None:
            self._send_json({"error": "No agent preview data found yet."}, status=HTTPStatus.NOT_FOUND)
            return

        if parsed.path == "/api/status":
            status_path = agent_dir / "status.json"
            if not status_path.exists():
                self._send_json({"error": "status.json not found"}, status=HTTPStatus.NOT_FOUND)
                return
            self._send_text(status_path.read_text(encoding="utf-8"), content_type="application/json; charset=utf-8")
            return

        if parsed.path == "/api/events":
            events_path = agent_dir / "recent-events.json"
            if not events_path.exists():
                self._send_json([])
                return
            self._send_text(events_path.read_text(encoding="utf-8"), content_type="application/json; charset=utf-8")
            return

        if parsed.path == "/api/diff-stat":
            diff_path = agent_dir / "diff-stat.txt"
            self._send_text(diff_path.read_text(encoding="utf-8") if diff_path.exists() else "")
            return

        self._send_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def _handle_sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        if self.watcher is None:
            self.wfile.write(b"event: error\ndata: {\"error\": \"No watcher\"}\n\n")
            self.wfile.flush()
            return

        sub = self.watcher.subscribe()
        try:
            while True:
                try:
                    msg = sub.get(timeout=15)
                    self.wfile.write(msg.encode("utf-8"))
                    self.wfile.flush()
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.watcher.unsubscribe(sub)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)

        if parsed.path == "/api/stop":
            agent_name = query.get("agent", [None])[0]
            if not agent_name:
                self._send_json({"error": "agent parameter required"}, status=HTTPStatus.BAD_REQUEST)
                return
            agent_dir = self.root / agent_name
            if not agent_dir.is_dir():
                self._send_json({"error": "agent not found"}, status=HTTPStatus.NOT_FOUND)
                return
            signal_path = agent_dir / "stop.signal"
            signal_path.write_text("stop\n", encoding="utf-8")
            self._send_json({"ok": True, "agent": agent_name})
            return

        self._send_json({"error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def log_message(self, format: str, *args) -> None:
        return


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Codex Engine Dashboard — multi-agent grid preview.")
    parser.add_argument("--root", default="/workspace/logs/codex-preview")
    parser.add_argument("--port", type=int, default=3001)
    args = parser.parse_args()

    root = Path(args.root)
    root.mkdir(parents=True, exist_ok=True)

    watcher = FileWatcher(root, interval=0.8)
    PreviewHandler.root = root
    PreviewHandler.watcher = watcher

    server = ThreadingHTTPServer(("0.0.0.0", args.port), PreviewHandler)
    print(f"Codex Engine Dashboard listening on http://0.0.0.0:{args.port}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
