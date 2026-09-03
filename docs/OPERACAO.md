# Operação dos coletores

Nenhum navegador é necessário depois da implementação. Todos os comandos abaixo são backend e usam somente GET público.

```bash
PYTHONPATH=src python3 -m bolsa_licitacoes.cli init-db
PYTHONPATH=src python3 -m bolsa_licitacoes.cli collect-pncp \
  --start 2026-09-01 --end 2026-09-01 --modalities 6 --max-pages 1 \
  --enrich-limit 1 --download-documents
PYTHONPATH=src python3 -m bolsa_licitacoes.cli collect-pncp-proposals --until 2026-09-02
PYTHONPATH=src python3 -m bolsa_licitacoes.cli collect-pncp-atas --start 2026-09-02 --end 2026-09-02
PYTHONPATH=src python3 -m bolsa_licitacoes.cli collect-pncp-contracts --start 2026-09-01 --end 2026-09-01
PYTHONPATH=src python3 -m bolsa_licitacoes.cli collect-pncp-pca --start 2026-09-01 --end 2026-09-01
PYTHONPATH=src python3 -m bolsa_licitacoes.cli collect-compras \
  --start 2025-02-01 --end 2025-02-28 --modalities 5 --max-pages 1
```

Sem `--modalities`, os conectores percorrem todos os códigos válidos de sua própria fonte. O PNCP limita publicações/propostas a 50 registros por página; outras consultas PNCP e os módulos Compras.gov aceitam até 500 conforme OpenAPI/manual.

## Central administrativa preparada

```bash
PYTHONPATH=src python3 -m bolsa_licitacoes.cli serve-admin --port 8088
```

Endpoints locais: `/health`, `/api/admin/stats`, `/api/admin/sources`, `/api/admin/runs` e `/api/admin/runs/{id}`. Eles alimentam a futura tela “Central de Fontes e Integrações” com status, volumes, páginas, latência, documentos, erros e checkpoint.

## Backfill

Use janelas pequenas e `max-pages`; cada período é uma execução isolada. `collection_checkpoints` persiste período/cursor/status, mas o orquestrador recorrente que agenda automaticamente janelas de 5–15 minutos e retoma checkpoints ainda não foi conectado a uma fila externa, pois o projeto não possuía sistema de filas.
