# Prompt inicial para o Claude Code

Antes: crie um repositório vazio, copie `CLAUDE.md` para a raiz e a pasta inteira deste handoff para `design/`. Depois cole o prompt abaixo.

---

Vamos construir o **Bandeja IA**, um app de barra de menus para macOS em SwiftUI. Leia `CLAUDE.md` (arquitetura e regras) e `design/README.md` (especificação visual). O protótipo de referência é `design/Bandeja IA v2.dc.html` — abra no navegador se precisar ver o comportamento.

Trabalhe em fases. Ao fim de cada fase: compile, rode os testes, faça commit e me mostre um resumo curto antes de seguir.

**Fase 0 — Investigação (não escreva código do app ainda)**
1. Inspecione `~/.claude/projects/` e me mostre a estrutura de uma linha JSONL (sem conteúdo de mensagens).
2. Inspecione `~/.gemini/` e diga quais arquivos permitem contar requisições do Gemini CLI.
3. Verifique se existe o item `Claude Code-credentials` no Keychain (`security find-generic-password -s "Claude Code-credentials"` sem imprimir o segredo) e descubra qual endpoint retorna os limites de 5 h e semanal. Salve uma resposta de exemplo anonimizada em `Tests/Fixtures/claude_usage.json`.
4. Atualize `CLAUDE.md` com o que encontrou.

**Fase 1 — Esqueleto**
Projeto Xcode (ou Swift Package com app target) `BandejaIA`, `LSUIElement`, `MenuBarExtra` estilo janela, GRDB, migrations, modelos, e o popover com a aba **Hoje** usando dados fictícios, fiel ao design.

**Fase 2 — Coleta**
ActivityMonitor (app em foco + URL da aba + ociosidade), gravação de sessões no SQLite, onboarding de permissões. A aba Hoje passa a usar dados reais.

**Fase 3 — Logs locais e projetos**
LogWatcher para Claude Code e Gemini CLI, ProjectResolver, troca manual de projeto.

**Fase 4 — Limites**
ClaudeProvider (Keychain → endpoint, fallback sessionKey, fallback estimado), GeminiProvider (contagem local + cota), card Limites, métrica na barra, notificações 80%/100%.

**Fase 5 — Relatório e Preferências**
Aba Relatório (semana/30 dias, por operador, por projeto) e janela de Preferências.

**Fase 6 — Distribuição**
Script `scripts/build-release.sh` que gera `.app` zipado, README do repositório com instalação manual (incluindo `xattr`), permissões necessárias e aviso de que os limites do Claude usam endpoint não oficial.

Regras: interface em pt-BR; nunca ler ou armazenar conteúdo de conversas; nunca imprimir tokens/segredos no terminal ou em logs.
