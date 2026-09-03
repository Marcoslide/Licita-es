PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sources (
  id INTEGER PRIMARY KEY,
  nome TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  categoria TEXT NOT NULL,
  url_site TEXT,
  url_documentacao TEXT,
  url_base_api TEXT,
  tipo_acesso TEXT NOT NULL,
  tipo_autenticacao TEXT NOT NULL DEFAULT 'NENHUMA',
  credencial_necessaria INTEGER NOT NULL DEFAULT 0,
  frequencia_coleta TEXT,
  limite_requisicoes TEXT,
  status TEXT NOT NULL CHECK (status IN ('MAPEANDO','ATIVA','OPERANDO','ATENCAO','ATRASADA','INDISPONIVEL','CREDENCIAL_PENDENTE','ESTRUTURA_ALTERADA','DESATIVADA')),
  ultima_tentativa TEXT,
  ultima_coleta_sucesso TEXT,
  ultimo_cursor TEXT,
  ultimo_periodo_processado TEXT,
  quantidade_registros INTEGER NOT NULL DEFAULT 0,
  quantidade_erros INTEGER NOT NULL DEFAULT 0,
  versao_api TEXT,
  observacoes TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS source_runs (
  id INTEGER PRIMARY KEY,
  source_id INTEGER NOT NULL REFERENCES sources(id),
  run_type TEXT NOT NULL,
  endpoint TEXT,
  period_start TEXT,
  period_end TEXT,
  status TEXT NOT NULL DEFAULT 'RUNNING',
  checkpoint TEXT,
  pages INTEGER NOT NULL DEFAULT 0,
  records_seen INTEGER NOT NULL DEFAULT 0,
  records_new INTEGER NOT NULL DEFAULT 0,
  records_updated INTEGER NOT NULL DEFAULT 0,
  records_unchanged INTEGER NOT NULL DEFAULT 0,
  records_discarded INTEGER NOT NULL DEFAULT 0,
  documents_found INTEGER NOT NULL DEFAULT 0,
  documents_downloaded INTEGER NOT NULL DEFAULT 0,
  errors INTEGER NOT NULL DEFAULT 0,
  latency_ms INTEGER NOT NULL DEFAULT 0,
  started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT,
  error_message TEXT
);

CREATE TABLE IF NOT EXISTS source_raw_records (
  id INTEGER PRIMARY KEY,
  source_id INTEGER NOT NULL REFERENCES sources(id),
  endpoint TEXT NOT NULL,
  request_url TEXT NOT NULL,
  request_method TEXT NOT NULL DEFAULT 'GET',
  request_params TEXT NOT NULL DEFAULT '{}',
  http_status INTEGER NOT NULL,
  external_id TEXT NOT NULL,
  entity_hint TEXT NOT NULL,
  payload_original TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  source_created_at TEXT,
  source_updated_at TEXT,
  collected_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  processing_status TEXT NOT NULL DEFAULT 'PENDING',
  processing_error TEXT,
  version INTEGER NOT NULL,
  previous_version_id INTEGER REFERENCES source_raw_records(id),
  UNIQUE(source_id, endpoint, external_id, version)
);
CREATE INDEX IF NOT EXISTS idx_raw_lookup ON source_raw_records(source_id, endpoint, external_id, version DESC);
CREATE INDEX IF NOT EXISTS idx_raw_hash ON source_raw_records(payload_hash);

CREATE TABLE IF NOT EXISTS states (
  id INTEGER PRIMARY KEY, code TEXT NOT NULL UNIQUE, name TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL NOT NULL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS cities (
  id INTEGER PRIMARY KEY, ibge_code TEXT UNIQUE, name TEXT, state_id INTEGER REFERENCES states(id),
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL NOT NULL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS organizations (
  id INTEGER PRIMARY KEY, tax_id TEXT NOT NULL UNIQUE, legal_name TEXT, government_level TEXT, government_branch TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL NOT NULL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS purchasing_units (
  id INTEGER PRIMARY KEY, organization_id INTEGER REFERENCES organizations(id), code TEXT NOT NULL, name TEXT,
  state_id INTEGER REFERENCES states(id), city_id INTEGER REFERENCES cities(id),
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL NOT NULL DEFAULT 1.0,
  UNIQUE(organization_id, code)
);
CREATE TABLE IF NOT EXISTS procurements (
  id INTEGER PRIMARY KEY, pncp_control_number TEXT UNIQUE, organization_id INTEGER REFERENCES organizations(id),
  purchasing_unit_id INTEGER REFERENCES purchasing_units(id), year INTEGER, sequence INTEGER, purchase_number TEXT,
  process_number TEXT, object TEXT, modality_id INTEGER, modality_name TEXT, dispute_mode_id INTEGER,
  status_id INTEGER, status_name TEXT, proposal_start TEXT, proposal_end TEXT,
  estimated_value REAL, homologated_value REAL, source_system TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL NOT NULL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS procurement_items (
  id INTEGER PRIMARY KEY, procurement_id INTEGER NOT NULL REFERENCES procurements(id), item_number INTEGER NOT NULL,
  description TEXT, material_or_service TEXT, quantity REAL, unit TEXT, estimated_unit_value REAL,
  estimated_total_value REAL, status_id INTEGER, status_name TEXT, has_result INTEGER,
  catalog_item_code TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL NOT NULL DEFAULT 1.0,
  UNIQUE(procurement_id, item_number)
);
CREATE TABLE IF NOT EXISTS procurement_lots (
  id INTEGER PRIMARY KEY, procurement_id INTEGER REFERENCES procurements(id), lot_number TEXT, description TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0,
  UNIQUE(procurement_id, lot_number)
);
CREATE TABLE IF NOT EXISTS suppliers (
  id INTEGER PRIMARY KEY, tax_id TEXT UNIQUE, name TEXT, size_id INTEGER, country_code TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS procurement_results (
  id INTEGER PRIMARY KEY, procurement_item_id INTEGER NOT NULL REFERENCES procurement_items(id),
  result_sequence INTEGER NOT NULL DEFAULT 1, supplier_id INTEGER REFERENCES suppliers(id), quantity REAL,
  unit_value REAL, total_value REAL, brand TEXT, status_id INTEGER, status_name TEXT, result_date TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0,
  UNIQUE(procurement_item_id, result_sequence)
);
CREATE TABLE IF NOT EXISTS price_records (
  id INTEGER PRIMARY KEY, procurement_item_id INTEGER, supplier_id INTEGER, unit_value REAL, quantity REAL, observed_at TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS bids (
  id INTEGER PRIMARY KEY, procurement_id INTEGER, supplier_id INTEGER, value REAL, status TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS proposals (
  id INTEGER PRIMARY KEY, procurement_id INTEGER, supplier_id INTEGER, value REAL, status TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS price_registry_atas (
  id INTEGER PRIMARY KEY, pncp_control_number TEXT UNIQUE, procurement_id INTEGER, organization_id INTEGER,
  ata_number TEXT, validity_start TEXT, validity_end TEXT, object TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS contracts (
  id INTEGER PRIMARY KEY, pncp_control_number TEXT UNIQUE, procurement_id INTEGER, organization_id INTEGER,
  supplier_id INTEGER, contract_number TEXT, object TEXT, initial_value REAL, current_value REAL,
  signed_at TEXT, validity_start TEXT, validity_end TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS contract_items (
  id INTEGER PRIMARY KEY, contract_id INTEGER, item_number TEXT, description TEXT, quantity REAL, unit_value REAL,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0,
  UNIQUE(contract_id, item_number)
);
CREATE TABLE IF NOT EXISTS contract_amendments (
  id INTEGER PRIMARY KEY, contract_id INTEGER, amendment_number TEXT, amendment_type TEXT, object TEXT, value REAL,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS commitments (
  id INTEGER PRIMARY KEY, contract_id INTEGER, supplier_id INTEGER, commitment_number TEXT, value REAL, issued_at TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS payments (
  id INTEGER PRIMARY KEY, contract_id INTEGER, supplier_id INTEGER, payment_number TEXT, value REAL, paid_at TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0
);
CREATE TABLE IF NOT EXISTS annual_procurement_plans (
  id INTEGER PRIMARY KEY, pncp_control_number TEXT, organization_id INTEGER, purchasing_unit_id INTEGER,
  year INTEGER, item_number INTEGER, description TEXT, estimated_value REAL, desired_date TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0,
  UNIQUE(source_id, source_external_id)
);
CREATE TABLE IF NOT EXISTS documents (
  id INTEGER PRIMARY KEY, procurement_id INTEGER, ata_id INTEGER, contract_id INTEGER,
  original_name TEXT, document_type TEXT, source_download_url TEXT NOT NULL,
  current_version INTEGER NOT NULL DEFAULT 0, download_status TEXT NOT NULL DEFAULT 'PENDING',
  published_at TEXT,
  source_id INTEGER, source_external_id TEXT, source_url TEXT, raw_record_id INTEGER,
  source_created_at TEXT, source_updated_at TEXT, collected_at TEXT, confidence REAL DEFAULT 1.0,
  UNIQUE(source_id, source_external_id)
);
CREATE TABLE IF NOT EXISTS document_versions (
  id INTEGER PRIMARY KEY, document_id INTEGER NOT NULL REFERENCES documents(id), version INTEGER NOT NULL,
  storage_key TEXT, mime_type TEXT, size_bytes INTEGER, sha256 TEXT, extracted_text_path TEXT,
  is_textual_pdf INTEGER, ocr_status TEXT NOT NULL DEFAULT 'PENDING', page_count INTEGER,
  collected_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(document_id, version), UNIQUE(document_id, sha256)
);
CREATE TABLE IF NOT EXISTS source_links (
  id INTEGER PRIMARY KEY, entity_type TEXT NOT NULL, entity_id INTEGER NOT NULL,
  source_id INTEGER NOT NULL REFERENCES sources(id), source_external_id TEXT NOT NULL,
  source_url TEXT, raw_record_id INTEGER REFERENCES source_raw_records(id), collected_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(entity_type, entity_id, source_id, source_external_id)
);
CREATE TABLE IF NOT EXISTS processing_jobs (
  id INTEGER PRIMARY KEY, job_type TEXT NOT NULL, entity_type TEXT, entity_id INTEGER,
  status TEXT NOT NULL DEFAULT 'PENDING', attempts INTEGER NOT NULL DEFAULT 0,
  available_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, started_at TEXT, finished_at TEXT,
  payload TEXT, error_message TEXT, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS collection_errors (
  id INTEGER PRIMARY KEY, source_id INTEGER REFERENCES sources(id), source_run_id INTEGER REFERENCES source_runs(id),
  endpoint TEXT, request_url TEXT, request_params TEXT, http_status INTEGER,
  error_type TEXT, message TEXT NOT NULL, retryable INTEGER NOT NULL DEFAULT 0,
  occurred_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS collection_checkpoints (
  id INTEGER PRIMARY KEY, source_id INTEGER NOT NULL, job_key TEXT NOT NULL, period_start TEXT,
  period_end TEXT, cursor TEXT, status TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(source_id, job_key, period_start, period_end)
);
