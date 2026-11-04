#!/usr/bin/env bash
# Monta build/Lupa.app a partir do SwiftPM. Uso: scripts/build-app.sh [--install] [--open]
# LUPA_SIGN_IDENTITY escolhe o certificado; sem ele, a assinatura é ad-hoc.
set -euo pipefail

cd "$(dirname "$0")/.."

install=false
open_after=false
for arg in "$@"; do
  case "$arg" in
    --install) install=true ;;
    --open) open_after=true ;;
    *) echo "opção desconhecida: $arg" >&2; exit 2 ;;
  esac
done

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
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign "${LUPA_SIGN_IDENTITY:--}" --identifier io.github.paulofroes.lupa "$app"
echo "pronto: $app"

if $install; then
  pkill -x Lupa 2>/dev/null || true
  rm -rf /Applications/Lupa.app
  cp -R "$app" /Applications/Lupa.app
  echo "instalado: /Applications/Lupa.app"
  app=/Applications/Lupa.app
fi

if $open_after; then
  open "$app"
fi
