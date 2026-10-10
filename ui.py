#!/usr/bin/env python3
"""Local web UI to scrub every RTSP feed to the same timestamp."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
import time
from collections import OrderedDict
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

ROOT = Path(__file__).resolve().parent
UI_DIR = ROOT / "ui"
START = ROOT / "start.sh"
STOP = ROOT / "stop.sh"
STATE = ROOT / ".rtsp-state"
VIDEO_EXTS = {".mp4", ".mkv", ".mov", ".avi", ".m4v", ".webm", ".ts", ".mts"}
SYNC_FILE = "rtsp-sync.txt"
PRESETS_FILE = "rtsp-presets.json"
HOST = os.environ.get("UI_HOST", "0.0.0.0")
PORT = int(os.environ.get("UI_PORT", "8787"))

CURRENT_FOLDER: Path | None = None
PROBE_CACHE: dict | None = None
FRAME_CACHE = OrderedDict()
FRAME_CACHE_LOCK = threading.Lock()
FRAME_CACHE_MAX = 96
FRAME_SEM = threading.Semaphore(2)
FRAME_JOBS = {}
FRAME_JOBS_LOCK = threading.Lock()
FRAME_JOB_GEN = {}
STREAM_LOCK = threading.Lock()
CLIP_LOCK = threading.Lock()
CLIP_STEM_RE = re.compile(r"^(.*)_clip(\d+)$")
OVERLAY_CORNERS = ("top-left", "bottom-left", "top-right", "bottom-right")


def normalize_overlay_pos(value) -> str:
    raw = str(value or "").strip().lower().replace("_", "-").replace(" ", "-")
    aliases = {
        "tl": "top-left",
        "topleft": "top-left",
        "tr": "top-right",
        "topright": "top-right",
        "bl": "bottom-left",
        "bottomleft": "bottom-left",
        "br": "bottom-right",
        "bottomright": "bottom-right",
    }
    raw = aliases.get(raw, raw)
    return raw if raw in OVERLAY_CORNERS else "top-left"


def parse_jitter_seconds(value) -> float:
    seconds = float(value)
    if seconds < 0.1 or seconds > 120:
        raise ValueError("jitter seconds must be between 0.1 and 120")
    return round(seconds, 3)


class FrameSuperseded(Exception):
    """A newer frame request replaced this ffmpeg job."""


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return ""


def running_ffmpeg() -> bool:
    pids = read_text(STATE / "pids")
    for line in pids.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "ffmpeg":
            try:
                os.kill(int(parts[1]), 0)
                return True
            except (OSError, ValueError):
                continue
    return False


def detect_lan_ip() -> str:
    try:
        result = subprocess.run(
            ["ip", "-4", "route", "get", "1.1.1.1"],
            capture_output=True,
            text=True,
            check=False,
            timeout=2,
        )
        parts = result.stdout.split()
        if "src" in parts:
            return parts[parts.index("src") + 1]
    except Exception:
        pass
    return "127.0.0.1"


def load_ui_session() -> dict:
    path = STATE / "ui.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def save_ui_session(body: dict) -> dict:
    STATE.mkdir(parents=True, exist_ok=True)
    current = load_ui_session()
    folder = str(body.get("folder") or current.get("folder") or "").strip()
    if folder:
        current["folder"] = folder
    if "height" in body:
        current["height"] = str(body.get("height") or "")
    if "offset" in body:
        current["offset"] = float(body["offset"] or 0)
    if "end" in body:
        end = body["end"]
        current["end"] = None if end in (None, "") else float(end)
    if "loop" in body:
        current["loop"] = bool(body["loop"])
    if "align" in body:
        current["align"] = bool(body["align"])
    if "selected" in body and isinstance(body["selected"], list):
        current["selected"] = [Path(str(name)).name for name in body["selected"]]
    if "marks" in body and isinstance(body["marks"], dict):
        current["marks"] = {Path(str(key)).name: float(val) for key, val in body["marks"].items()}
    if "ref" in body:
        ref = str(body.get("ref") or "").strip()
        current["ref"] = Path(ref).name if ref else None
    if "seeks" in body and isinstance(body["seeks"], dict):
        current["seeks"] = {Path(str(key)).name: float(val) for key, val in body["seeks"].items()}
    if "overlay" in body:
        current["overlay"] = bool(body["overlay"])
    if "overlay_pos" in body:
        current["overlay_pos"] = normalize_overlay_pos(body.get("overlay_pos"))
    if "origin" in body:
        current["origin"] = str(body.get("origin") or "").strip()
    if "jitter" in body and body["jitter"] not in (None, ""):
        current["jitter"] = parse_jitter_seconds(body["jitter"])
    (STATE / "ui.json").write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
    if folder and Path(folder).expanduser().is_dir() and any(k in body for k in ("marks", "ref", "align")):
        save_sync(
            folder,
            current.get("marks") or {},
            current.get("ref"),
            bool(current.get("align")),
        )
    return current


def parse_frame_rate(rate: str) -> float:
    raw = (rate or "").strip()
    if not raw or raw in {"0/0", "N/A"}:
        return 30.0
    try:
        if "/" in raw:
            num, den = raw.split("/", 1)
            denom = float(den)
            if denom == 0:
                return 30.0
            fps = float(num) / denom
        else:
            fps = float(raw)
        if fps <= 0 or fps > 240:
            return 30.0
        return fps
    except ValueError:
        return 30.0


def probe_media(path: Path) -> tuple[float, float]:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "format=duration:stream=r_frame_rate,avg_frame_rate",
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    data = json.loads(result.stdout or "{}")
    duration = float((data.get("format") or {}).get("duration") or 0)
    stream = (data.get("streams") or [{}])[0]
    avg_raw = (stream.get("avg_frame_rate") or "").strip()
    r_raw = (stream.get("r_frame_rate") or "").strip()
    fps = parse_frame_rate(avg_raw if avg_raw not in {"", "0/0", "N/A"} else r_raw or "30/1")
    return duration, fps


def list_videos(folder: Path) -> list[dict]:
    videos = []
    for path in sorted(folder.iterdir()):
        if path.is_file() and path.suffix.lower() in VIDEO_EXTS and not CLIP_STEM_RE.match(path.stem):
            duration, fps = probe_media(path)
            videos.append(
                {
                    "name": path.name,
                    "path": str(path),
                    "duration": duration,
                    "fps": fps,
                    "mtime": path.stat().st_mtime,
                }
            )
    return videos


def resolve_folder(folder: str) -> Path:
    path = Path(folder).expanduser().resolve()
    if not path.is_dir():
        raise ValueError(f"Not a directory: {path}")
    return path


def parse_sync_text(text: str) -> dict:
    marks: dict[str, float] = {}
    ref = None
    align = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        lower = line.lower()
        if lower.startswith("ref "):
            name = Path(line[4:].strip()).name
            ref = None if name in {"", "-", "none"} else name
            continue
        if lower.startswith("align "):
            align = line.split(None, 1)[1].strip().lower() not in {"0", "false", "no", "off"}
            continue
        parts = line.rsplit(" ", 1)
        if len(parts) != 2:
            continue
        try:
            marks[Path(parts[0]).name] = float(parts[1])
        except ValueError:
            continue
    return {"marks": marks, "ref": ref, "align": align}


def format_sync_text(marks: dict, ref: str | None, align: bool = False) -> str:
    lines = ["# rtsp-folder-streamer sync"]
    if ref:
        lines.append(f"ref {Path(str(ref)).name}")
    if align:
        lines.append("align 1")
    for name in sorted(marks):
        lines.append(f"{Path(str(name)).name} {float(marks[name]):.4f}")
    return "\n".join(lines) + "\n"


def load_sync(folder: Path) -> dict:
    path = folder / SYNC_FILE
    if not path.is_file():
        return {"marks": {}, "ref": None, "align": False, "path": str(path), "has_file": False}
    data = parse_sync_text(read_text(path))
    data["path"] = str(path)
    data["has_file"] = True
    return data


def save_sync(folder: str, marks: dict | None, ref: str | None, align: bool = False) -> dict:
    path = resolve_folder(folder)
    clean = {}
    for name, value in (marks or {}).items():
        base = Path(str(name)).name
        if not base or base in {".", ".."}:
            continue
        clean[base] = float(value)
    ref_name = Path(str(ref)).name if ref else None
    if ref_name in {"", "-", "none"}:
        ref_name = None
    dest = path / SYNC_FILE
    dest.write_text(format_sync_text(clean, ref_name, align), encoding="utf-8")
    return {"marks": clean, "ref": ref_name, "align": bool(align), "path": str(dest), "has_file": True}


def parse_presets(raw) -> list[dict]:
    rows = []
    if not isinstance(raw, list):
        return rows
    seen = set()
    for item in raw:
        if not isinstance(item, dict):
            continue
        name = re.sub(r"\s+", " ", str(item.get("name") or "").strip())[:80]
        if not name or name.lower() in seen:
            continue
        try:
            start = float(item.get("start"))
            end = float(item.get("end"))
        except (TypeError, ValueError):
            continue
        if end < start + 0.5:
            continue
        seen.add(name.lower())
        rows.append({"name": name, "start": start, "end": end})
    return rows[:80]


def load_presets(folder: Path) -> list[dict]:
    path = folder / PRESETS_FILE
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return []
    return parse_presets(data)


def save_presets(folder: str, presets) -> list[dict]:
    path = resolve_folder(folder)
    rows = parse_presets(presets)
    dest = path / PRESETS_FILE
    dest.write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
    return rows


def probe_folder(folder: str) -> dict:
    global CURRENT_FOLDER, PROBE_CACHE
    path = resolve_folder(folder)
    videos = list_videos(path)
    if not videos:
        raise ValueError(f"No video files in {path}")
    CURRENT_FOLDER = path
    max_offset = min(v["duration"] for v in videos)
    saved = load_sync(path)
    PROBE_CACHE = {
        "folder": str(path),
        "count": len(videos),
        "max_offset": max_offset,
        "videos": videos,
        "marks": saved["marks"],
        "ref": saved["ref"],
        "align": saved["align"],
        "has_file": saved["has_file"],
        "sync_file": saved["path"],
        "presets": load_presets(path),
    }
    return PROBE_CACHE


def safe_video(name: str) -> Path:
    if CURRENT_FOLDER is None:
        raise ValueError("Load a folder first")
    base = Path(unquote(name)).name
    path = (CURRENT_FOLDER / base).resolve()
    if path.parent != CURRENT_FOLDER:
        raise ValueError("invalid path")
    if path.suffix.lower() not in VIDEO_EXTS or not path.is_file():
        raise FileNotFoundError(base)
    return path


def extract_frame(path: Path, t: float, height: int = 360) -> bytes:
    t = max(0.0, float(t))
    height = max(120, min(1080, int(height)))
    key = (str(path), round(t, 4), height)
    with FRAME_CACHE_LOCK:
        cached = FRAME_CACHE.get(key)
        if cached:
            FRAME_CACHE.move_to_end(key)
            return cached
    # GOP on these files is ~1s; decode from the previous keyframe through t.
    pre = max(0.0, t - 1.05)
    remain = t - pre
    cmd = [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-threads",
        "1",
        "-ss",
        f"{pre:.4f}",
        "-i",
        str(path),
        "-ss",
        f"{remain:.4f}",
        "-frames:v",
        "1",
        "-update",
        "1",
        "-an",
        "-vf",
        "scale=-2:%d:flags=fast_bilinear" % height,
        "-q:v",
        "4",
        "-f",
        "image2pipe",
        "pipe:1",
    ]
    job_key = (str(path), height)
    with FRAME_JOBS_LOCK:
        gen = FRAME_JOB_GEN.get(job_key, 0) + 1
        FRAME_JOB_GEN[job_key] = gen
        old = FRAME_JOBS.pop(job_key, None)
    if old and old.poll() is None:
        old.kill()
    with FRAME_SEM:
        with FRAME_JOBS_LOCK:
            if FRAME_JOB_GEN.get(job_key) != gen:
                raise FrameSuperseded()
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        with FRAME_JOBS_LOCK:
            if FRAME_JOB_GEN.get(job_key) != gen:
                proc.kill()
                proc.communicate()
                raise FrameSuperseded()
            FRAME_JOBS[job_key] = proc
        try:
            stdout, _stderr = proc.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            raise RuntimeError(f"No frame at {t:.1f}s in {path.name}")
        finally:
            with FRAME_JOBS_LOCK:
                if FRAME_JOBS.get(job_key) is proc:
                    del FRAME_JOBS[job_key]
    with FRAME_JOBS_LOCK:
        if FRAME_JOB_GEN.get(job_key) != gen:
            raise FrameSuperseded()
    if proc.returncode and proc.returncode < 0:
        raise FrameSuperseded()
    if proc.returncode != 0 or not stdout:
        raise RuntimeError(f"No frame at {t:.1f}s in {path.name}")
    with FRAME_CACHE_LOCK:
        FRAME_CACHE[key] = stdout
        while len(FRAME_CACHE) > FRAME_CACHE_MAX:
            FRAME_CACHE.popitem(last=False)
    return stdout


def parse_urls(output: str) -> list[str]:
    urls = []
    capture = False
    for line in output.splitlines():
        if line.strip() == "RTSP URLs:":
            capture = True
            continue
        if capture:
            if line.startswith("rtsp://"):
                urls.append(line.strip())
            elif line.strip():
                break
    return urls


def parse_origin_unix(value) -> float | None:
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    raw = str(value).strip()
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        pass
    for fmt in (
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M",
        "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
    ):
        try:
            return datetime.strptime(raw, fmt).timestamp()
        except ValueError:
            continue
    raise ValueError("invalid origin datetime; use YYYY-MM-DDTHH:MM:SS")


def start_streams(
    folder: str,
    height: str,
    offset: float,
    end: float | None = None,
    loop: bool = True,
    files: list[str] | None = None,
    marks: dict | None = None,
    ref: str | None = None,
    overlay: bool = False,
    origin: str | float | None = None,
    overlay_pos: str | None = None,
) -> dict:
    global CURRENT_FOLDER
    CURRENT_FOLDER = Path(folder).expanduser().resolve()
    cmd = [str(START), folder]
    if height:
        cmd += ["--res", str(height)]
    cmd += ["--offset", f"{float(offset):.3f}"]
    if end is not None:
        cmd += ["--end", f"{float(end):.3f}"]
    cmd += ["--loop" if loop else "--no-loop"]
    for name in files or []:
        base = Path(str(name)).name
        if not base or "/" in str(name) or "\\" in str(name) or base in {".", ".."}:
            raise ValueError(f"invalid file name: {name}")
        cmd += ["--only", base]
    if marks and ref:
        for name, t in marks.items():
            base = Path(str(name)).name
            cmd += ["--mark", f"{base}={float(t):.3f}"]
        cmd += ["--ref", Path(str(ref)).name]
    overlay_pos = normalize_overlay_pos(overlay_pos)
    if overlay:
        cmd += ["--overlay", "--overlay-pos", overlay_pos]
        origin_unix = parse_origin_unix(origin)
        if origin_unix is not None:
            cmd += ["--origin-unix", f"{origin_unix:.3f}"]
    result = subprocess.run(
        cmd,
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    output = (result.stdout or "") + ("\n" + result.stderr if result.stderr else "")
    if result.returncode != 0:
        tail = "\n".join(output.strip().splitlines()[-12:]) or "start.sh failed"
        raise RuntimeError(tail)
    urls = [
        line.strip()
        for line in read_text(STATE / "urls").splitlines()
        if line.startswith("rtsp://")
    ] or parse_urls(output)
    n = len(urls)
    if end is not None and loop:
        message = f"{n} feed(s) looping {offset:.1f}s–{end:.1f}s."
    elif end is not None:
        message = f"{n} feed(s) playing {offset:.1f}s–{end:.1f}s once."
    else:
        message = f"{n} feed(s) started from {offset:.1f}s."
    if marks and ref:
        message = message[:-1] + f" aligned to {Path(str(ref)).name}."
    if overlay:
        message = message[:-1] + " with timestamp overlay."
    return {
        "urls": urls,
        "offset": float(offset),
        "end": end,
        "loop": loop,
        "files": files or [],
        "height": height,
        "folder": folder,
        "message": message,
        "marks": marks or {},
        "ref": ref,
        "overlay": overlay,
        "origin": origin,
        "overlay_pos": overlay_pos,
    }


def stop_streams() -> dict:
    result = subprocess.run(
        [str(STOP)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout or "stop.sh failed").strip())
    return {"message": (result.stdout or "Stopped.").strip().splitlines()[-1]}


def start_from_session(session: dict | None = None) -> dict:
    session = session or load_ui_session()
    folder = str(session.get("folder") or "").strip()
    if not folder:
        raise ValueError("folder is required")
    files = session.get("selected") if isinstance(session.get("selected"), list) else []
    files = [Path(str(name)).name for name in files]
    if not files:
        raise ValueError("Select at least one video")
    end = session.get("end")
    end = None if end in (None, "") else float(end)
    marks = session.get("marks") if isinstance(session.get("marks"), dict) else {}
    marks = {Path(str(key)).name: float(val) for key, val in marks.items()}
    ref = str(session.get("ref") or "").strip() or None
    align = bool(session.get("align"))
    use_align = bool(align and marks and ref)
    return start_streams(
        folder,
        str(session.get("height") or ""),
        float(session.get("offset") or 0),
        end,
        bool(session.get("loop", True)),
        files,
        marks if use_align else None,
        ref if use_align else None,
        bool(session.get("overlay")),
        session.get("origin") or "",
        session.get("overlay_pos"),
    )


def next_clip_number(folder: Path) -> int:
    highest = 0
    try:
        for path in folder.iterdir():
            match = CLIP_STEM_RE.match(path.stem if path.is_file() else path.name)
            if match:
                highest = max(highest, int(match.group(2)))
    except FileNotFoundError:
        return 1
    return highest + 1


def aligned_file_window(
    name: str,
    start: float,
    end: float,
    marks: dict[str, float],
    ref: str | None,
    align: bool,
) -> tuple[float, float]:
    ss = float(start)
    ee = float(end)
    if align and ref and marks.get(name) is not None and marks.get(ref) is not None:
        delta = float(marks[name]) - float(marks[ref])
        ss += delta
        ee += delta
    if ss < 0:
        raise ValueError(
            f"{name} starts at {ss:.3f}s after alignment. Move start later on the reference timeline."
        )
    if ee < ss + 0.5:
        raise ValueError(f"{name}: aligned range {ss:.3f}s–{ee:.3f}s is too short.")
    return ss, ee


def normalize_clip_height(value) -> int | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    if not re.fullmatch(r"[0-9]+", raw):
        raise ValueError("invalid height")
    height = int(raw) - int(raw) % 2
    if height < 144 or height > 4320:
        raise ValueError("invalid height")
    return height


def cut_clip(src: Path, dest: Path, start: float, duration: float, height: int | None = None) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    ss = f"{start:.3f}"
    dur = f"{duration:.3f}"
    timeout = max(300.0, duration * 20.0 + 60.0) if height else max(120.0, duration * 4.0 + 30.0)
    if not height:
        copy_cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-ss", ss, "-i", str(src), "-t", dur,
            "-map", "0:v:0", "-map", "0:a?",
            "-c", "copy", "-avoid_negative_ts", "make_zero",
            str(dest),
        ]
        result = subprocess.run(copy_cmd, capture_output=True, text=True, check=False, timeout=timeout)
        if result.returncode == 0 and dest.is_file() and dest.stat().st_size > 0:
            return
        if dest.exists():
            dest.unlink()
    encode_cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-ss", ss, "-i", str(src), "-t", dur,
        "-map", "0:v:0", "-map", "0:a?",
    ]
    if height:
        encode_cmd += ["-vf", f"scale=-2:{height}"]
    encode_cmd += [
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-movflags", "+faststart",
        str(dest),
    ]
    result = subprocess.run(encode_cmd, capture_output=True, text=True, check=False, timeout=timeout)
    if result.returncode != 0 or not dest.is_file() or dest.stat().st_size == 0:
        err = (result.stderr or result.stdout or "ffmpeg failed").strip().splitlines()
        raise RuntimeError(f"{src.name}: " + (err[-1] if err else "clip export failed"))


def export_clips(
    folder: str,
    offset: float,
    end: float,
    files: list[str],
    marks: dict | None = None,
    ref: str | None = None,
    align: bool = False,
    height: str | int | None = None,
) -> dict:
    global CURRENT_FOLDER
    path = resolve_folder(folder)
    CURRENT_FOLDER = path
    names = [Path(str(name)).name for name in files]
    if not names:
        raise ValueError("Select at least one video")
    if end < offset + 0.5:
        raise ValueError("End time must be at least 0.5s after start.")
    marks = {Path(str(key)).name: float(val) for key, val in (marks or {}).items()}
    ref_name = Path(str(ref)).name if ref else None
    use_align = bool(align and marks and ref_name)
    if use_align:
        missing = [name for name in names if name not in marks]
        if missing:
            raise ValueError("Missing sync mark for " + ", ".join(missing))
        if ref_name not in marks:
            raise ValueError(f"Reference camera '{ref_name}' has no sync mark.")
    n = next_clip_number(path)
    out_height = normalize_clip_height(height)
    written: list[str] = []
    for name in names:
        src = path / name
        if not src.is_file():
            raise FileNotFoundError(name)
        duration, _fps = probe_media(src)
        ss, ee = aligned_file_window(name, offset, end, marks, ref_name, use_align)
        if ee > duration:
            ee = duration
        if ee < ss + 0.5:
            raise ValueError(f"{name} aligned range is past the end of the file.")
        dest = path / f"{src.stem}_clip{n}{src.suffix.lower()}"
        cut_clip(src, dest, ss, ee - ss, out_height)
        written.append(str(dest))
    save_ui_session({"folder": str(path), "clip": n, "height": str(out_height or "")})
    label = f" at {out_height}p" if out_height else " at original resolution"
    return {
        "clip": n,
        "folder": str(path),
        "files": written,
        "offset": float(offset),
        "end": float(end),
        "height": out_height,
        "next_clip": n + 1,
        "message": f"Saved {len(written)} synchronized clip{n} file(s){label} in {path}.",
    }


def jitter_streams(seconds: float) -> dict:
    if not running_ffmpeg():
        raise ValueError("Start feeds before jitter")
    save_ui_session({"jitter": seconds})
    stop_streams()
    time.sleep(seconds)
    result = start_from_session()
    result["jitter"] = seconds
    result["message"] = f"Jittered {seconds:g}s. " + result["message"]
    return result


def status() -> dict:
    session = load_ui_session()
    folder = str(session.get("folder") or read_text(STATE / "folder") or "").strip()
    height = str(session["height"]) if "height" in session else read_text(STATE / "height")
    offset_raw = session.get("offset")
    if offset_raw is None:
        offset_raw = read_text(STATE / "offset") or "0"
    end_raw = session["end"] if "end" in session else read_text(STATE / "end")
    if "loop" in session:
        loop = bool(session["loop"])
    else:
        loop = (read_text(STATE / "loop") or "1") != "0"
    selected = session.get("selected")
    if not isinstance(selected, list) or not selected:
        selected = [line for line in read_text(STATE / "selected").splitlines() if line.strip()]
    marks: dict[str, float] = {}
    ref = ""
    align = bool(session.get("align"))
    has_file = False
    if folder and Path(folder).expanduser().is_dir():
        saved = load_sync(Path(folder).expanduser().resolve())
        marks = saved["marks"] or (session.get("marks") if isinstance(session.get("marks"), dict) else {})
        ref = saved["ref"] or session.get("ref") or ""
        align = saved["align"] if saved["has_file"] else align
        has_file = saved["has_file"]
    if not marks:
        session_marks = session.get("marks")
        if isinstance(session_marks, dict):
            marks = {str(k): float(v) for k, v in session_marks.items()}
        else:
            for line in read_text(STATE / "marks").splitlines():
                parts = line.rsplit(" ", 1)
                if len(parts) == 2:
                    try:
                        marks[parts[0]] = float(parts[1])
                    except ValueError:
                        pass
        ref = session.get("ref") or read_text(STATE / "ref")
    urls = [
        line.strip()
        for line in read_text(STATE / "urls").splitlines()
        if line.startswith("rtsp://")
    ]
    try:
        offset = float(offset_raw)
    except ValueError:
        offset = 0.0
    try:
        end = float(end_raw) if end_raw else None
    except ValueError:
        end = None
    payload = {
        "folder": folder,
        "height": height,
        "offset": offset,
        "end": end,
        "loop": loop,
        "selected": selected,
        "marks": marks,
        "ref": ref,
        "align": align,
        "has_file": has_file,
        "seeks": session.get("seeks") if isinstance(session.get("seeks"), dict) else {},
        "urls": urls if running_ffmpeg() else [],
        "running": running_ffmpeg(),
        "max_offset": 0.0,
        "videos": [],
        "host": detect_lan_ip(),
        "ui_url": f"http://{detect_lan_ip()}:{PORT}",
        "overlay": bool(session.get("overlay")),
        "overlay_pos": normalize_overlay_pos(session.get("overlay_pos")),
        "origin": str(session.get("origin") or ""),
        "jitter": 2.0,
        "next_clip": 1,
        "presets": [],
    }
    try:
        payload["jitter"] = parse_jitter_seconds(session.get("jitter", 2))
    except (TypeError, ValueError):
        payload["jitter"] = 2.0
    if folder and Path(folder).expanduser().is_dir():
        folder_path = Path(folder).expanduser().resolve()
        try:
            payload["next_clip"] = next_clip_number(folder_path)
        except OSError:
            payload["next_clip"] = 1
        payload["presets"] = load_presets(folder_path)
    if folder and PROBE_CACHE and PROBE_CACHE.get("folder") == str(Path(folder).resolve()):
        payload["max_offset"] = PROBE_CACHE["max_offset"]
        payload["videos"] = PROBE_CACHE["videos"]
    elif folder and Path(folder).is_dir():
        try:
            probed = probe_folder(folder)
            payload["max_offset"] = probed["max_offset"]
            payload["videos"] = probed["videos"]
        except (ValueError, subprocess.CalledProcessError):
            pass
    return payload


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = None

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code: int, payload, content_type: str = "application/json") -> None:
        data = payload if isinstance(payload, (bytes, bytearray)) else (
            payload.encode("utf-8") if isinstance(payload, str) else json.dumps(payload).encode("utf-8")
        )
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _json_body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/status":
            self._send(200, status())
            return
        if parsed.path == "/api/probe":
            folder = (parse_qs(parsed.query).get("folder") or [""])[0]
            try:
                self._send(200, probe_folder(folder))
            except Exception as exc:
                self._send(400, {"error": str(exc)})
            return
        if parsed.path == "/api/frame":
            qs = parse_qs(parsed.query)
            name = (qs.get("name") or [""])[0]
            t = (qs.get("t") or ["0"])[0]
            try:
                height = int((qs.get("h") or ["360"])[0])
            except ValueError:
                height = 360
            try:
                jpeg = extract_frame(safe_video(name), float(t), height)
                self._send(200, jpeg, "image/jpeg")
            except (FrameSuperseded, BrokenPipeError, ConnectionResetError):
                return
            except Exception as exc:
                try:
                    self._send(400, {"error": str(exc)})
                except (BrokenPipeError, ConnectionResetError):
                    return
            return
        if parsed.path in ("/", "/index.html"):
            html = (UI_DIR / "index.html").read_bytes()
            self._send(200, html, "text/html; charset=utf-8")
            return
        self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        try:
            body = self._json_body()
        except json.JSONDecodeError:
            self._send(400, {"error": "invalid JSON"})
            return
        try:
            if parsed.path == "/api/start":
                folder = str(body.get("folder") or "").strip()
                height = str(body.get("height") or "").strip()
                offset = float(body.get("offset") or 0)
                end_raw = body.get("end", None)
                end = float(end_raw) if end_raw not in (None, "") else None
                loop = bool(body.get("loop", True))
                files = body.get("files") or []
                if not folder:
                    raise ValueError("folder is required")
                if height and not re.fullmatch(r"[0-9]+", height):
                    raise ValueError("invalid height")
                if not isinstance(files, list):
                    raise ValueError("files must be a list")
                files = [str(name) for name in files]
                if not files:
                    raise ValueError("Select at least one video")
                raw_marks = body.get("marks") or {}
                if not isinstance(raw_marks, dict):
                    raise ValueError("marks must be an object")
                marks = {}
                for key, val in raw_marks.items():
                    marks[Path(str(key)).name] = float(val)
                ref = str(body.get("ref") or "").strip() or None
                overlay = bool(body.get("overlay"))
                overlay_pos = normalize_overlay_pos(body.get("overlay_pos"))
                origin = str(body.get("origin") or "").strip()
                if overlay and origin:
                    parse_origin_unix(origin)
                save_ui_session({
                    "folder": folder,
                    "height": height,
                    "offset": offset,
                    "end": end,
                    "loop": loop,
                    "selected": files,
                    "marks": marks,
                    "ref": ref,
                    "align": bool(body.get("align")),
                    "seeks": body.get("seeks") or {},
                    "overlay": overlay,
                    "overlay_pos": overlay_pos,
                    "origin": origin,
                    "jitter": body.get("jitter"),
                })
                if not STREAM_LOCK.acquire(blocking=False):
                    raise RuntimeError("Start/stop already in progress")
                try:
                    self._send(200, start_streams(
                        folder, height, offset, end, loop, files, marks or None, ref,
                        overlay, origin, overlay_pos,
                    ))
                finally:
                    STREAM_LOCK.release()
                return
            if parsed.path == "/api/session":
                self._send(200, save_ui_session(body))
                return
            if parsed.path == "/api/presets":
                folder = str(body.get("folder") or "").strip()
                if not folder:
                    raise ValueError("folder is required")
                rows = save_presets(folder, body.get("presets") or [])
                self._send(200, {"presets": rows, "folder": str(resolve_folder(folder))})
                return
            if parsed.path == "/api/jitter":
                seconds = parse_jitter_seconds(body.get("seconds", body.get("jitter")))
                if not STREAM_LOCK.acquire(blocking=False):
                    raise RuntimeError("Start/stop already in progress")
                try:
                    self._send(200, jitter_streams(seconds))
                finally:
                    STREAM_LOCK.release()
                return
            if parsed.path == "/api/sync":
                folder = str(body.get("folder") or "").strip()
                if not folder:
                    raise ValueError("folder is required")
                raw_marks = body.get("marks") or {}
                if not isinstance(raw_marks, dict):
                    raise ValueError("marks must be an object")
                marks = {}
                for key, val in raw_marks.items():
                    marks[Path(str(key)).name] = float(val)
                ref = str(body.get("ref") or "").strip() or None
                align = bool(body.get("align"))
                self._send(200, save_sync(folder, marks, ref, align))
                return
            if parsed.path == "/api/clip":
                folder = str(body.get("folder") or "").strip()
                offset = float(body.get("offset") or 0)
                end_raw = body.get("end", None)
                end = float(end_raw) if end_raw not in (None, "") else None
                files = body.get("files") or []
                if not folder:
                    raise ValueError("folder is required")
                if end is None:
                    raise ValueError("end time is required")
                if not isinstance(files, list):
                    raise ValueError("files must be a list")
                files = [str(name) for name in files]
                raw_marks = body.get("marks") or {}
                if not isinstance(raw_marks, dict):
                    raise ValueError("marks must be an object")
                marks = {Path(str(key)).name: float(val) for key, val in raw_marks.items()}
                ref = str(body.get("ref") or "").strip() or None
                height = str(body.get("height") or "").strip()
                if height and not re.fullmatch(r"[0-9]+", height):
                    raise ValueError("invalid height")
                if not CLIP_LOCK.acquire(blocking=False):
                    raise RuntimeError("Clip export already in progress")
                try:
                    self._send(200, export_clips(
                        folder, offset, end, files, marks, ref, bool(body.get("align")), height,
                    ))
                finally:
                    CLIP_LOCK.release()
                return
            if parsed.path == "/api/stop":
                if not STREAM_LOCK.acquire(blocking=False):
                    raise RuntimeError("Start/stop already in progress")
                try:
                    self._send(200, stop_streams())
                finally:
                    STREAM_LOCK.release()
                return
        except Exception as exc:
            self._send(400, {"error": str(exc)})
            return
        self._send(404, {"error": "not found"})


def main() -> None:
    if not START.is_file():
        sys.exit("start.sh not found")
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    lan = detect_lan_ip()
    print(f"Sync UI: http://127.0.0.1:{PORT}", flush=True)
    if lan not in {"127.0.0.1", "localhost"}:
        print(f"         http://{lan}:{PORT}", flush=True)
    print("Start from the web UI publishes RTSP on this machine.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped UI server.")


if __name__ == "__main__":
    main()
