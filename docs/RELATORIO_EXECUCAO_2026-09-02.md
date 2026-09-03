# Relatório de execução — 2026-09-02

## Resultado executivo

A primeira vertical real de coleta foi entregue e validada localmente. O backend consulta somente endpoints públicos por `GET`, preserva o JSON original, versiona alterações por SHA-256, normaliza as entidades centrais, consolida registros coincidentes entre PNCP e Compras.gov.br e expõe uma API administrativa somente leitura.

O banco de evidência desta execução está em `data/bolsa_licitacoes.db`. Arquivos de runtime permanecem ignorados pelo Git; migrations, código, testes e documentação são versionáveis.

## Fontes oficiais verificadas

| Fonte | Evidência consultada | Situação |
|---|---|---|
| PNCP | Swagger da API de Consulta, manual da API de Consulta e manual de Integração 2.6 | Operando |
| Compras.gov.br | Swagger/OpenAPI e Manual da API de Dados Abertos 2.0 | Operando |
| Portal da Transparência | Página oficial da API, autenticação e limites | Credencial pendente |
| Banco de Preços em Saúde | Página oficial e bases anuais compiladas em CSV | Mapeado; conector pendente |
| CMED/Anvisa | Listas oficiais de preços XLS/PDF e histórico | Mapeado; conector pendente |

Os catálogos reproduzíveis estão em `ENDPOINTS_PNCP.md` e `ENDPOINTS_COMPRAS.md`; o inventário e as decisões de acesso estão em `FONTES.md`.

## Chamadas reais executadas

| Fonte/endpoint | Resultado observado |
|---|---|
| PNCP `GET /v1/contratacoes/publicacao` | HTTP 200; 1.568 registros e 157 páginas para 2026-09-01, modalidade PNCP 6; página de 10 capturada e importada |
| PNCP `GET /v1/contratacoes/proposta` | HTTP 200; filtro de CNPJ retornou 5 oportunidades abertas e as 5 foram importadas |
| PNCP `GET /v1/orgaos/{cnpj}/compras/{ano}/{sequencial}` | HTTP 200; detalhe importado |
| PNCP `GET .../itens` | HTTP 200; 4 itens reais importados em duas contratações |
| PNCP `GET .../itens/{item}/resultados` | HTTP 200; 1 resultado homologado e fornecedor importados |
| PNCP `GET .../arquivos` | HTTP 200; 2 metadados e 2 arquivos baixados |
| PNCP `GET .../historico` | HTTP 200; 3 eventos brutos preservados |
| PNCP `GET /v1/contratos` | HTTP 200; 10 contratos coletados diretamente pelo conector |
| PNCP `GET .../atas` | HTTP 200; 1 ata de registro de preços importada |
| PNCP `GET .../pca/.../itens` | HTTP 200; 3 itens de PCA importados |
| Compras.gov.br `GET /modulo-contratacoes/1_consultarContratacoes_PNCP_14133` | HTTP 200; 7.645 registros e 765 páginas em fevereiro/2025, modalidade Compras 5; 20 registros coletados em duas janelas |

As respostas capturadas fora do processo por causa de oscilação do PNCP foram reprocessadas pelo mesmo armazenamento e pelos mesmos normalizadores. `REPLAY` identifica essas execuções: são respostas reais preservadas, não fixtures inventadas.

## Estado do banco ao encerrar

| Entidade | Quantidade |
|---|---:|
| Fontes | 4 |
| Execuções | 20 (14 com sucesso, 6 falhas) |
| Registros brutos versionados | 65 |
| Registros brutos ativos | 62 |
| Organizações / unidades compradoras | 29 / 30 |
| Contratações consolidadas | 34 |
| Itens / resultados | 4 / 1 |
| Fornecedores | 10 |
| Atas / contratos / itens de PCA | 1 / 10 / 3 |
| Documentos / versões | 2 / 2 |
| Vínculos de proveniência | 44 |
| Erros operacionais auditados | 6, todos marcados para nova tentativa |

Há 29 tabelas físicas: 27 tabelas de domínio/operação solicitadas, mais `schema_migrations` e `collection_checkpoints`. Três linhas brutas antigas de PCA foram marcadas `DUPLICATE` após a correção da chave determinística e mantidas para auditoria; por isso há 65 linhas físicas e 62 registros brutos ativos.

## Idempotência e versionamento comprovados

- Uma segunda coleta da página Compras.gov.br classificou os 10 registros como `unchanged`.
- O replay da publicação PNCP classificou os 18 registros brutos como `unchanged`.
- Repetições da ata e do PCA produziram, respectivamente, 1 e 3 `unchanged`.
- O download repetido do edital não criou uma terceira versão documental.
- O número de controle PNCP reuniu o mesmo processo encontrado no PNCP e no Compras.gov.br sem duplicar `procurements`.

## Documentos reais

| Documento | Tipo detectado | Tamanho | SHA-256 |
|---|---|---:|---|
| Edital Pregão 053/2026 | PDF, 106 páginas | 2.858.586 bytes | `b2d51f3668350adb771b73b9aa8ebfa20cab54aff47dc48b446b7e4f0103cd29` |
| Parecer Jurídico | DOCX | 8.297 bytes | `03e3d77bf6c7d488d415741459b8504f293fd37c7c53981c8b420462db708aa9` |

O PNCP informou `application/octet-stream` nos dois downloads. O serviço agora detecta PDF e OOXML pelo conteúdo, grava extensão/MIME corretos e continua deduplicando pelo hash.

## Verificação de software

`PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src python3 -m unittest discover -v`:

- 12 testes descobertos;
- 11 executados com sucesso;
- 1 integração pública opt-in ignorada no conjunto padrão;
- o teste opt-in de Compras.gov.br também foi executado separadamente e passou.

A API administrativa foi iniciada e consultada em `127.0.0.1:8088`: `/health`, `/api/admin/stats`, `/api/admin/sources`, `/api/admin/runs` e `/api/admin/runs/{id}` responderam corretamente. O processo de teste foi encerrado depois da verificação.

## Limites e pendências explícitas

- O PNCP apresentou timeouts intermitentes em consultas nacionais amplas de publicações, propostas, atas e PCA. As 6 falhas foram preservadas em `collection_errors` como recuperáveis; filtros menores funcionaram.
- Períodos recentes de 2026 no Compras.gov.br devolveram zero, enquanto fevereiro de 2025 devolveu dados; isso indica defasagem ou cobertura da fonte e não justifica fabricar registros.
- O Portal da Transparência exige token. `PORTAL_TRANSPARENCIA_API_TOKEN` foi preparado, mas nenhuma chamada autenticada foi feita sem credencial.
- BPS e CMED estão inventariados, mas seus coletores de arquivo ainda não foram implementados.
- A fila de OCR/processamento e a tabela de checkpoints estão modeladas; um orquestrador recorrente externo ainda não foi ligado.
- A Central de Fontes possui backend somente leitura; a integração visual com o protótipo estático do Claude não foi alterada para evitar conflito de trabalho.
- Nenhuma participação em pregão, envio de proposta, endpoint privado, login ou automação transacional foi executado.

## Critério de encerramento desta etapa

A etapa inicial está concluída para PNCP e Compras.gov.br: fontes e endpoints mapeados, chamadas reais realizadas, JSON original armazenado, núcleo normalizado, documentos baixados/versionados, idempotência testada, operação observável e limitações registradas. A expansão para Portal da Transparência, BPS, CMED, OCR em produção e cobertura nacional completa permanece como próxima fase, condicionada às credenciais e ao orquestrador escolhidos.
