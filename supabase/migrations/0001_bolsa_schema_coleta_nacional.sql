-- ============================================================
-- BOLSA DE LICITAÇÕES — Base Nacional (fase coleta) — schema isolado
-- Camadas: raw (imutável) -> normalizada -> views analíticas públicas
-- Aplicada em 2026-09-03 no projeto rxcfbbzosbfiwyloqtdk (sa-east-1)
-- ============================================================
create schema if not exists bolsa;

create table bolsa.fontes (
  id text primary key,
  nome text not null,
  base_url text not null,
  capabilities jsonb not null default '{}'::jsonb,
  status text not null default 'ATIVA',            -- ATIVA | TEMPORARILY_UNAVAILABLE | POSSIVELMENTE_QUEBRADA
  ultimo_sucesso_em timestamptz,
  criado_em timestamptz not null default now()
);

insert into bolsa.fontes (id, nome, base_url, capabilities) values
 ('pncp','Portal Nacional de Contratações Públicas','https://pncp.gov.br',
  '{"licitacoes":true,"itens":true,"documentos":true,"resultados":true,"contratos":true,"atas":true,"pca":true,"pagamentos":false,"lances":false}'::jsonb)
on conflict (id) do nothing;

create table bolsa.raw_payloads (
  id bigint generated always as identity primary key,
  fonte_id text not null references bolsa.fontes(id),
  url text not null,
  contexto text,
  http_status int,
  content_hash text not null,
  payload jsonb not null,
  colhido_em timestamptz not null default now(),
  unique (url, content_hash)
);
create index raw_payloads_ctx_idx on bolsa.raw_payloads (contexto, colhido_em desc);

create table bolsa.orgaos (
  cnpj text primary key,
  razao_social text,
  poder_id text,
  esfera_id text,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  source_payload jsonb
);

create table bolsa.unidades (
  id bigint generated always as identity primary key,
  orgao_cnpj text not null references bolsa.orgaos(cnpj),
  codigo text not null,
  nome text,
  uf text,
  municipio_nome text,
  codigo_ibge text,
  unique (orgao_cnpj, codigo)
);

create table bolsa.licitacoes (
  numero_controle_pncp text primary key,
  fonte_id text not null references bolsa.fontes(id),
  orgao_cnpj text references bolsa.orgaos(cnpj),
  unidade_codigo text,
  ano_compra int,
  sequencial_compra int,
  numero_compra text,
  processo text,
  modalidade_id int,
  modalidade_nome text,
  modo_disputa text,
  situacao_id int,
  situacao_nome text,
  situacao_fonte text,
  srp boolean,
  instrumento text,
  objeto text,
  valor_total_estimado numeric,
  valor_total_homologado numeric,
  data_publicacao_pncp timestamptz,
  data_abertura_proposta timestamptz,
  data_encerramento_proposta timestamptz,
  uf text,
  municipio_nome text,
  codigo_ibge text,
  amparo_legal text,
  informacao_complementar text,
  link_sistema_origem text,
  usuario_nome text,
  itens_coletados_em timestamptz,
  arquivos_coletados_em timestamptz,
  resultados_coletados_em timestamptz,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  source_updated_at timestamptz,
  source_payload jsonb not null,
  raw_hash text
);
create index licitacoes_uf_idx on bolsa.licitacoes (uf);
create index licitacoes_pub_idx on bolsa.licitacoes (data_publicacao_pncp desc);
create index licitacoes_situacao_idx on bolsa.licitacoes (situacao_nome);
create index licitacoes_modalidade_idx on bolsa.licitacoes (modalidade_id);
create index licitacoes_orgao_idx on bolsa.licitacoes (orgao_cnpj);
create index licitacoes_enc_idx on bolsa.licitacoes (data_encerramento_proposta);
create index licitacoes_objeto_fts on bolsa.licitacoes using gin (to_tsvector('portuguese', coalesce(objeto,'')));

create table bolsa.itens (
  id bigint generated always as identity primary key,
  numero_controle_pncp text not null references bolsa.licitacoes(numero_controle_pncp),
  numero_item int not null,
  descricao text,
  material_ou_servico text,
  quantidade numeric,
  unidade text,
  valor_unitario_estimado numeric,
  valor_total_estimado numeric,
  categoria_id int,
  categoria_nome text,
  criterio_julgamento text,
  situacao_fonte text,
  beneficio text,
  ncm_nbs text,
  catalogo_codigo text,
  tem_resultado boolean,
  orcamento_sigiloso boolean,
  source_updated_at timestamptz,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (numero_controle_pncp, numero_item)
);
create index itens_lic_idx on bolsa.itens (numero_controle_pncp);
create index itens_desc_fts on bolsa.itens using gin (to_tsvector('portuguese', coalesce(descricao,'')));

create table bolsa.fornecedores (
  ni text primary key,
  tipo_pessoa text,
  nome text,
  porte text,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create table bolsa.resultados_itens (
  id bigint generated always as identity primary key,
  numero_controle_pncp text not null references bolsa.licitacoes(numero_controle_pncp),
  numero_item int not null,
  sequencial_resultado int,
  fornecedor_ni text references bolsa.fornecedores(ni),
  fornecedor_nome text,
  tipo_pessoa text,
  porte text,
  quantidade_homologada numeric,
  valor_unitario_homologado numeric,
  valor_total_homologado numeric,
  percentual_desconto numeric,
  situacao_fonte text,
  data_resultado date,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  fornecedor_ni_key text generated always as (coalesce(fornecedor_ni,'-')) stored,
  seq_key int generated always as (coalesce(sequencial_resultado,0)) stored,
  unique (numero_controle_pncp, numero_item, fornecedor_ni_key, seq_key)
);
create index resultados_forn_idx on bolsa.resultados_itens (fornecedor_ni);
create index resultados_lic_idx on bolsa.resultados_itens (numero_controle_pncp);

create table bolsa.documentos (
  id bigint generated always as identity primary key,
  numero_controle_pncp text not null references bolsa.licitacoes(numero_controle_pncp),
  sequencial_documento int,
  titulo text,
  tipo_documento text,
  url text,
  status_ativo boolean,
  data_publicacao timestamptz,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  seq_key int generated always as (coalesce(sequencial_documento,0)) stored,
  url_key text generated always as (coalesce(url,'-')) stored,
  unique (numero_controle_pncp, seq_key, url_key)
);
create index documentos_lic_idx on bolsa.documentos (numero_controle_pncp);

create table bolsa.contratos (
  numero_controle_pncp text primary key,
  numero_controle_pncp_compra text,
  numero_contrato text,
  ano_contrato int,
  processo text,
  categoria text,
  tipo text,
  objeto text,
  orgao_cnpj text references bolsa.orgaos(cnpj),
  unidade_codigo text,
  uf text,
  municipio_nome text,
  fornecedor_ni text references bolsa.fornecedores(ni),
  fornecedor_nome text,
  valor_inicial numeric,
  valor_global numeric,
  data_assinatura date,
  vigencia_inicio date,
  vigencia_fim date,
  data_publicacao_pncp timestamptz,
  source_updated_at timestamptz,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index contratos_fim_idx on bolsa.contratos (vigencia_fim);
create index contratos_forn_idx on bolsa.contratos (fornecedor_ni);
create index contratos_compra_idx on bolsa.contratos (numero_controle_pncp_compra);

create table bolsa.eventos (
  id bigint generated always as identity primary key,
  entidade text not null,
  chave text not null,
  tipo text not null,
  campo text,
  valor_anterior text,
  valor_novo text,
  fonte_id text,
  detectado_em timestamptz not null default now()
);
create index eventos_chave_idx on bolsa.eventos (chave, detectado_em desc);
create index eventos_tempo_idx on bolsa.eventos (detectado_em desc);

create table bolsa.checkpoints (
  chave text primary key,
  valor jsonb not null,
  atualizado_em timestamptz not null default now()
);

create table bolsa.coleta_log (
  id bigint generated always as identity primary key,
  fonte_id text not null,
  job text not null,
  iniciado_em timestamptz not null default now(),
  finalizado_em timestamptz,
  paginas int default 0,
  registros int default 0,
  inseridos int default 0,
  atualizados int default 0,
  ignorados int default 0,
  documentos int default 0,
  erros int default 0,
  detalhe jsonb
);
create index coleta_log_idx on bolsa.coleta_log (fonte_id, iniciado_em desc);

create table bolsa.data_quality_issues (
  id bigint generated always as identity primary key,
  entidade text, chave text, campo text, problema text, valor text,
  detectado_em timestamptz not null default now()
);

alter table bolsa.fontes enable row level security;
alter table bolsa.raw_payloads enable row level security;
alter table bolsa.orgaos enable row level security;
alter table bolsa.unidades enable row level security;
alter table bolsa.licitacoes enable row level security;
alter table bolsa.itens enable row level security;
alter table bolsa.fornecedores enable row level security;
alter table bolsa.resultados_itens enable row level security;
alter table bolsa.documentos enable row level security;
alter table bolsa.contratos enable row level security;
alter table bolsa.eventos enable row level security;
alter table bolsa.checkpoints enable row level security;
alter table bolsa.coleta_log enable row level security;
alter table bolsa.data_quality_issues enable row level security;

grant usage on schema bolsa to anon, authenticated;
grant select on all tables in schema bolsa to anon, authenticated;

do $$ declare t text;
begin
  foreach t in array array['fontes','orgaos','unidades','licitacoes','itens','fornecedores',
    'resultados_itens','documentos','contratos','eventos','coleta_log'] loop
    execute format('create policy leitura_publica on bolsa.%I for select to anon, authenticated using (true)', t);
  end loop;
end $$;
-- raw_payloads, checkpoints e data_quality_issues: sem policy pública (apenas service role)
