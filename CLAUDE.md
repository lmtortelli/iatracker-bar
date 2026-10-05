# Bandeja IA — instruções do projeto

App de barra de menus para macOS que mede tempo de uso de assistentes de IA, atribui a projetos e mostra limites de plano. Operadores v1: **Claude** e **Gemini**. Especificação visual completa em `design/README.md` e protótipo em `design/Bandeja IA v2.dc.html`.

## Stack
- Swift 5.10+, SwiftUI, macOS 13+ (`MenuBarExtra` com `.menuBarExtraStyle(.window)`), `LSUIElement = YES` (sem ícone no Dock).
- Persistência: SQLite via **GRDB** (Swift Package).
- Sem sandbox; distribuição via GitHub Releases (app não notarizado). Documentar no README: `xattr -dr com.apple.quarantine /Applications/BandejaIA.app`.
- Sem dependências além de GRDB. Sem telemetria. Nada de conteúdo de conversa é lido ou salvo — só timestamps, origem, projeto e contadores.
- **Build sem Xcode:** a máquina de desenvolvimento só tem Command Line Tools (Swift 5.10, SDK 14.4, sem XCTest). Por isso o projeto é um **Swift Package** (não `.xcodeproj`), GRDB fixado em `6.29.x` (GRDB 7 exige Swift 6) e o `.app` é montado por `scripts/build-app.sh` com `Resources/Info.plist` + assinatura ad hoc.

## Comandos
```bash
swift build                              # compila tudo
swift run bandeja-tests                  # testes (mini-harness; sai com 1 se falhar)
swift run BandejaIA                      # roda o app (modo demonstração na Fase 1)
swift run BandejaIA --no-demo            # banco real em ~/Library/Application Support/BandejaIA
swift run BandejaIA --snapshot <pasta>   # DEBUG: salva PNGs do popover (claro/escuro) e sai
scripts/build-app.sh [debug|release]     # gera build/BandejaIA.app
```

## Estrutura
```
Package.swift
Sources/
  BandejaIACore/        lógica pura, sem AppKit — tudo que tem teste mora aqui
    Models/             Models.swift (registros GRDB + LimitWindow/ProviderLimits)
    Storage/            Database.swift (AppDatabase), Migrations.swift
    Providers/          GeminiQuota.swift · (Fase 3/4) parsers de log e de limites, UsageProvider
    Projects/           (Fase 3) ProjectResolver.swift
    Report/             ReportAggregator.swift (Hoje, semana, 30 dias, por projeto)
    Support/            Formatters.swift, DemoData.swift
  BandejaIA/            app SwiftUI/AppKit
    App/                BandejaIAApp.swift, AppState.swift, MenuBarLabel.swift
    Collector/          (Fase 2/3) ActivityMonitor, BrowserTabReader, IdleDetector, LogWatcher
    UI/                 Theme, PopoverView, TodayView, ReportView, LimitsCard, SessionRow, PreferencesView
    Support/            Preferences.swift, Keychain.swift, Snapshot.swift (DEBUG)
Tests/
  BandejaIATests/       executável `bandeja-tests` (main.swift + Harness.swift + *Tests.swift)
  Fixtures/             JSON/JSONL de exemplo anonimizados (acesso via Bundle.module)
Resources/Info.plist    LSUIElement, NSAppleEventsUsageDescription
scripts/build-app.sh
```

### Decisões de UI
- Item da barra: a bolinha + mini-barra é um `NSImage` colorido (a barra de menus só aceita imagem + texto).
- Botão `Projeto ▾` abre um `NSMenu` (o `Menu` do SwiftUI ignora o estilo customizado).
- Preferências numa `NSWindow` própria (`PreferencesWindow`): a cena `Settings` abre atrás das janelas em app `LSUIElement`.
- Sem rolagem no popover: a aba Hoje lista as 8 sessões mais recentes.
- Renovação em até 24 h mostra só a hora (`renova 04:00`); depois disso, dia + hora (`renova Qui 09:00`).
- ⌘Q no popover e "Sair do Bandeja IA" em Preferências › Geral (não há menu nem Dock).

## Modelo de dados
- `session(id, provider, source, project_id, cwd, started_at, ended_at, manual_project BOOL)`
- `counter(id, provider, kind, day, value)` — prompts do Gemini web, requisições do Gemini CLI
- `limit_snapshot(id, provider, window, used_pct, reset_at, source, fetched_at)`
- `project(id, name)` · `project_rule(id, project_id, kind[cwd|domain|title], pattern)`

## Interface de operador
```swift
protocol UsageProvider {
  var id: ProviderID { get }                 // .claude, .gemini
  func match(_ activity: Activity) -> Source? // app/aba/processo pertence a este operador?
  func refreshLimits() async throws -> [LimitWindow]
  var logLocations: [URL] { get }             // pastas a observar
  func ingest(logChange: URL) throws          // lê novas linhas e cria sessões/contadores
}
```
Adicionar um operador novo = nova implementação; nenhum outro arquivo deve mudar além do registro.

## Coleta de atividade (ActivityMonitor)
- Tick a cada **5 s** + `NSWorkspace.didActivateApplicationNotification`.
- App em foco por bundle id:
  - `com.anthropic.claudefordesktop` → Claude · `App Claude`
  - Safari / Chrome / Arc / Brave / Edge → ler URL da aba ativa (BrowserTabReader via `NSAppleScript`; requer permissão de Automação por navegador).
    - `claude.ai` → Claude · `claude.ai · <Navegador>`
    - `gemini.google.com`, `aistudio.google.com` → Gemini · `gemini.google.com · <Navegador>`
  - Terminais (Terminal, iTerm2, Warp, Ghostty, VS Code) → não decidir pela janela; usar LogWatcher.
- Ociosidade: `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)` > 120 s encerra a sessão (fim = último evento).
- Trocar de origem encerra a sessão atual e abre outra. Sessões < 30 s são descartadas.

## Logs locais (LogWatcher)
- Observar com FSEvents/`DispatchSource` (sem polling). Guardar offset lido por arquivo.
- **Claude Code:** `~/.claude/projects/**/*.jsonl`. Cada linha tem timestamp, `cwd` e uso de tokens. Agrupar mensagens com intervalo < 2 min na mesma sessão. `cwd` → projeto (raiz git).
- **Gemini CLI:** inspecionar `~/.gemini/` (ex.: `~/.gemini/tmp/*/logs.json`) **antes de implementar** e documentar o formato encontrado. Se insuficiente, habilitar telemetria local do CLI para arquivo (`telemetry.outfile` em `~/.gemini/settings.json`). Contar requisições por dia.

## Limites
### Claude — fonte "OFICIAL" (endpoint não documentado; tratar como frágil)
- Janelas: **sessão de 5 h** (contínua a partir da primeira mensagem) e **semanal**.
- Credencial, nesta ordem:
  1. Token OAuth do Claude Code no Keychain (item de serviço `Claude Code-credentials`, JSON com `claudeAiOauth.accessToken`). Pedir permissão de leitura ao usuário na primeira vez.
  2. `sessionKey` do claude.ai colado em Preferências, salvo no Keychain do próprio app.
- Endpoints a **verificar no início da implementação** (inspecionar o que o `/usage` do Claude Code e a página Settings › Usage do claude.ai chamam):
  - `GET https://api.anthropic.com/api/oauth/usage` com `Authorization: Bearer <token>`
  - `GET https://claude.ai/api/organizations/{orgId}/usage` com cookie `sessionKey`
- Isolar parsing num único arquivo com testes usando JSON de exemplo salvo em `Tests/Fixtures/`.
- Atualização: a cada **3 min**, ao abrir o popover e 10 s após fim de sessão Claude. Backoff exponencial em erro (máx. 30 min). Sempre exibir último snapshot válido + `atualizado há X min` se estiver velho.
- Fallback sem credencial: estimar janela de 5 h por tokens do Claude Code e marcar como `ESTIMADO`.

### Gemini — fonte "ESTIMADO" (sem consulta remota)
- **App web:** v1 estima prompts = sessões × taxa média (configurável) — OU, se `GeminiCounterExtension` estiver ativa, usa contagem exata. Cota diária definida pelo usuário (padrão 100).
- **CLI:** contagem exata dos logs contra 1000 req/dia.
- Reset diário à meia-noite de `America/Los_Angeles`, exibido no fuso local.

## Atribuição de projeto (ProjectResolver)
1. Sessão com `manual_project` → mantém.
2. `cwd` (Claude Code / Gemini CLI) → raiz git → regra `cwd` ou nome da pasta.
3. Título da aba / nome do Project no claude.ai → regras `title`/`domain`.
4. Último projeto usado.

## Permissões
Primeira execução: tela de onboarding pedindo Acessibilidade e Automação (por navegador), com botões que abrem os painéis corretos de Ajustes do Sistema. Preferências › Permissões mostra o status.

## Regras de código
- `@MainActor` para estado de UI; coleta e IO em actors próprios.
- Sem force unwrap fora de testes. Erros de rede nunca derrubam a UI.
- Formatadores: duração `3h 05m` / `41m`; horas `HH:mm`; dias abreviados pt-BR.
- Toda a interface em **português (pt-BR)**.
- Testes para: parser JSONL do Claude Code, parser de limites, ProjectResolver, agregações do relatório.

## Fase 0 — investigação (estado)
Itens que exigem ler dados locais do usuário ou credenciais **não foram executados** pelo agente (bloqueados por política de privacidade). Pendentes, para o usuário rodar ou autorizar:
1. **Formato do JSONL do Claude Code** (`~/.claude/projects/**/*.jsonl`). Formato esperado (conhecimento público, **não verificado nesta máquina**): uma linha JSON por evento com `type` (`user`/`assistant`/`summary`…), `timestamp` (ISO 8601), `cwd`, `sessionId`, `gitBranch`, `version` e, em `assistant`, `message.usage` com `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`. O parser deve ignorar `message.content`.
2. **Logs do Gemini CLI** (`~/.gemini/`). Esperado: `~/.gemini/tmp/<hash-do-projeto>/logs.json` (array de `{sessionId, messageId, type, timestamp, …}`; contar `type == "user"` por dia) e, em versões novas, `chats/session-*.json`. Alternativa: `telemetry.outfile` em `~/.gemini/settings.json`.
3. **Endpoint de limites do Claude.** Candidato: `GET https://api.anthropic.com/api/oauth/usage` com `Authorization: Bearer <accessToken>` e `anthropic-beta: oauth-2025-04-20`. Resposta esperada: `{"five_hour": {"utilization": <0–100>, "resets_at": "<ISO 8601>"}, "seven_day": {…}, "seven_day_opus": {…}|null}`. Salvar resposta real anonimizada em `Tests/Fixtures/claude_usage.json` antes da Fase 4.
