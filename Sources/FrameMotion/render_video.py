#!/usr/bin/env python3
"""Render a .frameproj + animation preset to mp4/mov with ffmpeg.

Real .frameproj schema is owned by Sources/FrameCore/project_schema.json:
screenshot.path holds the source pixels, frame.output is an optional cached
framed PNG, backdrop carries the studio composite. This script owns NO
compositing -- the still comes from the sibling Renderer:

Still inputs:  sibling Renderer.render(doc) -> PNG sequence via
  FrameMotion/engine.py -> ffmpeg encode.
Video inputs:  frame with `frames video`, passing through --strip-audio,
  --codec/--preset/--background, then carry the preset's scale envelope with
  an ffmpeg zoompan filter built from the same keyframe data.

Codecs: h264/hevc -> opaque .mp4; hevc-alpha/prores -> alpha .mov.
The output extension is corrected (and reported) rather than silently
dropping alpha. Without ffmpeg, prints a JSON error to stdout and exits 1:

    {"error": "ffmpeg missing", "fix": "brew install ffmpeg"}

Usage:
    render_video.py PROJECT.frameproj [--animation hero-zoom] [-o out.mp4]
        [--preset compact|balanced|best] [--codec h264|hevc|hevc-alpha|prores]
        [--fps 30] [--strip-audio] [--background white]

When --animation is omitted, the project's own animation.preset is used.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
MCP_DIR = HERE.parent / "FrameMCP"
FRAMECORE_DIR = HERE.parent / "FrameCore"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(MCP_DIR))
sys.path.insert(0, str(FRAMECORE_DIR))

from schema import load_project, validate_project  # noqa: E402
from engine import (load_preset, timeline, render_sequence,  # noqa: E402
                    encode_sequence, zoompan_filter, QUALITY, ALPHA_CODECS)

VIDEO_EXTS = {".mp4", ".mov", ".m4v"}


def fail(message: str, fix: str | None = None, **extra) -> int:
    payload = {"error": message}
    if fix:
        payload["fix"] = fix
    payload.update(extra)
    print(json.dumps(payload))
    return 1


def render_still(doc: dict, base_dir: str):
    """Delegate the composite to the sibling FrameCore Renderer."""
    import Renderer as _r  # type: ignore
    return _r.render(doc, base_dir)


def run_frames(*argv) -> subprocess.CompletedProcess:
    frames_bin = Path.home() / ".local" / "bin" / "frames"
    return subprocess.run([str(frames_bin), *argv], capture_output=True,
                          text=True, timeout=1200)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Render .frameproj + preset to video")
    ap.add_argument("project", help=".frameproj file")
    ap.add_argument("--animation", default=None,
                    help="preset name from presets.json (default: project's animation.preset)")
    ap.add_argument("-o", "--output", default=None, help="output file")
    ap.add_argument("--preset", default="balanced", choices=sorted(QUALITY),
                    help="size/quality preset (default: balanced)")
    ap.add_argument("--codec", default="h264",
                    choices=("h264", "hevc", "hevc-alpha", "prores"),
                    help="output codec (default: h264)")
    ap.add_argument("--fps", type=int, default=None, help="fps override")
    ap.add_argument("--strip-audio", action="store_true",
                    help="remove audio (passed to `frames video` for video inputs)")
    ap.add_argument("--background", default=None,
                    help="canvas color for video inputs (passed to `frames video`)")
    args = ap.parse_args(argv)

    if not shutil.which("ffmpeg"):
        return fail("ffmpeg missing", "brew install ffmpeg")

    try:
        doc = load_project(args.project)
    except ValueError as e:
        return fail(str(e))
    errors = validate_project(doc)
    if errors:
        return fail("invalid .frameproj", details=errors)

    anim_name = args.animation or (doc.get("animation") or {}).get("preset") or "hero-zoom"
    try:
        preset = load_preset(anim_name)
    except KeyError as e:
        return fail(str(e))

    fps = int(args.fps or preset.get("fps", 30))
    base_dir = str(Path(args.project).expanduser().parent)
    shot_path = (doc.get("screenshot") or {}).get("path", "")

    output = Path(args.output) if args.output else Path.cwd() / (
        Path(args.project).stem + f"_{preset['name']}.mp4")
    if args.codec in ALPHA_CODECS and output.suffix.lower() != ".mov":
        output = output.with_suffix(".mov")  # never silently drop alpha
    output.parent.mkdir(parents=True, exist_ok=True)

    if shot_path and Path(shot_path).suffix.lower() in VIDEO_EXTS:
        return render_video_input(shot_path, args, preset, fps, output)

    return render_still_input(doc, base_dir, args, preset, fps, output)


def render_still_input(doc: dict, base_dir: str, args, preset: dict,
                       fps: int, output: Path) -> int:
    try:
        img = render_still(doc, base_dir)
    except Exception as e:
        return fail(f"still render failed: {e}",
                    "check screenshot.path and frame.device via frame.info")
    with tempfile.TemporaryDirectory(prefix="frame_motion_") as tmp:
        seq_dir = Path(tmp) / "seq"
        still_path = Path(tmp) / "still.png"
        img.convert("RGBA").save(still_path)
        frames = render_sequence(still_path, preset, seq_dir, fps)
        result = encode_sequence(frames, output, fps, codec=args.codec, quality=args.preset)
        if result.get("error"):
            return fail(result["error"], result.get("fix"), stderr=result.get("stderr", ""))
        result["animation"] = preset["name"]
        result["frames_timeline"] = len(timeline(preset, fps))
        print(json.dumps(result))
        return 0


def render_video_input(source: str, args, preset: dict, fps: int, output: Path) -> int:
    with tempfile.TemporaryDirectory(prefix="frame_motion_") as tmp:
        tmpdir = Path(tmp)
        framed_dir = tmpdir / "framed"
        framed_dir.mkdir()
        cmd = ["video", source, "-o", str(framed_dir),
               "--preset", args.preset, "--codec",
               args.codec if args.codec in ("hevc-alpha", "hevc", "prores", "h264") else "h264"]
        if args.strip_audio:
            cmd.append("--strip-audio")
        if args.background:
            cmd += ["--background", args.background]
        proc = run_frames("--json", *cmd)
        try:
            data = json.loads(proc.stdout) if proc.stdout.strip() else None
        except json.JSONDecodeError:
            data = None
        framed = None
        if isinstance(data, dict):
            framed = data.get("output") or (data.get("outputs") or [None])[0]
        if proc.returncode != 0 or not framed:
            return fail("video framing failed", "check ffmpeg/ffprobe via `frames doctor`",
                        stderr=(proc.stderr or proc.stdout)[-2000:])
        # Carry the preset's zoom envelope; y-drift is skipped for video (see engine).
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=width,height", "-of", "csv=p=0", framed],
            capture_output=True, text=True)
        try:
            w, h = (int(v) for v in probe.stdout.strip().split(",")[:2])
        except ValueError:
            return fail("could not probe framed video", stderr=probe.stderr[-500:])
        zf = zoompan_filter(preset, fps, w + w % 2, h + h % 2)
        cmd = ["ffmpeg", "-y", "-i", framed, "-vf", zf,
               "-c:v", "libx264", "-crf", str(QUALITY[args.preset]["h264_crf"]),
               "-preset", "veryfast", "-pix_fmt", "yuv420p"]
        if not args.strip_audio:
            cmd += ["-c:a", "aac"]
        else:
            cmd += ["-an"]
        cmd.append(str(output))
        enc = subprocess.run(cmd, capture_output=True, text=True)
        if enc.returncode != 0:
            return fail("motion encode failed", stderr=enc.stderr[-2000:])
        print(json.dumps({"output": str(output), "codec": "h264",
                          "animation": preset["name"], "fps": fps,
                          "quality": args.preset,
                          "note": "video input: preset zoom applied via zoompan; "
                                  "y-drift skipped (see engine.zoompan_filter)"}))
        return 0


if __name__ == "__main__":
    sys.exit(main())
