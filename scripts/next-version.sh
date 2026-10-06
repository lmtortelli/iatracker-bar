#!/usr/bin/env bash
# Calcula a próxima versão pelos commits semânticos desde a última tag v*.
#   fix / perf                        → patch (0.1.0 → 0.1.1)
#   feat                              → minor (0.1.0 → 0.2.0)
#   tipo! ou "BREAKING CHANGE" no corpo → major (0.1.0 → 1.0.0)
#   demais tipos (docs, chore, ci, …)  → sem release
# Saída (stdout, formato do $GITHUB_OUTPUT): `version=<x.y.z>`, `bump=<major|minor|patch|none>`, `previous=<tag ou vazio>`.
# Uso: scripts/next-version.sh [ref]   (padrão: HEAD)
set -euo pipefail

REF="${1:-HEAD}"
LAST_TAG="$(git describe --tags --abbrev=0 --match "v[0-9]*" "$REF" 2>/dev/null || true)"
if [[ -n "$LAST_TAG" ]]; then
  RANGE="$LAST_TAG..$REF"
  BASE="${LAST_TAG#v}"
else
  RANGE="$REF"
  BASE="0.0.0"
fi

BUMP="none"
rank() { case "$1" in major) echo 3 ;; minor) echo 2 ;; patch) echo 1 ;; *) echo 0 ;; esac; }
raise() { if (( $(rank "$1") > $(rank "$BUMP") )); then BUMP="$1"; fi; }

# Um registro por commit: assunto, corpo; separados por \x1e.
while IFS= read -r -d $'\x1e' commit; do
  subject="$(printf '%s\n' "$commit" | sed -n '/./{p;q;}')"   # primeira linha não vazia
  if [[ "$subject" =~ ^[a-z]+(\([^\)]*\))?!: ]] || printf '%s\n' "$commit" | grep -qE '^BREAKING[ -]CHANGE:'; then
    raise major
  elif [[ "$subject" =~ ^feat(\([^\)]*\))?: ]]; then
    raise minor
  elif [[ "$subject" =~ ^(fix|perf)(\([^\)]*\))?: ]]; then
    raise patch
  fi
done < <(git log --no-merges --format='%s%n%b%x1e' "$RANGE")

IFS=. read -r MAJOR MINOR PATCH <<<"$BASE"
case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac

echo "version=$MAJOR.$MINOR.$PATCH"
echo "bump=$BUMP"
echo "previous=$LAST_TAG"
