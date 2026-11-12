#!/bin/bash
# Installs or updates MacPaperEngine. Paste this into Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/edisadk-pm/MacPaperEngine/main/install.sh | bash
#
# It downloads the latest release from GitHub, checks it against the SHA-256 published with it and
# its code signature, puts it in /Applications (or ~/Applications if that isn't writable) and opens
# it. Nothing else on the Mac is changed. After that, the app keeps itself up to date.
set -euo pipefail

REPO="edisadk-pm/MacPaperEngine"
BASE="https://github.com/$REPO/releases/latest/download"
APP="MacPaperEngine.app"

say() { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "MacPaperEngine runs on macOS only."
version=$(sw_vers -productVersion)
(( ${version%%.*} >= 14 )) || fail "MacPaperEngine needs macOS 14 Sonoma or later. This Mac has macOS $version."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

say "Downloading MacPaperEngine…"
curl -fL --progress-bar -o "$work/MacPaperEngine.zip" "$BASE/MacPaperEngine.zip" \
    || fail "The download failed. Check your internet connection and try again."
curl -fsSL -o "$work/MacPaperEngine.zip.sha256" "$BASE/MacPaperEngine.zip.sha256" \
    || fail "The checksum couldn't be downloaded."

say "Checking it…"
expected=$(awk '{print $1}' "$work/MacPaperEngine.zip.sha256")
actual=$(shasum -a 256 "$work/MacPaperEngine.zip" | awk '{print $1}')
[[ -n "$expected" && "$expected" == "$actual" ]] \
    || fail "The download doesn't match its published checksum. Nothing was installed."
ditto -x -k "$work/MacPaperEngine.zip" "$work/unpacked"
[[ -d "$work/unpacked/$APP" ]] || fail "The download doesn't contain $APP. Nothing was installed."
codesign --verify --deep --strict "$work/unpacked/$APP" 2>/dev/null \
    || fail "The app's signature isn't valid. Nothing was installed."

# MACPAPER_INSTALL_DIR installs somewhere else without opening it, for testing this script.
folder="${MACPAPER_INSTALL_DIR:-/Applications}"
if [[ -z "${MACPAPER_INSTALL_DIR:-}" && ! -w "$folder" ]]; then
    folder="$HOME/Applications"
fi
mkdir -p "$folder"
target="$folder/$APP"

# The copy being replaced is quit first if it's running: its window and the engine that draws
# the wallpaper.
if pgrep -f "$target/Contents/" >/dev/null; then
    say "Quitting the running copy…"
    pkill -f "$target/Contents/" 2>/dev/null || true
    sleep 1
fi

say "Installing in $folder…"
rm -rf "$target"
ditto "$work/unpacked/$APP" "$target"
# Downloaded with curl, so it isn't marked as coming from the internet. This makes sure.
xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

installed=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$target/Contents/Info.plist" 2>/dev/null || true)
if [[ -n "${MACPAPER_INSTALL_DIR:-}" ]]; then
    say "MacPaperEngine ${installed} is installed in $folder."
    exit 0
fi
say "MacPaperEngine ${installed} is installed. Opening it…"
open "$target"
