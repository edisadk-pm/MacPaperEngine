#!/bin/bash
# Publishes a new version that installed copies update to by themselves: sets the version, builds,
# zips, commits, tags, pushes and creates the GitHub release the app's updater reads.
#
# Usage: Packaging/release.sh 1.2.0 "What changed"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-}"
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

git commit -q -am "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" --repo "$REPO" \
    --title "MacPaperEngine $VERSION" --notes "${NOTES:-MacPaperEngine $VERSION}"

echo "Released $VERSION. Installed copies pick it up within six hours, or at once with Check for Updates."
