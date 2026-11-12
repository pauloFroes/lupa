#!/usr/bin/env bash
# Packages Lupa for someone else to install: a universal (Apple silicon and Intel) build zipped
# together with installation notes, ready to send.
#
# Usage: scripts/package.sh
#   Writes build/Lupa-<version>.zip. Needs Xcode for the universal build.
#
# The app is signed like any other build (see build-app.sh), not notarized, so the person
# installing it has to allow it once under System Settings › Privacy & Security. Keep signing with
# the same certificate across versions: macOS then keeps their permissions when they update.
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/build-app.sh --universal

app=build/Lupa.app
lipo "$app/Contents/MacOS/Lupa" -verify_arch arm64 x86_64 || {
  echo "error: $app is not a universal binary" >&2
  exit 1
}

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Lupa"
ditto "$app" "$stage/Lupa/Lupa.app"
cp Resources/Distribution/*.txt "$stage/Lupa/"

zip="build/Lupa-$version.zip"
rm -f "$zip"
# ditto keeps the bundle's symlinks and signature intact. --norsrc --noextattr leave out the
# AppleDouble "._*" entries: unzip(1) and other tools would extract them into the bundle as extra
# files, which breaks the signature.
ditto -c -k --norsrc --noextattr --keepParent "$stage/Lupa" "$zip"
echo "packaged: $zip ($(du -h "$zip" | cut -f1 | tr -d ' '))"
