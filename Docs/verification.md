# Verification

The release app builds and opens. The inspector now has a 300-point minimum
width and one scroll container. Pickers use their own rows, slider labels
sit above their tracks, and Export contains PNG and MP4 actions. The editor
uses system text, colors, and controls. Its energy/rhythm/motion dials are
1/1/1; the screenshot is the focal point and blue marks interactive controls.

Passed checks:

- Six Swift integration tests, including app-service versus CLI PNG byte
  equality after saving and reopening a canonical project.
- Live device-list uniqueness and manual-frame availability; an unrecognized
  1422 × 1000 screenshot waits for a device choice, then frames and renders
  successfully using MacBook Pro PROLED 16 through ProjectStore and the real CLI.
- Two Python tests, including direct/CLI/MCP pixel equality, deterministic
  grain, explicit canvas dimensions, and JPEG orientation.
- A 320 × 240 H.264 export with nine frames through the existing video pipeline.
- A release build, app bundle signing, and opening the rebuilt app.

Interactive visual and keyboard verification remains pending. macOS denied
assistive access to osascript and screen capture could not obtain a display.
The prior user-provided screenshot showed clipping caused by the narrow
sidebar and nested form/list. Those containers were replaced, but a fresh
capture of the rebuilt window has not been inspected. No complete UI or
antislop delivery-gate pass is claimed.

The earlier 1.28% difference was reported against an external reference.
Its original measurement method has not been reproduced. This change removes
the separate CoreImage compositor and random grain; parity checks now compare
the app, CLI, and MCP against the shared renderer. They do not establish
equality with that external reference.

The framing regression came from continuing after unsuccessful automatic
detection, starting a renderer without a framed image, and allowing that
older render's failure to overwrite a later successful operation. The device
parser also repeated names for every supported resolution and omitted manual
frames. Detection now pauses for a device choice, preview tasks are cancelled
before framing, failed framing never starts a composite, and device entries
are unique with manual frames included. Existing manual selections survive
replacement imports.

Projects still reference assets on the local filesystem. The bundle includes
renderer scripts but requires Python with Pillow and NumPy; ffmpeg is required
for motion. The app exports opaque H.264 MP4. Other codecs remain CLI/MCP options.
