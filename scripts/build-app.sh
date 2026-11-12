#!/usr/bin/env bash
# Builds build/Lupa.app from the Swift package.
#
# Usage: scripts/build-app.sh [--install] [--open]
#   --install  quit any running Lupa, replace /Applications/Lupa.app and verify the copy
#   --open     launch the built (or installed) app and verify that copy is the one running
#
# LUPA_SIGN_IDENTITY picks the code-signing identity. By default the script creates (once) and
# uses a self-signed "Lupa Local Signing" certificate; LUPA_SIGN_IDENTITY=- signs ad hoc.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly bundle_id=io.github.paulofroes.lupa
install=false
open_after=false
for arg in "$@"; do
  case "$arg" in
    --install) install=true ;;
    --open) open_after=true ;;
    -h | --help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

fail() {
  echo "error: $*" >&2
  exit 1
}

swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"

if [ ! -f build/AppIcon.icns ]; then
  mkdir -p build/AppIcon.iconset
  swiftc -O -o build/make-icon scripts/make-icon.swift
  build/make-icon build/icon-1024.png
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" build/icon-1024.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" build/icon-1024.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

app=build/Lupa.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Fonts"
cp "$bin_dir/Lupa" "$app/Contents/MacOS/Lupa"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/Fonts/*.ttf "$app/Contents/Resources/Fonts/"
cp -R Resources/*.lproj "$app/Contents/Resources/"
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

identity="${LUPA_SIGN_IDENTITY:-Lupa Local Signing}"
if [ "$identity" = "Lupa Local Signing" ]; then
  scripts/make-signing-cert.sh "$identity" >/dev/null
fi
codesign --force --sign "$identity" --identifier "$bundle_id" "$app"
echo "built: $app"

app_running() { pgrep -x Lupa >/dev/null; }

# Waits up to $1 tenths of a second; succeeds once no Lupa process is left.
wait_gone() {
  for _ in $(seq 1 "$1"); do
    app_running || return 0
    sleep 0.1
  done
  ! app_running
}

designated_requirement() { codesign -dr - "$1" 2>/dev/null | sed -n 's/^designated => //p'; }

if $install; then
  dest=/Applications/Lupa.app
  old_requirement="$([ -d "$dest" ] && designated_requirement "$dest" || true)"
  # Quit first: deleting the bundle of a live process leaves the old build running, and opening
  # while it is still quitting fails with Launch Services error -600.
  if app_running; then
    pkill -TERM -x Lupa || true
    if ! wait_gone 50; then
      echo "Lupa did not quit within 5 s; killing it"
      pkill -KILL -x Lupa || true
      wait_gone 30 || fail "could not quit Lupa; quit it from its menu and run this again"
    fi
    echo "quit: the running Lupa"
  fi
  rm -rf "$dest"
  [ ! -e "$dest" ] || fail "could not remove $dest"
  ditto "$app" "$dest"
  cmp -s "$app/Contents/MacOS/Lupa" "$dest/Contents/MacOS/Lupa" || fail "$dest does not match the build"
  codesign --verify --strict "$dest" || fail "the signature of $dest does not verify"
  # Launch Services caches the old bundle; re-registering makes `open` pick up the new one.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$dest" >/dev/null 2>&1 || true
  # Privacy permissions are tied to the code signature. When it changes, System Settings still
  # shows Lupa as allowed but the new build is not; resetting makes macOS ask again.
  if [ "$old_requirement" != "$(designated_requirement "$dest")" ]; then
    for service in ScreenCapture Microphone Camera; do
      tccutil reset "$service" "$bundle_id" >/dev/null 2>&1 || true
    done
    echo "new signature: allow Lupa under Screen Recording again (one time only)"
  fi
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dest/Contents/Info.plist")"
  echo "installed: $dest (version $version, commit $(git rev-parse --short HEAD 2>/dev/null || echo unknown))"
  app="$dest"
fi

if $open_after; then
  app_path="$(cd "$app" && pwd)"
  opened=false
  for attempt in 1 2 3; do
    if open "$app_path"; then
      opened=true
      break
    fi
    [ "$attempt" -lt 3 ] && sleep 1
  done
  $opened || fail "could not open $app_path"
  pid=""
  for _ in $(seq 1 50); do
    pid="$(pgrep -x Lupa | head -1)" && break
    sleep 0.1
  done
  [ -n "$pid" ] || fail "Lupa did not stay open"
  running="$(ps -p "$pid" -o comm=)"
  [ "$running" = "$app_path/Contents/MacOS/Lupa" ] || fail "a different copy of Lupa is running: $running"
  echo "running: $app_path (pid $pid)"
fi
