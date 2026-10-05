# Handoff: Bandeja IA — rastreador de uso de IA na barra de menus (macOS)

## Overview
App nativo de barra de menus para macOS que registra **quanto tempo** o usuário usa assistentes de IA, **em qual projeto**, e **quanto resta dos limites** de cada plano. Primeira versão: **Claude** e **Gemini**. Uso pessoal, distribuído via GitHub (fora da App Store, sem sandbox).

## About the Design Files
`Bandeja IA v2.dc.html` é uma **referência de design em HTML** — protótipo que mostra aparência e comportamento, não código de produção. Abra no navegador (precisa de `support.js` ao lado). A tarefa é **recriar em SwiftUI** seguindo padrões nativos do macOS. Dados no protótipo são fictícios.

## Fidelity
**Alta fidelidade** para layout, hierarquia, textos e cores semânticas. Use materiais e fontes do sistema (SF Pro, `.popover` material) em vez de imitar os valores RGBA do HTML; mantenha tamanhos e espaçamentos.

---

## Screens / Views

### 1. Item da barra de menus (`MenuBarExtra` label)
- Pílula: bolinha de status 8×8 (verde ativo `#3FB56A` / cinza pausado `#8E9096`) + mini‑barra 22×5 (raio 3) preenchida com a cor do limite + texto mono 12/500 `"Claude 5h 63%"`.
- Nunca quebra linha. Métrica configurável: `Claude 5h` (padrão), `Claude sem.`, `Gemini`.

### 2. Popover (largura 360, raio 12, sombra `0 12 40 rgba(0,0,0,.22)`)
**Topo:** segmented control `Hoje | Relatório` (padding 10/12/8, controle raio 7, segmento ativo branco com sombra `0 1 2 rgba(0,0,0,.15)`, texto 12/500).

**Rodapé (sempre):** borda superior 1px `rgba(0,0,0,.08)`, padding 8/12, texto 12. Esquerda: `❙❙ Pausar detecção` / `▶ Retomar detecção`. Direita: `Preferências…` (secundário).

#### 2a. Aba Hoje (padding 4/12/12, gap 12)
1. **Card "Detectando agora"** (fundo branco, raio 9, borda `rgba(0,0,0,.06)`, padding 10, gap 8)
   - Linha label 11px maiúsculas, tracking .05em, cinza, com bolinha verde 6×6.
   - Ícone 30×30 raio 8 na cor do operador com inicial branca 14/600 · nome 14/600 · origem 12 cinza (ex. `Claude Code · Terminal`) · cronômetro mono 17/500 `HH:MM:SS` à direita.
   - Botão `Projeto: **Site Lumen** ▾` (borda `rgba(0,0,0,.1)`, raio 6, padding 3/8, 12px, nowrap) + texto mono 10 cinza `auto · ~/dev/site-lumen` ou `manual` (trunca com reticências).
   - Pausado: card tracejado `Detecção pausada. Nenhum uso está sendo registrado.`
2. **Card "Limites"** (mesmo estilo do card acima, gap 10). Título 12/600 cinza.
   Para cada operador (separador 1px no topo):
   - Quadradinho 8×8 raio 2 na cor · nome 13/600 · selo mono 10/500 raio 4: `OFICIAL` (fundo `#E3F4E8`, texto `#2F6E44`) para Claude, `ESTIMADO` (fundo `rgba(0,0,0,.06)`, texto cinza) para Gemini.
   - Linhas de janela em grid `116px | 1fr | 40px`, gap 10:
     - col 1: rótulo 12 + detalhe mono 10 cinza
     - col 2: barra 5px raio 3 (trilho `rgba(0,0,0,.08)`) + `↻ renova 16:05` mono 10
     - col 3: % mono 12/600 alinhado à direita (colorido se ≥80%)
   - Claude: `Sessão 5 h` (detalhe `desde 11:05`, `renova 16:05`), `Semanal` (`todos os modelos`, `renova Qui 09:00`).
   - Gemini: `App · diária` (`38 de 100 prompts`), `CLI · diária` (`212 de 1000 req.`), ambas `renova 04:00` (meia-noite Pacífico convertida para o fuso local).
   - ≥100% → texto do reset vira `limite atingido`.
3. **Total do dia**: `Hoje` 12/600 cinza ↔ `3h 15m` mono 13/600. Barra empilhada 6px (gap 2) proporcional por operador. Legenda 11px com quadradinho + nome + tempo mono.
4. **Lista de sessões** (mais recente primeiro; separador 1px; padding 7/0): ícone 22×22 raio 6 · origem 13/500 · `Projeto · 11:05–11:46` 11 cinza · duração mono 12/500. Sessão ativa mostra `14:20 – agora`.

#### 2b. Aba Relatório (padding 4/12/12, gap 14)
1. Toggle `Semana | 30 dias` (botões 12px raio 5; ativo fundo `#2E3036` texto branco) ↔ total do período mono 13/600.
2. Gráfico de barras 120px de altura, barras empilhadas por operador (raio 3), rótulo 10px (`Seg…Dom` ou dia 1,6,11…). Gap 8 (semana) / 2 (30 dias). Dias futuros: barra 2% cinza.
3. Tabela "Por operador" grid `1fr 64px 64px`: nome com quadradinho · sessões · tempo.
4. "Por projeto": nome ↔ tempo mono; barra 5px empilhada por operador com largura relativa ao maior projeto.

### 3. Preferências (não desenhada — seguir padrão `Settings` do macOS)
Abas sugeridas: **Geral** (métrica da barra, iniciar com o sistema, tempo de ociosidade = 2 min), **Operadores** (Claude: origem da credencial / colar `sessionKey`; Gemini: cota diária de prompts, padrão 100), **Projetos** (regras pasta→projeto, domínio/título→projeto), **Permissões** (status de Acessibilidade e Automação com botão para abrir Ajustes).

---

## Interactions & Behavior
- Cronômetro da sessão ativa atualiza a cada 1s.
- `Projeto ▾` abre menu com projetos; escolha manual sobrescreve o automático para a sessão atual (mostrar `manual`).
- Pausar: para coletor; card vira estado pausado; bolinha da barra fica cinza.
- Cores de limite: `<80%` verde `#4A9D63`, `80–99%` âmbar `#D69A2B`, `≥100%` vermelho `#D9483E`.
- Notificações locais ao cruzar 80% e 100% de qualquer janela (uma vez por janela).
- Indicar dado velho: se a última consulta de limite do Claude falhou, mostrar `atualizado há X min` no detalhe.

## State Management
- `ActivityState`: sessão ativa (operador, origem, início, projeto, projeto manual?), pausado.
- `TodayStore`: sessões do dia (do SQLite), totais por operador.
- `LimitsStore`: por operador, lista de janelas `{rótulo, usado%, detalhe, resetAt, fonte: oficial|estimado, atualizadoEm}`.
- `ReportStore`: agregados por dia/operador/projeto para 7 e 30 dias.

## Design Tokens
| Token | Valor (oklch do protótipo) | Hex aprox. |
|---|---|---|
| Claude | oklch(0.66 0.13 45) | `#CC7A50` |
| Gemini | oklch(0.60 0.15 300) | `#9168C9` |
| OK | oklch(0.62 0.13 150) | `#4A9D63` |
| Alerta | oklch(0.74 0.15 70) | `#D69A2B` |
| Erro | oklch(0.60 0.19 25) | `#D9483E` |
| Texto | oklch(0.22 0.01 260) | `#1E2026` |
| Texto secundário | oklch(0.50 0.01 260) | `#6B6E75` |
| Fundo popover | rgba(247,247,249,.94) | usar material `.popover` |

Tipografia: SF Pro (sistema) 11–14; números em **JetBrains Mono** (ou `.monospacedDigit()` / SF Mono) 10–17. Raios: 2, 3, 5, 6, 7, 8, 9, 12. Espaçamento base 2/4/6/8/10/12/14.

## Assets
Nenhum. Ícones de operador são quadrados coloridos com inicial. Não usar logos oficiais.

## Files
- `Bandeja IA v2.dc.html` — protótipo interativo (referência visual e de comportamento)
- `support.js` — runtime para abrir o protótipo
- `CLAUDE.md` — arquitetura e regras técnicas (copiar para a raiz do repositório)
- `PROMPT.md` — prompt inicial para colar no Claude Code
