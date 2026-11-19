#!/usr/bin/env python3
"""Frame MCP server (stdio, localhost only).

Owns Frame's AI access: exposes framing + animation tools over JSON-RPC 2.0
on stdio (newline-delimited, one request per line). No sockets, no secrets,
all JSON in/out -- local pipe transport means localhost-only by construction.

Tools:
  frame.info            validate a .frameproj, report layers/device/colors
  frame.render          still PNG via the project (delegates to the sibling
                        FrameCore Renderer) -- NO compositing logic lives
                        here, only delegation
  frame.animate_preview return a preset's expanded timeline JSON for live preview
  frame.export_video    ffmpeg render via render_video.py (PNG seq -> h264/hevc,
                        hevc-alpha/prores alpha -> .mov)
  frame.list_devices    passthrough `frames list`
  frame.list_colors     passthrough `frames list-colors <device>`

Protocol: {"jsonrpc":"2.0","id":1,"method":"tools/call",
           "params":{"name":"frame.info","arguments":{...}}}
plus MCP handshake methods `initialize` and `tools/list`.
Every response carries {"jsonrpc":"2.0","id":<id>,"result":{...}} or
{"jsonrpc":"2.0","id":<id>,"error":{"code":N,"message":...,"data":...}}.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parent
MOTION_DIR = SERVER_DIR.parent / "FrameMotion"
sys.path.insert(0, str(SERVER_DIR))
sys.path.insert(0, str(MOTION_DIR))
sys.path.insert(0, str(SERVER_DIR.parent / "FrameCore"))

from schema import load_project, validate_project, using_sibling_schema  # noqa: E402
from engine import load_preset, load_presets, timeline, swiftui_params  # noqa: E402

SERVER_VERSION = "0.1.0"
FRAMES_BIN = os.environ.get("FRAMES_BIN") or str(Path.home() / ".local" / "bin" / "frames")
VIDEO_EXTS = {".mp4", ".mov", ".m4v"}


def _err(message: str, data=None) -> dict:
    e = {"code": -32000, "message": message}
    if data is not None:
        e["data"] = data
    return e


def _run_frames(*argv, timeout=300) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    if "FRAMES_ASSETS" in os.environ:  # passthrough, never minted here
        env["FRAMES_ASSETS"] = os.environ["FRAMES_ASSETS"]
    return subprocess.run([FRAMES_BIN, *argv], capture_output=True, text=True,
                          timeout=timeout, env=env)


def _project_args(doc: dict, project_path: str) -> dict:
    """Resolve a validated .frameproj to input paths (read-only).

    Real schema (Sources/FrameCore/project_schema.json): screenshot.path is
    the source pixels; frame.output is an optional cached framed PNG;
    backdrop.path is an optional photo. Relative paths resolve against the
    .frameproj file's directory.
    """
    base = Path(project_path).expanduser().parent
    shot = doc.get("screenshot") or {}
    frame = doc.get("frame") or {}
    bd = doc.get("backdrop") or {}

    def _abs(p):
        p = Path(p)
        return str(p if p.is_absolute() else base / p)

    sources = []
    if shot.get("path"):
        sources.append(_abs(shot["path"]))
    if frame.get("output"):
        sources.append(_abs(frame["output"]))
    if bd.get("path"):
        sources.append(_abs(bd["path"]))
    missing = [s for s in sources if not Path(s).exists()]
    videos = [s for s in sources if Path(s).suffix.lower() in VIDEO_EXTS]
    return {"sources": sources, "missing": missing, "videos": videos,
            "frame": {"device": frame.get("device"), "color": frame.get("color")},
            "animation_preset": (doc.get("animation") or {}).get("preset")}


def tool_info(args: dict) -> dict:
    path = args.get("project")
    if not path:
        return {"error": "missing argument: project (.frameproj path)"}
    try:
        project = load_project(path)
    except ValueError as e:
        return {"error": str(e)}
    errors = validate_project(project)
    if errors:
        return {"error": "invalid .frameproj", "details": errors}
    resolved = _project_args(project, path)
    if resolved["missing"]:
        return {"error": "layer source(s) not found", "missing": resolved["missing"]}
    out: dict = {"project": str(path),
                 "frame": resolved["frame"],
                 "animation_preset": resolved["animation_preset"],
                 "schema": "sibling-FrameCore" if using_sibling_schema() else "builtin-minimal"}
    # Device/color detection delegates to `frames info` per source image.
    stills = [s for s in resolved["sources"] if s not in resolved["videos"]]
    if stills:
        proc = _run_frames("--json", "info", *stills)
        try:
            out["detection"] = json.loads(proc.stdout) if proc.stdout.strip() else None
        except json.JSONDecodeError:
            out["detection"] = {"raw": proc.stdout[-1000:], "stderr": proc.stderr[-500:]}
    if resolved["videos"]:
        out["video_inputs"] = resolved["videos"]
    return out


def _render_via_sibling(project: dict, base_dir: str):
    """Render a still by delegating to the sibling FrameCore Renderer.

    Returns a PIL Image. Raises RuntimeError when the sibling Renderer is
    unavailable -- callers turn that into a clear JSON error. No compositing
    logic lives in the MCP layer.
    """
    try:
        import Renderer as _r  # type: ignore
        return _r.render(project, base_dir)
    except Exception as e:
        raise RuntimeError(
            "still render needs the sibling FrameCore Renderer "
            f"(Sources/FrameCore/Renderer.py): {e}")


def tool_render(args: dict) -> dict:
    path = args.get("project")
    if not path:
        return {"error": "missing argument: project (.frameproj path)"}
    try:
        project = load_project(path)
    except ValueError as e:
        return {"error": str(e)}
    errors = validate_project(project)
    if errors:
        return {"error": "invalid .frameproj", "details": errors}
    resolved = _project_args(project, path)
    if resolved["missing"]:
        return {"error": "layer source(s) not found", "missing": resolved["missing"]}
    if resolved["videos"]:
        return {"error": "project contains video input; use frame.export_video",
                "fix": "call frame.export_video with the same project"}
    output = args.get("output") or str(Path.cwd() / "frame_render")
    Path(output).mkdir(parents=True, exist_ok=True)
    # Still PNG via the project: delegate to the sibling FrameCore
    # Renderer (no compositing logic in this layer).
    try:
        img = _render_via_sibling(project, str(Path(path).expanduser().parent))
    except RuntimeError as e:
        return {"error": str(e)}
    out_path = str(Path(output) / (Path(path).stem + "_still.png"))
    img.save(out_path)
    return {"output": out_path, "via": "FrameCore.Renderer.render",
            "frame": resolved["frame"],
            "size": {"width": img.size[0], "height": img.size[1]}}



def tool_animate_preview(args: dict) -> dict:
    path = args.get("project")
    if not path:
        return {"error": "missing argument: project (.frameproj path)"}
    try:
        project = load_project(path)
    except ValueError as e:
        return {"error": str(e)}
    errors = validate_project(project)
    if errors:
        return {"error": "invalid .frameproj", "details": errors}
    # Default to the project's own animation.preset (sibling layer 5),
    # so `animate_preview` with no preset honors the saved project.
    preset_name = args.get("preset") or (project.get("animation") or {}).get("preset") \
        or "hero-zoom"
    try:
        preset = load_preset(preset_name)
    except KeyError as e:
        return {"error": str(e)}
    fps = int(args.get("fps") or preset.get("fps", 30))
    frames = timeline(preset, fps)
    return {
        "project": str(path),
        "preset": {"name": preset["name"], "description": preset.get("description", ""),
                   "duration": preset["duration"], "fps": fps,
                   "loop": bool(preset.get("loop", False)),
                   "frame_count": len(frames)},
        # Live path: SwiftUI consumes swiftui_example + keyframes directly.
        "keyframes": preset["keyframes"],
        "frames": frames,
        "swiftui_example": swiftui_params(preset, min(0.25, float(preset["duration"]))),
        "swiftui_mapping": {"scaleEffect": ".scaleEffect(p.scale)",
                            "offsetY": ".offset(y: p.y * canvasHeight)",
                            "blurRadius": ".blur(radius: p.blur)"},
    }


def tool_export_video(args: dict) -> dict:
    path = args.get("project")
    if not path:
        return {"error": "missing argument: project (.frameproj path)"}
    if not shutil.which("ffmpeg"):
        return {"error": "ffmpeg missing", "fix": "brew install ffmpeg"}
    cmd = [sys.executable, str(MOTION_DIR / "render_video.py"), str(path)]
    for key, flag in (("animation", "--animation"), ("output", "-o"),
                      ("quality", "--preset"), ("codec", "--codec"),
                      ("background", "--background")):
        if args.get(key):
            cmd += [flag, str(args[key])]
    if args.get("fps"):
        cmd += ["--fps", str(args["fps"])]
    if args.get("strip_audio"):
        cmd.append("--strip-audio")
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=1200)
    except subprocess.TimeoutExpired:
        return {"error": "export timed out after 20 minutes"}
    try:
        data = json.loads(proc.stdout.strip().splitlines()[-1]) if proc.stdout.strip() else None
    except (json.JSONDecodeError, IndexError):
        data = None
    if proc.returncode != 0 or data is None:
        return {"error": "export failed",
                "stderr": ((proc.stderr or "") + (proc.stdout or ""))[-2000:]}
    if isinstance(data, dict) and data.get("error"):
        return data
    return data or {"error": "export produced no output"}


def tool_list_devices(args: dict) -> dict:  # noqa: ARG001
    proc = _run_frames("list")
    devices = []
    for line in proc.stdout.splitlines():
        m = re.match(r"\s*(\d+)px\s+→\s+(.+?)(?:\s+\((.+)\))?\s*$", line)
        if m:
            devices.append({"width_px": int(m.group(1)), "device": m.group(2).strip(),
                            "flags": m.group(3) or ""})
    return {"count": len(devices), "devices": devices, "raw": proc.stdout}


def tool_list_colors(args: dict) -> dict:
    device = args.get("device")
    if not device:
        return {"error": "missing argument: device (e.g. 'iPhone 18 Pro')"}
    proc = _run_frames("list-colors", str(device))
    if proc.returncode != 0:
        return {"error": "device not found", "stderr": proc.stderr[-1000:],
                "fix": "call frame.list_devices for exact names"}
    matches, current = [], None
    for line in proc.stdout.splitlines():
        if re.match(r"^  \S", line):
            current = {"device": line.strip(), "colors": [], "default": None}
            matches.append(current)
            continue
        m2 = re.match(r"\s*\d+\.\s+(.+?)(\s+\(default\))?\s*$", line)
        if m2 and current is not None:
            current["colors"].append(m2.group(1).strip())
            if m2.group(2):
                current["default"] = m2.group(1).strip()
    seen, flat = set(), []
    for m in matches:
        for c in m["colors"]:
            if c not in seen:
                seen.add(c)
                flat.append(c)
    return {"device_query": device, "matches": matches,
            "colors": flat, "raw": proc.stdout}


TOOLS = {
    "frame.info": (tool_info, "Validate a .frameproj and report layers, detected device, colors.",
                   {"project": "path to .frameproj file"}),
    "frame.render": (tool_render, "Render a still PNG via the sibling FrameCore Renderer.",
                     {"project": ".frameproj path", "output": "output dir (optional)"}),
    "frame.animate_preview": (tool_animate_preview, "Return a preset timeline JSON for live preview.",
                              {"project": ".frameproj path", "preset": "preset name",
                               "fps": "frames/sec override (optional)"}),
    "frame.export_video": (tool_export_video, "Render mp4/mov via ffmpeg from a .frameproj + preset.",
                           {"project": ".frameproj path", "animation": "preset name",
                            "output": "output file (optional)", "quality": "compact|balanced|best",
                            "codec": "h264|hevc|hevc-alpha|prores",
                            "strip_audio": "bool passthrough for video inputs",
                            "background": "canvas color for video inputs"}),
    "frame.list_devices": (tool_list_devices, "List supported devices (passthrough `frames list`).", {}),
    "frame.list_colors": (tool_list_colors, "List colors for a device (passthrough `frames list-colors`).",
                          {"device": "device name, partial match ok"}),
}


def handle(request: dict):
    method = request.get("method")
    rid = request.get("id")
    params = request.get("params") or {}

    if method == "initialize":
        return {"jsonrpc": "2.0", "id": rid,
                "result": {"protocolVersion": "2024-11-05",
                           "serverInfo": {"name": "frame-mcp", "version": SERVER_VERSION},
                           "capabilities": {"tools": {}}}}
    if method in ("notifications/initialized", "notifications/cancelled"):
        return None
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid,
                "result": {"tools": [
                    {"name": n, "description": d, "inputSchema": {
                        "type": "object", "properties": {
                            k: {"type": "string"} for k in sig},
                        "required": ["project"] if "project" in sig else
                                    (["device"] if n == "frame.list_colors" else [])}}
                    for n, (fn, d, sig) in TOOLS.items()]}}
    if method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if name not in TOOLS:
            return {"jsonrpc": "2.0", "id": rid,
                    "error": _err(f"unknown tool {name!r}",
                                  {"available": sorted(TOOLS)})}
        fn = TOOLS[name][0]
        try:
            result = fn(arguments)
        except Exception as e:  # never leak tracebacks; JSON out only
            return {"jsonrpc": "2.0", "id": rid,
                    "error": _err(f"{name} failed: {e}")}
        return {"jsonrpc": "2.0", "id": rid,
                "result": {"content": [{"type": "text",
                                        "text": json.dumps(result, indent=2)}],
                           "isError": bool(isinstance(result, dict)
                                           and result.get("error"))}}
    return {"jsonrpc": "2.0", "id": rid,
            "error": _err(f"unknown method {method!r}",
                          {"methods": ["initialize", "tools/list", "tools/call"]})}


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as e:
            sys.stdout.write(json.dumps(
                {"jsonrpc": "2.0", "id": None,
                 "error": _err(f"invalid JSON: {e}")}) + "\n")
            sys.stdout.flush()
            continue
        try:
            response = handle(request)
        except Exception as e:  # last-resort guard; always JSON out
            response = {"jsonrpc": "2.0", "id": request.get("id"),
                        "error": _err(f"internal error: {e}")}
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
