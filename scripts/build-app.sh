#!/usr/bin/env bash
# Gera build/IAtracker-bar.app a partir do Swift Package (não requer Xcode).
# Uso: scripts/build-app.sh [debug|release]
#   UNIVERSAL=1           binário para Apple Silicon e Intel (lipo)
#   IATRACKER_VERSION=x   versão do bundle (padrão: última tag v*, senão 0.1.0)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/IAtracker-bar.app"
VERSION="${IATRACKER_VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 --match "v[0-9]*" 2>/dev/null || echo 0.1.0)}"
VERSION="${VERSION#v}"

cd "$ROOT"
mkdir -p build
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  for arch in arm64 x86_64; do
    swift build -c "$CONFIG" --product IAtrackerBar --triple "$arch-apple-macosx13.0"
  done
  BIN="$ROOT/build/IAtrackerBar-universal"
  lipo -create -output "$BIN" \
    ".build/arm64-apple-macosx/$CONFIG/IAtrackerBar" \
    ".build/x86_64-apple-macosx/$CONFIG/IAtrackerBar"
else
  swift build -c "$CONFIG" --product IAtrackerBar
  BIN="$(swift build -c "$CONFIG" --show-bin-path)/IAtrackerBar"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/IAtrackerBar"
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

# Assinatura ad hoc: suficiente para rodar localmente (o app não é notarizado).
xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "✓ $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/IAtrackerBar"))"
