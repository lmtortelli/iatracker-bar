#!/usr/bin/env python3
"""Sonda o endpoint de limites do Claude com o token OAuth do Claude Code.

- Lê o item `Claude Code-credentials` do Keychain (o macOS pode pedir confirmação).
- NUNCA imprime o token nem o grava em disco.
- Imprime só a estrutura da resposta: chaves, números e datas ISO; outras strings viram "<str>".
- Com `--save <arquivo>`, grava essa versão anonimizada como fixture de teste.

Uso: python3 scripts/probe-claude-usage.py [--save Tests/Fixtures/claude_usage.json]
"""
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

ENDPOINT = "https://api.anthropic.com/api/oauth/usage"
ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}")


def anonymize(value):
    if isinstance(value, dict):
        return {k: anonymize(v) for k, v in value.items()}
    if isinstance(value, list):
        return [anonymize(v) for v in value]
    if isinstance(value, str):
        return value if ISO.match(value) else "<str>"
    return value  # números, bool, null


def main():
    try:
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as error:
        print(f"Não foi possível ler o Keychain (status {error.returncode}).")
        return 1

    try:
        oauth = json.loads(raw).get("claudeAiOauth", {})
    except json.JSONDecodeError:
        print("Item do Keychain não é JSON.")
        return 1
    token = oauth.get("accessToken")
    print("credencial: campos =", sorted(oauth.keys()))
    expires = oauth.get("expiresAt")
    if isinstance(expires, (int, float)):
        print(f"token expira em: {round((expires / 1000 - time.time()) / 60)} min")
    if not token:
        print("Sem accessToken.")
        return 1

    request = urllib.request.Request(ENDPOINT, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "Accept": "application/json",
        "User-Agent": "BandejaIA/0.1",
    })
    del token
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            status, body = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, body = error.code, error.read()
    except urllib.error.URLError as error:
        print("Falha de rede:", error.reason)
        return 1

    print("HTTP", status)
    try:
        data = anonymize(json.loads(body))
    except json.JSONDecodeError:
        print("Resposta não é JSON.")
        return 1
    print(json.dumps(data, indent=2, ensure_ascii=False))

    if "--save" in sys.argv and status == 200:
        path = sys.argv[sys.argv.index("--save") + 1]
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        print("fixture salva em", path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
