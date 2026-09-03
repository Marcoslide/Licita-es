# Mapa de relacionamentos e proveniência

```text
Fonte -> Execução -> Registro bruto (versionado por hash)
                      |
                      +-> Organização -> Unidade compradora -> Contratação -> Item -> Resultado -> Fornecedor
                                                             |             |
                                                             |             +-> Registro de preço
                                                             +-> Documento -> Versão física (hash/objeto)
                                                             +-> Ata
                                                             +-> Contrato -> Item/Aditivo -> Empenho -> Pagamento
                                                             +-> Vínculos de fonte (PNCP, Compras.gov, ...)
```

`procurements.pncp_control_number` é a chave de consolidação nacional quando disponível. Uma contratação vista no PNCP e no Compras.gov ocupa uma linha em `procurements` e duas linhas em `source_links`; nenhum registro bruto é apagado.

Toda entidade normalizada possui os campos de proveniência solicitados: `source_id`, `source_external_id`, `source_url`, `raw_record_id`, datas da fonte, `collected_at` e `confidence`.

## Documentos e OCR

O download usa armazenamento por conteúdo (`sha256`) fora do banco e cria `document_versions` apenas quando o binário muda. O schema já reserva MIME, tamanho, página, detecção de PDF textual, estado de OCR e caminho do texto extraído. Extração/OCR propriamente ditos permanecem como jobs futuros em `processing_jobs`, preservando o caminho necessário `resposta -> documento -> página -> cláusula -> trecho`.
