-- O retorno real de contratos/atas usa numeroControlePNCP. Repara linhas criadas
-- pela primeira versão do normalizador sem descartar a proveniência bruta.
UPDATE contracts
SET pncp_control_number = (
  SELECT json_extract(r.payload_original, '$.numeroControlePNCP')
  FROM source_raw_records r WHERE r.id = contracts.raw_record_id
)
WHERE pncp_control_number IS NULL;

UPDATE price_registry_atas
SET pncp_control_number = (
  SELECT json_extract(r.payload_original, '$.numeroControlePNCP')
  FROM source_raw_records r WHERE r.id = price_registry_atas.raw_record_id
)
WHERE pncp_control_number IS NULL;

UPDATE source_raw_records
SET external_id = json_extract(payload_original, '$.numeroControlePNCP')
WHERE entity_hint IN ('contract', 'price_registry_ata')
  AND json_extract(payload_original, '$.numeroControlePNCP') IS NOT NULL;
