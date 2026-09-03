# Motor Nacional de Coleta — Bolsa de Licitações

Fase atual: **coletar o mercado público nacional a partir de sites públicos** e construir a
base histórica própria. Sem cadastro de cliente, sem CNPJ operacional, sem participação em
pregão — apenas Brasil, mercado público, sites, coleta, histórico e dados.

## Arquitetura

```
SITES PÚBLICOS ──> COLETORES ──> RAW (imutável) ──> NORMALIZAÇÃO ──> DEDUP ──> RELACIONAMENTO
                                                      │                              │
                                                      └──> EVENTOS (histórico)  ANALYTICS/VIEWS ──> API ──> BOLSA (UI)
```

O front-end **nunca** raspa os sites: consulta somente a nossa base (§90).

### Duas execuções do mesmo desenho

| Onde | Para quê | Código |
|---|---|---|
| **Produção** — Supabase Edge Function `coleta-pncp` + Postgres (schema `bolsa`), agendada por `pg_cron` | Coleta contínua real (delta 20 min, detalhes 3×/h, contratos 1×/h) | `supabase/functions/coleta-pncp/index.ts` |
| **Local/servidor** — Node ≥ 22 + SQLite (`data/bolsa.db`) | Referência, desenvolvimento, backfill em escala e testes offline | `engine/collectors/pncp.mjs` + `engine/jobs/run.mjs` |

Mesmo modelo canônico nos dois (Postgres: `supabase/migrations/`; SQLite: `engine/schema.sql`).

### Modelo de conector (`PublicSourceCollector`)

Cada fonte implementa somente o que possui (capabilities registradas na tabela `fontes`):

| Fonte | licitações | itens | documentos | resultados | contratos | atas | pca | pagamentos | lances |
|---|---|---|---|---|---|---|---|---|---|
| **PNCP** (implementado) | ✔ | ✔ | ✔ (metadados+URL) | ✔ | ✔ | prev. | prev. | ✖ | ✖ |
| Compras.gov (Etapa 2) | — | — | — | — | — | — | — | — | — |
| Contratos.gov (Etapa 3) | — | — | — | — | — | — | — | — | — |
| Portal da Transparência (Etapa 4) | — | — | — | — | — | — | — | ✔ (previsto) | ✖ |

### Regras implementadas

- **Somente informação pública** — nenhum login, CAPTCHA ou bloqueio é contornado (§5).
- **RAW imutável** — todo corpo de resposta é gravado em `raw_payloads` com hash SHA-256;
  o mesmo conteúdo da mesma URL não duplica fisicamente (§11, §23-24).
- **NULL ≠ 0** — campo ausente vira `NULL`, nunca `0` (§35).
- **`source_payload` preservado** em toda entidade normalizada (§27); objeto original nunca é editado (§44).
- **Dedup por identificador oficial** — `numeroControlePNCP` é a chave primária (§29);
  o match secundário por similaridade entra quando houver segunda fonte (§30-31).
- **Histórico** — `first_seen_at` / `last_seen_at` / `source_updated_at` (§22) e tabela
  `eventos` com `NOVO_REGISTRO`, `DATA_SESSAO_ALTERADA`, `VALOR_ESTIMADO_ALTERADO`,
  `SITUACAO_ALTERADA`, `OBJETO_ALTERADO`, `VALOR_HOMOLOGADO_ALTERADO` (antes/depois) (§20-21).
- **Checkpoint** por fonte+janela+modalidade+página — a coleta retoma de onde parou (§46).
- **Idempotência** — reaplicar o mesmo lote não duplica (upsert por chave oficial; teste em `engine/test/`) (§47).
- **Preços em níveis separados** — estimado / homologado / contratado, jamais um campo único (§41).
- **Respeito à fonte** — atraso entre requisições, timeout, retry com backoff exponencial e
  jitter, limite de tentativas; falha total marca a fonte `TEMPORARILY_UNAVAILABLE` (§53-55).
- **Qualidade** — CNPJ validado por dígito verificador, UF contra lista oficial; inválidos
  não são descartados: viram `data_quality_issues` (§58).
- **Log de coleta** — cada execução registra páginas, registros, inseridos, atualizados,
  ignorados, documentos, erros e notas (§61).

### Frequências (configuráveis em `bolsa.coleta_config`, §52)

| Job | Cron inicial | Conteúdo |
|---|---|---|
| `delta` | `*/20 * * * *` | novas contratações (ontem+hoje, modalidades prioritárias) + detalhes pendentes |
| `detalhes` | `8,28,48 * * * *` | itens, documentos e resultados de licitações ainda sem detalhe |
| `contratos` | `12 * * * *` | contratos publicados nas últimas 48h |
| `backfill` | manual | janelas históricas por ano→mês→dia (§45) |

### Endpoints públicos do PNCP utilizados

- `GET /api/consulta/v1/contratacoes/publicacao` — listagem por data de publicação + modalidade (paginada)
- `GET /api/pncp/v1/orgaos/{cnpj}/compras/{ano}/{seq}/itens` — itens da contratação
- `GET /api/pncp/v1/orgaos/{cnpj}/compras/{ano}/{seq}/itens/{n}/resultados` — resultado por item (fornecedor, valores homologados)
- `GET /api/pncp/v1/orgaos/{cnpj}/compras/{ano}/{seq}/arquivos` — documentos (edital, anexos)
- `GET /api/consulta/v1/contratos` — contratos por data de publicação

### Limitações conhecidas desta etapa (honestas, §95)

- Download físico dos PDFs de edital ainda não é feito — guardamos metadados + URL oficial
  (extração de texto/páginas é etapa própria, §12-13).
- Atas de RP e PCA do PNCP: tabelas previstas, conectores ainda não implementados.
- Lances e propostas: o PNCP não expõe histórico estruturado de lances — **não inventamos**;
  virão de outras fontes ou de atas com marcação `EXTRAÍDO DE DOCUMENTO` (§40).
- Pagamentos/empenhos: fora do PNCP; entram com o conector do Portal da Transparência.
- `possible_duplicate`/divergência entre fontes: ativam quando a 2ª fonte (Compras.gov) entrar.

## Uso local

```bash
node engine/jobs/run.mjs status
node engine/jobs/run.mjs delta --de 20260901 --ate 20260903 --paginas 3
node engine/jobs/run.mjs detalhes --lote 10
node engine/test/run-tests.mjs   # idempotência, eventos, validação (fixtures reais)
```

> Observação: no sandbox do Claude Code o egress bloqueia `pncp.gov.br`, por isso a coleta
> ao vivo roda na Edge Function (infra Supabase, sa-east-1). O CLI local funciona em
> qualquer máquina com internet normal.
