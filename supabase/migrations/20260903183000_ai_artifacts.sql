-- BOLSA DE LICITACOES -- memoria operacional e estrategica por empresa.
-- Estrutura isolada das tabelas de coleta. Nenhum dado publico e duplicado aqui.

create table if not exists public.saas_empresas (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  criado_por uuid not null references auth.users(id) on delete restrict,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  arquivado_em timestamptz
);

create table if not exists public.saas_empresa_membros (
  company_id uuid not null references public.saas_empresas(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  papel text not null default 'membro' check (papel in ('proprietario','admin','editor','revisor','leitor')),
  criado_em timestamptz not null default now(),
  primary key (company_id, user_id)
);
create index if not exists saas_empresa_membros_user_idx on public.saas_empresa_membros(user_id, company_id);

create or replace function public.saas_company_role(p_company uuid)
returns text language sql stable security definer set search_path = public as $$
  select papel from public.saas_empresa_membros
  where company_id = p_company and user_id = auth.uid() limit 1;
$$;
grant execute on function public.saas_company_role(uuid) to authenticated;

create or replace function public.saas_company_can(p_company uuid, p_action text default 'view')
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when public.saas_is_admin() then true
    when p_action = 'view' then public.saas_company_role(p_company) is not null
    when p_action = 'comment' then public.saas_company_role(p_company) in ('proprietario','admin','editor','revisor')
    when p_action = 'review' then public.saas_company_role(p_company) in ('proprietario','admin','revisor')
    else public.saas_company_role(p_company) in ('proprietario','admin','editor')
  end;
$$;
grant execute on function public.saas_company_can(uuid, text) to authenticated;

create or replace function public.saas_ensure_my_company()
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_company uuid; v_name text;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;
  select company_id into v_company from public.saas_empresa_membros
   where user_id = v_uid order by criado_em limit 1;
  if v_company is not null then return v_company; end if;
  select nullif(trim(concat_ws(' ', nome, sobrenome)), '') into v_name
    from public.saas_perfis where user_id = v_uid;
  insert into public.saas_empresas(nome, criado_por)
  values (coalesce(v_name, 'Minha empresa'), v_uid) returning id into v_company;
  insert into public.saas_empresa_membros(company_id, user_id, papel)
  values (v_company, v_uid, 'proprietario');
  return v_company;
end $$;
grant execute on function public.saas_ensure_my_company() to authenticated;

create table if not exists public.ai_artifacts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.saas_empresas(id) on delete restrict,
  procurement_id text not null,
  type text not null,
  title text not null,
  status text not null default 'RASCUNHO' check (status in ('RASCUNHO','EM_REVISAO','APROVADO','PRECISA_ATUALIZACAO','DESATUALIZADO','ARQUIVADO','BLOQUEADO')),
  freshness text not null default 'ATUALIZADO' check (freshness in ('ATUALIZADO','POSSIVEL_IMPACTO','IMPACTO_CONFIRMADO','DESATUALIZADO')),
  current_version_id uuid,
  owner_user_id uuid references auth.users(id) on delete set null,
  reviewer_user_id uuid references auth.users(id) on delete set null,
  approver_user_id uuid references auth.users(id) on delete set null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  favorite boolean not null default false,
  pinned boolean not null default false,
  lock_version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);
create index if not exists ai_artifacts_company_proc_idx on public.ai_artifacts(company_id, procurement_id, updated_at desc);
create index if not exists ai_artifacts_attention_idx on public.ai_artifacts(company_id, status, freshness) where archived_at is null;

create table if not exists public.ai_artifact_versions (
  id uuid primary key default gen_random_uuid(),
  artifact_id uuid not null references public.ai_artifacts(id) on delete cascade,
  version_number integer not null,
  content text not null default '',
  content_format text not null default 'html' check (content_format in ('html','markdown','text','json')),
  structured_data jsonb not null default '{}'::jsonb,
  generation_type text not null check (generation_type in ('AI_GENERATED','HUMAN_CREATED','AI_ASSISTED','HUMAN_EDITED','SYSTEM_GENERATED','RESTORED')),
  ai_model_reference text,
  source_snapshot jsonb not null default '[]'::jsonb,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  change_summary text,
  approved_at timestamptz,
  approved_by_user_id uuid references auth.users(id) on delete set null,
  frozen_at timestamptz,
  restored_from_version_id uuid references public.ai_artifact_versions(id),
  unique (artifact_id, version_number)
);
alter table public.ai_artifacts drop constraint if exists ai_artifacts_current_version_fk;
alter table public.ai_artifacts add constraint ai_artifacts_current_version_fk
  foreign key (current_version_id) references public.ai_artifact_versions(id) deferrable initially deferred;
create index if not exists ai_artifact_versions_artifact_idx on public.ai_artifact_versions(artifact_id, version_number desc);

create table if not exists public.ai_artifact_sources (
  id bigint generated always as identity primary key,
  artifact_version_id uuid not null references public.ai_artifact_versions(id) on delete cascade,
  source_type text not null,
  source_id text,
  document_id text,
  document_version_id text,
  page_number integer,
  clause text,
  source_record_id text,
  source_url text,
  source_label text,
  classification text not null default 'FATO_DE_FONTE' check (classification in ('FATO_DE_FONTE','DADO_INTERNO','ANALISE','INFERENCIA','RECOMENDACAO')),
  snapshot_at timestamptz not null default now()
);
create index if not exists ai_artifact_sources_version_idx on public.ai_artifact_sources(artifact_version_id);

create table if not exists public.ai_artifact_dependencies (
  artifact_id uuid not null references public.ai_artifacts(id) on delete cascade,
  depends_on_type text not null,
  depends_on_id text not null,
  impact_status text not null default 'SEM_IMPACTO' check (impact_status in ('SEM_IMPACTO','POSSIVEL_IMPACTO','IMPACTO_CONFIRMADO')),
  dependency_snapshot jsonb not null default '{}'::jsonb,
  checked_at timestamptz not null default now(),
  primary key (artifact_id, depends_on_type, depends_on_id)
);

create table if not exists public.ai_artifact_comments (
  id uuid primary key default gen_random_uuid(),
  artifact_id uuid not null references public.ai_artifacts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete restrict,
  parent_id uuid references public.ai_artifact_comments(id) on delete cascade,
  content text not null,
  mentions uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete set null
);
create index if not exists ai_artifact_comments_artifact_idx on public.ai_artifact_comments(artifact_id, created_at);

create table if not exists public.ai_artifact_tasks (
  id uuid primary key default gen_random_uuid(),
  artifact_id uuid not null references public.ai_artifacts(id) on delete cascade,
  company_id uuid not null references public.saas_empresas(id) on delete restrict,
  procurement_id text not null,
  title text not null,
  description text,
  status text not null default 'PENDENTE' check (status in ('PENDENTE','EM_ANDAMENTO','CONCLUIDA','CANCELADA')),
  priority text not null default 'NORMAL' check (priority in ('BAIXA','NORMAL','ALTA','CRITICA')),
  responsible_user_id uuid references auth.users(id) on delete set null,
  due_at timestamptz,
  agenda_event_key text,
  source_excerpt text,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ai_artifact_tasks_company_idx on public.ai_artifact_tasks(company_id, status, due_at);

create table if not exists public.ai_artifact_events (
  id bigint generated always as identity primary key,
  artifact_id uuid not null references public.ai_artifacts(id) on delete cascade,
  company_id uuid not null references public.saas_empresas(id) on delete restrict,
  event_type text not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  version_id uuid references public.ai_artifact_versions(id) on delete set null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists ai_artifact_events_artifact_idx on public.ai_artifact_events(artifact_id, created_at desc);

create table if not exists public.ai_artifact_exports (
  id bigint generated always as identity primary key,
  artifact_id uuid not null references public.ai_artifacts(id) on delete cascade,
  version_id uuid not null references public.ai_artifact_versions(id) on delete restrict,
  company_id uuid not null references public.saas_empresas(id) on delete restrict,
  exported_by_user_id uuid not null references auth.users(id) on delete restrict,
  format text not null check (format in ('PRINT','PDF','DOCX','HTML')),
  created_at timestamptz not null default now()
);

alter table public.saas_empresas enable row level security;
alter table public.saas_empresa_membros enable row level security;
alter table public.ai_artifacts enable row level security;
alter table public.ai_artifact_versions enable row level security;
alter table public.ai_artifact_sources enable row level security;
alter table public.ai_artifact_dependencies enable row level security;
alter table public.ai_artifact_comments enable row level security;
alter table public.ai_artifact_tasks enable row level security;
alter table public.ai_artifact_events enable row level security;
alter table public.ai_artifact_exports enable row level security;

create policy empresas_select on public.saas_empresas for select to authenticated
  using (public.saas_company_can(id, 'view'));
create policy membros_select on public.saas_empresa_membros for select to authenticated
  using (public.saas_company_can(company_id, 'view'));

create policy artifacts_select on public.ai_artifacts for select to authenticated
  using (public.saas_company_can(company_id, 'view'));
create policy artifacts_insert on public.ai_artifacts for insert to authenticated
  with check (public.saas_company_can(company_id, 'edit') and created_by_user_id = auth.uid());
create policy artifacts_update on public.ai_artifacts for update to authenticated
  using (public.saas_company_can(company_id, 'edit')) with check (public.saas_company_can(company_id, 'edit'));

create policy versions_select on public.ai_artifact_versions for select to authenticated
  using (exists(select 1 from public.ai_artifacts a where a.id=artifact_id and public.saas_company_can(a.company_id,'view')));
create policy versions_insert on public.ai_artifact_versions for insert to authenticated
  with check (created_by_user_id=auth.uid() and exists(select 1 from public.ai_artifacts a where a.id=artifact_id and public.saas_company_can(a.company_id,'edit')));
create policy versions_update on public.ai_artifact_versions for update to authenticated
  using (created_by_user_id=auth.uid() and exists(select 1 from public.ai_artifacts a where a.id=artifact_id and public.saas_company_can(a.company_id,'edit')));

create policy sources_all on public.ai_artifact_sources for all to authenticated
  using (exists(select 1 from public.ai_artifact_versions v join public.ai_artifacts a on a.id=v.artifact_id where v.id=artifact_version_id and public.saas_company_can(a.company_id,'view')))
  with check (exists(select 1 from public.ai_artifact_versions v join public.ai_artifacts a on a.id=v.artifact_id where v.id=artifact_version_id and public.saas_company_can(a.company_id,'edit')));
create policy dependencies_all on public.ai_artifact_dependencies for all to authenticated
  using (exists(select 1 from public.ai_artifacts a where a.id=artifact_id and public.saas_company_can(a.company_id,'view')))
  with check (exists(select 1 from public.ai_artifacts a where a.id=artifact_id and public.saas_company_can(a.company_id,'edit')));
create policy comments_select on public.ai_artifact_comments for select to authenticated
  using (exists(select 1 from public.ai_artifacts a where a.id=artifact_id and public.saas_company_can(a.company_id,'view')));
create policy comments_insert on public.ai_artifact_comments for insert to authenticated
  with check (user_id=auth.uid() and exists(select 1 from public.ai_artifacts a where a.id=artifact_id and public.saas_company_can(a.company_id,'comment')));
create policy comments_update on public.ai_artifact_comments for update to authenticated
  using (user_id=auth.uid() or exists(select 1 from public.ai_artifacts a where a.id=artifact_id and public.saas_company_can(a.company_id,'review')));
create policy tasks_all on public.ai_artifact_tasks for all to authenticated
  using (public.saas_company_can(company_id,'view')) with check (public.saas_company_can(company_id,'edit'));
create policy events_select on public.ai_artifact_events for select to authenticated
  using (public.saas_company_can(company_id,'view'));
create policy exports_select on public.ai_artifact_exports for select to authenticated
  using (public.saas_company_can(company_id,'view'));
create policy exports_insert on public.ai_artifact_exports for insert to authenticated
  with check (exported_by_user_id=auth.uid() and public.saas_company_can(company_id,'view'));

create or replace function public.ai_artifact_create(
  p_procurement_id text, p_type text, p_title text, p_content text default '',
  p_generation_type text default 'HUMAN_CREATED', p_structured_data jsonb default '{}'::jsonb,
  p_source_snapshot jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid:=auth.uid(); v_company uuid; v_artifact uuid; v_version uuid;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;
  v_company := public.saas_ensure_my_company();
  insert into public.ai_artifacts(company_id,procurement_id,type,title,owner_user_id,created_by_user_id)
  values(v_company,left(p_procurement_id,160),left(p_type,80),left(p_title,180),v_uid,v_uid) returning id into v_artifact;
  insert into public.ai_artifact_versions(artifact_id,version_number,content,structured_data,generation_type,source_snapshot,created_by_user_id,change_summary)
  values(v_artifact,1,coalesce(p_content,''),coalesce(p_structured_data,'{}'),p_generation_type,coalesce(p_source_snapshot,'[]'),v_uid,'Versao inicial') returning id into v_version;
  update public.ai_artifacts set current_version_id=v_version where id=v_artifact;
  insert into public.ai_artifact_events(artifact_id,company_id,event_type,actor_user_id,version_id)
  values(v_artifact,v_company,'CREATED',v_uid,v_version);
  return jsonb_build_object('artifact_id',v_artifact,'version_id',v_version,'version_number',1,'lock_version',1,'company_id',v_company);
end $$;
grant execute on function public.ai_artifact_create(text,text,text,text,text,jsonb,jsonb) to authenticated;

create or replace function public.ai_artifact_save_version(
  p_artifact_id uuid, p_content text, p_change_summary text,
  p_generation_type text default 'HUMAN_EDITED', p_expected_lock_version integer default null,
  p_structured_data jsonb default '{}'::jsonb, p_source_snapshot jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid:=auth.uid(); a public.ai_artifacts; v_number integer; v_version uuid;
begin
  select * into a from public.ai_artifacts where id=p_artifact_id for update;
  if a.id is null or not public.saas_company_can(a.company_id,'edit') then raise exception 'FORBIDDEN'; end if;
  if p_expected_lock_version is not null and a.lock_version<>p_expected_lock_version then raise exception 'ARTIFACT_CONFLICT'; end if;
  select coalesce(max(version_number),0)+1 into v_number from public.ai_artifact_versions where artifact_id=a.id;
  insert into public.ai_artifact_versions(artifact_id,version_number,content,structured_data,generation_type,source_snapshot,created_by_user_id,change_summary)
  values(a.id,v_number,coalesce(p_content,''),coalesce(p_structured_data,'{}'),p_generation_type,coalesce(p_source_snapshot,'[]'),v_uid,nullif(trim(p_change_summary),'')) returning id into v_version;
  update public.ai_artifacts set current_version_id=v_version,updated_at=now(),lock_version=lock_version+1,
    status=case when status='APROVADO' then 'RASCUNHO' else status end where id=a.id;
  insert into public.ai_artifact_events(artifact_id,company_id,event_type,actor_user_id,version_id,details)
  values(a.id,a.company_id,'VERSION_CREATED',v_uid,v_version,jsonb_build_object('summary',p_change_summary,'generation_type',p_generation_type));
  return jsonb_build_object('version_id',v_version,'version_number',v_number,'lock_version',a.lock_version+1);
end $$;
grant execute on function public.ai_artifact_save_version(uuid,text,text,text,integer,jsonb,jsonb) to authenticated;

create or replace function public.ai_artifact_approve(p_artifact_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid:=auth.uid(); a public.ai_artifacts;
begin
  select * into a from public.ai_artifacts where id=p_artifact_id for update;
  if a.id is null or not public.saas_company_can(a.company_id,'review') then raise exception 'FORBIDDEN'; end if;
  update public.ai_artifacts set status='APROVADO',approver_user_id=v_uid,updated_at=now(),lock_version=lock_version+1 where id=a.id;
  update public.ai_artifact_versions set approved_at=now(),approved_by_user_id=v_uid where id=a.current_version_id;
  insert into public.ai_artifact_events(artifact_id,company_id,event_type,actor_user_id,version_id) values(a.id,a.company_id,'APPROVED',v_uid,a.current_version_id);
  return jsonb_build_object('status','APROVADO','lock_version',a.lock_version+1);
end $$;
grant execute on function public.ai_artifact_approve(uuid) to authenticated;

comment on table public.ai_artifacts is 'Artefatos privados e company-scoped; conteudo corrente vive em ai_artifact_versions.';
comment on column public.ai_artifact_versions.source_snapshot is 'Dependencias e fontes usadas na geracao, sem chain-of-thought.';
