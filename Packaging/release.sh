#!/bin/bash
# Publishes a new version that installed copies update to by themselves: sets the version, builds,
# zips, makes the disk image, commits, tags, pushes and creates the GitHub release the app's
# updater and install.sh read. The release notes are the version's section of CHANGELOG.md, which
# the app also shows as What's New, followed by how to install.
#
# Usage: Packaging/release.sh 1.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
REPO="edisadk-pm/MacPaperEngine"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Give a version such as 1.2.0" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit or stash your changes first, so the release matches a commit." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "v$VERSION already exists." >&2
    exit 1
fi

# The section under "## 1.2.0 — date", up to the next heading, without leading blank lines.
NOTES=$(awk -v v="$VERSION" '
    /^## / { if (found) exit; split(substr($0, 4), heading, " — "); found = (heading[1] == v); next }
    found { print }
' CHANGELOG.md | sed -e '/./,$!d')
if [[ -z "${NOTES//[[:space:]]/}" ]]; then
    echo "Add a \"## $VERSION — date\" section to CHANGELOG.md first. It's the release notes and the app's What's New." >&2
    exit 1
fi

PLISTBUDDY=/usr/libexec/PlistBuddy
BUILD=$(( $($PLISTBUDDY -c "Print :CFBundleVersion" Packaging/App-Info.plist) + 1 ))
for plist in Packaging/App-Info.plist Packaging/Helper-Info.plist; do
    $PLISTBUDDY -c "Set :CFBundleShortVersionString $VERSION" "$plist"
    $PLISTBUDDY -c "Set :CFBundleVersion $BUILD" "$plist"
done

./build.sh

# The updater looks for exactly these two names.
ZIP=build/MacPaperEngine.zip
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent build/MacPaperEngine.app "$ZIP"
(cd build && shasum -a 256 MacPaperEngine.zip > MacPaperEngine.zip.sha256)
# For people installing by hand: drag the app onto Applications.
Packaging/make-dmg.sh
DMG=build/MacPaperEngine.dmg

# Every release page says how to install, under the version's own notes.
NOTES="$NOTES

## Install

**Easiest:** paste this into Terminal. It installs MacPaperEngine in Applications and opens it.

\`\`\`
curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash
\`\`\`

**Or by hand:** download **MacPaperEngine.dmg** below, open it and drag MacPaperEngine onto Applications. The app isn't notarized by Apple, so the first time you open it macOS stops it: open **System Settings > Privacy & Security** and click **Open Anyway**.

Needs macOS 14 Sonoma or later, on Apple silicon or Intel. Once installed, MacPaperEngine keeps itself up to date."

git commit -q -am "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
gh release create "v$VERSION" "$DMG" "$ZIP" "$ZIP.sha256" --repo "$REPO" \
    --title "MacPaperEngine $VERSION" --notes "$NOTES"

echo "Released $VERSION. Installed copies pick it up the next time they open, or at once with Check for Updates."
