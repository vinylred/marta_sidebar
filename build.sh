#!/bin/bash
# Build the Marta "Places Sidebar" native library and assemble the plugin.
#
# Marta loads a compiled dynamic library (.so) whose Lua symbols are resolved
# from Marta's own process at load time. We compile plugin.swift once per
# architecture and lipo the slices into one universal binary (arm64 + x86_64),
# so it runs on both Apple Silicon and Intel Macs.
#
# Two header sources are supported automatically:
#   * If Marta.app is installed, use its bundled Lua headers.
#   * Otherwise fall back to the vendored headers in vendor/lua (so CI runners
#     without Marta can still build). Lua symbols are linked with
#     -undefined dynamic_lookup either way.
#
# Usage:
#   ./build.sh            build universal .so into dist/
#   ./build.sh install    build, then copy into Marta's Plugins folder
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

MARTA="/Applications/Marta.app"
LUAKIT="$MARTA/Contents/Frameworks/LuaKit.framework/Versions/Current"

if [ -d "$LUAKIT/Resources/include" ]; then
    INCLUDE="$LUAKIT/Resources/include"
    echo "Using Marta's bundled Lua headers."
elif [ -d "$HERE/vendor/lua" ]; then
    INCLUDE="$HERE/vendor/lua"
    echo "Marta not found; using vendored Lua headers (vendor/lua)."
else
    echo "error: no Lua headers found (neither Marta.app nor vendor/lua)." >&2
    exit 1
fi

OUT_NAME="libmartasidebar.so"
DIST="$HERE/dist/places-sidebar"
BUILD="$HERE/build"
ARCHS=("arm64" "x86_64")

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$DIST"

SLICES=()
for arch in "${ARCHS[@]}"; do
    echo "Compiling $OUT_NAME ($arch) ..."
    slice="$BUILD/$OUT_NAME.$arch"
    swiftc \
        -target "$arch-apple-macosx11.0" \
        -emit-library \
        -o "$slice" \
        -module-name libmartasidebar \
        -import-objc-header "$HERE/martasidebar-Bridging-Header.h" \
        -I "$INCLUDE" \
        -Xlinker -undefined -Xlinker dynamic_lookup \
        -Xlinker -install_name -Xlinker "@rpath/$OUT_NAME" \
        -framework Cocoa \
        -O \
        "$HERE/plugin.swift"
    SLICES+=("$slice")
done

echo "Creating universal binary ..."
lipo -create "${SLICES[@]}" -output "$DIST/$OUT_NAME"
cp "$HERE/init.lua" "$DIST/init.lua"

echo "Built plugin at: $DIST"
echo "Architectures: $(lipo -archs "$DIST/$OUT_NAME")"
ls -la "$DIST"

# Optional install step:  ./build.sh install
if [ "${1:-}" = "install" ]; then
    PLUGINS="$HOME/Library/Application Support/org.yanex.marta/Plugins"
    DEST="$PLUGINS/places-sidebar"
    rm -rf "$DEST"
    cp -R "$DIST" "$DEST"
    echo "Installed to: $DEST"
    echo "Restart Marta, then run the 'Show Places Sidebar' action (Cmd-Shift-P)."
fi
