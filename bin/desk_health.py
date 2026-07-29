#!/usr/bin/env python3
"""
desk-health — macOS layered break-alarm daemon (stdlib only).

Layers (priority C > B > A when multiple are due):
  A every 20 min  — eyes / micro-break
  B every 40 min  — posture + stretch
  C every 90 min  — full reset (subsumes A/B for that cycle)

CLI:
  run | once [A|B|C] | status | pause | resume | snooze [N]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
EXERCISES_PATH = DATA / "exercises.json"
CONFIG_PATH = DATA / "config.json"
CONFIG_DEFAULT_PATH = DATA / "config.default.json"
STATE_PATH = DATA / "state.json"
LOG_PATH = DATA / "desk_health.log"
PID_PATH = DATA / "desk_health.pid"
CHEAT_SHEET_PATH = Path("/tmp/desk-health-current.txt")
PAYLOAD_PATH = Path("/tmp/desk-health-payload.json")
# Native SwiftUI/AppKit overlay (preferred)
NATIVE_OVERLAY = ROOT / "bin" / "DeskHealthOverlay"

_LAYER_SYMBOLS = {
    "A": "eye",
    "B": "figure.stand",
    "C": "dumbbell.fill",
}

LAYERS = ("A", "B", "C")
# Higher index = higher priority when several are due
PRIORITY = {"C": 3, "B": 2, "A": 1}

DEFAULT_CONFIG: Dict[str, Any] = {
    "workday_start": "09:00",
    "workday_end": "18:00",
    "quiet_lunch_start": "12:00",
    "quiet_lunch_end": "13:00",
    "intervals": {"A": 20, "B": 40, "C": 90},
    "sound": "Purr",
    "tick_seconds": 20,
    "notification_max_body_chars": 180,
}

DEFAULT_EXERCISES: Dict[str, Any] = {
    "A": {
        "title": "Eyes + Micro-break",
        "subtitle": "Layer A · every 20 min",
        "steps": [
            "20-20-20: look 20 ft away for 20 seconds",
            "Blink slowly 10 times",
            "Roll shoulders back 5 times",
        ],
    },
    "B": {
        "title": "Posture + Stretch",
        "subtitle": "Layer B · every 40 min",
        "steps": [
            "Stand up and walk 30–60 seconds",
            "Chest opener: clasp hands behind back",
            "Neck: ear-to-shoulder, 15s each side",
        ],
    },
    "C": {
        "title": "Full Reset",
        "subtitle": "Layer C · every 90 min (includes stretch + eyes)",
        "steps": [
            "Leave desk: 2–3 min walk",
            "20-20-20 eye rest + body shake-out",
            "Hydrate; reset posture and monitor height",
        ],
    },
}

DEFAULT_STATE: Dict[str, Any] = {
    "paused": False,
    "snooze_until": None,
    "last_A": None,
    "last_B": None,
    "last_C": None,
    "session_started": None,
    "day": None,  # ISO date string; used to reset last_* on new calendar day
}


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def log(msg: str) -> None:
    """Append a timestamped line to the log file and stdout when useful."""
    DATA.mkdir(parents=True, exist_ok=True)
    line = f"{datetime.now().isoformat(timespec='seconds')}  {msg}"
    try:
        with LOG_PATH.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass
    print(line, flush=True)


def _parse_hhmm(s: str) -> Tuple[int, int]:
    parts = s.strip().split(":")
    return int(parts[0]), int(parts[1])


def _time_on_date(d: date, hhmm: str) -> datetime:
    h, m = _parse_hhmm(hhmm)
    return datetime(d.year, d.month, d.day, h, m, 0)


def parse_iso(s: Optional[str]) -> Optional[datetime]:
    if not s:
        return None
    try:
        # Support both "Z" and naive ISO strings
        return datetime.fromisoformat(s.replace("Z", "+00:00")).replace(tzinfo=None)
    except (ValueError, TypeError):
        return None


def to_iso(dt: Optional[datetime]) -> Optional[str]:
    if dt is None:
        return None
    return dt.isoformat(timespec="seconds")


# ---------------------------------------------------------------------------
# JSON load / save
# ---------------------------------------------------------------------------

def load_json(path: Path, fallback: Dict[str, Any]) -> Dict[str, Any]:
    if not path.exists():
        return dict(fallback)
    try:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            log(f"warn: {path} is not an object; using defaults")
            return dict(fallback)
        # Merge so missing keys still have defaults
        out = dict(fallback)
        out.update(data)
        return out
    except (OSError, json.JSONDecodeError) as e:
        log(f"warn: failed to load {path}: {e}; using defaults")
        return dict(fallback)


def save_json(path: Path, data: Dict[str, Any]) -> None:
    DATA.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    tmp.replace(path)


def ensure_config() -> Dict[str, Any]:
    """Load config.json; seed from config.default.json or baked-in defaults."""
    DATA.mkdir(parents=True, exist_ok=True)
    if not CONFIG_PATH.exists():
        if CONFIG_DEFAULT_PATH.exists():
            shutil.copy2(CONFIG_DEFAULT_PATH, CONFIG_PATH)
            log(f"seeded config from {CONFIG_DEFAULT_PATH}")
        else:
            save_json(CONFIG_PATH, DEFAULT_CONFIG)
            log(f"wrote default config to {CONFIG_PATH}")
    cfg = load_json(CONFIG_PATH, DEFAULT_CONFIG)
    # Nested merge for intervals
    intervals = dict(DEFAULT_CONFIG["intervals"])
    intervals.update(cfg.get("intervals") or {})
    cfg["intervals"] = intervals
    return cfg


def ensure_exercises() -> Dict[str, Any]:
    DATA.mkdir(parents=True, exist_ok=True)
    if not EXERCISES_PATH.exists():
        save_json(EXERCISES_PATH, DEFAULT_EXERCISES)
        log(f"wrote default exercises to {EXERCISES_PATH}")
    raw = load_json(EXERCISES_PATH, DEFAULT_EXERCISES)
    # Ensure each layer exists
    for layer in LAYERS:
        if layer not in raw or not isinstance(raw[layer], dict):
            raw[layer] = DEFAULT_EXERCISES[layer]
        for key in ("title", "subtitle", "steps"):
            if key not in raw[layer]:
                raw[layer][key] = DEFAULT_EXERCISES[layer][key]
    return raw


def load_state() -> Dict[str, Any]:
    state = load_json(STATE_PATH, DEFAULT_STATE)
    # Coerce types
    state["paused"] = bool(state.get("paused", False))
    return state


def save_state(state: Dict[str, Any]) -> None:
    save_json(STATE_PATH, state)


# ---------------------------------------------------------------------------
# Work window / quiet lunch
# ---------------------------------------------------------------------------

def in_work_window(now: datetime, cfg: Dict[str, Any]) -> bool:
    start = _time_on_date(now.date(), cfg["workday_start"])
    end = _time_on_date(now.date(), cfg["workday_end"])
    return start <= now < end


def in_quiet_lunch(now: datetime, cfg: Dict[str, Any]) -> bool:
    if cfg.get("quiet_lunch") is False:
        return False
    qs = cfg.get("quiet_lunch_start")
    qe = cfg.get("quiet_lunch_end")
    if not qs or not qe:
        return False
    start = _time_on_date(now.date(), qs)
    end = _time_on_date(now.date(), qe)
    return start <= now < end


def is_snoozed(state: Dict[str, Any], now: datetime) -> bool:
    until = parse_iso(state.get("snooze_until"))
    if until is None:
        return False
    if now < until:
        return True
    # Snooze expired — clear it
    state["snooze_until"] = None
    return False


# ---------------------------------------------------------------------------
# Notifications (osascript)
# ---------------------------------------------------------------------------

def _as_escape(s: str) -> str:
    """Escape a string for safe embedding in an AppleScript double-quoted string."""
    return (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", " ")
        .replace("\r", " ")
    )


def notify(title: str, subtitle: str, body: str, sound: str = "Purr") -> None:
    """Fire a macOS notification banner via osascript."""
    t = _as_escape(title)
    st = _as_escape(subtitle)
    b = _as_escape(body)
    snd = _as_escape(sound or "Purr")
    script = (
        f'display notification "{b}" '
        f'with title "{t}" '
        f'subtitle "{st}" '
        f'sound name "{snd}"'
    )
    try:
        subprocess.run(
            ["osascript", "-e", script],
            check=False,
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"error: notify failed: {e}")


def _resolve_layer_info(
    layer: str,
    exercises: Dict[str, Any],
    cfg: Dict[str, Any],
) -> Dict[str, Any]:
    """Pick title/subtitle/steps for a layer, honoring layer_c_preference for C."""
    info = dict(exercises.get(layer) or DEFAULT_EXERCISES.get(layer, {}))
    if layer == "C":
        pref = str(cfg.get("layer_c_preference") or "bands").lower()
        options = info.get("options") if isinstance(info.get("options"), dict) else {}
        if pref in options and isinstance(options[pref], dict):
            chosen = options[pref]
            info["title"] = chosen.get("title") or info.get("title")
            info["subtitle"] = chosen.get("subtitle") or info.get("subtitle")
            if chosen.get("steps"):
                info["steps"] = chosen["steps"]
    return info


def build_notification(
    layer: str,
    exercises: Dict[str, Any],
    cfg: Dict[str, Any],
) -> Tuple[str, str, str, str]:
    """Return (title, subtitle, body, sound); write full cheat sheet to /tmp."""
    info = _resolve_layer_info(layer, exercises, cfg)
    title = str(info.get("title") or f"Desk Health · {layer}")
    subtitle = str(info.get("subtitle") or f"Layer {layer}")
    steps: List[str] = list(info.get("steps") or [])
    sound = str(info.get("sound") or cfg.get("sound") or "Purr")

    # Full detail file for the user
    lines = [f"{title}", f"{subtitle}", ""]
    for i, step in enumerate(steps, 1):
        lines.append(f"{i}. {step}")
    lines.append("")
    lines.append(f"(Layer {layer} · desk-health · full set also in Notification Center)")
    lines.append(f"Protocol: {ROOT / 'docs' / 'PROTOCOL.md'}")
    try:
        CHEAT_SHEET_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    except OSError:
        pass

    max_chars = int(cfg.get("notification_max_body_chars") or 180)
    numbered = [f"{i}. {s}" for i, s in enumerate(steps, 1)]
    body = " · ".join(numbered) if numbered else f"Layer {layer} break"

    if len(body) > max_chars:
        short = " · ".join(numbered[:2]) if numbered else body[: max_chars - 40]
        body = f"{short} … see /tmp/desk-health-current.txt"

    return title, subtitle, body, sound


def _duration_hint(layer: str, info: Dict[str, Any]) -> str:
    sub = str(info.get("subtitle") or "")
    # Pull a short duration fragment if present
    for token in ("30–45", "90–120", "3–5", "40", "2 min", "4 min"):
        if token in sub:
            return sub.split("·")[-1].strip() if "·" in sub else sub
    defaults = {"A": "~40 seconds", "B": "~2 minutes", "C": "~4 minutes"}
    return defaults.get(layer, "")


def show_layer_overlay(
    layer: str,
    exercises: Dict[str, Any],
    cfg: Dict[str, Any],
    *,
    test_mode: bool = False,
) -> str:
    """Show native full-screen takeover. Returns done|snooze|skip."""
    info = _resolve_layer_info(layer, exercises, cfg)
    title = str(info.get("title") or f"Desk Health · {layer}")
    subtitle = str(info.get("subtitle") or f"Layer {layer}")
    steps: List[str] = [str(s) for s in (info.get("steps") or [])]
    duration = _duration_hint(layer, info)

    # Always refresh cheat sheet file
    build_notification(layer, exercises, cfg)

    intervals = (cfg.get("intervals") or {}) if isinstance(cfg, dict) else {}
    interval = int(intervals.get(layer, {"A": 20, "B": 40, "C": 90}.get(layer, 20)))
    reasons = {
        "A": "Eye strain + static posture reset",
        "B": "Mobility break — undo desk stiffness",
        "C": "Strength reset — posture muscles + blood flow",
    }
    payload = {
        "layer": layer,
        "title": title,
        "subtitle": subtitle,
        "steps": steps,
        "duration_hint": duration,
        "test_mode": bool(test_mode),
        "symbol_name": _LAYER_SYMBOLS.get(layer, "heart.text.square.fill"),
        "interval_minutes": interval,
        "reason": reasons.get(layer, "Scheduled movement break"),
    }

    log(f"overlay open layer={layer} test={test_mode} native={NATIVE_OVERLAY.exists()}")
    action = _run_native_overlay(payload, layer=layer, test_mode=test_mode)
    log(f"overlay closed layer={layer} action={action}")
    return action


def _run_native_overlay(
    payload: Dict[str, Any],
    *,
    layer: str,
    test_mode: bool,
) -> str:
    """Launch Swift DeskHealthOverlay; parse done|snooze|skip from stdout."""
    if not NATIVE_OVERLAY.exists():
        log("error: native overlay missing — build with: cd native && swift build -c release")
        # last-resort banner so the schedule still advances
        title_n, sub_n, body, sound = (
            str(payload.get("title") or "Desk Health"),
            str(payload.get("subtitle") or ""),
            " · ".join(str(s) for s in (payload.get("steps") or [])),
            "Purr",
        )
        notify(title_n, sub_n, body[:180], sound=sound)
        return "done"

    try:
        PAYLOAD_PATH.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    except OSError as e:
        log(f"warn: could not write payload: {e}")

    cmd = [str(NATIVE_OVERLAY), "--payload", str(PAYLOAD_PATH)]
    if test_mode:
        cmd.append("--test")

    try:
        proc = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
            timeout=60 * 30,  # 30 min max for a break UI
        )
    except subprocess.TimeoutExpired:
        log("error: native overlay timed out")
        return "skip"
    except OSError as e:
        log(f"error: failed to launch native overlay: {e}")
        return "skip"

    if proc.stderr:
        for line in proc.stderr.strip().splitlines()[-5:]:
            log(f"overlay stderr: {line}")

    # Prefer last non-empty stdout line: done | skip | snooze | snooze:N
    action = "skip"
    snooze_mins: Optional[int] = None
    for line in (proc.stdout or "").strip().splitlines():
        token = line.strip().lower()
        if token in ("done", "skip"):
            action = token
            snooze_mins = None
        elif token == "snooze":
            action = "snooze"
            snooze_mins = None
        elif token.startswith("snooze:"):
            action = "snooze"
            try:
                snooze_mins = int(token.split(":", 1)[1])
            except ValueError:
                snooze_mins = None

    if snooze_mins is not None and snooze_mins >= 1:
        # Stash requested delay for fire_layer / callers
        cfg_path = CONFIG_PATH
        try:
            # ephemeral: write next snooze override into state via return encoding
            # fire_layer reads "snooze" and uses config; patch state here if we have access
            pass
        except Exception:
            pass
        # Encode minutes in return as snooze:N for fire_layer
        return f"snooze:{snooze_mins}"

    if proc.returncode not in (0, None) and action == "skip":
        log(f"warn: overlay exit {proc.returncode}")

    return action


def fire_layer(
    layer: str,
    state: Dict[str, Any],
    exercises: Dict[str, Any],
    cfg: Dict[str, Any],
    now: Optional[datetime] = None,
    *,
    update_schedule: bool = True,
    test_mode: bool = False,
) -> str:
    """Full-screen takeover for layer. Optionally update last_* schedule."""
    now = now or datetime.now()
    action = show_layer_overlay(layer, exercises, cfg, test_mode=test_mode)

    if action == "snooze" or (isinstance(action, str) and action.startswith("snooze")):
        mins = int(cfg.get("snooze_minutes") or 5)
        if isinstance(action, str) and action.startswith("snooze:"):
            try:
                mins = max(1, int(action.split(":", 1)[1]))
            except ValueError:
                pass
        until = now + timedelta(minutes=mins)
        state["snooze_until"] = to_iso(until)
        save_state(state)
        log(f"snoozed {mins}m until {state['snooze_until']}")
        return "snooze"

    if action == "skip":
        # Skip: still advance schedule so we don't re-fire immediately
        if update_schedule:
            _stamp_layer_done(layer, state, now)
        return action

    # done
    if update_schedule:
        _stamp_layer_done(layer, state, now)
    return action


def _stamp_layer_done(layer: str, state: Dict[str, Any], now: datetime) -> None:
    iso = to_iso(now)
    state[f"last_{layer}"] = iso
    if layer == "C":
        state["last_B"] = iso
        state["last_A"] = iso
    elif layer == "B":
        state["last_A"] = iso
    state["day"] = now.date().isoformat()
    if not state.get("session_started"):
        state["session_started"] = iso
    save_state(state)
    log(f"stamped layer {layer} done at {iso}")


# ---------------------------------------------------------------------------
# Schedule evaluation
# ---------------------------------------------------------------------------

def maybe_reset_day(state: Dict[str, Any], now: datetime) -> None:
    """On calendar-day change, clear last_* so the workday starts fresh.

    If day was never stamped (first run / after once), only stamp today —
    do not wipe last_* that may have just been set by a test fire.
    """
    today = now.date().isoformat()
    prev = state.get("day")
    if prev == today:
        return
    if prev is not None:
        log(f"new day {today} (was {prev}): resetting last fire times")
        state["last_A"] = None
        state["last_B"] = None
        state["last_C"] = None
        # pause is "until end of day"
        state["paused"] = False
        state["snooze_until"] = None
    state["day"] = today
    if not state.get("session_started"):
        state["session_started"] = to_iso(now)
    save_state(state)


def layer_due(layer: str, state: Dict[str, Any], cfg: Dict[str, Any], now: datetime) -> bool:
    interval = int(cfg["intervals"].get(layer, DEFAULT_CONFIG["intervals"][layer]))
    last = parse_iso(state.get(f"last_{layer}"))
    if last is None:
        return True
    return (now - last).total_seconds() >= interval * 60


def pick_due_layer(
    state: Dict[str, Any],
    cfg: Dict[str, Any],
    now: datetime,
) -> Optional[str]:
    """Return highest-priority due layer, or None."""
    due = [L for L in LAYERS if layer_due(L, state, cfg, now)]
    if not due:
        return None
    return max(due, key=lambda L: PRIORITY[L])


def next_due_times(
    state: Dict[str, Any],
    cfg: Dict[str, Any],
    now: datetime,
) -> Dict[str, Optional[datetime]]:
    out: Dict[str, Optional[datetime]] = {}
    for layer in LAYERS:
        interval = int(cfg["intervals"].get(layer, DEFAULT_CONFIG["intervals"][layer]))
        last = parse_iso(state.get(f"last_{layer}"))
        if last is None:
            out[layer] = now  # due immediately when active
        else:
            out[layer] = last + timedelta(minutes=interval)
    return out


# ---------------------------------------------------------------------------
# PID management
# ---------------------------------------------------------------------------

def read_pid() -> Optional[int]:
    if not PID_PATH.exists():
        return None
    try:
        text = PID_PATH.read_text(encoding="utf-8").strip()
        return int(text) if text else None
    except (OSError, ValueError):
        return None


def pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def acquire_pid() -> bool:
    """Write PID file. Return False if another live daemon holds it."""
    existing = read_pid()
    if existing is not None and pid_is_alive(existing):
        print(f"desk-health already running (pid {existing})", file=sys.stderr)
        return False
    DATA.mkdir(parents=True, exist_ok=True)
    PID_PATH.write_text(str(os.getpid()) + "\n", encoding="utf-8")
    return True


def release_pid() -> None:
    try:
        if PID_PATH.exists():
            cur = read_pid()
            if cur is None or cur == os.getpid():
                PID_PATH.unlink(missing_ok=True)  # type: ignore[call-arg]
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_once(layer: str) -> int:
    """Fire overlay and advance schedule (real break)."""
    layer = layer.upper()
    if layer not in LAYERS:
        print(f"unknown layer {layer!r}; use A, B, or C", file=sys.stderr)
        return 2
    cfg = ensure_config()
    exercises = ensure_exercises()
    state = load_state()
    action = fire_layer(layer, state, exercises, cfg, update_schedule=True)
    print(f"Layer {layer}: {action}. Cheat sheet: {CHEAT_SHEET_PATH}")
    return 0


def cmd_test(layer: str) -> int:
    """Preview native UI. Default walks A→B→C. Pass A|B|C for a single layer."""
    layer = (layer or "all").upper()
    if not NATIVE_OVERLAY.exists():
        print("error: native overlay missing — bash native/build.sh", file=sys.stderr)
        return 1

    if layer in ("ALL", "SEQ", "SEQUENCE", ""):
        print("Opening TEST sequence A → B → C…")
        print("  Pre-warning → slow fade · Next through layers · Esc skips")
        cmd = [str(NATIVE_OVERLAY), "--test"]
    elif layer in LAYERS:
        print(f"Opening full-screen TEST for layer {layer}…")
        cmd = [str(NATIVE_OVERLAY), "--layer", layer, "--test"]
    else:
        print(f"unknown layer {layer!r}; use A, B, C, or all", file=sys.stderr)
        return 2

    try:
        proc = subprocess.run(cmd, check=False, text=True, capture_output=True, timeout=60 * 30)
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    action = "skip"
    for line in (proc.stdout or "").strip().splitlines():
        token = line.strip().lower()
        if token in ("done", "snooze", "skip"):
            action = token
    print(f"Test closed: {action}")
    print("(Schedule unchanged — this was preview only.)")
    return 0


def cmd_status() -> int:
    cfg = ensure_config()
    state = load_state()
    now = datetime.now()
    maybe_reset_day(state, now)

    print("desk-health status")
    print(f"  now:            {now.isoformat(timespec='seconds')}")
    print(f"  workday:        {cfg['workday_start']} – {cfg['workday_end']}")
    print(
        f"  quiet lunch:    {cfg.get('quiet_lunch_start')} – {cfg.get('quiet_lunch_end')}"
    )
    print(f"  intervals:      A={cfg['intervals']['A']}m  "
          f"B={cfg['intervals']['B']}m  C={cfg['intervals']['C']}m")
    print(f"  in work window: {in_work_window(now, cfg)}")
    print(f"  quiet lunch:    {in_quiet_lunch(now, cfg)}")
    print(f"  paused:         {state.get('paused')}")
    print(f"  snooze_until:   {state.get('snooze_until')}")
    print(f"  session_started:{state.get('session_started')}")
    print(f"  day:            {state.get('day')}")

    for layer in LAYERS:
        print(f"  last_{layer}:       {state.get(f'last_{layer}')}")

    due = next_due_times(state, cfg, now)
    print("  next due (if active):")
    for layer in LAYERS:
        t = due[layer]
        overdue = t is not None and t <= now
        flag = " (DUE NOW)" if overdue else ""
        print(f"    {layer}: {to_iso(t)}{flag}")

    pid = read_pid()
    if pid and pid_is_alive(pid):
        print(f"  daemon:         running (pid {pid})")
    else:
        print("  daemon:         not running")

    print(f"  config:         {CONFIG_PATH}")
    print(f"  exercises:      {EXERCISES_PATH}")
    print(f"  state:          {STATE_PATH}")
    print(f"  log:            {LOG_PATH}")
    return 0


def cmd_pause() -> int:
    state = load_state()
    state["paused"] = True
    save_state(state)
    log("paused until end of day (or resume)")
    print("Paused. Notifications suppressed until resume or next calendar day.")
    return 0


def cmd_resume() -> int:
    state = load_state()
    state["paused"] = False
    state["snooze_until"] = None
    save_state(state)
    log("resumed")
    print("Resumed.")
    return 0


def cmd_snooze(minutes: int) -> int:
    if minutes < 1:
        print("snooze minutes must be >= 1", file=sys.stderr)
        return 2
    state = load_state()
    until = datetime.now() + timedelta(minutes=minutes)
    state["snooze_until"] = to_iso(until)
    save_state(state)
    log(f"snoozed until {state['snooze_until']}")
    print(f"Snoozed for {minutes} minute(s) (until {state['snooze_until']}).")
    return 0


def cmd_run() -> int:
    if not acquire_pid():
        return 1

    cfg = ensure_config()
    exercises = ensure_exercises()
    state = load_state()
    now = datetime.now()
    if not state.get("session_started"):
        state["session_started"] = to_iso(now)
    maybe_reset_day(state, now)
    # First start of a session with no prior fires: seed last_* to NOW so the
    # first Layer A is ~20 min later (not an instant C blast on install).
    if state.get("last_A") is None and state.get("last_B") is None and state.get("last_C") is None:
        iso = to_iso(now)
        state["last_A"] = iso
        state["last_B"] = iso
        state["last_C"] = iso
        log("seeded last_* to now — first A in ~20m, B ~40m, C ~90m")
    save_state(state)

    tick = int(cfg.get("tick_seconds") or 20)
    tick = max(10, min(tick, 60))  # clamp 10–60s
    log(f"daemon started pid={os.getpid()} tick={tick}s")

    try:
        last_eval_minute: Optional[Tuple[int, int, int, int, int]] = None
        while True:
            now = datetime.now()
            # Reload config/exercises/state lightly so pause/snooze take effect
            try:
                cfg = ensure_config()
                exercises = ensure_exercises()
                state = load_state()
            except Exception as e:  # noqa: BLE001 — keep daemon alive
                log(f"warn: reload failed: {e}")

            maybe_reset_day(state, now)

            # Evaluate at most once per wall-clock minute (responsive snooze via tick)
            minute_key = (now.year, now.month, now.day, now.hour, now.minute)
            if minute_key != last_eval_minute:
                last_eval_minute = minute_key
                _evaluate_tick(now, state, cfg, exercises)

            time.sleep(tick)
    except KeyboardInterrupt:
        log("daemon stopped (KeyboardInterrupt)")
        print("\nStopped.")
        return 0
    finally:
        release_pid()


def _evaluate_tick(
    now: datetime,
    state: Dict[str, Any],
    cfg: Dict[str, Any],
    exercises: Dict[str, Any],
) -> None:
    if cfg.get("enabled") is False:
        return
    if state.get("paused"):
        return
    if is_snoozed(state, now):
        # Persist cleared snooze if it expired inside is_snoozed
        save_state(state)
        return
    if not in_work_window(now, cfg):
        return
    if in_quiet_lunch(now, cfg):
        return

    layer = pick_due_layer(state, cfg, now)
    if layer is None:
        return
    fire_layer(layer, state, exercises, cfg, now=now)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="desk-health",
        description="macOS layered desk-health break alarms (stdlib only).",
    )
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("run", help="run foreground daemon loop")
    once = sub.add_parser("once", help="fire real full-screen break (updates schedule)")
    once.add_argument(
        "layer",
        nargs="?",
        default="A",
        help="layer A, B, or C (default A)",
    )
    test = sub.add_parser(
        "test",
        help="preview UI (default: A→B→C sequence). Pass A|B|C for one layer.",
    )
    test.add_argument(
        "layer",
        nargs="?",
        default="all",
        help="all (default, A→B→C) or A|B|C",
    )
    sub.add_parser("menubar", help="start native menu bar manager")
    sub.add_parser("status", help="print next due times and config")
    sub.add_parser("pause", help="pause until end of day")
    sub.add_parser("resume", help="resume after pause/snooze")
    sn = sub.add_parser("snooze", help="snooze N minutes (default 5)")
    sn.add_argument("minutes", nargs="?", type=int, default=5)

    return p


def cmd_menubar() -> int:
    script = ROOT / "bin" / "start-menubar.sh"
    if not script.exists():
        print("error: start-menubar.sh missing", file=sys.stderr)
        return 1
    subprocess.Popen(["/bin/bash", str(script)])
    print("Starting menu bar… look for the figure icon near the clock.")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    cmd = args.command

    if cmd == "run":
        return cmd_run()
    if cmd == "once":
        return cmd_once(args.layer)
    if cmd == "test":
        return cmd_test(args.layer)
    if cmd == "menubar":
        return cmd_menubar()
    if cmd == "status":
        return cmd_status()
    if cmd == "pause":
        return cmd_pause()
    if cmd == "resume":
        return cmd_resume()
    if cmd == "snooze":
        return cmd_snooze(args.minutes)

    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
