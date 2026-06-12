#!/bin/bash
# Build a clean, distributable release zip of the Places Sidebar plugin.
#
# Produces:  release/places-sidebar-<version>.zip
# containing a single `places-sidebar/` folder ready to drop into Marta's
# Plugins directory.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

VERSION="${1:-dev}"
RELEASE="$HERE/release"
DIST="$HERE/dist/places-sidebar"

# Always build fresh (universal).
./build.sh

# Include the user-facing README inside the plugin folder.
cp "$HERE/README.md" "$DIST/README.md" 2>/dev/null || true
cp "$HERE/LICENSE" "$DIST/LICENSE" 2>/dev/null || true

mkdir -p "$RELEASE"
ZIP="$RELEASE/places-sidebar-$VERSION.zip"
rm -f "$ZIP"

# Zip the folder (not its contents) so it unpacks as `places-sidebar/`.
# -X strips extended attributes; we also exclude macOS cruft.
( cd "$HERE/dist" && zip -r -X "$ZIP" places-sidebar \
    -x "*.DS_Store" "__MACOSX*" )

echo ""
echo "Release artifact: $ZIP"
unzip -l "$ZIP"
echo ""
echo "sha256:"
shasum -a 256 "$ZIP"
