#!/usr/bin/env bash
# Gera build/IAtracker-bar.app a partir do Swift Package (não requer Xcode).
# Uso: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/IAtracker-bar.app"
VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 --match "v[0-9]*" 2>/dev/null || echo 0.1.0)"

cd "$ROOT"
swift build -c "$CONFIG" --product IAtrackerBar
BIN="$(swift build -c "$CONFIG" --show-bin-path)/IAtrackerBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/IAtrackerBar"
sed "s/__VERSION__/${VERSION#v}/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

# Assinatura ad hoc: suficiente para rodar localmente (o app não é notarizado).
xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "✓ $APP"
