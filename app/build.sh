#!/usr/bin/env bash
# Build "Call Transcriber.app" for macOS 14+ on Apple Silicon, signed locally (no Apple Developer account).
#   ./build.sh            -> app/build/Call Transcriber.app
#   ./build.sh --open     -> build, then launch it
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Call Transcriber.app"
swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/CallTranscriber "$APP/Contents/MacOS/CallTranscriber"
# The engine runs as its own process next to the app (so Pause and Stop act at once, and a crash in the
# speech libraries can't take the window down).
cp .build/arm64-apple-macosx/release/transcribe-cli "$APP/Contents/MacOS/transcribe-cli"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/donate.html "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # redraw with: swift make_icon.swift

# Signature. With a self-signed "Call Transcriber Dev" code-signing certificate in your Keychain, every
# build carries the same identity, so firewalls like Little Snitch (and macOS) recognise rebuilds as
# the same app. Without it, an ad-hoc signature is used, which changes on every build, and macOS asks again
# for the microphone and System Audio Recording permissions after each build.
# Another Mac asks once either way: System Settings > Privacy and Security > Open Anyway.
SIGN_ID="${SIGN_ID:-Call Transcriber Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --deep --sign "$SIGN_ID" "$APP"
  echo "Signed with: $SIGN_ID"
else
  codesign --force --deep --sign - "$APP"
  echo "Signed ad-hoc (create a \"$SIGN_ID\" code-signing certificate for a stable identity)"
fi

echo "Built: $(pwd)/$APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
