#!/usr/bin/env python3
"""Sonda o endpoint de limites do Claude com o token OAuth do Claude Code.

- Lê o item `Claude Code-credentials` do Keychain (o macOS pode pedir confirmação).
- NUNCA imprime o token nem o grava em disco.
- Imprime só a estrutura da resposta: chaves, números e datas ISO; outras strings viram "<str>".
- Com `--save <arquivo>`, grava essa versão anonimizada como fixture de teste.

Token informado manualmente (ex.: gerado por `claude setup-token`), em vez do Keychain:
  --clipboard     lê da área de transferência (não fica no histórico do shell)
  --ask-token     pede o token com digitação oculta (precisa de um terminal)
  CLAUDE_USAGE_TOKEN=…  variável de ambiente (fica no histórico; evite)

Uso: python3 scripts/probe-claude-usage.py [--clipboard | --ask-token] [--save Tests/Fixtures/claude_usage.json]
"""
import getpass
import os
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


def keychain_services():
    """Serviços `Claude Code-credentials*` (versões novas criam um por pasta de configuração)."""
    dump = subprocess.run(["security", "dump-keychain"], capture_output=True, text=True).stdout
    found = {}
    current = None
    for line in dump.splitlines():
        match = re.search(r'"svce"<blob>="(Claude Code-credentials[^"]*)"', line)
        if match:
            current = match.group(1)
        match = re.search(r'"mdat"<timedate>=\S+\s+"(\d{14})Z', line)
        if match and current:
            found[current] = match.group(1)
            current = None
    return sorted(found.items(), key=lambda item: item[1], reverse=True)


def read_oauth(service):
    try:
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", service, "-w"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        return json.loads(raw).get("claudeAiOauth", {})
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def manual_token():
    """Token informado pelo usuário, se algum dos modos manuais foi pedido."""
    if "--clipboard" in sys.argv:
        # O terminal pode quebrar o token em linhas ao copiar; token não tem espaços.
        value = re.sub(r"\s+", "", subprocess.run(["pbpaste"], capture_output=True, text=True).stdout)
        print("token: lido da área de transferência" + ("" if value else " (vazia!)"))
        return value or None
    if "--ask-token" in sys.argv:
        value = re.sub(r"\s+", "", getpass.getpass("Cole o token (não aparece na tela): "))
        return value or None
    value = os.environ.get("CLAUDE_USAGE_TOKEN", "").strip()
    if value:
        print("token: lido de CLAUDE_USAGE_TOKEN")
    return value or None


def describe(token):
    """Só o formato do token (prefixo e tamanho), nunca o valor."""
    prefix = re.match(r"^[a-z]+-[a-z]+-[a-z0-9]+-", token)
    return f"prefixo {prefix.group(0) if prefix else '(desconhecido)'} · {len(token)} caracteres"


def main():
    token = manual_token()
    if token:
        print("token manual:", describe(token))
        if not token.startswith("sk-ant-oat01-"):
            print("Aviso: não parece um token do `claude setup-token` (esperado prefixo sk-ant-oat01-).")
    for service, modified in ([] if token else keychain_services()):
        oauth = read_oauth(service)
        if oauth is None:
            print(f"{service}: ilegível (modificado {modified})")
            continue
        expires = oauth.get("expiresAt") or 0
        minutes = round((expires / 1000 - time.time()) / 60) if expires else None
        valid = bool(oauth.get("accessToken")) and minutes is not None and minutes > 1
        print(f"{service}: modificado {modified} · token {'válido' if valid else 'ausente/vencido'}"
              + (f" · expira em {minutes} min" if minutes is not None and minutes > 0 else ""))
        if valid and token is None:
            token = oauth["accessToken"]
            print(f"  → usando {service}")
    if not token:
        print("Nenhum token válido. Faça /login no Claude Code (terminal) e rode de novo.")
        return 1

    request = urllib.request.Request(ENDPOINT, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "Accept": "application/json",
        "User-Agent": "IAtrackerBar/0.1",
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
