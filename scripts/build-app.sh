#!/bin/bash
# Compile Murmur.app. Ajoute --install pour la copier dans /Applications et la relancer.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Murmur"

APP="build/Murmur.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signe avec une identité stable si tu en as une (garde les autorisations entre deux builds), sinon ad hoc.
IDENTITY="${MURMUR_SIGN_IDENTITY:--}"
codesign --force --deep --options runtime --entitlements Resources/Murmur.entitlements --sign "$IDENTITY" "$APP"
echo "App compilée : $APP (signature : $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Murmur 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Murmur.app
  cp -R "$APP" /Applications/Murmur.app
  open /Applications/Murmur.app
  echo "Installée et lancée : /Applications/Murmur.app"
fi
