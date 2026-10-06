#!/usr/bin/env bash
# Compila e instala o IAtracker-bar em /Applications, substituindo a versão anterior.
# Os dados (~/Library/Application Support/IAtracker-bar) não são tocados.
# Uso: scripts/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="/Applications/IAtracker-bar.app"

"$ROOT/scripts/build-app.sh" release

# Só substitui depois que o build novo existe.
[[ -d "$ROOT/build/IAtracker-bar.app" ]] || { echo "build/IAtracker-bar.app não foi gerado" >&2; exit 1; }

if pgrep -x IAtrackerBar >/dev/null; then
  osascript -e 'quit app id "io.github.lmtortelli.iatracker-bar"' 2>/dev/null || pkill -x IAtrackerBar || true
  sleep 1
fi
rm -rf "$TARGET"
mv "$ROOT/build/IAtracker-bar.app" "$TARGET"
open "$TARGET"
echo "✓ instalado em $TARGET"
