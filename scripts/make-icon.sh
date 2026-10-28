#!/bin/bash
# Régénère Resources/AppIcon.icns à partir de Resources/Icon/murmur-icon.svg.
# Le rendu SVG passe par Google Chrome sans interface ; sips et iconutil sont fournis avec macOS.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SVG="$PWD/Resources/Icon/murmur-icon.svg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$CHROME" --headless --disable-gpu --hide-scrollbars --window-size=1024,1024 \
  --default-background-color=00000000 --screenshot="$TMP/icon-1024.png" "file://$SVG" 2>/dev/null

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$TMP/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Icône générée : Resources/AppIcon.icns"
