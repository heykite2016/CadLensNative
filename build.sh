#!/bin/bash
# Builds the native macOS app using the shared toolchain in ~/Documents/libshare.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LS="${LIBSHARE:-$HOME/Documents/libshare}"
SWIFTC="${SWIFTC:-swiftc}"
CXX="${CXX:-clang++}"
export PATH="$LS/bin:$PATH"

BUILD="$ROOT/build"
APP="$BUILD/CadLens.app"
mkdir -p "$BUILD"

TARGET="x86_64-apple-macos12.0"
if [ "$(uname -m)" = "arm64" ]; then
    TARGET="arm64-apple-macos12.0"
fi

echo "==> 编译 C++ 解析核心"
"$CXX" -c -O2 -std=c++17 -fvisibility=hidden \
    -I"$LS/include" -I"$LS/include/libredwg" -I"$ROOT/Sources/CadCore/include" \
    "$ROOT/Sources/CadCore/cadcore.cpp" -o "$BUILD/cadcore.o"

echo "==> 编译 Swift 应用"
SWIFT_FLAGS=(-O -target "$TARGET" -I "$ROOT/Sources/CadCore/include")
SWIFT_FILES=("$ROOT"/Sources/CadLens/*.swift)
"$SWIFTC" "${SWIFT_FLAGS[@]}" \
    -o "$BUILD/CadLens" \
    "${SWIFT_FILES[@]}" "$BUILD/cadcore.o" \
    -L"$LS/lib" -lredwg -ldxfrw -liconv -lc++ \
    -framework AppKit -framework Foundation -framework CoreText \
    -framework QuartzCore -framework UniformTypeIdentifiers \
    -framework PDFKit -framework Metal -framework CoreServices

if [ "${1:-}" = "tool" ]; then
    echo "==> 编译命令行工具"
    "$SWIFTC" -O -target "$TARGET" -I "$ROOT/Sources/CadCore/include" \
        -o "$BUILD/cadtool" "$ROOT/Sources/cadtool/main.swift" "$BUILD/cadcore.o" \
        -L"$LS/lib" -lredwg -ldxfrw -liconv -lc++ -framework Foundation
fi

echo "==> 打包 CadLens.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/CadLens" "$APP/Contents/MacOS/CadLens"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -d "$ROOT/Resources/fonts" ]; then
    cp -R "$ROOT/Resources/fonts" "$APP/Contents/Resources/fonts"
fi
if [ -d "$ROOT/Resources/Donate" ]; then
    cp -R "$ROOT/Resources/Donate" "$APP/Contents/Resources/Donate"
fi
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
for icon in DWGFileIcon DXFFileIcon; do
    if [ -f "$ROOT/Resources/$icon.icns" ]; then
        cp "$ROOT/Resources/$icon.icns" "$APP/Contents/Resources/$icon.icns"
    fi
done
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "==> 完成: $APP"
