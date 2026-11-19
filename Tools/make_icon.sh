#!/bin/bash
# Builds Resources/AppIcon.icns from Tools/make_icon.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources"
MASTER="$OUT/AppIcon-1024.png"
SET="$OUT/AppIcon.iconset"

swiftc -O "$ROOT/Tools/make_icon.swift" -o /tmp/cadlens-mkicon -framework AppKit
/tmp/cadlens-mkicon "$MASTER"

rm -rf "$SET"
mkdir -p "$SET"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    size="${spec%% *}"
    name="${spec##* }"
    sips -z "$size" "$size" "$MASTER" --out "$SET/$name.png" >/dev/null
done

iconutil -c icns "$SET" -o "$OUT/AppIcon.icns"
rm -rf "$SET"
echo "==> 图标已生成: $OUT/AppIcon.icns"
