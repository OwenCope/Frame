# Frame

A native macOS editor for framing screenshots with the local `frames` CLI.

Drop a screenshot, choose a device and backdrop, then export a PNG or MP4.
Output formats include original dimensions, a 1290 × 2796 portrait canvas,
a 2400 × 1350 release image, and a 1080 × 1080 social canvas. Scale, blur,
and grain live under Advanced adjustments. Motion is optional; rendering
a motion preview uses the same pipeline as MP4 export.

Launch from this directory:

```sh
./build.sh run
```

Requires macOS 26 or later, a compatible Xcode SDK, `frames`, Python 3 with
Pillow and NumPy, and ffmpeg for video. `FRAMES_BIN` overrides the frames
executable. `FRAME_PYTHON` overrides `/usr/bin/python3`. The app bundle
includes the Python renderer and video pipeline, but no Python runtime.

The inspector uses native controls and system colors. Its minimum width is
300 points so picker values and labels remain visible. The screenshot is
the visual focus; advanced controls and motion stay collapsed initially.
Design dials are energy 1, rhythm 1, motion 1 for the editor. Motion in the
exported artwork is controlled separately by the selected animation preset.

The app, CLI, and MCP share `Sources/FrameCore/Renderer.py`. Previews use
that renderer's PNG directly. Grain is deterministic, foreground placement
preserves aspect ratio, and `canvas.width` / `canvas.height` set output size.
Imported screenshots and backdrops become oriented PNGs in
`~/Library/Application Support/Frame/Imports`. The Python renderer also
normalizes JPEG orientation and uses `sips` to convert HEIC when needed.

Projects use layered `.frameproj` v1 JSON. The app preserves unknown fields
and resolves relative asset paths from the project directory. Legacy app
projects migrate when saved. Projects reference local image files; they
are not self-contained bundles. Keep imported assets when moving a project.

Render a saved project from the terminal:

```sh
python3 Sources/FrameCore/Renderer.py project.frameproj -o output.png --json
python3 Sources/FrameMotion/render_video.py project.frameproj -o output.mp4
```

The MCP configuration is in `mcp.json`. `frame.render` accepts a project path
and an output directory. `frame.export_video` uses the same saved animation
preset as the editor. The editor exports opaque H.264 MP4; other codecs
remain available through the existing video CLI and MCP.

Run verification:

```sh
swift test
python3 -m unittest discover -s Tests -v
```

The Swift checks cover canonical save/reopen, preservation of unknown
layers, relative paths, legacy migration, and resetting canvas presets.
Python checks compare direct, CLI, and MCP output pixels and verify image
orientation. These checks do not replace interactive macOS layout and
keyboard testing.
