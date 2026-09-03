# RELATÓRIO — Modo Monitoramento + Memória Histórica Nacional

Branch: `claude/landing-login-admin` · Data: 03/09/2026
Regra seguida à risca: **nenhum dado fictício**; todos os números abaixo saíram de consultas reais ao banco durante a execução.

---

## PARTE A — MODO MONITORAMENTO (entregue e testado)

### Código criado

| Item | Onde |
|---|---|
| Migração do motor | `supabase/migrations/20260903T060000_monitoramento_engine.sql` (aplicada) |
| Tabelas | `saas_monitores`, `saas_monitor_regras` (estruturadas §20), `saas_monitor_matches` (novidade ≠ match §31), `saas_monitor_eventos` (17 tipos + BASELINE_READY, importância baixa/média/alta/crítica §30/§34), `saas_monitor_baseline` (§37), `saas_monitor_config_hist` (§94) |
| Funções | `saas_monitor_criar` (limite por plano + análise histórica imediata §21/§96), `saas_monitor_avaliar` (matching + diff §32 + alertas legíveis §33), `saas_monitor_baseline_calc`, `saas_monitor_painel` (tela completa em 1 chamada §22), `saas_meus_monitores`, `saas_monitor_atualizar` (preserva config §94), `saas_monitor_duplicar` (§95), `saas_monitor_sugerir_expansoes` (expansões visíveis a partir de itens reais §6), `saas_monitor_tick`, `saas_admin_monitor_stats` (§97) |
| Cron | `saas_monitores_tick` — `*/10 * * * *` (reavaliação ~10 min §23; ingestão das fontes mantém frequência própria §24-25) |
| UI | `apps/portal/monitores.html` (central + wizard + cards §91-92) e `apps/portal/monitor.html` (AGORA/MERCADO/PREÇO/CONCORRENTES/ÓRGÃOS/MAPA/HISTÓRICO/FUTURO/TIMELINE, auto-refresh 60s sem F5 §27, banner "o que mudou" §28, "atualizado há X min · próxima em ~Y min" §26) |
| Limites por plano | entitlements `max_monitores`: Explorar 1 · Profissional 10 · Inteligência 50 · Business ilimitado/fair use — editáveis no admin (§96) |

### TESTES 1–6 (§105) — executados com dados reais

| Teste | Resultado real |
|---|---|
| 1. Criar "Medicamentos MG" | Monitor id=1 criado (usuário interno de teste, provisionado pelo trigger real de cadastro) |
| 2. Primeira análise histórica | Executada na criação, 110 ms. MG tem **0** processos de medicamentos na cobertura atual — o sistema mostrou ausência, não inventou histórico (§108). O monitor nacional (id=2) teve baseline real: **18 processos**, R$ 101,3 mi, mediana R$ 98.992, UFs SP 7/BA 2/CE 2…, série 2026-06: 8 · 2026-09: 10 |
| 3. Reexecução sem mudanças | `novos_matches: 0, eventos: 0` em 55 ms — **zero alertas duplicados** |
| 4. Novidade encontrada | Registro real removido do radar e reencontrado → evento `NEW_PROCUREMENT` ("🚨 Nova oportunidade de R$ 1 encontrada em PE"); coleta delta real também disparada |
| 5. Alteração → diff | Valor de licitação real alterado +10% e restaurado → 2 eventos `PRICE_CHANGE` com antes/depois e variação (+10,0% / −9,1%) (§32) |
| 6. Tudo no escopo do monitor | Painel do monitor 2: 7 abertas (R$ 37,2 mi em disputa), 56 matches, mapa por UF, série mensal, 20 contratos vencendo, 9 atas, timeline com 4 eventos — nada global (§43) |

Extra: limite de plano validado de verdade — 2º monitor no plano Explorar foi **bloqueado** com `LIMITE_PLANO` (o front converte em modal de upgrade, não em "403").

Monitores testados: **2** (1 usuário de teste interno, assinatura `teste_interno`).

### Honestidades registradas

- Concorrentes do monitor 2 = 0 porque os 18 processos de medicamentos ainda não têm resultados homologados coletados (a fila de detalhes continua rodando). O painel escreve exatamente isso, com terminologia "padrão público observado" (§41).
- Matching textual é ILIKE + expansões aprovadas pelo usuário; sem embeddings nesta fase (candidato à evolução).

---

## PARTE B — MEMÓRIA HISTÓRICA NACIONAL (motor rodando; crescimento contínuo)

### Código criado

| Item | Onde |
|---|---|
| Migração | `supabase/migrations/20260903T070000_memoria_historica.sql` (aplicada) |
| Fila particionada | `bolsa.backfill_jobs` — fonte → dataset → ano → mês, status QUEUED/RUNNING/PAUSED/COMPLETED/FAILED/PARTIAL (§57-58), cursor jsonb de retomada exata (§59), contadores reais |
| Importador | Edge Function `coleta-pncp-backfill` v3 — reivindica partição atômica (`backfill_reivindicar`, PARTIAL antes de QUEUED), coleta o mês por modalidade/página, RAW imutável com hash (§61-62), upsert idempotente (dedup por `numero_controle_pncp` §63), falha real **não pula páginas**: salva posição e retoma |
| Cron | `bolsa_backfill_tick` — `*/10 * * * *`, uma leva por vez (backfill controlado §55/§102); `bolsa_agregados_refresh` de hora em hora |
| Cobertura | `bolsa_vw_memoria` — % por ano com metodologia declarada (meses com ≥1 registro / meses do ano — dado CALCULADO §109), primeiro/último registro, licitações/itens/resultados/contratos (§64-65) |
| Memória de preços | `bolsa_vw_precos_historicos` (§68) — fases estimado/homologado, com **unidade da fonte** na linha (nunca misturar unidades §69), classificação DADO CONFIRMADO |
| Agregações | matviews `bolsa.mv_mercado_mensal` e `bolsa.mv_fornecedor_mensal` + refresh (§81-82) |
| Admin | Seções **Monitoramento** (§97) e **Memória histórica** (§98) em `apps/portal/admin/index.html` via `saas_admin_monitor_stats()` / `saas_admin_memoria()` — barras de cobertura por ano + fila com progresso |

### Fila criada (períodos reais na fila agora)

- **PNCP · contratações**: 69 partições mensais — 2026-09 → 2021-01 (prioridade: recente primeiro §103; o PNCP nasceu com a Lei 14.133/2021 — meses sem dados ficarão COMPLETED com 0, que é evidência de cobertura da fonte, não enfeite §47)
- **PNCP · contratos**: 21 partições mensais (2026, 2025)
- **PAUSED com motivo declarado** (nada invisível): Compras.gov CSV anuais 2024/2025 (importação em lote a validar §48-50), Transparência downloads (AGUARDANDO_CHAVE — depende da chave que você vai cadastrar), Contratos.gov histórico (validar parâmetros de período no OpenAPI)

### Execuções reais desta sessão

- 1ª rodada (v2): **setembro/2026 → 350 licitações inseridas, 0 erros de escrita**, `expected_records` da fonte = **3.138** para o mês. A base saiu de 596 para **946 licitações** durante esta sessão (set/2026: 846 gravadas). Aqui apareceram dois defeitos, corrigidos na hora:
  1. `tamanhoPagina=100` era rejeitado pela API (limite real: 50) e o v1 tratava a rejeição como "mês vazio" → dois meses foram marcados COMPLETED com 0. **Resetados e reprocessados** — o motor não pode fingir mês completo.
  2. Falha 5xx no meio do mês avançava de modalidade perdendo páginas → v3 agora **salva a posição exata e marca PARTIAL** (§59).
- Rodadas seguintes: o PNCP entrou em janela de instabilidade (timeouts — o coletor delta registrou o mesmo). Os jobs de ago/set-2026 estão **PARTIAL com cursor salvo**; o cron `*/10` retoma automaticamente e a fonte se auto-reporta `TEMPORARILY_UNAVAILABLE` até a próxima resposta boa. Comportamento honesto por design.

### O que a Memória é hoje — e o que ainda não é

A memória **não está pronta**; está **crescendo**. Hoje ela contém, consultável em `bolsa_vw_memoria`:
2026 com cobertura real de junho a setembro (596+ licitações, 1.462 itens, resultados homologados, 150 atas, contratos, PCA), e a fila configurada para retroceder mês a mês até 2021 no ritmo do cron (~6 rodadas/hora). Anos 2021-2025 aparecem no painel com 0% — verdade atual, que o backfill vai preenchendo.

### Próximos períodos a importar (ordem da fila)

set/2026 (retomada) → ago/2026 (retomada) → jul → … → jan/2026 → dez/2025 → … → 2021; em paralelo (prioridade menor), contratos PNCP 2026→2025. Compras.gov/Transparência/Contratos.gov destravam nas condições descritas acima.

### Limitações conhecidas

- Volume por rodada limitado pelo orçamento de 45 s da Edge Function (~350-450 registros/rodada com upserts unitários); se quisermos acelerar: lotes `unnest`/COPY (§60) — planejado, não implementado.
- Detalhes históricos (itens/resultados/documentos) entram pela fila de detalhes já existente, mais lenta que a listagem (§100-101: contratação primeiro, documentos em fila separada).
- Sazonalidade/recorrência de órgão (§74-75) precisam de ≥2 anos gravados — ficam honestamente vazias até lá.
