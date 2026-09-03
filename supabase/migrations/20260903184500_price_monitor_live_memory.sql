-- BOLSA DE LICITACOES -- espinha dorsal compartilhada de precos, monitores e memoria viva.
-- Aditiva e idempotente: reutiliza coleta, monitores, timeline e artefatos existentes.

create table if not exists bolsa.unit_dictionary (
  canonical_unit text not null,
  alias text primary key,
  unit_kind text not null default 'COUNT',
  multiplier numeric,
  requires_package_quantity boolean not null default false,
  confidence numeric not null default 1 check (confidence between 0 and 1),
  updated_at timestamptz not null default now()
);

insert into bolsa.unit_dictionary(canonical_unit,alias,unit_kind,multiplier,requires_package_quantity) values
  ('UN','UN','COUNT',1,false),('UN','UND','COUNT',1,false),('UN','UNIDADE','COUNT',1,false),
  ('UN','PECA','COUNT',1,false),('UN','PC','COUNT',1,false),
  ('CX','CX','PACKAGE',null,true),('CX','CAIXA','PACKAGE',null,true),
  ('PCT','PCT','PACKAGE',null,true),('PCT','PACOTE','PACKAGE',null,true),
  ('KIT','KIT','PACKAGE',null,true),('KG','KG','MASS',1,false),('G','G','MASS',1,false),
  ('L','L','VOLUME',1,false),('ML','ML','VOLUME',1,false),('M','M','LENGTH',1,false),
  ('M2','M2','AREA',1,false),('M3','M3','VOLUME',1,false),('H','HORA','TIME',1,false),
  ('DIARIA','DIARIA','TIME',1,false),('SERVICO','SERVICO','SERVICE',1,false)
on conflict (alias) do update set canonical_unit=excluded.canonical_unit,unit_kind=excluded.unit_kind,
  multiplier=excluded.multiplier,requires_package_quantity=excluded.requires_package_quantity,updated_at=now();

create table if not exists bolsa.normalized_items (
  id uuid primary key default gen_random_uuid(),
  catalog_type text,
  catalog_code text,
  normalized_description text not null,
  essential_attributes jsonb not null default '{}'::jsonb,
  normalization_version text not null default 'item-normalization-v1',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (catalog_type,catalog_code,normalized_description)
);
create index if not exists normalized_items_catalog_idx on bolsa.normalized_items(catalog_type,catalog_code);
create index if not exists normalized_items_desc_fts on bolsa.normalized_items using gin(to_tsvector('portuguese',normalized_description));

create table if not exists bolsa.price_observations (
  id bigint generated always as identity primary key,
  normalized_item_id uuid references bolsa.normalized_items(id) on delete set null,
  source_id text not null,
  source_record_id text not null,
  procurement_id text,
  item_number int,
  contract_id text,
  ata_id text,
  supplier_id text,
  supplier_name text,
  agency_id text,
  price_type text not null check (price_type in (
    'ESTIMATED','REFERENCE','INITIAL_PROPOSAL','BID','FINAL','AWARDED','HOMOLOGATED',
    'ATA_REGISTERED','CONTRACTED','COMMITTED','LIQUIDATED','PAID','OFFICIAL_TABLE','QUOTATION','COMPANY_INTERNAL')),
  description_original text,
  description_normalized text,
  catalog_type text,
  catalog_code text,
  brand text,
  model text,
  manufacturer text,
  essential_attributes jsonb not null default '{}'::jsonb,
  quantity numeric,
  original_unit text,
  normalized_unit text,
  package_quantity numeric,
  unit_price_original numeric,
  unit_price_normalized numeric,
  total_price numeric,
  currency text not null default 'BRL',
  reference_date date,
  municipality text,
  state_code text,
  modality text,
  source_url text,
  source_timestamp timestamptz,
  collected_at timestamptz not null default now(),
  quality_score numeric not null default 70 check (quality_score between 0 and 100),
  normalization_status text not null default 'NORMALIZED',
  normalization_version text not null default 'unit-normalization-v1',
  raw_payload jsonb not null default '{}'::jsonb,
  unique (source_id,source_record_id,price_type)
);
create index if not exists price_obs_item_date_idx on bolsa.price_observations(normalized_item_id,reference_date desc);
create index if not exists price_obs_catalog_idx on bolsa.price_observations(catalog_type,catalog_code,reference_date desc);
create index if not exists price_obs_proc_idx on bolsa.price_observations(procurement_id,item_number);
create index if not exists price_obs_supplier_idx on bolsa.price_observations(supplier_id,reference_date desc);
create index if not exists price_obs_agency_idx on bolsa.price_observations(agency_id,reference_date desc);
create index if not exists price_obs_geo_idx on bolsa.price_observations(state_code,municipality,reference_date desc);

create table if not exists bolsa.price_source_links (
  observation_id bigint not null references bolsa.price_observations(id) on delete cascade,
  source_id text not null,
  source_record_id text not null,
  source_url text,
  source_timestamp timestamptz,
  raw_hash text,
  created_at timestamptz not null default now(),
  primary key(observation_id,source_id,source_record_id)
);

-- Materializa o que ja existe sem misturar estimado e homologado.
insert into bolsa.price_observations(
  source_id,source_record_id,procurement_id,item_number,agency_id,price_type,
  description_original,description_normalized,catalog_type,catalog_code,quantity,original_unit,normalized_unit,
  unit_price_original,unit_price_normalized,total_price,reference_date,municipality,state_code,modality,
  source_url,source_timestamp,collected_at,quality_score,normalization_status,raw_payload)
select 'pncp', i.numero_controle_pncp || ':' || i.numero_item,
  i.numero_controle_pncp,i.numero_item,l.orgao_cnpj,'ESTIMATED',i.descricao,lower(trim(i.descricao)),
  case when i.material_ou_servico ilike '%serv%' then 'CATSER' else 'CATMAT' end,i.catalogo_codigo,
  i.quantidade,i.unidade,coalesce(d.canonical_unit,upper(nullif(trim(i.unidade),''))),
  i.valor_unitario_estimado,i.valor_unitario_estimado,i.valor_total_estimado,
  l.data_publicacao_pncp::date,l.municipio_nome,l.uf,l.modalidade_nome,l.link_sistema_origem,
  i.source_updated_at,coalesce(i.last_seen_at,now()),82,
  case when d.requires_package_quantity then 'UNKNOWN_PACKAGE' when nullif(trim(i.unidade),'') is null then 'UNKNOWN_UNIT' else 'NORMALIZED' end,
  jsonb_build_object('item_id',i.id)
from bolsa.itens i join bolsa.licitacoes l using(numero_controle_pncp)
left join bolsa.unit_dictionary d on d.alias=upper(trim(i.unidade))
where i.valor_unitario_estimado>0
on conflict (source_id,source_record_id,price_type) do update set
  unit_price_original=excluded.unit_price_original,total_price=excluded.total_price,
  source_timestamp=excluded.source_timestamp,collected_at=excluded.collected_at,raw_payload=excluded.raw_payload;

insert into bolsa.price_observations(
  source_id,source_record_id,procurement_id,item_number,supplier_id,supplier_name,agency_id,price_type,
  description_original,description_normalized,catalog_type,catalog_code,quantity,original_unit,normalized_unit,
  unit_price_original,unit_price_normalized,total_price,reference_date,municipality,state_code,modality,
  source_url,source_timestamp,collected_at,quality_score,normalization_status,raw_payload)
select 'pncp',r.numero_controle_pncp || ':' || r.numero_item || ':' || coalesce(r.fornecedor_ni,'-') || ':' || coalesce(r.sequencial_resultado,0),
  r.numero_controle_pncp,r.numero_item,r.fornecedor_ni,r.fornecedor_nome,l.orgao_cnpj,'HOMOLOGATED',
  i.descricao,lower(trim(i.descricao)),case when i.material_ou_servico ilike '%serv%' then 'CATSER' else 'CATMAT' end,
  i.catalogo_codigo,r.quantidade_homologada,i.unidade,coalesce(d.canonical_unit,upper(nullif(trim(i.unidade),''))),
  r.valor_unitario_homologado,r.valor_unitario_homologado,r.valor_total_homologado,
  r.data_resultado,l.municipio_nome,l.uf,l.modalidade_nome,l.link_sistema_origem,
  r.last_seen_at,coalesce(r.last_seen_at,now()),94,
  case when d.requires_package_quantity then 'UNKNOWN_PACKAGE' when nullif(trim(i.unidade),'') is null then 'UNKNOWN_UNIT' else 'NORMALIZED' end,
  jsonb_build_object('result_id',r.id,'discount_percent',r.percentual_desconto)
from bolsa.resultados_itens r
join bolsa.itens i on i.numero_controle_pncp=r.numero_controle_pncp and i.numero_item=r.numero_item
join bolsa.licitacoes l using(numero_controle_pncp)
left join bolsa.unit_dictionary d on d.alias=upper(trim(i.unidade))
where r.valor_unitario_homologado>0
on conflict (source_id,source_record_id,price_type) do update set
  unit_price_original=excluded.unit_price_original,total_price=excluded.total_price,
  source_timestamp=excluded.source_timestamp,collected_at=excluded.collected_at,raw_payload=excluded.raw_payload;

create table if not exists public.price_baskets (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.saas_empresas(id) on delete cascade,
  procurement_id text,
  item_number int,
  title text not null,
  status text not null default 'DRAFT' check(status in ('DRAFT','APPROVED','ARCHIVED','NEEDS_REVIEW')),
  price_type text not null default 'HOMOLOGATED',
  target_snapshot jsonb not null default '{}'::jsonb,
  methodology jsonb not null default '{}'::jsonb,
  current_version int not null default 1,
  created_by uuid not null references auth.users(id),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.price_basket_items (
  basket_id uuid not null references public.price_baskets(id) on delete cascade,
  basket_version int not null,
  observation_id bigint not null references bolsa.price_observations(id) on delete restrict,
  included boolean not null default true,
  comparability_score numeric not null default 0,
  possible_outlier boolean not null default false,
  decision_reason text,
  decided_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  primary key(basket_id,basket_version,observation_id)
);

create table if not exists bolsa.change_events (
  id bigint generated always as identity primary key,
  procurement_id text not null,
  entity_type text not null,
  entity_id text not null,
  event_type text not null,
  source_type text not null default 'PUBLIC_OFFICIAL',
  source_id text,
  previous_snapshot jsonb,
  current_snapshot jsonb,
  diff jsonb not null default '{}'::jsonb,
  importance text not null default 'MEDIUM' check(importance in ('LOW','MEDIUM','HIGH','CRITICAL')),
  materiality numeric not null default 0,
  occurred_at timestamptz,
  detected_at timestamptz not null default now(),
  event_key text not null unique
);
create index if not exists change_events_proc_idx on bolsa.change_events(procurement_id,detected_at desc);

create or replace function bolsa.capture_live_change() returns trigger
language plpgsql security definer set search_path=bolsa,public as $$
declare oldj jsonb; newj jsonb; v_key text; v_proc text; v_entity text; v_diff jsonb; v_event text; v_importance text;
begin
  oldj := case when tg_op='INSERT' then '{}'::jsonb else to_jsonb(old) end;
  newj := to_jsonb(new);
  v_proc := coalesce(newj->>'numero_controle_pncp',newj->>'numero_controle_pncp_compra');
  v_entity := coalesce(newj->>'id',newj->>'numero_item',newj->>'sequencial_documento',v_proc);
  select coalesce(jsonb_object_agg(k,jsonb_build_object('before',oldj->k,'after',newj->k)),'{}'::jsonb)
    into v_diff from jsonb_object_keys(newj) k
   where oldj->k is distinct from newj->k
     and k not in ('source_payload','last_seen_at','first_seen_at','itens_coletados_em','arquivos_coletados_em','resultados_coletados_em');
  if tg_op='UPDATE' and v_diff='{}'::jsonb then return new; end if;
  v_event := case when tg_table_name='documentos' and tg_op='INSERT' then 'NEW_DOCUMENT'
                  when tg_table_name='documentos' then 'DOCUMENT_UPDATED'
                  else 'PROCUREMENT_UPDATED' end;
  v_importance := case when v_diff ?| array['data_encerramento_proposta','data_abertura_proposta','situacao_nome','valor_total_estimado'] then 'HIGH' else 'MEDIUM' end;
  v_key := md5(tg_table_name || ':' || coalesce(v_entity,'-') || ':' || v_event || ':' || v_diff::text);
  insert into bolsa.change_events(procurement_id,entity_type,entity_id,event_type,source_id,
    previous_snapshot,current_snapshot,diff,importance,materiality,occurred_at,event_key)
  values(v_proc,tg_table_name,coalesce(v_entity,'-'),v_event,'pncp',nullif(oldj,'{}'::jsonb),newj,v_diff,v_importance,
    case when v_importance='HIGH' then 80 else 40 end,coalesce((newj->>'source_updated_at')::timestamptz,now()),v_key)
  on conflict(event_key) do nothing;
  return new;
end $$;

drop trigger if exists live_licitacao_change on bolsa.licitacoes;
create trigger live_licitacao_change after update on bolsa.licitacoes for each row execute function bolsa.capture_live_change();
drop trigger if exists live_document_change on bolsa.documentos;
create trigger live_document_change after insert or update on bolsa.documentos for each row execute function bolsa.capture_live_change();

create table if not exists public.live_change_impacts (
  id bigint generated always as identity primary key,
  change_event_id bigint not null references bolsa.change_events(id) on delete cascade,
  company_id uuid not null references public.saas_empresas(id) on delete cascade,
  procurement_id text not null,
  target_type text not null,
  target_id text,
  impact_type text not null default 'INFORMATIONAL',
  impact_level text not null default 'MEDIUM' check(impact_level in ('NONE','LOW','MEDIUM','HIGH','CRITICAL')),
  action text not null default 'REVIEW',
  status text not null default 'PENDING' check(status in ('PENDING','PROCESSING','UPDATED','REVIEW_REQUIRED','REVIEWED','IGNORED','FAILED')),
  explanation text,
  processed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  unique(change_event_id,company_id,target_type,target_id)
);
create index if not exists live_impacts_attention_idx on public.live_change_impacts(company_id,status,impact_level,procurement_id);

create table if not exists public.user_update_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  change_event_id bigint not null references bolsa.change_events(id) on delete cascade,
  seen_at timestamptz,
  read_at timestamptz,
  reviewed_at timestamptz,
  primary key(user_id,change_event_id)
);

create table if not exists public.recalculation_jobs (
  id bigint generated always as identity primary key,
  company_id uuid references public.saas_empresas(id) on delete cascade,
  procurement_id text not null,
  trigger_event_id bigint references bolsa.change_events(id) on delete set null,
  dependency_type text not null,
  dependency_id text,
  priority int not null default 50,
  status text not null default 'PENDING' check(status in ('PENDING','PROCESSING','COMPLETE','FAILED','DEAD_LETTER')),
  attempts int not null default 0,
  next_attempt_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  error text,
  idempotency_key text not null unique,
  created_at timestamptz not null default now()
);
create index if not exists recalculation_jobs_queue_idx on public.recalculation_jobs(status,next_attempt_at,priority desc);

alter table public.saas_monitores add column if not exists company_id uuid references public.saas_empresas(id) on delete cascade;
alter table public.saas_monitores add column if not exists owner_user_id uuid references auth.users(id) on delete set null;
alter table public.saas_monitores add column if not exists digest_frequency text not null default 'DAILY';
alter table public.saas_monitor_matches add column if not exists relevance_score numeric;
alter table public.saas_monitor_matches add column if not exists score_components jsonb not null default '{}'::jsonb;
alter table public.saas_monitor_matches add column if not exists match_reasons jsonb not null default '[]'::jsonb;
alter table public.saas_monitor_matches add column if not exists previous_score numeric;
alter table public.saas_monitor_matches add column if not exists enrichment_status text not null default 'BASIC_DATA';
update public.saas_monitores m set owner_user_id=m.user_id where owner_user_id is null;
update public.saas_monitores m set company_id=em.company_id
from public.saas_empresa_membros em where em.user_id=m.user_id and m.company_id is null;

create table if not exists public.saas_monitor_feedback (
  id bigint generated always as identity primary key,
  monitor_id bigint not null references public.saas_monitores(id) on delete cascade,
  entity_type text not null,
  entity_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  feedback text not null check(feedback in ('RELEVANT','NOT_RELEVANT')),
  reason text,
  created_at timestamptz not null default now(),
  unique(monitor_id,entity_type,entity_id,user_id)
);

alter table bolsa.unit_dictionary enable row level security;
alter table bolsa.normalized_items enable row level security;
alter table bolsa.price_observations enable row level security;
alter table bolsa.price_source_links enable row level security;
alter table bolsa.change_events enable row level security;
alter table public.price_baskets enable row level security;
alter table public.price_basket_items enable row level security;
alter table public.live_change_impacts enable row level security;
alter table public.user_update_state enable row level security;
alter table public.recalculation_jobs enable row level security;
alter table public.saas_monitor_feedback enable row level security;

drop policy if exists price_units_public on bolsa.unit_dictionary;
create policy price_units_public on bolsa.unit_dictionary for select to anon,authenticated using(true);
drop policy if exists normalized_items_public on bolsa.normalized_items;
create policy normalized_items_public on bolsa.normalized_items for select to anon,authenticated using(true);
drop policy if exists price_observations_public on bolsa.price_observations;
create policy price_observations_public on bolsa.price_observations for select to anon,authenticated using(true);
drop policy if exists price_links_public on bolsa.price_source_links;
create policy price_links_public on bolsa.price_source_links for select to anon,authenticated using(true);
drop policy if exists change_events_public on bolsa.change_events;
create policy change_events_public on bolsa.change_events for select to anon,authenticated using(true);

drop policy if exists price_baskets_company on public.price_baskets;
create policy price_baskets_company on public.price_baskets for all to authenticated
  using(public.saas_company_can(company_id,'view')) with check(public.saas_company_can(company_id,'edit'));
drop policy if exists price_basket_items_company on public.price_basket_items;
create policy price_basket_items_company on public.price_basket_items for all to authenticated
  using(exists(select 1 from public.price_baskets b where b.id=basket_id and public.saas_company_can(b.company_id,'view')))
  with check(exists(select 1 from public.price_baskets b where b.id=basket_id and public.saas_company_can(b.company_id,'edit')));
drop policy if exists live_impacts_company on public.live_change_impacts;
create policy live_impacts_company on public.live_change_impacts for all to authenticated
  using(public.saas_company_can(company_id,'view')) with check(public.saas_company_can(company_id,'edit'));
drop policy if exists update_state_user on public.user_update_state;
create policy update_state_user on public.user_update_state for all to authenticated
  using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists recalculation_jobs_company on public.recalculation_jobs;
create policy recalculation_jobs_company on public.recalculation_jobs for select to authenticated
  using(company_id is not null and public.saas_company_can(company_id,'view'));
drop policy if exists monitor_feedback_user on public.saas_monitor_feedback;
create policy monitor_feedback_user on public.saas_monitor_feedback for all to authenticated
  using(user_id=auth.uid() or exists(select 1 from public.saas_monitores m where m.id=monitor_id and m.user_id=auth.uid()))
  with check(user_id=auth.uid() and exists(select 1 from public.saas_monitores m where m.id=monitor_id and m.user_id=auth.uid()));

grant select on bolsa.unit_dictionary,bolsa.normalized_items,bolsa.price_observations,bolsa.price_source_links,bolsa.change_events to anon,authenticated;

create or replace function public.bolsa_procurement_changes(p_procurement_id text,p_limit int default 50)
returns jsonb language sql stable security definer set search_path=public,bolsa as $$
  select jsonb_build_object(
    'procurement_id',p_procurement_id,
    'events',coalesce(jsonb_agg(row_to_json(e) order by e.detected_at desc),'[]'::jsonb),
    'unread',(select count(*) from bolsa.change_events c where c.procurement_id=p_procurement_id
      and not exists(select 1 from public.user_update_state s where s.change_event_id=c.id and s.user_id=auth.uid() and s.read_at is not null))
  ) from (select id,entity_type,entity_id,event_type,source_type,source_id,diff,importance,materiality,occurred_at,detected_at
          from bolsa.change_events where procurement_id=p_procurement_id order by detected_at desc limit least(greatest(p_limit,1),200)) e;
$$;
grant execute on function public.bolsa_procurement_changes(text,int) to anon,authenticated;

create or replace function public.bolsa_mark_updates_read(p_event_ids bigint[])
returns int language plpgsql security definer set search_path=public,bolsa as $$
declare v_uid uuid:=auth.uid(); v_count int;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;
  insert into public.user_update_state(user_id,change_event_id,seen_at,read_at)
  select v_uid,id,now(),now() from bolsa.change_events where id=any(p_event_ids)
  on conflict(user_id,change_event_id) do update set seen_at=coalesce(public.user_update_state.seen_at,now()),read_at=now();
  get diagnostics v_count=row_count; return v_count;
end $$;
grant execute on function public.bolsa_mark_updates_read(bigint[]) to authenticated;

create or replace function public.ai_artifact_list(p_procurement_id text)
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(row_to_json(x) order by x.updated_at desc),'[]'::jsonb) from (
    select a.id,a.procurement_id,a.type,a.title,a.status,a.freshness,a.favorite,a.pinned,a.lock_version,
      a.created_at,a.updated_at,v.id version_id,v.version_number,v.content,v.content_format,v.structured_data,
      v.generation_type,v.change_summary,v.created_at version_created_at,
      (select count(*) from public.ai_artifact_versions av where av.artifact_id=a.id) versions
    from public.ai_artifacts a left join public.ai_artifact_versions v on v.id=a.current_version_id
    where a.procurement_id=p_procurement_id and a.archived_at is null and public.saas_company_can(a.company_id,'view')
  ) x;
$$;
grant execute on function public.ai_artifact_list(text) to authenticated;

comment on table bolsa.price_observations is 'Fatos publicos de preco tipados; valores originais nunca sao sobrescritos por normalizacao.';
comment on table bolsa.change_events is 'Mudancas oficiais globais processadas uma vez e reutilizadas por monitores e empresas.';
