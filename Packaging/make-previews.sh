#!/bin/bash
# Rebuilds the previews in Resources/ from the full media in Media/. Usage: Packaging/make-previews.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Compiled together with the core sources, which read dynamic-wallpaper schedules.
swiftc -O -module-name MacPaperCore Sources/MacPaperCore/*.swift Packaging/MakePreviews/main.swift -o "$OUT/make-previews"
"$OUT/make-previews" "$(pwd)"
