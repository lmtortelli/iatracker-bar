#!/usr/bin/env bash
# Notas de release em Markdown a partir dos commits semânticos desde a tag anterior.
# Uso: scripts/release-notes.sh <tag anterior ou vazio> [ref]
set -euo pipefail

PREVIOUS="${1:-}"
REF="${2:-HEAD}"
RANGE="${PREVIOUS:+$PREVIOUS..}$REF"

section() {
  local title="$1" pattern="$2" lines
  lines="$(git log --no-merges --format='%s' "$RANGE" | grep -E "$pattern" | sed -E 's/^[a-z]+(\([^)]*\))?!?: */- /' || true)"
  if [[ -n "$lines" ]]; then
    printf '## %s\n\n%s\n\n' "$title" "$lines"
  fi
}

breaking="$(git log --no-merges --format='%s%n%b%x1e' "$RANGE" \
  | awk 'BEGIN{RS="\x1e"} /^[a-z]+(\([^)]*\))?!:/ || /\nBREAKING[ -]CHANGE:/ {split($0, l, "\n"); print l[1]}' \
  | sed -E '/^$/d; s/^[a-z]+(\([^)]*\))?!?: */- /' || true)"
if [[ -n "$breaking" ]]; then
  printf '## Mudanças incompatíveis\n\n%s\n\n' "$breaking"
fi
section "Novidades" '^feat(\([^)]*\))?!?:'
section "Correções" '^(fix|perf)(\([^)]*\))?!?:'

cat <<'INSTALL'
## Instalação

1. Baixe `IAtracker-bar-<versão>.zip` abaixo, descompacte e mova **IAtracker-bar.app** para **Aplicativos**.
2. O app não é notarizado; libere a primeira abertura com:
   ```bash
   xattr -dr com.apple.quarantine /Applications/IAtracker-bar.app
   ```
3. Abra o app: ele aparece na barra de menus. Requer macOS 13 ou mais novo (Apple Silicon ou Intel).
INSTALL
