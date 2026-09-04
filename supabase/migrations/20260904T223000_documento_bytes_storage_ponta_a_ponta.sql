-- PARTE A2 (fechamento Wave 1) — armazenamento físico de documentos do
-- motor genérico (entidade='documento_processo'), reaproveitando o bucket
-- já provado em PROMPT01 (memoria-bruta) e o mesmo padrão de upload via
-- Storage REST usado por coleta-historico-transp (SUPABASE_SERVICE_ROLE_KEY
-- nos headers authorization+apikey).
--
-- documento_bytes: bytes armazenados uma única vez por SHA-256 (dedup real,
-- não duplica quando o hash já existe — content-addressed).
-- documento_download: vínculo entre o registro da fonte (fonte_id/entidade/
-- chave) e os bytes armazenados; N registros podem apontar pro mesmo hash.
create table if not exists bolsa.documento_bytes (
  id bigserial primary key,
  sha256 text not null unique,
  tamanho_bytes bigint not null,
  content_type text,
  storage_path text not null,
  baixado_em timestamptz not null default now()
);

create table if not exists bolsa.documento_download (
  id bigserial primary key,
  fonte_id text not null,
  entidade text not null default 'documento_processo',
  chave text not null,
  url_original text not null,
  sha256 text not null references bolsa.documento_bytes(sha256),
  criado_em timestamptz not null default now(),
  unique (fonte_id, entidade, chave)
);
