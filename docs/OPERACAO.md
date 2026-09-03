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

Quando `BOLSA_ADMIN_API_TOKEN` estiver configurado, todos os endpoints exceto `/health` exigem `Authorization: Bearer <token>`.

## VPS com Docker Compose

Os arquivos de implantação ficam em `deploy/vps`. A primeira subida usa SQLite em volume local persistente para validar o staging com o menor impacto possível na VPS compartilhada. A migração para PostgreSQL deve acontecer antes de ampliar concorrência, retenção ou cobertura nacional.

```bash
sudo bash deploy/vps/bootstrap.sh
cp deploy/vps/.env.example deploy/vps/.env
docker compose --env-file deploy/vps/.env -f deploy/vps/docker-compose.yml config
docker compose --env-file deploy/vps/.env -f deploy/vps/docker-compose.yml up -d --build
```

O staging publica somente em loopback: API em `127.0.0.1:18120` e interface em `127.0.0.1:18121`. A rede bridge permite saída para as APIs oficiais, mas nenhum contêiner recebe porta pública. Nada fica exposto na internet até que um domínio seja escolhido e o proxy HTTPS compartilhado seja configurado conscientemente.

Os vhosts preparados para `bolsa.frontlinetec.com.br` ficam em `deploy/vps/proxy`. A versão HTTP existe apenas para o desafio ACME inicial; depois da emissão do certificado ela deve ser substituída pela versão HTTPS. O proxy compartilhado deve ser conectado somente à rede externa `licita-es-proxy`, que expõe o contêiner web pelo alias exclusivo `licita-es-web`. A API e o scheduler permanecem na rede `licita-es-internal` e não devem ser ligados ao proxy compartilhado.

Execute primeiro `deploy/vps/bootstrap.sh`, suba o Compose e então execute como root `deploy/vps/install-shared-proxy.sh`. Os scripts são idempotentes: preparam a rede de proxy, conectam apenas os dois contêineres envolvidos, instalam o vhost HTTPS, validam o Nginx e recarregam sua configuração sem recriar o proxy compartilhado.

## Backfill

Use janelas pequenas e `max-pages`; cada período é uma execução isolada. `collection_checkpoints` persiste período/cursor/status, mas o orquestrador recorrente que agenda automaticamente janelas de 5–15 minutos e retoma checkpoints ainda não foi conectado a uma fila externa, pois o projeto não possuía sistema de filas.
