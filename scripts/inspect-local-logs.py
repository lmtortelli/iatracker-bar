#!/usr/bin/env python3
"""Inspeciona a ESTRUTURA dos logs locais do Claude Code e do Gemini CLI.

Imprime apenas nomes de campos, tipos e contagens — nunca valores.
Campos de conteúdo de conversa são descartados antes de qualquer análise.

Uso: python3 scripts/inspect-local-logs.py [claude|gemini|all]
"""
import glob
import json
import os
import re
import sys
from collections import Counter

HOME = os.path.expanduser("~")
# Campos que carregam conteúdo de conversa, código ou resultados de ferramentas: nunca descer neles.
CONTENT_KEYS = {
    "content", "text", "message_text", "prompt", "toolUseResult", "summary", "snapshot",
    "parts", "thinking", "input", "output", "result", "stdout", "stderr", "messages",
    "history", "displayContent", "promptText",
}
MAX_KEYS = 40
MAX_DEPTH = 4
ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}")


def kind(value):
    """Tipo do valor, com dica de formato para strings (sem revelar o valor)."""
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    if value is None:
        return "null"
    if isinstance(value, str):
        if ISO_RE.match(value):
            return "str<iso8601>"
        if re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", value):
            return "str<uuid>"
        if value.startswith("/"):
            return "str<path>"
        return "str"
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "dict"
    return type(value).__name__


def shape(value, depth=0, parent_key=None):
    if parent_key in CONTENT_KEYS:
        return f"<{kind(value)} omitido: conteúdo>"
    if isinstance(value, dict):
        if depth >= MAX_DEPTH:
            return "{…}"
        keys = list(value.keys())
        out = {k: shape(value[k], depth + 1, k) for k in keys[:MAX_KEYS]}
        if len(keys) > MAX_KEYS:
            out["…"] = f"+{len(keys) - MAX_KEYS} chaves"
        return out
    if isinstance(value, list):
        if not value:
            return []
        return [shape(value[0], depth + 1, parent_key), f"len≈{len(value)}"]
    return kind(value)


def merge_keys(acc, obj, prefix=""):
    """Conta em quantos registros cada caminho de chave aparece (sem descer em conteúdo)."""
    if not isinstance(obj, dict):
        return
    for k, v in obj.items():
        path = f"{prefix}.{k}" if prefix else k
        acc[path] += 1
        if k not in CONTENT_KEYS and isinstance(v, dict) and path.count(".") < MAX_DEPTH:
            merge_keys(acc, v, path)


def inspect_claude():
    root = os.path.join(HOME, ".claude", "projects")
    files = sorted(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True), key=os.path.getmtime, reverse=True)
    print(f"== Claude Code: {root}")
    print(f"arquivos .jsonl: {len(files)} · pastas de projeto: {len(set(os.path.dirname(f) for f in files))}")
    print("padrão de caminho:", "~/.claude/projects/<cwd-com-hifens>/<sessionId>.jsonl" if files else "(nenhum)")
    if not files:
        return

    by_type = {}
    key_counts = {}
    totals = Counter()
    bad = 0
    for path in files[:20]:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    bad += 1
                    continue
                t = str(obj.get("type"))
                totals[t] += 1
                by_type.setdefault(t, obj)
                merge_keys(key_counts.setdefault(t, Counter()), obj)

    print(f"linhas analisadas (20 arquivos mais recentes): {sum(totals.values())} · inválidas: {bad}")
    print("linhas por type:", dict(totals))
    for t, sample in by_type.items():
        print(f"\n-- type={t}: estrutura de um exemplo")
        print(json.dumps(shape(sample), indent=1, ensure_ascii=False))
        print(f"-- type={t}: frequência das chaves")
        n = totals[t]
        for path, c in sorted(key_counts[t].items()):
            print(f"   {path}: {c}/{n}")


def inspect_gemini():
    root = os.path.join(HOME, ".gemini")
    print(f"\n== Gemini CLI: {root}")
    if not os.path.isdir(root):
        print("(pasta não existe)")
        return

    # Árvore só das pastas do Gemini CLI. Nomes fora da lista conhecida viram `<arquivo>.ext`
    # e pastas viram `<pasta>`, para não expor nomes de arquivos do usuário.
    known_files = re.compile(
        r"^(logs\.json|settings\.json|GEMINI\.md|installation_id|user_id|google_accounts\.json|"
        r"oauth_creds\.json|shell_history|session-.*\.json|checkpoint.*\.json|telemetry.*\.log)$"
    )
    known_dirs = {".", "tmp", "chats", "history", "extensions", "commands"}
    patterns = Counter()
    for dirpath, dirnames, filenames in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        if rel == ".":
            dirnames[:] = [d for d in dirnames if d in known_dirs]
        parts = []
        for part in rel.split(os.sep):
            if part in known_dirs:
                parts.append(part)
            elif re.fullmatch(r"[0-9a-f]{16,}", part):
                parts.append("<hash>")
            else:
                parts.append("<pasta>")
        rel = os.path.join(*parts)
        for name in filenames:
            if known_files.match(name):
                generic = re.sub(r"[0-9a-f]{8,}|\d{4}-\d{2}-\d{2}T[\d\-:.]+Z?", "<id>", name)
            else:
                generic = "<arquivo>" + os.path.splitext(name)[1]
            patterns[os.path.join(rel, generic)] += 1
    print("arquivos (padrão: quantidade):")
    for p, c in sorted(patterns.items()):
        print(f"   {p}: {c}")

    candidates = (
        glob.glob(os.path.join(root, "tmp", "*", "logs.json"))
        + glob.glob(os.path.join(root, "tmp", "*", "chats", "*.json"))
        + glob.glob(os.path.join(root, "settings.json"))
        + glob.glob(os.path.join(root, "telemetry*.log"))
    )
    seen = set()
    for path in sorted(candidates, key=os.path.getmtime, reverse=True):
        label = re.sub(r"[0-9a-f]{16,}", "<hash>", os.path.relpath(path, root))
        label = re.sub(r"[0-9a-f]{8,}|\d{4}-\d{2}-\d{2}T[\d\-:.]+Z?", "<id>", label)
        if label in seen:
            continue
        seen.add(label)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                data = json.load(fh)
        except (json.JSONDecodeError, OSError):
            print(f"\n-- {label}: não é JSON único")
            continue
        print(f"\n-- {label}: estrutura")
        print(json.dumps(shape(data), indent=1, ensure_ascii=False))
        if isinstance(data, list) and data and isinstance(data[0], dict):
            types = Counter(str(e.get("type")) for e in data if isinstance(e, dict))
            print("   entradas por type:", dict(types))


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "all"
    if target in ("claude", "all"):
        inspect_claude()
    if target in ("gemini", "all"):
        inspect_gemini()
