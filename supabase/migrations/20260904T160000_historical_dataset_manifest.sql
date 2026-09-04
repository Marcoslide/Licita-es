-- ============================================================
-- FASE DE ESTABILIZAÇÃO — PRIORIDADE 2: manifest leve do histórico.
-- Estrutura proposta pelo usuário para a Bolsa saber exatamente onde
-- está cada pedaço da memória histórica (hoje só existe o RAW Storage
-- para as fontes bulk e nenhum inventário centralizado por dataset).
-- Apenas cria a tabela — não move nem apaga nada, não popula
-- automaticamente com dados antigos ainda (isso é decisão separada,
-- com exportação/hash/validação/aprovação, per instrução explícita).
-- ============================================================
create table if not exists bolsa.historical_dataset_manifest (
  id bigint generated always as identity primary key,
  source_id text not null,
  dataset text not null,
  ano integer,
  mes integer,
  object_path text,
  format text,
  compression text,
  record_count bigint,
  file_size bigint,
  sha256 text,
  schema_version text,
  min_date date,
  max_date date,
  created_at timestamptz not null default now(),
  verified_at timestamptz,
  unique (source_id, dataset, ano, mes)
);
create index if not exists historical_dataset_manifest_dataset_idx on bolsa.historical_dataset_manifest (dataset, ano, mes);
alter table bolsa.historical_dataset_manifest enable row level security;
