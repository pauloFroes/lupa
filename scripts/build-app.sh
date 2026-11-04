#!/usr/bin/env bash
# Monta build/Lupa.app a partir do SwiftPM. Uso: scripts/build-app.sh [--install] [--open]
# LUPA_SIGN_IDENTITY escolhe o certificado; sem ele, usa (e cria na primeira vez) o certificado
# local "Lupa Local Signing". LUPA_SIGN_IDENTITY=- volta à assinatura ad-hoc.
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

identity="${LUPA_SIGN_IDENTITY:-Lupa Local Signing}"
[ "$identity" = "Lupa Local Signing" ] && scripts/make-signing-cert.sh "$identity" >/dev/null
codesign --force --sign "$identity" --identifier io.github.paulofroes.lupa "$app"
echo "pronto: $app"

app_running() { pgrep -x Lupa >/dev/null; }

# Espera em décimos de segundo; devolve sucesso quando nenhuma Lupa está rodando.
wait_gone() {
  for _ in $(seq 1 "$1"); do
    app_running || return 0
    sleep 0.1
  done
  ! app_running
}

fail() { echo "erro: $*" >&2; exit 1; }

requirement() { codesign -dr - "$1" 2>/dev/null | sed -n 's/^designated => //p'; }

if $install; then
  dest=/Applications/Lupa.app
  old_requirement="$( [ -d "$dest" ] && requirement "$dest" || true )"
  # Fechar antes de trocar: apagar o bundle de um processo vivo deixa a versão velha rodando,
  # e abrir enquanto ela ainda sai dá o erro -600 do Launch Services.
  if app_running; then
    pkill -TERM -x Lupa || true
    if ! wait_gone 50; then
      echo "a Lupa não fechou em 5 s; forçando"
      pkill -KILL -x Lupa || true
      wait_gone 30 || fail "não consegui fechar a Lupa; saia pelo menu dela e rode de novo"
    fi
    echo "fechada: a Lupa que estava aberta"
  fi
  rm -rf "$dest"
  [ ! -e "$dest" ] || fail "não consegui apagar $dest"
  ditto "$app" "$dest"
  cmp -s "$app/Contents/MacOS/Lupa" "$dest/Contents/MacOS/Lupa" || fail "a cópia em $dest não confere com o build"
  codesign --verify --strict "$dest" || fail "a assinatura de $dest não confere"
  # O Launch Services guarda em cache o bundle antigo; registrar de novo faz o open achar o novo.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest" >/dev/null 2>&1 || true
  # A permissão fica presa à assinatura antiga quando ela muda: os Ajustes mostram a Lupa
  # ligada, mas a nova não está autorizada. Zerar faz o macOS perguntar de novo.
  if [ "$old_requirement" != "$(requirement "$dest")" ]; then
    for service in ScreenCapture Microphone Camera; do
      tccutil reset "$service" io.github.paulofroes.lupa >/dev/null 2>&1 || true
    done
    echo "assinatura nova: permita a Lupa de novo em Gravação de Tela (só desta vez)"
  fi
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dest/Contents/Info.plist")"
  echo "instalado: $dest (versão $version, commit $(git rev-parse --short HEAD))"
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
  $opened || fail "não consegui abrir $app_path"
  pid=""
  for _ in $(seq 1 50); do
    pid="$(pgrep -x Lupa | head -1)" && break
    sleep 0.1
  done
  [ -n "$pid" ] || fail "a Lupa não ficou aberta"
  running="$(ps -p "$pid" -o comm=)"
  [ "$running" = "$app_path/Contents/MacOS/Lupa" ] || fail "a Lupa aberta é outra cópia: $running"
  echo "aberta: $app_path (pid $pid)"
fi
