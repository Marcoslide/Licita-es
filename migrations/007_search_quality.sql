CREATE TABLE IF NOT EXISTS search_events (
  id INTEGER PRIMARY KEY,
  query_normalized TEXT,
  search_mode TEXT NOT NULL,
  filter_names TEXT NOT NULL DEFAULT '[]',
  result_count INTEGER NOT NULL DEFAULT 0,
  zero_result INTEGER NOT NULL DEFAULT 0,
  latency_ms REAL,
  search_engine_version TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_search_events_created_at ON search_events(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_search_events_query ON search_events(query_normalized, search_mode);

CREATE TABLE IF NOT EXISTS search_feedback (
  id INTEGER PRIMARY KEY,
  query_normalized TEXT NOT NULL,
  procurement_id TEXT NOT NULL,
  relevant INTEGER NOT NULL CHECK (relevant IN (0, 1)),
  scope_json TEXT NOT NULL DEFAULT '{}',
  reason TEXT,
  search_engine_version TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS search_golden_set (
  id INTEGER PRIMARY KEY,
  query TEXT NOT NULL,
  procurement_id TEXT NOT NULL,
  relevance_grade INTEGER NOT NULL CHECK (relevance_grade BETWEEN 0 AND 3),
  notes TEXT,
  approved_by TEXT,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(query, procurement_id)
);
