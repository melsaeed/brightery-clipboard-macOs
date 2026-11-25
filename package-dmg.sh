#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "build/Brightery Clipboard.app" "$STAGE/Brightery Clipboard.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
OUT="dist/BrighteryClipboard-$VERSION-universal.dmg"
hdiutil create -ov -format UDZO -volname "Brightery Clipboard" -srcfolder "$STAGE" "$OUT"
hdiutil verify "$OUT"
(cd dist && shasum -a 256 "BrighteryClipboard-$VERSION-universal.dmg" > SHA256SUMS.txt)
echo "Created $OUT"
