#!/usr/bin/env python3
"""Frame still renderer: pure function render(project.json) -> PNG.

Pipeline (proven against SakuraCord-PROLED16-Black-desert.png):
  cover-resize backdrop -> GaussianBlur(blur) -> gaussian grain(grain)
  -> alpha_composite(framed foreground at scale, default 0.70)
  -> adjust brightness/contrast/saturation.

Unknown JSON fields are preserved on load (forward-compat); every layer is
independently replaceable: open -> edit one layer -> re-render.

CLI: renderer.py project.frameproj -o out.png --json
"""
import argparse
import hashlib
import json
import sys
import subprocess
import tempfile
import os
import shutil
from pathlib import Path

from PIL import Image, ImageEnhance, ImageFilter, ImageOps

SCHEMA_VERSION = 1
DEFAULTS = {"blur": 8.0, "grain": 6.0, "scale": 0.70, "offset": [0, 0],
            "brightness": 1.0, "contrast": 1.0, "saturation": 1.0}


class ProjectError(Exception):
    pass


def open_image(path):
    """Normalize orientation; use macOS ImageIO for HEIC when Pillow cannot."""
    try:
        with Image.open(path) as image:
            return ImageOps.exif_transpose(image).copy()
    except OSError as original:
        if Path(path).suffix.lower() not in (".heic", ".heif"):
            raise ProjectError(f"Cannot read image {path}: {original}") from original
        with tempfile.TemporaryDirectory(prefix="frame_import_") as tmp:
            output = Path(tmp) / "converted.png"
            try:
                subprocess.run(["/usr/bin/sips", "-s", "format", "png", str(path),
                                "--out", str(output)], capture_output=True, check=True)
                with Image.open(output) as image:
                    return ImageOps.exif_transpose(image).copy()
            except (OSError, subprocess.CalledProcessError) as error:
                raise ProjectError(f"Cannot convert {path}. Export it as PNG and try again.") from error


def load_project(path):
    """Load a .frameproj file, preserving unknown fields verbatim."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise ProjectError(f"cannot read project: {e}")
    if not isinstance(doc, dict):
        raise ProjectError("project root must be a JSON object")
    if doc.get("frameproj") != SCHEMA_VERSION:
        raise ProjectError(
            f"unsupported frameproj version {doc.get('frameproj')!r} (supports 1)")
    return doc


def save_project(doc, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def cover_resize(img, size):
    """Cover-resize: fill `size`, preserving aspect ratio, centered crop."""
    tw, th = size
    s = max(tw / img.width, th / img.height)
    nw, nh = max(1, round(img.width * s)), max(1, round(img.height * s))
    img = img.resize((nw, nh), Image.LANCZOS)
    left = (nw - tw) // 2
    top = (nh - th) // 2
    return img.crop((left, top, left + tw, top + th))


def add_grain(img, sigma, seed):
    """Additive gaussian grain, deterministic for (seed, sigma)."""
    if sigma <= 0:
        return img
    import numpy as np
    rng = np.random.default_rng(seed)
    a = np.asarray(img.convert("RGB"), dtype=np.float32)
    noise = rng.normal(0.0, sigma, a.shape).astype(np.float32)
    a += noise
    np.clip(a, 0, 255, out=a)
    return Image.fromarray(a.astype("uint8"))


def grain_seed(fg_bytes_hash, params):
    digest = hashlib.sha256(
        (fg_bytes_hash + json.dumps(params, sort_keys=True)).encode()
    ).digest()
    return int.from_bytes(digest[:8], "big")


def parse_color(value):
    v = value.strip().lstrip("#")
    if len(v) == 3:
        v = "".join(c * 2 for c in v)
    if len(v) != 6:
        raise ProjectError(f"bad color {value!r}, want #RRGGBB")
    try:
        return (int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16))
    except ValueError:
        raise ProjectError(f"bad color {value!r}, want #RRGGBB")


def render(doc, base_dir=None):
    """Pure render: project dict -> RGB Image. Raises ProjectError."""
    base = Path(base_dir) if base_dir else Path.cwd()

    shot = doc.get("screenshot") or {}
    shot_path = shot.get("path")
    if not shot_path:
        raise ProjectError("screenshot.path is required")
    shot_file = (base / shot_path) if not Path(shot_path).is_absolute() else Path(shot_path)
    if not shot_file.is_file():
        raise ProjectError(f"screenshot not found: {shot_path}")
    if shot.get("sha256"):
        actual = sha256_file(shot_file)
        if actual != shot["sha256"].lower():
            raise ProjectError(
                f"screenshot sha256 mismatch for {shot_path} "
                f"(project {shot['sha256'][:16]}.. != file {actual[:16]}..)")

    frame = doc.get("frame") or {}
    if not (frame.get("device") or "").strip():
        raise ProjectError("frame.device must be non-empty")
    fg_file = None
    if frame.get("output"):
        cand = (base / frame["output"]) if not Path(frame["output"]).is_absolute() \
            else Path(frame["output"])
        if cand.is_file():
            fg_file = cand
    if fg_file is None:
        with tempfile.TemporaryDirectory(prefix="frame_device_") as tmp:
            binary = os.environ.get("FRAMES_BIN") or shutil.which("frames") or str(Path.home() / ".local/bin/frames")
            command = [binary, "--json", "frame", "--output", tmp]
            if frame.get("device") != "Auto":
                command += ["--device", frame["device"]]
            if frame.get("color") and frame["color"] != "Default":
                command += ["--color", frame["color"]]
            command.append(str(shot_file))
            try:
                process = subprocess.run(command, capture_output=True, text=True, check=True)
                result = json.loads(process.stdout)
                if isinstance(result, list):
                    result = result[0]
                generated = Path(tmp) / result["output"]
                fg = open_image(generated)
                foreground_hash = sha256_file(generated)
            except (OSError, subprocess.CalledProcessError, ValueError, KeyError, IndexError) as error:
                raise ProjectError(f"Cannot frame screenshot: {error}. Check device and color with frames list.") from error
    else:
        fg = open_image(fg_file)
        foreground_hash = sha256_file(fg_file)
    fg_rgba = fg.convert("RGBA") if fg.mode != "RGBA" else fg
    canvas = doc.get("canvas") or {}
    canvas_size = (int(canvas.get("width", fg_rgba.width)),
                   int(canvas.get("height", fg_rgba.height)))
    backdrop_path = (doc.get("backdrop") or {}).get("path")
    if canvas.get("fit") == "backdrop" and backdrop_path:
        bp = Path(backdrop_path)
        bp = bp if bp.is_absolute() else base / bp
        if bp.is_file():
            canvas_size = open_image(bp).size
    if not all(0 < n <= 8192 for n in canvas_size):
        raise ProjectError("canvas dimensions must be between 1 and 8192")

    bd = doc.get("backdrop") or {}
    blur = float(bd.get("blur", DEFAULTS["blur"]))
    grain = float(bd.get("grain", DEFAULTS["grain"]))
    scale = float(bd.get("scale", DEFAULTS["scale"]))
    offset = bd.get("offset", DEFAULTS["offset"])
    try:
        dx, dy = int(offset[0]), int(offset[1])
    except (TypeError, IndexError, ValueError):
        raise ProjectError("backdrop.offset must be [dx, dy]")
    position = bd.get("position") or [0, 0]
    try:
        dx += round(float(position[0]) * canvas_size[0])
        dy += round(float(position[1]) * canvas_size[1])
    except (TypeError, IndexError, ValueError):
        raise ProjectError("backdrop.position must be [x, y] fractions of the canvas")
    if scale <= 0:
        raise ProjectError("backdrop.scale must be > 0")

    if bd.get("path"):
        bp = bd["path"]
        bg_file = (base / bp) if not Path(bp).is_absolute() else Path(bp)
        if not bg_file.is_file():
            raise ProjectError(f"backdrop not found: {bp}")
        bg = cover_resize(open_image(bg_file).convert("RGB"), canvas_size)
    elif bd.get("color"):
        bg = Image.new("RGB", canvas_size, parse_color(bd["color"]))
    else:
        bg = cover_resize(fg.convert("RGB"), canvas_size)
    if blur > 0:
        bg = bg.filter(ImageFilter.GaussianBlur(blur))
    bg = add_grain(bg, grain, grain_seed(
        foreground_hash,
        {"blur": blur, "grain": grain, "scale": scale,
         "offset": [dx, dy], "size": list(canvas_size)}))

    fit = min(canvas_size[0] / fg_rgba.width, canvas_size[1] / fg_rgba.height) * scale
    fw, fh = max(1, round(fg_rgba.width * fit)), max(1, round(fg_rgba.height * fit))
    fg_small = fg_rgba.resize((fw, fh), Image.LANCZOS)
    layer = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    layer.alpha_composite(fg_small, ((canvas_size[0] - fw) // 2 + dx,
                                     (canvas_size[1] - fh) // 2 + dy))
    out = bg.convert("RGBA")
    out.alpha_composite(layer)
    out = out.convert("RGB")

    adj = doc.get("adjust") or {}
    br = float(adj.get("brightness", DEFAULTS["brightness"]))
    co = float(adj.get("contrast", DEFAULTS["contrast"]))
    sa = float(adj.get("saturation", DEFAULTS["saturation"]))
    if br != 1.0:
        out = ImageEnhance.Brightness(out).enhance(br)
    if co != 1.0:
        out = ImageEnhance.Contrast(out).enhance(co)
    if sa != 1.0:
        out = ImageEnhance.Color(out).enhance(sa)
    return out


# ---- Swift generation (project_schema.json is the source of truth) ----

_SWIFT_HEADER = """// FrameProject.swift
// GENERATED from project_schema.json (frameproj v%d) — do not hand-edit.
// Regenerate: python3 Sources/FrameCore/Renderer.py --generate-swift Sources/FrameCore/FrameProject.swift
// Unknown fields are preserved on load (forward-compat); every layer is
// independently replaceable: open -> edit one layer -> re-render.

import Foundation
"""

_ANYJSON = '''
/// Minimal JSON value box so unknown fields survive a decode/encode round-trip.
public enum AnyJSON: Codable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([AnyJSON]), object([String: AnyJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([AnyJSON].self) { self = .array(v); return }
        self = .object(try c.decode([String: AnyJSON].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String; var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = "\\(intValue)" }
}
'''

_LAYER_EXTRA = '''
    /// Unknown fields within this layer, preserved verbatim.
    public var unknown: [String: AnyJSON] = [:]

    public init(from decoder: Decoder) throws {
        let known = Set(_knownKeys)
        let bag = try decoder.container(keyedBy: AnyKey.self)
        for key in bag.allKeys where !known.contains(key.stringValue) {
            unknown[key.stringValue] = try bag.decode(AnyJSON.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var bag = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in unknown {
            try bag.encode(v, forKey: AnyKey(stringValue: k)!)
        }
    }
'''

_TOP_EXTRA = '''
    /// Unknown top-level fields, preserved verbatim for forward compatibility.
    public var unknown: [String: AnyJSON] = [:]

    private enum TopKeys: String, CodingKey {
        case frameproj, screenshot, frame, backdrop, adjust, animation
    }

    public init(frameproj: Int = %(version)d, screenshot: ScreenshotLayer, frame: FrameLayer,
                backdrop: BackdropLayer, adjust: AdjustLayer = AdjustLayer(),
                animation: AnimationLayer = AnimationLayer()) {
        self.frameproj = frameproj; self.screenshot = screenshot; self.frame = frame
        self.backdrop = backdrop; self.adjust = adjust; self.animation = animation
    }

    public init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: TopKeys.self)
        frameproj = try known.decode(Int.self, forKey: .frameproj)
        screenshot = try known.decode(ScreenshotLayer.self, forKey: .screenshot)
        frame = try known.decode(FrameLayer.self, forKey: .frame)
        backdrop = try known.decode(BackdropLayer.self, forKey: .backdrop)
        adjust = try known.decodeIfPresent(AdjustLayer.self, forKey: .adjust) ?? AdjustLayer()
        animation = try known.decodeIfPresent(AnimationLayer.self, forKey: .animation) ?? AnimationLayer()
        let bag = try decoder.container(keyedBy: AnyKey.self)
        let knownNames: Set<String> = ["frameproj", "screenshot", "frame", "backdrop", "adjust", "animation"]
        for key in bag.allKeys where !knownNames.contains(key.stringValue) {
            unknown[key.stringValue] = try bag.decode(AnyJSON.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var known = encoder.container(keyedBy: TopKeys.self)
        try known.encode(frameproj, forKey: .frameproj)
        try known.encode(screenshot, forKey: .screenshot)
        try known.encode(frame, forKey: .frame)
        try known.encode(backdrop, forKey: .backdrop)
        try known.encode(adjust, forKey: .adjust)
        try known.encode(animation, forKey: .animation)
        var bag = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in unknown {
            try bag.encode(v, forKey: AnyKey(stringValue: k)!)
        }
    }
'''


def _swift_type(prop):
    t = prop.get("type")
    if t == "string":
        return "String"
    if t == "integer":
        return "Int"
    if t == "number":
        return "Double"
    if t == "array":
        return "[Double]"
    return "AnyJSON"


def _swift_default(prop):
    d = prop.get("default", None)
    if d is None:
        return None
    if isinstance(d, list):
        return "[" + ", ".join(f"{x}" for x in d) + "]"
    if isinstance(d, bool):
        return "true" if d else "false"
    return f"{d}"


_STRUCT_NAMES = {
    "screenshot": "ScreenshotLayer",
    "frame": "FrameLayer",
    "backdrop": "BackdropLayer",
    "adjust": "AdjustLayer",
    "animation": "AnimationLayer",
}


def generate_swift(schema):
    """Build FrameProject.swift from the schema's layer definitions."""
    props = schema["properties"]
    version = schema["properties"]["frameproj"].get("const", 1)
    chunks = [_SWIFT_HEADER % version, _ANYJSON]
    order = ["screenshot", "frame", "backdrop", "adjust", "animation"]
    for layer in order:
        node = props[layer]
        name = _STRUCT_NAMES[layer]
        req = set(node.get("required", []))
        lines = [f"public struct {name}: Codable, Equatable {{",
                 f"    private static let _knownKeys = [{', '.join(json.dumps(k) for k in node['properties'])}]"]
        inits = []
        for field, fprop in node["properties"].items():
            st = _swift_type(fprop)
            if field in req:
                lines.append(f"    public var {field}: {st}")
                inits.append(f"{field}: {st}")
            else:
                d = _swift_default(fprop)
                if d is None:
                    lines.append(f"    public var {field}: {st}? = nil")
                    inits.append(f"{field}: {st}? = nil")
                else:
                    lines.append(f"    public var {field}: {st} = {d}")
                    inits.append(f"{field}: {st} = {d}")
        lines.append("")
        lines.append(f"    public init({', '.join(inits)}) {{")
        for field in node["properties"]:
            lines.append(f"        self.{field} = {field}")
        lines.append("    }")
        lines.append("")
        lines.append("    /// Unknown fields within this layer, preserved verbatim.")
        lines.append("    public var unknown: [String: AnyJSON] = [:]")
        lines.append("")
        lines.append("    private enum KnownKeys: String, CodingKey {")
        lines.append("        " + "; ".join(f"case {f}" for f in node["properties"]))
        lines.append("    }")
        lines.append("")
        lines.append("    public init(from decoder: Decoder) throws {")
        lines.append("        let known = try decoder.container(keyedBy: KnownKeys.self)")
        for field, fprop in node["properties"].items():
            st = _swift_type(fprop)
            key = f".{field}"
            if field in req:
                lines.append(f"        {field} = try known.decode({st}.self, forKey: {key})")
            else:
                d = _swift_default(fprop)
                fallback = d if d is not None else "nil"
                lines.append(f"        {field} = try known.decodeIfPresent({st}.self, forKey: {key}) ?? {fallback}")
        lines.append("        let bag = try decoder.container(keyedBy: AnyKey.self)")
        lines.append("        for key in bag.allKeys where !Self._knownKeys.contains(key.stringValue) {")
        lines.append("            unknown[key.stringValue] = try bag.decode(AnyJSON.self, forKey: key)")
        lines.append("        }")
        lines.append("    }")
        lines.append("")
        lines.append("    public func encode(to encoder: Encoder) throws {")
        lines.append("        var known = encoder.container(keyedBy: KnownKeys.self)")
        for field in node["properties"]:
            lines.append(f"        try known.encodeIfPresent({field}, forKey: .{field})"
                         if field not in req else
                         f"        try known.encode({field}, forKey: .{field})")
        lines.append("        var bag = encoder.container(keyedBy: AnyKey.self)")
        lines.append("        for (k, v) in unknown {")
        lines.append("            try bag.encode(v, forKey: AnyKey(stringValue: k)!)")
        lines.append("        }")
        lines.append("    }")
        lines.append("}")
        chunks.append("\n".join(lines))
    top_lines = ["public struct FrameProject: Codable, Equatable {",
                 "    public var frameproj: Int = %d" % version,
                 "    public var screenshot: ScreenshotLayer",
                 "    public var frame: FrameLayer",
                 "    public var backdrop: BackdropLayer",
                 "    public var adjust: AdjustLayer = AdjustLayer()",
                 "    public var animation: AnimationLayer = AnimationLayer()",
                 _TOP_EXTRA % {"version": version},
                 "}"]
    chunks.append("\n".join(top_lines))
    chunks.append("")
    return "\n\n".join(chunks)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Render a .frameproj project to PNG (cover-resize + "
                    "GaussianBlur + gaussian grain + alpha_composite).")
    ap.add_argument("project", nargs="?",
                    help="Path to project.frameproj (JSON, frameproj v1).")
    ap.add_argument("-o", "--output", help="Output PNG path.")
    ap.add_argument("--json", action="store_true",
                    help="Print result JSON {output,width,height,bytes} to stdout.")
    ap.add_argument("--generate-swift", metavar="PATH",
                    help="Generate FrameProject.swift from project_schema.json and exit.")
    ap.add_argument("--schema", action="store_true",
                    help="Print the path of the bundled project_schema.json and exit.")
    args = ap.parse_args(argv)

    here = Path(__file__).resolve().parent
    schema_path = here / "project_schema.json"

    if args.schema:
        print(str(schema_path))
        return 0
    if args.generate_swift:
        try:
            with open(schema_path, encoding="utf-8") as f:
                schema = json.load(f)
        except OSError as e:
            print(json.dumps({"error": f"cannot read schema: {e}"}))
            return 1
        Path(args.generate_swift).write_text(generate_swift(schema), encoding="utf-8")
        if not args.json:
            print(f"wrote {args.generate_swift}")
        else:
            print(json.dumps({"generated": args.generate_swift}))
        return 0
    if not args.project or not args.output:
        ap.error("project and -o/--output are required (or use --generate-swift).")
    try:
        doc = load_project(args.project)
        img = render(doc, base_dir=Path(args.project).resolve().parent)
        img.save(args.output, "PNG")
    except ProjectError as e:
        print(json.dumps({"error": str(e)}))
        return 1
    except (OSError, ValueError) as e:
        print(json.dumps({"error": f"render failed: {e}"}))
        return 1
    if args.json:
        out = Path(args.output)
        print(json.dumps({
            "output": str(out),
            "width": img.width,
            "height": img.height,
            "bytes": out.stat().st_size,
        }))
    else:
        print(f"wrote {args.output} ({img.width}x{img.height})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
