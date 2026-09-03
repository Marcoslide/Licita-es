-- Preserva capturas duplicadas produzidas pela chave não determinística inicial,
-- mas marca as antigas explicitamente; a mais recente recebe a chave oficial estável.
UPDATE source_raw_records AS target
SET external_id =
  printf('%s-0-%06d/%s:%s',
    json_extract(target.payload_original, '$.cnpj'),
    json_extract(target.payload_original, '$.sequencialPca'),
    json_extract(target.payload_original, '$.anoPca'),
    json_extract(target.payload_original, '$.numeroItem')
  ) ||
  CASE WHEN target.id = (
    SELECT MAX(other.id) FROM source_raw_records AS other
    WHERE other.entity_hint='annual_procurement_plan'
      AND other.endpoint=target.endpoint
      AND other.payload_hash=target.payload_hash
  ) THEN '' ELSE ':legacy-duplicate:' || target.id END
WHERE target.entity_hint='annual_procurement_plan'
  AND json_extract(target.payload_original, '$.cnpj') IS NOT NULL;

UPDATE source_raw_records
SET processing_status='DUPLICATE',
    processing_error='Chave legada não determinística; conteúdo idêntico preservado para auditoria'
WHERE entity_hint='annual_procurement_plan'
  AND external_id LIKE '%:legacy-duplicate:%';
