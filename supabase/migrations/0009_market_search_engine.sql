-- Bolsa de Licitações — Market Search Engine V1/V2
-- Preparada para aplicação no mesmo projeto Supabase das migrações 0001–0008.
-- A aplicação pública atual não depende desta migração: o gateway executa o
-- mesmo ranking sobre o snapshot real até o benchmark autorizar mover retrieval ao banco.

create extension if not exists pg_trgm;
create extension if not exists unaccent;

create table if not exists bolsa.search_synonyms (
  id bigint generated always as identity primary key,
  primary_term text not null,
  synonym text not null,
  category text,
  origin text not null check (origin in ('MANUAL','TAXONOMY','HISTORICAL','AI_SUGGESTED','USER')),
  confidence numeric(4,3) not null default 1 check (confidence between 0 and 1),
  approved boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (primary_term, synonym, category)
);

create table if not exists bolsa.procurement_search_documents (
  search_document_key text primary key,
  procurement_id text not null references bolsa.licitacoes(numero_controle_pncp) on delete cascade,
  item_id bigint references bolsa.itens(id) on delete cascade,
  object_text text,
  item_text text,
  normalized_text text not null,
  catalogue_codes text[] not null default '{}',
  technical_attributes jsonb not null default '{}'::jsonb,
  uf text,
  city text,
  organization_id text,
  published_at timestamptz,
  estimated_value numeric,
  lexical_vector tsvector,
  updated_at timestamptz not null default now()
);
create index if not exists search_documents_lexical_idx on bolsa.procurement_search_documents using gin (lexical_vector);
create index if not exists search_documents_trgm_idx on bolsa.procurement_search_documents using gin (normalized_text gin_trgm_ops);
create index if not exists search_documents_scope_idx on bolsa.procurement_search_documents (uf, city, published_at desc);
create index if not exists search_documents_procurement_idx on bolsa.procurement_search_documents (procurement_id);
create index if not exists search_synonyms_lookup_idx on bolsa.search_synonyms using gin (primary_term gin_trgm_ops, synonym gin_trgm_ops) where approved;

create or replace function bolsa.refresh_search_document(p_procurement_id text)
returns void language plpgsql security definer set search_path = bolsa, public as $$
declare p bolsa.licitacoes%rowtype;
begin
  select * into p from bolsa.licitacoes where numero_controle_pncp = p_procurement_id;
  if not found then return; end if;
  delete from bolsa.procurement_search_documents where procurement_id = p_procurement_id;
  insert into bolsa.procurement_search_documents (
    search_document_key, procurement_id, item_id, object_text, item_text, normalized_text,
    catalogue_codes, uf, city, organization_id, published_at, estimated_value, lexical_vector
  )
  select
    p.numero_controle_pncp || ':item:' || i.id,
    p.numero_controle_pncp, i.id, p.objeto, i.descricao,
    lower(unaccent(concat_ws(' ', p.objeto, i.descricao, i.categoria_nome, i.material_ou_servico))),
    case when i.catalogo_codigo is null then '{}'::text[] else array[i.catalogo_codigo] end,
    p.uf, p.municipio_nome, p.orgao_cnpj, p.data_publicacao_pncp, p.valor_total_estimado,
    setweight(to_tsvector('portuguese', coalesce(i.descricao,'')), 'A') ||
    setweight(to_tsvector('portuguese', coalesce(p.objeto,'')), 'A') ||
    setweight(to_tsvector('portuguese', coalesce(i.categoria_nome,'')), 'B')
  from bolsa.itens i where i.numero_controle_pncp = p.numero_controle_pncp;

  if not exists (select 1 from bolsa.itens i where i.numero_controle_pncp = p.numero_controle_pncp) then
    insert into bolsa.procurement_search_documents (
      search_document_key, procurement_id, object_text, normalized_text, uf, city,
      organization_id, published_at, estimated_value, lexical_vector
    ) values (
      p.numero_controle_pncp || ':object', p.numero_controle_pncp, p.objeto,
      lower(unaccent(coalesce(p.objeto,''))), p.uf, p.municipio_nome, p.orgao_cnpj,
      p.data_publicacao_pncp, p.valor_total_estimado,
      setweight(to_tsvector('portuguese', coalesce(p.objeto,'')), 'A')
    );
  end if;
end $$;

create or replace function bolsa.search_document_trigger()
returns trigger language plpgsql security definer set search_path = bolsa, public as $$
declare procurement_key text;
begin
  procurement_key := case when tg_op = 'DELETE' then old.numero_controle_pncp else new.numero_controle_pncp end;
  perform bolsa.refresh_search_document(procurement_key);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

drop trigger if exists licitacoes_search_refresh on bolsa.licitacoes;
create trigger licitacoes_search_refresh after insert or update of objeto, uf, municipio_nome, orgao_cnpj,
  data_publicacao_pncp, valor_total_estimado on bolsa.licitacoes
  for each row execute function bolsa.search_document_trigger();
drop trigger if exists itens_search_refresh on bolsa.itens;
create trigger itens_search_refresh after insert or update or delete on bolsa.itens
  for each row execute function bolsa.search_document_trigger();

do $$ declare procurement_key text; begin
  for procurement_key in select numero_controle_pncp from bolsa.licitacoes loop
    perform bolsa.refresh_search_document(procurement_key);
  end loop;
end $$;

create table if not exists bolsa.search_query_logs (
  id bigint generated always as identity primary key,
  query_normalized text,
  filters jsonb not null default '{}'::jsonb,
  mode text not null,
  result_count int not null,
  latency_ms numeric,
  zero_result boolean not null,
  search_engine_version text not null,
  embedding_model_version text,
  reranker_version text,
  synonym_dictionary_version text,
  created_at timestamptz not null default now()
);
create index if not exists search_query_logs_time_idx on bolsa.search_query_logs (created_at desc);

create table if not exists bolsa.search_feedback (
  id bigint generated always as identity primary key,
  user_id uuid,
  query_normalized text not null,
  procurement_id text not null,
  scope jsonb not null default '{}'::jsonb,
  relevant boolean not null,
  reason text,
  search_engine_version text not null,
  created_at timestamptz not null default now()
);

create table if not exists bolsa.search_golden_set (
  id bigint generated always as identity primary key,
  query text not null,
  procurement_id text not null,
  relevance_grade smallint not null check (relevance_grade between 0 and 3),
  notes text,
  approved_by uuid,
  updated_at timestamptz not null default now(),
  unique (query, procurement_id)
);

alter table bolsa.search_synonyms enable row level security;
alter table bolsa.procurement_search_documents enable row level security;
alter table bolsa.search_query_logs enable row level security;
alter table bolsa.search_feedback enable row level security;
alter table bolsa.search_golden_set enable row level security;
grant select on bolsa.search_synonyms, bolsa.procurement_search_documents to anon, authenticated;
grant all on bolsa.search_synonyms, bolsa.procurement_search_documents, bolsa.search_query_logs,
  bolsa.search_feedback, bolsa.search_golden_set to service_role;
