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
swift run BandejaIA                      # roda o app com coleta real (~/Library/Application Support/BandejaIA)
swift run BandejaIA --demo               # dados fictícios do protótipo, banco em memória
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
    Activity/           ActivityClassifier.swift (foco/URL → operador), SessionTracker.swift (máquina de sessões)
    Limits/             ClaudeLimits.swift (parser + janelas), ClaudeEstimator, GeminiLimits, LimitAlerts
    Logs/               LogParsers.swift (JSONL do Claude Code, logs.json do Gemini CLI), LogIngestors.swift (cursores + LogSessionWriter)
    Providers/          GeminiQuota.swift · (Fase 3/4) parsers de log e de limites, UsageProvider
    Projects/           ProjectResolver.swift (cwd → raiz git, domínio, título, último usado), ProjectAssigner, GitRoot
    Report/             ReportAggregator.swift (Hoje, semana, 30 dias, por projeto)
    Support/            Formatters.swift, DemoData.swift
  BandejaIA/            app SwiftUI/AppKit
    App/                BandejaIAApp.swift, AppState.swift, MenuBarLabel.swift
    Limits/             ClaudeProvider.swift (Keychain/sessionKey + HTTP, protocolo UsageProvider), LimitsService.swift (+ LimitNotifier)
    Collector/          ActivityMonitor, BrowserTabReader, IdleDetector (+ WindowTitleReader), LogWatcher (FSEvents)
    UI/                 Theme, PopoverView, TodayView, ReportView, LimitsCard, SessionRow, PreferencesView, PermissionsView
    Support/            Preferences.swift, Permissions.swift, Keychain.swift, Snapshot.swift (DEBUG)
Tests/
  BandejaIATests/       executável `bandeja-tests` (main.swift + Harness.swift + *Tests.swift)
  Fixtures/             JSON/JSONL de exemplo anonimizados (acesso via Bundle.module)
Resources/Info.plist    LSUIElement, NSAppleEventsUsageDescription
scripts/build-app.sh
```

### Decisões de UI
- Boas-vindas em 5 passos (`OnboardingView`): o que é + privacidade + prévia do item da barra, navegadores, conexão com o Claude (com comandos para copiar e "Verificar agora"), ajustes rápidos, pronto. Reabrível em Preferências › Geral.
- Credencial do Claude: só o login do Claude Code (`/login`). `sessionKey` removido (não validável); token de longa duração (`claude setup-token`) não testado.
- Popover avisa quando a Automação de um navegador foi negada; textos de estado vazio explicam o que é contado.
- Projetos: renomear para um nome existente junta os dois (sessões e regras); excluir deixa as sessões sem projeto.
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
- Voltar à mesma origem em até 60 s **retoma** a sessão anterior (evita picotar ao alternar janelas).
- O tracker altera só `ended_at` (`AppDatabase.setSessionEnd`), para não sobrescrever o projeto escolhido manualmente.
- Repouso, tela bloqueada e saída do app encerram a sessão. Sessões órfãs (app morto) são fechadas no próximo início usando o `lastHeartbeat` gravado a cada tick.
- Ociosidade não exige permissão; Acessibilidade é opcional (só para título da janela do app Claude).
- Assinatura ad hoc muda a cada build: o macOS pode pedir as permissões de Automação de novo após recompilar.

## Logs locais (LogWatcher)
- Observar com FSEvents/`DispatchSource` (sem polling). Guardar offset lido por arquivo.
- **Claude Code:** `~/.claude/projects/**/*.jsonl`. Cada linha tem timestamp, `cwd` e uso de tokens. Agrupar mensagens com intervalo < 2 min na mesma sessão. `cwd` → projeto (raiz git).
- **Gemini CLI:** inspecionar `~/.gemini/` (ex.: `~/.gemini/tmp/*/logs.json`) **antes de implementar** e documentar o formato encontrado. Se insuficiente, habilitar telemetria local do CLI para arquivo (`telemetry.outfile` em `~/.gemini/settings.json`). Contar requisições por dia.

### Implementação (Fase 3)
- Cursor por arquivo na tabela `log_cursor` (migration `v2_log_cursor`): offset em bytes (JSONL) ou nº de entradas (`logs.json`), mais a sessão aberta e o último evento. Arquivo menor que o offset = recomeça do zero.
- `LogSessionWriter`: eventos com intervalo < 2 min formam uma sessão; ela fica com `ended_at = NULL` enquanto pode receber eventos e é fechada no último evento pelo `sweep` (a cada 30 s). Sessões < 30 s são descartadas.
- Primeira leitura importa só os últimos 30 dias. Pausar fecha as sessões de log e, ao retomar, pula o que foi escrito durante a pausa (`fastForward`).
- Claude Code: ignora `isSidechain` (subagentes); tokens = input + output + criação de cache, deduplicados por `message.id`, gravados por hora em `counter(kind = claude_code_tokens, day = yyyy-MM-ddTHH UTC)`. Rótulo pelo `entrypoint`: `cli` → `Claude Code · Terminal`; `*desktop*` → `Claude Code · App Claude`; `*vscode*`, `*jetbrains*`, `*sdk*`.
- Gemini CLI: conta entradas `type == "user"` (prompts, não chamadas de API — limite inferior das requisições) por dia de cota. A pasta `tmp/<hash>` é casada com SHA-256 das pastas já conhecidas (cwds do Claude Code e regras `cwd`).
- Detecção por foco "App Claude" é suprimida enquanto há sessão aberta `Claude Code · App Claude` (mesmo uso, contaria em dobro). Outras sobreposições (ex.: claude.ai no navegador com Claude Code trabalhando em segundo plano) contam as duas sessões.

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

### Implementação (Fase 4)
- `ClaudeLimits.parse` aceita as janelas `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` (nulas são ignoradas; exige 5 h ou semanal). Renovação vencida zera o uso até a próxima consulta.
- Itens do Keychain: versões novas do Claude Code criam `Claude Code-credentials-<hash>` (um por pasta de configuração) além do item sem sufixo. O app lista os atributos (sem pedido de permissão), lê só os modificados nas últimas 24 h, do mais recente ao mais antigo, e usa o primeiro com token válido.
- `ClaudeProvider`: ordem das credenciais conforme Preferências (padrão: token do Claude Code, depois `sessionKey`). Token em memória até expirar; sem token válido, relê o Keychain no máximo a cada 30 min; se o usuário negar o pedido, não pergunta de novo na execução. Nunca renova o token (isso rotacionaria o refresh token do Claude Code).
- `LimitsService`: consulta a cada 3 min, ao abrir o popover (mínimo 30 s entre consultas) e 10 s após o fim de uma sessão do Claude; erro → backoff 60 s, 120 s… até 30 min. Snapshots oficiais ficam na tabela por 7 dias e valem para exibição por até 6 h; depois disso, ou sem credencial, a janela de 5 h é **estimada** pelos tokens do Claude Code das últimas 5 horas (`ClaudeEstimator`).
- Orçamento da estimativa: padrão 4 mi tokens/5 h (arbitrário) até ser **calibrado** por uma leitura oficial com uso ≥ 5% (tokens locais ÷ uso). Estimativa sem calibração não gera notificação.
- Gemini app: prompts = sessões web no dia de cota × taxa (Preferências, padrão 4) + contador exato `web_prompts` (reservado para uma futura extensão). CLI: contador `cli_requests` ÷ 1000.
- Notificações (`LimitAlerts`): uma por janela, faixa (80/100) e período de renovação; pular de <80 para 100 avisa só 100. Exigem rodar como `.app` (UNUserNotificationCenter precisa de bundle).
- Assinatura ad hoc: o macOS pede de novo a permissão do Keychain a cada build.

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
Inspeção feita com `scripts/inspect-local-logs.py`, que imprime só nomes de campos, tipos e contagens, nunca valores. Liberado em `~/.claude/settings.json` com a regra `Bash(python3 …/scripts/inspect-local-logs.py*)`.

### Claude Code — verificado em 05/10/2026
- Caminho: `~/.claude/projects/<cwd-com-hifens>/<sessionId>.jsonl`, uma linha JSON por evento.
- Campos comuns em `user`/`assistant`: `type`, `timestamp` (ISO 8601), `sessionId` (uuid), `cwd` (caminho absoluto), `gitBranch`, `version`, `entrypoint`, `isSidechain`, `uuid`, `parentUuid`; subagentes trazem `agentId`.
- `assistant`: `message.model`, `message.id`, `requestId` e `message.usage` com `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` (+ `cache_creation.ephemeral_5m/1h_input_tokens`, `service_tier`, `speed`).
- Outros `type` presentes e **ignoráveis** pelo parser: `queue-operation`, `attachment`, `last-prompt`, `custom-title`, `ai-title`, `agent-name`, `file-history-snapshot`, `file-history-delta`, `atis-latch`, `system`.
- Regras do parser: ler só `type`, `timestamp`, `cwd`, `sessionId`, `isSidechain`/`agentId`, `message.model`, `message.id`/`requestId` e `message.usage`; **nunca** `message.content`. A mesma resposta pode ocupar várias linhas com o mesmo `message.id`: deduplicar antes de somar tokens. `cwd` → raiz git → projeto.

### Gemini CLI — não verificável nesta máquina
`~/.gemini/` não tem `tmp/`, `settings.json` nem logs do CLI (só `GEMINI.md`; existe `antigravity-backup/`, que é de outro app e deve ser ignorado). Implementar o leitor de forma tolerante, para o formato esperado: `~/.gemini/tmp/<hash>/logs.json` (array de `{sessionId, messageId, type, timestamp, …}`, contar `type == "user"` por dia de cota) e `~/.gemini/tmp/<hash>/chats/session-*.json`. Alternativa: `telemetry.outfile` em `~/.gemini/settings.json`. Revalidar com o script depois de usar o Gemini CLI.

### Limites do Claude — verificado em 05/10/2026
- `GET https://api.anthropic.com/api/oauth/usage` com `Authorization: Bearer <accessToken>` + `anthropic-beta: oauth-2025-04-20` → HTTP 200. Resposta anonimizada em `Tests/Fixtures/claude_usage.json` (gerada por `scripts/probe-claude-usage.py --save …`, que não imprime o token).
- `five_hour` e `seven_day`: `{utilization: 0–100, resets_at: ISO 8601 com microssegundos, limit_dollars, used_dollars, remaining_dollars, locked_reason}`. Janelas por modelo (`seven_day_opus`, `seven_day_sonnet`, …) e várias chaves internas vêm `null`. Há também `limits[]` (percent, severity, is_active), `extra_usage`, `spend` e `seven_day_breakdown` — não usados.
- O token só existe depois de `/login` no Claude Code do terminal; o app desktop não deixa token utilizável no Keychain. Itens `Claude Code-credentials-<hash>` antigos ficam com token vazio.
- Não testado: token de longa duração (`claude setup-token`) e `sessionKey` do claude.ai.

### Implementação (Fase 4)
- `ClaudeLimits.parse` aceita as janelas `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` (nulas são ignoradas; exige 5 h ou semanal). Renovação vencida zera o uso até a próxima consulta.
- Itens do Keychain: versões novas do Claude Code criam `Claude Code-credentials-<hash>` (um por pasta de configuração) além do item sem sufixo. O app lista os atributos (sem pedido de permissão), lê só os modificados nas últimas 24 h, do mais recente ao mais antigo, e usa o primeiro com token válido.
- `ClaudeProvider`: ordem das credenciais conforme Preferências (padrão: token do Claude Code, depois `sessionKey`). Token em memória até expirar; sem token válido, relê o Keychain no máximo a cada 30 min; se o usuário negar o pedido, não pergunta de novo na execução. Nunca renova o token (isso rotacionaria o refresh token do Claude Code).
- `LimitsService`: consulta a cada 3 min, ao abrir o popover (mínimo 30 s entre consultas) e 10 s após o fim de uma sessão do Claude; erro → backoff 60 s, 120 s… até 30 min. Snapshots oficiais ficam na tabela por 7 dias e valem para exibição por até 6 h; depois disso, ou sem credencial, a janela de 5 h é **estimada** pelos tokens do Claude Code das últimas 5 horas (`ClaudeEstimator`).
- Orçamento da estimativa: padrão 4 mi tokens/5 h (arbitrário) até ser **calibrado** por uma leitura oficial com uso ≥ 5% (tokens locais ÷ uso). Estimativa sem calibração não gera notificação.
- Gemini app: prompts = sessões web no dia de cota × taxa (Preferências, padrão 4) + contador exato `web_prompts` (reservado para uma futura extensão). CLI: contador `cli_requests` ÷ 1000.
- Notificações (`LimitAlerts`): uma por janela, faixa (80/100) e período de renovação; pular de <80 para 100 avisa só 100. Exigem rodar como `.app` (UNUserNotificationCenter precisa de bundle).
- Assinatura ad hoc: o macOS pede de novo a permissão do Keychain a cada build.

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
Inspeção feita com `scripts/inspect-local-logs.py`, que imprime só nomes de campos, tipos e contagens, nunca valores. Liberado em `~/.claude/settings.json` com a regra `Bash(python3 …/scripts/inspect-local-logs.py*)`.

### Claude Code — verificado em 05/10/2026
- Caminho: `~/.claude/projects/<cwd-com-hifens>/<sessionId>.jsonl`, uma linha JSON por evento.
- Campos comuns em `user`/`assistant`: `type`, `timestamp` (ISO 8601), `sessionId` (uuid), `cwd` (caminho absoluto), `gitBranch`, `version`, `entrypoint`, `isSidechain`, `uuid`, `parentUuid`; subagentes trazem `agentId`.
- `assistant`: `message.model`, `message.id`, `requestId` e `message.usage` com `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` (+ `cache_creation.ephemeral_5m/1h_input_tokens`, `service_tier`, `speed`).
- Outros `type` presentes e **ignoráveis** pelo parser: `queue-operation`, `attachment`, `last-prompt`, `custom-title`, `ai-title`, `agent-name`, `file-history-snapshot`, `file-history-delta`, `atis-latch`, `system`.
- Regras do parser: ler só `type`, `timestamp`, `cwd`, `sessionId`, `isSidechain`/`agentId`, `message.model`, `message.id`/`requestId` e `message.usage`; **nunca** `message.content`. A mesma resposta pode ocupar várias linhas com o mesmo `message.id`: deduplicar antes de somar tokens. `cwd` → raiz git → projeto.

### Gemini CLI — não verificável nesta máquina
`~/.gemini/` não tem `tmp/`, `settings.json` nem logs do CLI (só `GEMINI.md`; existe `antigravity-backup/`, que é de outro app e deve ser ignorado). Implementar o leitor de forma tolerante, para o formato esperado: `~/.gemini/tmp/<hash>/logs.json` (array de `{sessionId, messageId, type, timestamp, …}`, contar `type == "user"` por dia de cota) e `~/.gemini/tmp/<hash>/chats/session-*.json`. Alternativa: `telemetry.outfile` em `~/.gemini/settings.json`. Revalidar com o script depois de usar o Gemini CLI.

### Limites do Claude — não verificável nesta máquina (05/10/2026)
`scripts/probe-claude-usage.py` (não imprime o token) mostrou que o item `Claude Code-credentials` existe com os campos `accessToken`, `expiresAt`, `refreshToken`, `refreshTokenExpiresAt`, `scopes`, `subscriptionType`, `rateLimitTier`, mas com `accessToken` vazio e `expiresAt` = 0 (Claude Code usado só pelo app desktop, sem `claude /login` no terminal). Quando houver token válido, rodar `python3 scripts/probe-claude-usage.py --save Tests/Fixtures/claude_usage.json` e trocar a fixture sintética (`claude_usage.synthetic.json`) pela real. Candidato: `GET https://api.anthropic.com/api/oauth/usage` com `Authorization: Bearer <accessToken>` e `anthropic-beta: oauth-2025-04-20`; resposta esperada `{"five_hour": {"utilization": 0–100, "resets_at": ISO 8601}, "seven_day": {…}, "seven_day_opus": {…}|null}`. Salvar resposta real anonimizada em `Tests/Fixtures/claude_usage.json` antes da Fase 4.
