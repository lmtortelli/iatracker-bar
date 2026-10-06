#!/usr/bin/env bash
# Testa scripts/next-version.sh num repositório git temporário.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/next-version.sh"
FAILED=0

check() {
  local name="$1" expected="$2" got
  got="$("$SCRIPT" | sed -n 's/^version=//p') $("$SCRIPT" | sed -n 's/^bump=//p')"
  if [[ "$got" == "$expected" ]]; then echo "  ✓ $name"; else echo "  ✗ $name: esperado '$expected', obtido '$got'"; FAILED=1; fi
}

commit() { git commit -q --allow-empty -m "$1" ${2:+-m "$2"}; }

repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
cd "$repo"
git init -q -b main
git config user.email ci@example.com
git config user.name CI

commit "chore: inicial"
check "só chore, sem tag: nada" "0.0.0 none"
commit "feat: primeira funcionalidade"
check "feat sem tag: 0.1.0" "0.1.0 minor"
git tag v0.1.0

commit "docs: readme"
check "depois da tag, só docs: nada" "0.1.0 none"
commit "fix(ui): corrige popover"
check "fix: patch" "0.1.1 patch"
commit "feat(avisos): renovação"
check "feat vence fix: minor" "0.2.0 minor"
git tag v0.2.0

commit "fix: algo" "BREAKING CHANGE: muda o formato do banco"
check "BREAKING CHANGE no corpo: major" "1.0.0 major"
git tag v1.0.0
commit "feat!: remove sessionKey"
check "tipo com !: major" "2.0.0 major"
git tag v2.0.0
commit "perf: mais rápido"
check "perf: patch" "2.0.1 patch"
commit "Merge pull request #3 from x/y"
check "merge não conta" "2.0.1 patch"

exit $FAILED
