#!/bin/sh
# Builds Frame.app into ./build. Pass "run" to launch it afterwards.
# Same pattern as NudgeMac/build.sh.
set -e
cd "$(dirname "$0")"

swift build -c release
APP=build/Frame.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Frame "$APP/Contents/MacOS/Frame"
cp Support/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/FrameCore"
cp Sources/FrameCore/Renderer.py "$APP/Contents/Resources/FrameCore/Renderer.py"
cp -R Sources/FrameMotion Sources/FrameMCP "$APP/Contents/Resources/"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

if [ "$1" = "run" ]; then
  pkill -x Frame 2>/dev/null || true
  open -n "$APP"
fi
