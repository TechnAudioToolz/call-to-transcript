#!/usr/bin/env bash
# Builds the offline edition: the app with the speech, voice and sound clean-up models and ffmpeg inside,
# so it installs and works on a Mac with no internet connection.
#   ./build.sh && ./make_offline_dmg.sh     -> build/Call Transcriber (offline).dmg
# The downloaded parts are kept in build/offline-payload and reused; move it to the Trash to fetch fresh ones.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Call Transcriber.app"
PAYLOAD="$(pwd)/build/offline-payload"
[ -d "$APP" ] || { echo "Build the app first: ./build.sh"; exit 1; }

if [ ! -f "$PAYLOAD/.complete" ]; then
  echo "Gathering the offline payload (downloads about 700 MB once)…"
  rm -rf "$PAYLOAD"
  mkdir -p "$PAYLOAD/bin"
  # The models: fetched by the app's own engine, then copied from its models folder.
  "$APP/Contents/MacOS/transcribe-cli" --download-models | grep -v '^\['
  MODELS="$HOME/Library/Application Support/Transcript Maker/models"
  mkdir -p "$PAYLOAD/models"
  for m in parakeet-ultra speaker-diarization localvqe; do ditto "$MODELS/$m" "$PAYLOAD/models/$m"; done
  # ffmpeg for MKV, WebM, AVI and other files macOS can't open itself: the self-contained Apple Silicon build
  # from imageio-ffmpeg 0.6.0 (FFmpeg 7.1, GPL; source at https://ffmpeg.org).
  WHEEL_DIR="$(mktemp -d)"
  python3 -m pip download --quiet --no-deps --only-binary=:all: --platform macosx_11_0_arm64 \
    imageio-ffmpeg==0.6.0 -d "$WHEEL_DIR"
  unzip -q -o -j "$WHEEL_DIR"/imageio_ffmpeg-*.whl 'imageio_ffmpeg/binaries/ffmpeg-*' -d "$WHEEL_DIR/bin"
  mv "$WHEEL_DIR"/bin/ffmpeg-* "$PAYLOAD/bin/ffmpeg"
  chmod +x "$PAYLOAD/bin/ffmpeg"
  rm -rf "$WHEEL_DIR"
  touch "$PAYLOAD/.complete"
fi

# The app, with the payload inside it.
OUT="build/offline"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$APP" "$OUT/Call Transcriber.app"
ditto "$PAYLOAD/models" "$OUT/Call Transcriber.app/Contents/Resources/models"
ditto "$PAYLOAD/bin" "$OUT/Call Transcriber.app/Contents/Resources/bin"
SIGN_ID="${SIGN_ID:-Call Transcriber Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --deep --sign "$SIGN_ID" "$OUT/Call Transcriber.app"
else
  codesign --force --deep --sign - "$OUT/Call Transcriber.app"
fi
codesign --verify --deep "$OUT/Call Transcriber.app"

# The disk image: the app, an Applications shortcut to drag it onto, and how to open it.
DMG="build/Call Transcriber (offline).dmg"
STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
mv "$OUT/Call Transcriber.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to open.txt" <<NOTE
Call Transcriber

1. Drag "Call Transcriber" onto the Applications folder.
2. Open it from Applications.

The first time, macOS may say it can't check the app for malicious software. That's because
this free app isn't registered with Apple. To open it anyway:

   System Settings > Privacy and Security > scroll down > "Open Anyway"

You only need to do this once.

This is the offline edition: the speech recognition, speaker and sound clean-up models are inside
the app, so it needs no internet connection. Your videos and transcripts never leave your Mac.
The first transcript takes a minute or two longer while macOS prepares the models for this Mac.

Needs macOS 14 Sonoma or newer, on a Mac with Apple Silicon (M1 or later).

Inside: Parakeet speech recognition (NVIDIA, CC-BY-4.0) and pyannote speaker models, run through
FluidAudio (Apache 2.0); LocalVQE (Apache 2.0); FFmpeg 7.1 (GPL, source at https://ffmpeg.org).
NOTE
hdiutil create -volname "Call Transcriber" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE" "$OUT"
echo "Built: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
