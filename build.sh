#!/bin/bash
# Builds Teleprompter.app into ./build (no Xcode needed, just the Command Line Tools).
#   ./build.sh          build
#   ./build.sh run      build and launch
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Teleprompter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Teleprompter"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
if [[ "${1:-}" == "run" ]]; then open "$APP"; fi
