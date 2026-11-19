"""FrameMotion engine: data-driven animation presets.

Presets live in presets.json (data, not code branches). This module:
- live path: sample/swiftui_params() turn keyframes into per-frame
  SwiftUI parameters (.scaleEffect / .offset / .blur).
- export path: render_sequence() rasterizes a PNG sequence from a framed
  still with PIL, and encode_sequence() turns it into mp4/mov with ffmpeg.
- video-input path: zoompan_filter() builds an ffmpeg zoompan expression
  from the preset's scale envelope so `frames video` output can carry the
  same motion without re-rendering per-frame PNGs.

Units (see presets.json): t seconds, scale multiplier, y as a fraction of
canvas height (positive = down), blur px at 1080p reference width.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

try:
    from PIL import Image, ImageFilter
except ImportError:  # pragma: no cover
    Image = None  # type: ignore
    ImageFilter = None  # type: ignore

PRESETS_PATH = Path(__file__).resolve().parent / "presets.json"

QUALITY = {
    "compact": {"h264_crf": 24, "hevc_crf": 28, "h264_bitrate": "6M", "hevc_bitrate": "4M"},
    "balanced": {"h264_crf": 20, "hevc_crf": 24, "h264_bitrate": "10M", "hevc_bitrate": "7M"},
    "best": {"h264_crf": 18, "hevc_crf": 20, "h264_bitrate": "16M", "hevc_bitrate": "10M"},
}

ALPHA_CODECS = {"hevc-alpha", "prores"}


def _require_pil():
    if Image is None:
        raise RuntimeError("Pillow is required. Install with: pip3 install Pillow")


def load_presets(path: str | Path = PRESETS_PATH) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    return {p["name"]: p for p in data["presets"]}


def load_preset(name: str, path: str | Path = PRESETS_PATH) -> dict:
    presets = load_presets(path)
    if name not in presets:
        raise KeyError(f"unknown preset {name!r}; available: {sorted(presets)}")
    return presets[name]


def sample(preset: dict, t: float) -> dict:
    """Interpolate keyframes at time t (seconds). Returns {t, scale, y, blur}."""
    keys = sorted(preset["keyframes"], key=lambda k: k["t"])
    t = max(keys[0]["t"], min(float(t), keys[-1]["t"]))
    for a, b in zip(keys, keys[1:]):
        if a["t"] <= t <= b["t"]:
            span = b["t"] - a["t"]
            f = 0.0 if span <= 0 else (t - a["t"]) / span
            return {
                "t": round(t, 4),
                "scale": a["scale"] + (b["scale"] - a["scale"]) * f,
                "y": a["y"] + (b["y"] - a["y"]) * f,
                "blur": a["blur"] + (b["blur"] - a["blur"]) * f,
            }
    k = keys[-1]
    return {"t": round(t, 4), "scale": k["scale"], "y": k["y"], "blur": k["blur"]}


def timeline(preset: dict, fps: int | None = None) -> list:
    """Expand a preset to per-frame params at fps. Data for animate_preview."""
    fps = int(fps or preset.get("fps", 30))
    duration = float(preset["duration"])
    n = max(1, int(round(duration * fps)))
    frames = []
    for i in range(n):
        t = min(i / fps, duration)
        s = sample(preset, t)
        frames.append({"i": i, "t": s["t"], "scale": s["scale"], "y": s["y"], "blur": s["blur"]})
    # Pin the final frame exactly to the last keyframe.
    last = preset["keyframes"][-1]
    frames[-1].update({"t": duration, "scale": last["scale"], "y": last["y"], "blur": last["blur"]})
    return frames


def swiftui_params(preset: dict, t: float, canvas_height: float = 800.0) -> dict:
    """Live-preview mapping: keyframe params -> SwiftUI modifier arguments."""
    s = sample(preset, t)
    return {
        "scaleEffect": round(s["scale"], 4),
        "offsetY": round(s["y"] * canvas_height, 2),
        "blurRadius": round(s["blur"], 2),
    }


def render_frame(base: "Image.Image", params: dict, backdrop=(255, 255, 255, 255)) -> "Image.Image":
    """Apply one sampled frame's transform to an RGBA still."""
    _require_pil()
    w, h = base.size
    scale = max(0.05, float(params["scale"]))
    dy = float(params["y"]) * h
    blur = max(0.0, float(params["blur"])) * (w / 1080.0)

    img = base
    if blur > 0.05:
        img = img.filter(ImageFilter.GaussianBlur(radius=blur))

    sw, sh = max(1, int(w * scale)), max(1, int(h * scale))
    resized = img.resize((sw, sh), Image.LANCZOS)
    canvas = Image.new("RGBA", (w, h), backdrop)
    if scale >= 1.0:
        # Center-crop the oversized image, shifted by dy.
        left = (sw - w) // 2
        top = int((sh - h) // 2 + dy * scale)
        top = max(0, min(sh - h, top))
        canvas = resized.crop((left, top, left + w, top + h))
    else:
        canvas.paste(resized, ((w - sw) // 2, int((h - sh) // 2 + dy)), resized)
    return canvas.convert("RGBA")


def render_sequence(still_path: str | Path, preset: dict, out_dir: str | Path,
                    fps: int | None = None, backdrop=(255, 255, 255, 255)) -> list:
    """Rasterize a PNG sequence for the export path. Returns frame paths."""
    _require_pil()
    fps = int(fps or preset.get("fps", 30))
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    with Image.open(still_path) as im:
        base = im.convert("RGBA")
    paths = []
    for f in timeline(preset, fps):
        frame = render_frame(base, f, backdrop)
        p = out_dir / f"f{f['i']:05d}.png"
        frame.save(p)
        paths.append(str(p))
    return paths


def encode_sequence(frame_paths: list, output: str | Path, fps: int,
                    codec: str = "h264", quality: str = "best") -> dict:
    """Encode a PNG sequence with ffmpeg. Alpha codecs keep alpha, never drop it."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return {"error": "ffmpeg missing", "fix": "brew install ffmpeg"}
    if quality not in QUALITY:
        return {"error": f"unknown quality preset {quality!r}",
                "fix": f"use one of {sorted(QUALITY)}"}
    output = Path(output)
    if codec in ALPHA_CODECS and output.suffix.lower() != ".mov":
        output = output.with_suffix(".mov")  # never silently drop alpha
    q = QUALITY[quality]
    first = frame_paths[0]
    probe_w, probe_h = _png_size(first)
    if codec == "hevc-alpha":
        vf = f"scale={probe_w}:{probe_h}"
        enc = ["-c:v", "hevc_videotoolbox", "-pix_fmt", "bgra",
               "-alpha_quality", "1", "-allow_sw", "1", "-tag:v", "hvc1",
               "-b:v", q["hevc_bitrate"]]
    elif codec == "prores":
        vf = f"scale={probe_w}:{probe_h}"
        enc = ["-c:v", "prores_ks", "-profile:v", "4", "-pix_fmt", "yuva444p10le"]
    elif codec == "hevc":
        w, h = probe_w + probe_w % 2, probe_h + probe_h % 2
        vf = f"scale={w}:{h},format=yuv420p"
        enc = ["-c:v", "libx265", "-crf", str(q["hevc_crf"]), "-preset", "veryfast",
               "-tag:v", "hvc1"]
    else:  # h264 opaque mp4
        w, h = probe_w + probe_w % 2, probe_h + probe_h % 2
        vf = f"scale={w}:{h},format=yuv420p"
        enc = ["-c:v", "libx264", "-crf", str(q["h264_crf"]), "-preset", "veryfast",
               "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
    cmd = [ffmpeg, "-y", "-framerate", str(fps), "-i", str(Path(frame_paths[0]).parent / "f%05d.png"),
           "-vf", vf, *enc, str(output)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return {"error": "ffmpeg encode failed", "stderr": proc.stderr[-2000:]}
    return {"output": str(output), "codec": codec, "frames": len(frame_paths),
            "fps": fps, "quality": quality}


def _png_size(path: str | Path) -> tuple:
    _require_pil()
    with Image.open(path) as im:
        return im.size


def zoompan_filter(preset: dict, fps: int, width: int, height: int) -> str:
    """Build an ffmpeg zoompan filter carrying the preset's scale envelope.

    Used for video inputs (already framed by `frames video`): per-frame PNG
    re-rendering would discard the source motion, so the still-preset zoom is
    applied as a filter instead. y-drift under 2% of height is intentionally
    skipped -- zoompan-time panning on compressed video shimmers.
    """
    fps = int(fps)
    keys = sorted(preset["keyframes"], key=lambda k: k["t"])
    # Piecewise-linear scale envelope in terms of output frame number `in`.
    segs = []
    for a, b in zip(keys, keys[1:]):
        i0, i1 = a["t"] * fps, b["t"] * fps
        if i1 - i0 < 1:
            continue
        slope = (b["scale"] - a["scale"]) / (i1 - i0)
        intercept = a["scale"] - slope * i0
        segs.append((i1, slope, intercept))
    if not segs:
        expr = f"{keys[0]['scale']}"
    else:
        expr = f"{segs[-1][1]:.6f}*in+{segs[-1][2]:.6f}"
        for i1, slope, intercept in reversed(segs):
            expr = f"if(lt(in,{i1:.1f}),{slope:.6f}*in+{intercept:.6f},{expr})"
    return (f"zoompan=z='{expr}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
            f":d=1:s={width}x{height}:fps={fps}")
