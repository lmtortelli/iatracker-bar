#!/usr/bin/env bash
# Gera build/IAtracker-bar-<versão>.zip (app universal) para anexar a um GitHub Release.
# Uso: scripts/build-release.sh [versão]      ex.: scripts/build-release.sh 0.1.0
#   SKIP_TESTS=1  pula os testes (o pipeline de release já rodou antes)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(git -C "$ROOT" describe --tags --abbrev=0 --match "v[0-9]*" 2>/dev/null || echo 0.1.0)}"
VERSION="${VERSION#v}"
ZIP="$ROOT/build/IAtracker-bar-$VERSION.zip"

cd "$ROOT"
if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  echo "→ testes"
  swift run iatracker-tests
fi

echo "→ app universal $VERSION"
IATRACKER_VERSION="$VERSION" UNIVERSAL=1 scripts/build-app.sh release

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/IAtracker-bar.app" "$ZIP"
echo "✓ $ZIP"
shasum -a 256 "$ZIP"

cat <<NEXT

Próximos passos:
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION "$ZIP" --title "IAtracker-bar $VERSION" --generate-notes
  (ou crie o release em github.com/lmtortelli/iatracker-bar/releases/new e anexe o .zip)
NEXT
