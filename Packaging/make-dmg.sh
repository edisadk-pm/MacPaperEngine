#!/bin/bash
# Makes build/MacPaperEngine.dmg from build/MacPaperEngine.app: a window with the app beside
# Applications and an arrow between them, to drag it across. Run ./build.sh first.
#
# The layout is written by dmgbuild (https://github.com/dmgbuild/dmgbuild), installed once into
# build/dmgbuild-env, so Finder never has to be scripted.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/MacPaperEngine.app
DMG=build/MacPaperEngine.dmg
WORK=build/dmg
ENV=build/dmgbuild-env
[[ -d "$APP" ]] || { echo "Run ./build.sh first." >&2; exit 1; }

if [[ ! -x "$ENV/bin/dmgbuild" ]]; then
    python3 -m venv "$ENV"
    "$ENV/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==1.6.7"
fi

rm -rf "$WORK"
mkdir -p "$WORK"
swift Packaging/dmg/MakeBackground.swift "$WORK"
# One file holding both resolutions, so the background is sharp on Retina displays.
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" 2>/dev/null

# The window's title, from the volume's name: "MacPaperEngine 1.2.0".
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

rm -f "$DMG"
"$ENV/bin/dmgbuild" -s Packaging/dmg/settings.py \
    -D app="$APP" \
    -D background="$WORK/background.tiff" \
    -D icon="$APP/Contents/Resources/AppIcon.icns" \
    "MacPaperEngine $VERSION" "$DMG" 2>&1 >/dev/null | grep -v "is deprecated" >&2 || true
[[ -f "$DMG" ]] || { echo "The disk image wasn't made." >&2; exit 1; }
echo "Made $(pwd)/$DMG"
