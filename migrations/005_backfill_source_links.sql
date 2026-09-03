INSERT OR IGNORE INTO source_links(entity_type, entity_id, source_id, source_external_id, source_url, raw_record_id)
SELECT 'contract', id, source_id, source_external_id, source_url, raw_record_id
FROM contracts
WHERE source_id IS NOT NULL AND source_external_id IS NOT NULL;

INSERT OR IGNORE INTO source_links(entity_type, entity_id, source_id, source_external_id, source_url, raw_record_id)
SELECT 'price_registry_ata', id, source_id, source_external_id, source_url, raw_record_id
FROM price_registry_atas
WHERE source_id IS NOT NULL AND source_external_id IS NOT NULL;

INSERT OR IGNORE INTO source_links(entity_type, entity_id, source_id, source_external_id, source_url, raw_record_id)
SELECT 'annual_procurement_plan', id, source_id, source_external_id, source_url, raw_record_id
FROM annual_procurement_plans
WHERE source_id IS NOT NULL AND source_external_id IS NOT NULL;
