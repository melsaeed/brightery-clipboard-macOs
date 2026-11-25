#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin ]]; then echo 'Build on macOS 13 or later.' >&2; exit 1; fi
if ! xcode-select -p >/dev/null 2>&1; then echo 'Install Apple Command Line Tools with: xcode-select --install' >&2; exit 1; fi
NAME='Brightery Clipboard'
BUILD="$PWD/build"
APP="$BUILD/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
export MACOSX_DEPLOYMENT_TARGET=13.0
for ARCH in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -whole-module-optimization -target "$ARCH-apple-macos13.0" \
    -framework AppKit -framework Carbon -framework ApplicationServices -framework ServiceManagement \
    -lsqlite3 Sources/HistoryStore.swift Sources/main.swift -o "$BUILD/clipboard-$ARCH"
done
xcrun lipo -create "$BUILD/clipboard-arm64" "$BUILD/clipboard-x86_64" -output "$APP/Contents/MacOS/$NAME"
cp Info.plist "$APP/Contents/Info.plist"
xcrun swift Icon.swift "$BUILD/icon.png"
mkdir -p "$BUILD/AppIcon.iconset"
for n in 16 32 128 256 512; do
  sips -z "$n" "$n" "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${n}x${n}.png" >/dev/null
  sips -z "$((n*2))" "$((n*2))" "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
if [[ "${1:-}" == --install ]]; then
  DEST="$HOME/Applications/$NAME.app"
  mkdir -p "$HOME/Applications"
  if pgrep -x "$NAME" >/dev/null; then echo 'Quit Brightery Clipboard from its menu bar first, then rerun.' >&2; exit 1; fi
  ditto "$APP" "$DEST"
  open "$DEST"
  echo "Installed: $DEST"
else
  echo "Built: $APP"
fi
