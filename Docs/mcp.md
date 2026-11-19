# Frame MCP — local AI access

Stdio server at `Sources/FrameMCP/server.py` (Python 3, stdlib only).
Transport is a local pipe, so it is localhost-only by construction: no ports,
no auth tokens, no secrets in payloads. `FRAMES_ASSETS` passes through from
the host environment; override the CLI location with `FRAMES_BIN`.

Add to your MCP client with `mcp.json`:

```json
{
  "mcpServers": {
    "frame": {
      "command": "python3",
      "args": ["/Users/owencope/Developer/Frame/Sources/FrameMCP/server.py"],
      "env": { "FRAMES_BIN": "/Users/owencope/.local/bin/frames" }
    }
  }
}
```

`.frameproj` files are validated read-only through `Sources/FrameMCP/schema.py`,
which uses the sibling `Sources/FrameCore/Renderer.py:load_project` when it
is importable and otherwise checks the required keys of
`Sources/FrameCore/project_schema.json` (`frameproj==1`, `screenshot.path`,
`frame.device`/`frame.color`). Stills render by delegating to
`FrameCore.Renderer.render` — the MCP layer owns no compositing. Animation
presets are pure data in `Sources/FrameMotion/presets.json`; adding one is a
JSON append. When `--animation` is omitted, the project's own
`animation.preset` wins (the sibling example uses `rise`).

## Tools

| Tool | Args | What it does |
|---|---|---|
| `frame.info` | `project` | Validate `.frameproj`; report layers + `frames info` device/colors per still |
| `frame.render` | `project`, `output?` | Still PNG via `FrameCore.Renderer.render` delegation (no compositing here) |
| `frame.animate_preview` | `project`, `preset?`, `fps?` | Preset timeline JSON: `keyframes`, per-frame `frames[]`, `swiftui_example` + `swiftui_mapping` for the live SwiftUI path |
| `frame.export_video` | `project`, `animation?`, `output?`, `quality?` (`compact`/`balanced`/`best`), `codec?` (`h264`/`hevc`/`hevc-alpha`/`prores`), `strip_audio?`, `background?`, `fps?` | Video render via `render_video.py` + ffmpeg. Alpha codecs write `.mov`, opaque writes `.mp4`; without ffmpeg returns `{"error":"ffmpeg missing","fix":"brew install ffmpeg"}` |
| `frame.list_devices` | — | Passthrough `frames list` (parsed + raw) |
| `frame.list_colors` | `device` | Passthrough `frames list-colors <device>` (parsed + raw) |

Wire format is JSON-RPC 2.0, one request per line on stdin, one response per
line on stdout. A tool result is `{"content":[{"type":"text","text":"<JSON>"}],
"isError":false}`; tool-level failures set `isError:true` and the JSON holds
`{"error":..., "fix":...}` — always JSON, never a traceback.

## End-to-end: info → render still → animate_preview → export_video

Every request below is a single line on stdin. Responses come back on stdout.

**1. Validate the project and detect the device**

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"frame.info","arguments":{"project":"/tmp/shot.frameproj"}}}
```

```json
{"project":"/tmp/shot.frameproj","frame":{"device":"iPhone 18 Pro Portrait","color":"Burgundy"},
 "animation_preset":"hero-zoom","schema":"sibling-FrameCore",
 "detection":{"file":"/tmp/shot.png","device":"iPhone 18 Pro Portrait",
 "colors":["Burgundy","Glacier","Silver","Black"]}}
```

`.frameproj` shape (schema owned by `Sources/FrameCore/project_schema.json`):

```json
{"frameproj": 1,
 "screenshot": {"path": "/tmp/shot.png"},
 "frame": {"device": "iPhone 18 Pro Portrait", "color": "Burgundy"},
 "backdrop": {"color": "#1a1a1e", "blur": 8, "grain": 6, "scale": 0.7, "offset": [0, 0]},
 "animation": {"preset": "hero-zoom"}}
```

**2. Render the still**

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"frame.render","arguments":{"project":"/tmp/shot.frameproj","output":"/tmp/frame_out","color":"Burgundy"}}}
```

```json
{"output":"/tmp/frame_out/shot_still.png","via":"FrameCore.Renderer.render",
 "frame":{"device":"iPhone 18 Pro Portrait","color":"Burgundy"},
 "size":{"width":1206,"height":2622}}
```

**3. Preview the animation timeline (live SwiftUI path uses the same numbers)**

```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"frame.animate_preview","arguments":{"project":"/tmp/shot.frameproj","preset":"hero-zoom"}}}
```

```json
{"preset":{"name":"hero-zoom","duration":2.0,"fps":30,"loop":false,"frame_count":60},
 "keyframes":[{"t":0.0,"scale":1.0,"y":0.01,"blur":0.0},{"t":2.0,"scale":1.1,"y":-0.01,"blur":0.0}],
 "swiftui_example":{"scaleEffect":1.008,"offsetY":6.4,"blurRadius":0.0},
 "swiftui_mapping":{"scaleEffect":".scaleEffect(p.scale)","offsetY":".offset(y: p.y * canvasHeight)","blurRadius":".blur(radius: p.blur)"}}
```

(`frames[]` holds all 60 per-frame samples; trimmed here.)

**4. Export the video (PNG sequence → ffmpeg)**

```json
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"frame.export_video","arguments":{"project":"/tmp/shot.frameproj","animation":"hero-zoom","output":"/tmp/shot_hero.mp4","quality":"balanced","codec":"h264"}}}
```

```json
{"output":"/tmp/shot_hero.mp4","codec":"h264","frames":60,"fps":30,"quality":"balanced","animation":"hero-zoom","frames_timeline":60}
```

Same call over CLI without MCP:

```bash
python3 Sources/FrameMotion/render_video.py /tmp/shot.frameproj \
  --animation hero-zoom -o /tmp/shot_hero.mp4 --preset balanced --codec h264
```

Video-input projects (a layer whose source is `.mp4`/`.mov`/`.m4v`) frame via
`frames video` with `--strip-audio` / `--codec` / `--preset` / `--background`
passed through, then carry the preset zoom via a zoompan filter.
