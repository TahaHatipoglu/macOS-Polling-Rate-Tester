#!/bin/bash
# Converts a 1024x1024 PNG into AppIcon.icns using tools built into macOS.
# Usage:  chmod +x make_icon.sh && ./make_icon.sh icon.png
set -euo pipefail

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "Usage: ./make_icon.sh path/to/icon.png   (a 1024x1024 PNG)"
  exit 1
fi

SRC="$1"
SET="AppIcon.iconset"
rm -rf "$SET"
mkdir "$SET"

for s in 16 32 128 256 512; do
  d=$((s * 2))
  sips -z "$s" "$s" "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z "$d" "$d" "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$SET"
echo "Created AppIcon.icns — now run ./build.sh"
