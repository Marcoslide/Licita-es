CREATE INDEX IF NOT EXISTS idx_procurements_collected_at
ON procurements(collected_at DESC);

CREATE INDEX IF NOT EXISTS idx_procurements_source_created_at
ON procurements(source_created_at DESC);

CREATE INDEX IF NOT EXISTS idx_procurements_purchasing_unit_id
ON procurements(purchasing_unit_id);

CREATE INDEX IF NOT EXISTS idx_purchasing_units_state_id
ON purchasing_units(state_id);

CREATE INDEX IF NOT EXISTS idx_documents_procurement_id
ON documents(procurement_id);

CREATE INDEX IF NOT EXISTS idx_contracts_procurement_id
ON contracts(procurement_id);

PRAGMA optimize;
