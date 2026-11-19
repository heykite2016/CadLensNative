#!/bin/bash
# Builds the distributable DMG + ZIP from build/CadLens.app.
# Usage: Tools/package_release.sh 3.0.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-3.0.0}"
APP="$ROOT/build/CadLens.app"
OUT="$ROOT/release"
NAME="CadLens-${VERSION}-macos-x86_64"

[ -d "$APP" ] || { echo "missing $APP; run ./build.sh first" >&2; exit 1; }

rm -rf "$OUT" /tmp/cadlens-dmg
mkdir -p "$OUT" /tmp/cadlens-dmg
ditto "$APP" /tmp/cadlens-dmg/CadLens.app
ln -s /Applications /tmp/cadlens-dmg/Applications
cp "$ROOT/Resources/Brand/package-b.icns" /tmp/cadlens-dmg/.VolumeIcon.icns

hdiutil create -volname "速看CAD" -srcfolder /tmp/cadlens-dmg -fs HFS+ \
    -format UDRW -ov /tmp/CadLens-rw.dmg >/dev/null
hdiutil attach -nobrowse -readwrite /tmp/CadLens-rw.dmg >/tmp/cadlens-attach.log
VOL="$(grep -o '/Volumes/.*' /tmp/cadlens-attach.log | head -1 | sed 's/[[:space:]]*$//')"
SetFile -a C "$VOL" 2>/dev/null || true
hdiutil detach "$VOL" >/dev/null
hdiutil convert /tmp/CadLens-rw.dmg -format UDZO -imagekey zlib-level=9 \
    -o "$OUT/$NAME.dmg" >/dev/null
rm -f /tmp/CadLens-rw.dmg

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME.zip"
( cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt )
echo "==> $OUT/$NAME.dmg"
echo "==> $OUT/$NAME.zip"
