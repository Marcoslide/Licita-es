-- BOLSA DE LICITACOES -- mesa privada de precificacao por empresa.
-- Depende de 20260903183000_ai_artifacts.sql (empresas e saas_company_can).
-- Valores monetarios criticos sao armazenados em centavos; percentuais em basis points.

create table if not exists public.procurement_pricing_workspaces (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.saas_empresas(id) on delete cascade,
  procurement_id text not null,
  scope_type text not null default 'GLOBAL' check(scope_type in ('GLOBAL','LOT','ITEM')),
  scope_id text not null default '',
  status text not null default 'DRAFT' check(status in ('DRAFT','IN_REVIEW','APPROVED','AWARDED','ARCHIVED')),
  current_payload jsonb not null default '{}'::jsonb,
  current_version integer not null default 0,
  lock_version integer not null default 1,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique(company_id,procurement_id,scope_type,scope_id)
);
create index if not exists pricing_workspace_proc_idx
  on public.procurement_pricing_workspaces(company_id,procurement_id,updated_at desc)
  where archived_at is null;

create table if not exists public.procurement_pricing_cost_components (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.procurement_pricing_workspaces(id) on delete cascade,
  name text not null,
  category text not null check(category in ('DIRECT','INDIRECT','TAX','LOGISTICS','COMMERCIAL','FINANCIAL','RISK','OTHER')),
  calculation_type text not null check(calculation_type in ('AMOUNT','PER_UNIT','PERCENT_REVENUE')),
  amount_cents bigint not null default 0 check(amount_cents >= 0),
  unit_cost_cents bigint not null default 0 check(unit_cost_cents >= 0),
  quantity numeric(20,6) not null default 0 check(quantity >= 0),
  revenue_rate_bps integer not null default 0 check(revenue_rate_bps between 0 and 9999),
  minimum_cents bigint not null default 0 check(minimum_cents >= 0),
  locked boolean not null default false,
  reducible boolean not null default true,
  supplier_name text,
  quoted_at date,
  valid_until date,
  source_note text,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists pricing_components_workspace_idx
  on public.procurement_pricing_cost_components(workspace_id,position,id);

create table if not exists public.procurement_pricing_scenarios (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.procurement_pricing_workspaces(id) on delete cascade,
  name text not null,
  sale_price_cents bigint not null check(sale_price_cents >= 0),
  desired_margin_bps integer not null default 0,
  minimum_margin_bps integer not null default 0,
  result jsonb not null default '{}'::jsonb,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists pricing_scenarios_workspace_idx
  on public.procurement_pricing_scenarios(workspace_id,updated_at desc);

create table if not exists public.procurement_pricing_versions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.procurement_pricing_workspaces(id) on delete cascade,
  version_number integer not null,
  payload jsonb not null,
  change_summary text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(workspace_id,version_number)
);

create table if not exists public.procurement_pricing_approvals (
  id bigint generated always as identity primary key,
  workspace_id uuid not null references public.procurement_pricing_workspaces(id) on delete cascade,
  version_number integer not null,
  decision text not null check(decision in ('SUBMITTED','APPROVED','REJECTED','REOPENED')),
  note text,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

alter table public.procurement_pricing_workspaces enable row level security;
alter table public.procurement_pricing_cost_components enable row level security;
alter table public.procurement_pricing_scenarios enable row level security;
alter table public.procurement_pricing_versions enable row level security;
alter table public.procurement_pricing_approvals enable row level security;

drop policy if exists pricing_workspace_company on public.procurement_pricing_workspaces;
create policy pricing_workspace_company on public.procurement_pricing_workspaces for all to authenticated
  using(public.saas_company_can(company_id,'view'))
  with check(public.saas_company_can(company_id,'edit'));
drop policy if exists pricing_components_company on public.procurement_pricing_cost_components;
create policy pricing_components_company on public.procurement_pricing_cost_components for all to authenticated
  using(exists(select 1 from public.procurement_pricing_workspaces w where w.id=workspace_id and public.saas_company_can(w.company_id,'view')))
  with check(exists(select 1 from public.procurement_pricing_workspaces w where w.id=workspace_id and public.saas_company_can(w.company_id,'edit')));
drop policy if exists pricing_scenarios_company on public.procurement_pricing_scenarios;
create policy pricing_scenarios_company on public.procurement_pricing_scenarios for all to authenticated
  using(exists(select 1 from public.procurement_pricing_workspaces w where w.id=workspace_id and public.saas_company_can(w.company_id,'view')))
  with check(exists(select 1 from public.procurement_pricing_workspaces w where w.id=workspace_id and public.saas_company_can(w.company_id,'edit')));
drop policy if exists pricing_versions_company on public.procurement_pricing_versions;
create policy pricing_versions_company on public.procurement_pricing_versions for select to authenticated
  using(exists(select 1 from public.procurement_pricing_workspaces w where w.id=workspace_id and public.saas_company_can(w.company_id,'view')));
drop policy if exists pricing_approvals_company on public.procurement_pricing_approvals;
create policy pricing_approvals_company on public.procurement_pricing_approvals for all to authenticated
  using(exists(select 1 from public.procurement_pricing_workspaces w where w.id=workspace_id and public.saas_company_can(w.company_id,'view')))
  with check(exists(select 1 from public.procurement_pricing_workspaces w where w.id=workspace_id and public.saas_company_can(w.company_id,'review')));

create or replace function public.pricing_workspace_get(
  p_procurement_id text,
  p_scope_type text default 'GLOBAL',
  p_scope_id text default ''
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_company uuid; v_result jsonb;
begin
  select company_id into v_company from public.saas_empresa_membros
   where user_id=auth.uid() order by criado_em limit 1;
  if v_company is null then return null; end if;
  select jsonb_build_object(
    'id',w.id,'company_id',w.company_id,'procurement_id',w.procurement_id,
    'scope_type',w.scope_type,'scope_id',w.scope_id,'status',w.status,
    'payload',w.current_payload,'current_version',w.current_version,
    'lock_version',w.lock_version,'updated_at',w.updated_at)
    into v_result
    from public.procurement_pricing_workspaces w
   where w.company_id=v_company and w.procurement_id=p_procurement_id
     and w.scope_type=p_scope_type and w.scope_id=coalesce(p_scope_id,'') and w.archived_at is null;
  return v_result;
end $$;
grant execute on function public.pricing_workspace_get(text,text,text) to authenticated;

create or replace function public.pricing_workspace_save(
  p_procurement_id text,
  p_payload jsonb,
  p_scope_type text default 'GLOBAL',
  p_scope_id text default '',
  p_expected_lock_version integer default null,
  p_change_summary text default 'Precificacao atualizada'
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_company uuid; v_workspace public.procurement_pricing_workspaces%rowtype; v_version integer;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;
  v_company:=public.saas_ensure_my_company();
  select * into v_workspace from public.procurement_pricing_workspaces
   where company_id=v_company and procurement_id=p_procurement_id
     and scope_type=p_scope_type and scope_id=coalesce(p_scope_id,'') and archived_at is null for update;
  if v_workspace.id is null then
    insert into public.procurement_pricing_workspaces(
      company_id,procurement_id,scope_type,scope_id,current_payload,current_version,created_by,updated_by)
    values(v_company,p_procurement_id,p_scope_type,coalesce(p_scope_id,''),coalesce(p_payload,'{}'::jsonb),1,v_uid,v_uid)
    returning * into v_workspace;
    v_version:=1;
  else
    if p_expected_lock_version is not null and v_workspace.lock_version<>p_expected_lock_version then
      raise exception 'VERSION_CONFLICT';
    end if;
    v_version:=v_workspace.current_version+1;
    update public.procurement_pricing_workspaces set
      current_payload=coalesce(p_payload,'{}'::jsonb),current_version=v_version,
      lock_version=lock_version+1,updated_by=v_uid,updated_at=now()
      where id=v_workspace.id returning * into v_workspace;
  end if;
  insert into public.procurement_pricing_versions(workspace_id,version_number,payload,change_summary,created_by)
  values(v_workspace.id,v_version,coalesce(p_payload,'{}'::jsonb),p_change_summary,v_uid);
  insert into public.recalculation_jobs(company_id,procurement_id,dependency_type,dependency_id,status,idempotency_key)
  values(v_company,p_procurement_id,'PRIVATE_PRICING',v_workspace.id::text,'PENDING',
    md5(v_workspace.id::text||':'||v_version::text||':PRIVATE_PRICING')) on conflict(idempotency_key) do nothing;
  return jsonb_build_object('id',v_workspace.id,'company_id',v_company,'current_version',v_version,
    'lock_version',v_workspace.lock_version,'updated_at',v_workspace.updated_at);
end $$;
grant execute on function public.pricing_workspace_save(text,jsonb,text,text,integer,text) to authenticated;

grant select,insert,update,delete on public.procurement_pricing_workspaces,
  public.procurement_pricing_cost_components,public.procurement_pricing_scenarios,
  public.procurement_pricing_approvals to authenticated;
grant select on public.procurement_pricing_versions to authenticated;
grant usage,select on sequence public.procurement_pricing_approvals_id_seq to authenticated;
