#!/bin/bash
# Builds build/MacPaperEngine.app. Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

# One universal app: Apple silicon and Intel.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="build/MacPaperEngine.app"
ENGINE="$APP/Contents/Library/LoginItems/MacPaperEngine Helper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$ENGINE/Contents/MacOS" "$ENGINE/Contents/Resources"

# The SwiftPM products keep their names; the bundles carry the app's.
cp "$BIN/MacPaper" "$APP/Contents/MacOS/MacPaperEngine"
cp "$BIN/MacPaperEngine" "$ENGINE/Contents/MacOS/MacPaperEngine Helper"
cp Packaging/App-Info.plist "$APP/Contents/Info.plist"
cp Packaging/Helper-Info.plist "$ENGINE/Contents/Info.plist"

# Produces Assets.car (Default, Dark, Tinted and Clear looks) and AppIcon.icns for macOS 15 and older.
if ! xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" \
    --platform macosx --target-device mac --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist build/AppIcon-partial.plist > build/actool.log 2>&1; then
    cat build/actool.log >&2
    echo "Icon compile failed" >&2
    exit 1
fi
cp "$APP/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/Assets.car" "$ENGINE/Contents/Resources/"
# What's New on the About page.
cp CHANGELOG.md "$APP/Contents/Resources/"

# -c clones on APFS, so the bundled files take no extra disk space inside the app.
for bundled in Footage Dynamic; do
    if [[ -d Resources/$bundled ]]; then
        cp -Rc "Resources/$bundled" "$ENGINE/Contents/Resources/"
    fi
done

strip -x "$APP/Contents/MacOS/MacPaperEngine" "$ENGINE/Contents/MacOS/MacPaperEngine Helper"

# Inner bundle first: signing the outer app seals the inner one.
codesign --force --sign - "$ENGINE"
codesign --force --sign - "$APP"

echo "Built $(pwd)/$APP"
