# Relatório de Coleta — Conector PNCP (Etapa 1)

Entregável de fonte conforme a especificação (§95): evidências, não apenas "integração
concluída". Gerado em **03/09/2026 ~01:35 UTC**, com dados verificáveis por SQL nas views
`public.bolsa_vw_*` do projeto Supabase `rxcfbbzosbfiwyloqtdk` (sa-east-1).

## Onde a coleta roda

O sandbox do Claude Code **bloqueia egress para pncp.gov.br** (403 do proxy de política —
verificado e reportado; nenhuma tentativa de contorno). A coleta real roda, portanto, na
**Edge Function `coleta-pncp`** (Supabase, região sa-east-1 — IP brasileiro, internet aberta),
agendada por `pg_cron`, gravando via conexão direta ao Postgres. O código está versionado em
`supabase/functions/coleta-pncp/index.ts` e o espelho de referência em `engine/`.

## Áreas públicas do PNCP acessadas

| Endpoint | Uso |
|---|---|
| `/api/consulta/v1/contratacoes/publicacao` | listagem por data de publicação + modalidade (paginada) |
| `/api/pncp/v1/orgaos/{cnpj}/compras/{ano}/{seq}/itens` | itens da contratação |
| `/api/pncp/v1/.../itens/{n}/resultados` | resultado por item (fornecedor, valores homologados) |
| `/api/pncp/v1/.../arquivos` | documentos (edital e anexos — metadados + URL) |
| `/api/consulta/v1/contratos` | contratos por data de publicação |

Somente endpoints públicos e documentados; sem login, CAPTCHA ou qualquer contorno (§5).

## Números reais gravados (instantâneo 01:34 UTC)

| Métrica | Valor |
|---|---|
| Licitações | **596** (janela 02–03/09/2026, modalidades 6/8/4/9/12 + amostra 15–16/06/2026) |
| Valor estimado somado | **R$ 2,42 bi** |
| Recebendo propostas | 288 |
| Itens | **1.007** |
| Documentos | 102 (metadados + URL oficial) |
| Resultados homologados | 21 (R$ 1,86 mi) |
| Fornecedores públicos | **191** (CNPJ validado por dígito verificador) |
| Órgãos compradores | 428 · Unidades vinculadas |
| Contratos | **250** (R$ 85,1 mi) — 169 vencendo em ≤180 dias |
| Payloads RAW imutáveis | 113 (hash SHA-256, dedupe físico por url+hash) |
| Eventos de histórico | 596 `NOVO_REGISTRO` · 0 alterações até o momento |
| Execuções logadas | 11 (inclui 2 disparos autônomos do cron: 01:20 e 01:28) |

## As 7 provas

1. **Cadeia completa (real)** — `07615750000117-1-000063/2026`: *Aquisição de equipamentos
   para o Hospital Municipal de Jaguaruana/CE* (Pregão Eletrônico, R$ 267.566) → órgão
   MUNICIPIO DE JAGUARUANA → **11 itens** (bomba de infusão, DEA, macas…) → documento
   *Edital_e_anexos_082026PE* → **7 itens homologados** → fornecedores **M CARREGA COM. DE
   PRODUTOS HOSPITALARES LTDA** (32.593.430/0001-50) e **PRO-SAUDE DIST LTDA**
   (47.968.031/0001-02). Fonte: <https://pncp.gov.br/app/editais/07615750000117/2026/63>.
   Contrato vinculado a esta compra: ainda não publicado na fonte (registrado como ausente,
   não inventado).
2. **Várias licitações, paginação, documentos, relacionamentos** — 596 processos por
   paginação com checkpoint por modalidade/página; itens/documentos/resultados relacionados
   por `numero_controle_pncp`; 27 UFs cobertas.
3. **Idempotência** — segunda passagem do delta nas mesmas janelas: `registros=350,
   inseridos=0, ignorados=350` (e outra com 400/0/400). Contagens estáveis. Também provada
   offline: `engine/test/run-tests.mjs` (5/5 OK) com payloads reais.
4. **Alteração com antes/depois** — nenhuma licitação re-visitada mudou na fonte durante a
   ~1h de observação (0 eventos de alteração reais — dizer o contrário seria inventar).
   O mecanismo está provado por teste com payload real modificado: evento
   `DATA_SESSAO_ALTERADA` com `valor_anterior`/`valor_novo` corretos. O cron contínuo
   registrará as alterações reais conforme ocorrerem.
5. **Objeto com histórico** — termo mais recorrente no universo coletado: "manutenção"
   (6+ processos relacionados, com órgão/UF/valor/data; vencedores quando o resultado
   existir na fonte).
6. **Visão de mercado (MG)** — 49 processos, R$ 321,8 mi estimados; cidades líderes:
   Araxá (R$ 150 mi — credenciamento CIMINAS), Montes Claros, Caratinga; BH com 8
   processos; órgãos mais ativos listados. É a semente real do mapa de calor (aba F7).
7. **Ranking de fornecedores** — por valor homologado no universo coletado:
   CONSTRUCOST LTDA (R$ 1,49 mi), ALLGED SOLUÇÕES DE TI (R$ 240 mil), PRO-SAUDE
   (R$ 78,9 mil)… — sempre com a ressalva **“com base nos dados atualmente monitorados
   pela Bolsa”**.

## Erros e comportamento sob falha

- 4 falhas transitórias de rede (HTTP 0 após retries) registradas no `coleta_log` — a
  execução continua nas demais modalidades; falha total marcaria a fonte
  `TEMPORARILY_UNAVAILABLE` (§54).
- 1 correção de dado aplicada: payloads gravados como *string JSON* (dupla serialização do
  driver) — corrigidos por trigger + update de representação (conteúdo intacto), migração
  `0005`.
- `data_quality_issues`: validação de CNPJ (dígitos) e UF ativa; nenhum descarte silencioso.

## Frequências em produção (configuráveis em `bolsa.coleta_config`)

`delta` a cada 20 min · `detalhes` 3×/hora · `contratos` 1×/hora · `backfill` manual por
janela (ano→mês→dia). Orçamento de ~35 s por execução, atraso de ~100 ms entre requisições,
retry exponencial com jitter (§52-55).

## Limitações honestas desta etapa

- Download físico dos PDFs e extração de texto/página: etapa própria ainda não feita
  (guardamos metadados + URL oficial) — §11-13 pendentes.
- Atas de RP e PCA do PNCP: previstos, não implementados.
- Lances/propostas: o PNCP não expõe histórico estruturado de lances — não inventamos (§40).
- Pagamentos/empenhos: virão com o conector do Portal da Transparência (Etapa 4).
- Backfill histórico amplo: mecanismo pronto (checkpoint por janela), execução contínua a
  cargo do cron — o volume atual é o acumulado de ~1h de operação + amostra de junho.
- Dedup multi-fonte (`possible_duplicate`, divergência entre sites): ativa quando a 2ª
  fonte (Compras.gov) entrar — hoje há uma única fonte.
- A base vive em schema isolado `bolsa` num projeto Supabase existente do usuário
  (limite de 2 projetos ativos no plano free impediu criar projeto dedicado; nada do
  schema `public` foi alterado). Migração para projeto próprio: rodar `supabase/migrations/`
  + implantar a função + recriar os crons.
