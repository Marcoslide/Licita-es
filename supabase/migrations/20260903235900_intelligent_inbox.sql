-- BOLSA DE LICITACOES -- Caixa de Entrada Inteligente.
-- Reutiliza saas_monitor_eventos, bolsa.change_events e ai_artifact_events.
-- A Inbox trata atencao por usuario; Timeline e eventos oficiais continuam sendo a origem auditavel.

create table if not exists public.saas_inbox_messages (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.saas_empresas(id) on delete cascade,
  event_key text not null,
  thread_key text not null,
  grouping_key text,
  source_event_type text not null,
  source_event_id text,
  entity_type text not null,
  entity_id text not null,
  category text not null,
  priority text not null check (priority in ('CRITICAL','HIGH','MEDIUM','LOW','SILENT')),
  importance_score integer not null default 50 check (importance_score between 0 and 100),
  subject text not null,
  preview text not null default '',
  body text not null default '',
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  requires_action boolean not null default false,
  source jsonb not null default '[]'::jsonb,
  related_url text,
  metadata jsonb not null default '{}'::jsonb,
  group_count integer not null default 1,
  first_event_at timestamptz not null,
  last_event_at timestamptz not null,
  unique (company_id,event_key)
);

create table if not exists public.saas_inbox_recipients (
  message_id uuid not null references public.saas_inbox_messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  seen_at timestamptz,
  read_at timestamptz,
  archived_at timestamptz,
  snoozed_until timestamptz,
  is_important boolean not null default false,
  assigned_to uuid references auth.users(id) on delete set null,
  action_status text not null default 'NEW' check (action_status in (
    'NEW','READ','ACTION_REQUIRED','IN_PROGRESS','RESOLVED','SNOOZED','ARCHIVED'
  )),
  resolved_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (message_id,user_id)
);

create table if not exists public.saas_inbox_event_receipts (
  company_id uuid not null references public.saas_empresas(id) on delete cascade,
  event_key text not null,
  message_id uuid references public.saas_inbox_messages(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (company_id,event_key)
);

create table if not exists public.saas_inbox_threads (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.saas_empresas(id) on delete cascade,
  thread_key text not null,
  entity_type text not null,
  entity_id text not null,
  last_message_id uuid references public.saas_inbox_messages(id) on delete set null,
  last_message_at timestamptz not null,
  message_count integer not null default 1,
  muted_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id,thread_key)
);

create table if not exists public.saas_inbox_preferences (
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null,
  min_priority text not null default 'LOW' check (min_priority in ('CRITICAL','HIGH','MEDIUM','LOW')),
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (user_id,category)
);

create table if not exists public.saas_inbox_audit (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.saas_empresas(id) on delete cascade,
  message_id uuid not null references public.saas_inbox_messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete restrict,
  action text not null,
  previous_state jsonb,
  current_state jsonb,
  created_at timestamptz not null default now()
);

create index if not exists inbox_message_company_date_idx on public.saas_inbox_messages(company_id,created_at desc);
create index if not exists inbox_message_entity_idx on public.saas_inbox_messages(company_id,entity_type,entity_id,created_at desc);
create index if not exists inbox_message_priority_idx on public.saas_inbox_messages(company_id,priority,created_at desc);
create index if not exists inbox_message_group_idx on public.saas_inbox_messages(company_id,grouping_key,last_event_at desc);
create index if not exists inbox_recipient_unread_idx on public.saas_inbox_recipients(user_id,read_at,updated_at desc) where archived_at is null;
create index if not exists inbox_recipient_status_idx on public.saas_inbox_recipients(user_id,action_status,updated_at desc);
create index if not exists inbox_recipient_assigned_idx on public.saas_inbox_recipients(assigned_to,action_status,updated_at desc);
create index if not exists inbox_recipient_snooze_idx on public.saas_inbox_recipients(user_id,snoozed_until) where snoozed_until is not null;
create index if not exists inbox_audit_message_idx on public.saas_inbox_audit(message_id,created_at desc);

alter table public.saas_inbox_messages enable row level security;
alter table public.saas_inbox_recipients enable row level security;
alter table public.saas_inbox_event_receipts enable row level security;
alter table public.saas_inbox_threads enable row level security;
alter table public.saas_inbox_preferences enable row level security;
alter table public.saas_inbox_audit enable row level security;

drop policy if exists inbox_messages_company on public.saas_inbox_messages;
create policy inbox_messages_company on public.saas_inbox_messages for select to authenticated
  using (public.saas_company_can(company_id,'view'));
drop policy if exists inbox_recipients_user on public.saas_inbox_recipients;
create policy inbox_recipients_user on public.saas_inbox_recipients for select to authenticated
  using (user_id=auth.uid());
drop policy if exists inbox_receipts_company on public.saas_inbox_event_receipts;
create policy inbox_receipts_company on public.saas_inbox_event_receipts for select to authenticated
  using (public.saas_company_can(company_id,'view'));
drop policy if exists inbox_threads_company on public.saas_inbox_threads;
create policy inbox_threads_company on public.saas_inbox_threads for select to authenticated
  using (public.saas_company_can(company_id,'view'));
drop policy if exists inbox_preferences_user on public.saas_inbox_preferences;
create policy inbox_preferences_user on public.saas_inbox_preferences for all to authenticated
  using (user_id=auth.uid()) with check (user_id=auth.uid());
drop policy if exists inbox_audit_company on public.saas_inbox_audit;
create policy inbox_audit_company on public.saas_inbox_audit for select to authenticated
  using (public.saas_company_can(company_id,'view'));

create or replace function public.saas_inbox_route_event(
  p_company_id uuid,
  p_event_key text,
  p_source_event_type text,
  p_source_event_id text,
  p_entity_type text,
  p_entity_id text,
  p_category text,
  p_priority text,
  p_subject text,
  p_preview text,
  p_body text,
  p_occurred_at timestamptz,
  p_requires_action boolean default false,
  p_source jsonb default '[]'::jsonb,
  p_related_url text default null,
  p_metadata jsonb default '{}'::jsonb,
  p_grouping_key text default null,
  p_audience_user uuid default null,
  p_importance_score integer default null
) returns uuid language plpgsql security definer set search_path=public,bolsa as $$
declare
  v_message uuid;
  v_priority text:=upper(coalesce(p_priority,'MEDIUM'));
  v_score integer;
  v_thread text:=upper(p_entity_type)||':'||p_entity_id;
begin
  if v_priority not in ('CRITICAL','HIGH','MEDIUM','LOW','SILENT') then v_priority:='MEDIUM'; end if;
  v_score:=coalesce(p_importance_score,case v_priority when 'CRITICAL' then 95 when 'HIGH' then 78 when 'MEDIUM' then 55 when 'LOW' then 30 else 5 end);
  if p_requires_action then v_score:=least(100,v_score+8); end if;
  if v_priority='SILENT' or v_score<20 then return null; end if;

  insert into public.saas_inbox_event_receipts(company_id,event_key)
  values(p_company_id,p_event_key) on conflict(company_id,event_key) do nothing;
  if not found then
    select message_id into v_message from public.saas_inbox_event_receipts
     where company_id=p_company_id and event_key=p_event_key;
    return v_message;
  end if;

  if p_grouping_key is not null then
    perform pg_advisory_xact_lock(hashtext(p_company_id::text||':'||p_grouping_key));
    select id into v_message from public.saas_inbox_messages
     where company_id=p_company_id and grouping_key=p_grouping_key
       and last_event_at>=coalesce(p_occurred_at,now())-interval '60 minutes'
     order by last_event_at desc limit 1;
  end if;

  if v_message is not null then
    update public.saas_inbox_messages set
      subject=p_subject, preview=p_preview, body=p_body,
      priority=case when importance_score<=v_score then v_priority else priority end,
      importance_score=greatest(importance_score,v_score),
      requires_action=requires_action or p_requires_action,
      source=coalesce(source,'[]'::jsonb)||coalesce(p_source,'[]'::jsonb),
      metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('latest_event',p_metadata),
      group_count=group_count+1,last_event_at=greatest(last_event_at,coalesce(p_occurred_at,now())),updated_at=now()
     where id=v_message;
  else
    insert into public.saas_inbox_messages(company_id,event_key,thread_key,grouping_key,source_event_type,
      source_event_id,entity_type,entity_id,category,priority,importance_score,subject,preview,body,
      occurred_at,requires_action,source,related_url,metadata,first_event_at,last_event_at)
    values(p_company_id,p_event_key,v_thread,p_grouping_key,p_source_event_type,p_source_event_id,
      upper(p_entity_type),p_entity_id,upper(p_category),v_priority,v_score,p_subject,coalesce(p_preview,''),
      coalesce(p_body,''),coalesce(p_occurred_at,now()),p_requires_action,coalesce(p_source,'[]'::jsonb),
      p_related_url,coalesce(p_metadata,'{}'::jsonb),coalesce(p_occurred_at,now()),coalesce(p_occurred_at,now()))
    on conflict(company_id,event_key) do update set
      source=public.saas_inbox_messages.source||excluded.source,updated_at=now()
    returning id into v_message;
  end if;

  insert into public.saas_inbox_recipients(message_id,user_id,assigned_to,action_status)
  select v_message,m.user_id,case when p_requires_action then p_audience_user else null end,
    case when p_requires_action then 'ACTION_REQUIRED' else 'NEW' end
    from public.saas_empresa_membros m
    left join public.saas_inbox_preferences pref on pref.user_id=m.user_id and pref.category=upper(p_category)
   where m.company_id=p_company_id and (p_audience_user is null or m.user_id=p_audience_user)
     and coalesce(pref.enabled,true)
     and case coalesce(pref.min_priority,'LOW') when 'CRITICAL' then 4 when 'HIGH' then 3 when 'MEDIUM' then 2 else 1 end
       <= case v_priority when 'CRITICAL' then 4 when 'HIGH' then 3 when 'MEDIUM' then 2 else 1 end
  on conflict(message_id,user_id) do nothing;

  insert into public.saas_inbox_threads(company_id,thread_key,entity_type,entity_id,last_message_id,last_message_at)
  values(p_company_id,v_thread,upper(p_entity_type),p_entity_id,v_message,coalesce(p_occurred_at,now()))
  on conflict(company_id,thread_key) do update set last_message_id=excluded.last_message_id,
    last_message_at=greatest(public.saas_inbox_threads.last_message_at,excluded.last_message_at),
    message_count=public.saas_inbox_threads.message_count+1,updated_at=now();
  update public.saas_inbox_event_receipts set message_id=v_message
   where company_id=p_company_id and event_key=p_event_key;
  return v_message;
end $$;
revoke execute on function public.saas_inbox_route_event(uuid,text,text,text,text,text,text,text,text,text,text,timestamptz,boolean,jsonb,text,jsonb,text,uuid,integer) from public,anon,authenticated;

create or replace function public.saas_inbox_from_monitor_event() returns trigger
language plpgsql security definer set search_path=public,bolsa as $$
declare v_company uuid; v_owner uuid; v_category text; v_action boolean; v_group text;
begin
  select company_id,coalesce(owner_user_id,user_id) into v_company,v_owner from public.saas_monitores where id=new.monitor_id;
  if v_company is null then return new; end if;
  v_category:=case
    when new.tipo in ('NEW_PROCUREMENT','REPUBLISHED') then 'OPPORTUNITY'
    when new.tipo in ('DEADLINE_CHANGED') then 'DEADLINE'
    when new.tipo in ('NEW_DOCUMENT') then 'DOCUMENT'
    when new.tipo in ('NEW_RESULT','NEW_WINNER') then 'RESULT'
    when new.tipo in ('PRICE_CHANGE') then 'PRICE'
    when new.tipo in ('NEW_CONTRACT','CONTRACT_EXPIRING') then 'CONTRACT'
    when new.tipo='NEW_PCA' then 'PCA' when new.tipo='NEW_ATA' then 'ATA'
    when new.tipo in ('DESERTED','FAILED') then 'RISK' else 'CHANGE' end;
  v_action:=new.tipo in ('DEADLINE_CHANGED','PRICE_CHANGE','CONTRACT_EXPIRING');
  v_group:=case when new.tipo='NEW_PROCUREMENT' then 'MONITOR:'||new.monitor_id||':OPPORTUNITIES:'||date_trunc('hour',new.criado_em)::text
                else 'MONITOR:'||new.monitor_id||':'||new.tipo||':'||coalesce(new.chave,'-') end;
  perform public.saas_inbox_route_event(v_company,'MONITOR_EVENT:'||new.id,'MONITOR_EVENT',new.id::text,
    upper(coalesce(new.entidade,'MONITOR')),coalesce(new.chave,new.monitor_id::text),v_category,
    case new.importancia when 'critica' then 'CRITICAL' when 'alta' then 'HIGH' when 'baixa' then 'LOW' else 'MEDIUM' end,
    new.titulo,coalesce(new.dados->>'preview',new.titulo),
    coalesce(new.dados->>'body','Acontecimento detectado pelo Monitor Inteligente com base em dados oficiais.'),
    new.criado_em,v_action,jsonb_build_array(jsonb_build_object('type','monitor','id',new.monitor_id)),
    case when new.entidade='licitacao' then '/terminal/?procurement='||new.chave else '/terminal/?view=monitors' end,
    new.dados,v_group,v_owner,null);
  return new;
end $$;
drop trigger if exists saas_monitor_event_to_inbox on public.saas_monitor_eventos;
create trigger saas_monitor_event_to_inbox after insert on public.saas_monitor_eventos
for each row execute function public.saas_inbox_from_monitor_event();

create or replace function public.saas_inbox_from_live_change() returns trigger
language plpgsql security definer set search_path=public,bolsa as $$
declare rec record; v_category text; v_subject text; v_action boolean;
begin
  v_category:=case when new.event_type like '%DOCUMENT%' then 'DOCUMENT'
    when new.diff ?| array['data_encerramento_proposta','data_abertura_proposta'] then 'DEADLINE'
    else 'CHANGE' end;
  v_action:=new.importance in ('HIGH','CRITICAL') or v_category='DEADLINE';
  v_subject:=case when v_category='DOCUMENT' then 'Novo documento em licitação acompanhada'
    when v_category='DEADLINE' then 'Prazo alterado em licitação acompanhada'
    else 'Licitação acompanhada foi atualizada' end;
  for rec in
    select distinct m.company_id,coalesce(m.owner_user_id,m.user_id) owner_user_id
      from public.saas_monitores m join public.saas_monitor_matches mm on mm.monitor_id=m.id
     where m.company_id is not null and mm.entidade='licitacao' and mm.chave=new.procurement_id
  loop
    perform public.saas_inbox_route_event(rec.company_id,'LIVE_CHANGE:'||new.event_key,'CHANGE_EVENT',new.id::text,
      'PROCUREMENT',new.procurement_id,v_category,new.importance,v_subject,
      coalesce(new.diff::text,'Alteração oficial detectada'),
      'A Memória Viva detectou uma mudança oficial. Revise os campos alterados e os impactos dependentes.',
      coalesce(new.occurred_at,new.detected_at),v_action,
      jsonb_build_array(jsonb_build_object('type',new.source_type,'id',new.source_id,'event',new.id)),
      '/terminal/?procurement='||new.procurement_id,
      jsonb_build_object('diff',new.diff,'materiality',new.materiality),
      'PROCUREMENT:'||new.procurement_id||':'||v_category||':'||date_trunc('hour',new.detected_at)::text,
      rec.owner_user_id,null);
  end loop;
  return new;
end $$;
drop trigger if exists live_change_to_inbox on bolsa.change_events;
create trigger live_change_to_inbox after insert on bolsa.change_events
for each row execute function public.saas_inbox_from_live_change();

create or replace function public.saas_inbox_from_artifact_event() returns trigger
language plpgsql security definer set search_path=public,bolsa as $$
declare v_artifact public.ai_artifacts; v_category text; v_action boolean;
begin
  select * into v_artifact from public.ai_artifacts where id=new.artifact_id;
  if v_artifact.id is null then return new; end if;
  v_category:='ARTIFACT';
  v_action:=new.event_type in ('APPROVAL_REQUESTED','COMMENTED','MENTIONED','OUTDATED');
  perform public.saas_inbox_route_event(new.company_id,'ARTIFACT_EVENT:'||new.id,'ARTIFACT_EVENT',new.id::text,
    'ARTIFACT',new.artifact_id::text,v_category,case when v_action then 'HIGH' else 'MEDIUM' end,
    case when new.event_type='APPROVED' then 'Análise aprovada: ' else 'Análise atualizada: ' end||v_artifact.title,
    'O artefato recebeu uma nova movimentação.',
    'Abra a análise para consultar versão, fontes, comentários e próxima ação.',new.created_at,v_action,
    jsonb_build_array(jsonb_build_object('type','artifact','id',new.artifact_id)),
    '/terminal/?procurement='||v_artifact.procurement_id||'&section=strategy',new.details,
    'ARTIFACT:'||new.artifact_id||':'||date_trunc('hour',new.created_at)::text,null,null);
  return new;
end $$;
drop trigger if exists artifact_event_to_inbox on public.ai_artifact_events;
create trigger artifact_event_to_inbox after insert on public.ai_artifact_events
for each row execute function public.saas_inbox_from_artifact_event();

create or replace function public.saas_inbox_deadline_sweep(p_company uuid default null)
returns integer language plpgsql security definer set search_path=public,bolsa as $$
declare rec record; v_count integer:=0; v_priority text;
begin
  for rec in
    select distinct m.company_id,coalesce(m.owner_user_id,m.user_id) owner_user_id,l.numero_controle_pncp,
      l.objeto,l.data_encerramento_proposta,l.orgao_cnpj
      from public.saas_monitores m join public.saas_monitor_matches mm on mm.monitor_id=m.id and mm.entidade='licitacao'
      join bolsa.licitacoes l on l.numero_controle_pncp=mm.chave
     where m.company_id is not null and (p_company is null or m.company_id=p_company)
       and l.data_encerramento_proposta between now() and now()+interval '48 hours'
  loop
    v_priority:=case when rec.data_encerramento_proposta<=now()+interval '24 hours' then 'CRITICAL' else 'HIGH' end;
    perform public.saas_inbox_route_event(rec.company_id,
      'DEADLINE:'||rec.numero_controle_pncp||':'||rec.data_encerramento_proposta::text,'AGENDA_DEADLINE',
      rec.numero_controle_pncp||':'||rec.data_encerramento_proposta::text,'PROCUREMENT',rec.numero_controle_pncp,
      'DEADLINE',v_priority,'Prazo de proposta se aproxima',coalesce(rec.objeto,'Licitação acompanhada'),
      'O encerramento das propostas está próximo. Confirme documentos, preço e envio antes do prazo oficial.',
      now(),true,jsonb_build_array(jsonb_build_object('type','pncp','field','data_encerramento_proposta')),
      '/terminal/?procurement='||rec.numero_controle_pncp,
      jsonb_build_object('deadline',rec.data_encerramento_proposta,'organization_id',rec.orgao_cnpj),
      'DEADLINE:'||rec.numero_controle_pncp,rec.owner_user_id,case when v_priority='CRITICAL' then 98 else 84 end);
    v_count:=v_count+1;
  end loop;
  return v_count;
end $$;
revoke execute on function public.saas_inbox_deadline_sweep(uuid) from public,anon,authenticated;

-- Helper idempotente para reaproveitar o mesmo roteamento do trigger em eventos historicos.
create or replace function public.saas_inbox_from_monitor_event_materialized(p_event_id bigint)
returns uuid language plpgsql security definer set search_path=public,bolsa as $$
declare e public.saas_monitor_eventos; m public.saas_monitores; v_category text; v_action boolean; v_group text; v_message uuid;
begin
  select * into e from public.saas_monitor_eventos where id=p_event_id;
  if e.id is null then return null; end if;
  select * into m from public.saas_monitores where id=e.monitor_id;
  if m.company_id is null then return null; end if;
  v_category:=case when e.tipo in ('NEW_PROCUREMENT','REPUBLISHED') then 'OPPORTUNITY'
    when e.tipo='DEADLINE_CHANGED' then 'DEADLINE' when e.tipo='NEW_DOCUMENT' then 'DOCUMENT'
    when e.tipo in ('NEW_RESULT','NEW_WINNER') then 'RESULT' when e.tipo='PRICE_CHANGE' then 'PRICE'
    when e.tipo in ('NEW_CONTRACT','CONTRACT_EXPIRING') then 'CONTRACT' when e.tipo='NEW_PCA' then 'PCA'
    when e.tipo='NEW_ATA' then 'ATA' when e.tipo in ('DESERTED','FAILED') then 'RISK' else 'CHANGE' end;
  v_action:=e.tipo in ('DEADLINE_CHANGED','PRICE_CHANGE','CONTRACT_EXPIRING');
  v_group:=case when e.tipo='NEW_PROCUREMENT' then 'MONITOR:'||e.monitor_id||':OPPORTUNITIES:'||date_trunc('hour',e.criado_em)::text
                else 'MONITOR:'||e.monitor_id||':'||e.tipo||':'||coalesce(e.chave,'-') end;
  v_message:=public.saas_inbox_route_event(m.company_id,'MONITOR_EVENT:'||e.id,'MONITOR_EVENT',e.id::text,
    upper(coalesce(e.entidade,'MONITOR')),coalesce(e.chave,e.monitor_id::text),v_category,
    case e.importancia when 'critica' then 'CRITICAL' when 'alta' then 'HIGH' when 'baixa' then 'LOW' else 'MEDIUM' end,e.titulo,
    coalesce(e.dados->>'preview',e.titulo),coalesce(e.dados->>'body','Acontecimento real detectado pelo Monitor Inteligente.'),
    e.criado_em,v_action,jsonb_build_array(jsonb_build_object('type','monitor','id',e.monitor_id)),
    case when e.entidade='licitacao' then '/terminal/?procurement='||e.chave else '/terminal/?view=monitors' end,
    e.dados,v_group,coalesce(m.owner_user_id,m.user_id),null);
  return v_message;
end $$;

-- Recria a funcao anterior apos o helper existir (o PostgreSQL resolve chamadas no CREATE).
create or replace function public.saas_inbox_materialize_real(p_limit integer default 250)
returns jsonb language plpgsql security definer set search_path=public,bolsa as $$
declare v_uid uuid:=auth.uid(); v_company uuid; rec record; v_before integer:=0; v_after integer:=0;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;
  v_company:=public.saas_ensure_my_company();
  select count(*) into v_before from public.saas_inbox_messages where company_id=v_company;
  for rec in
    select e.id from public.saas_monitor_eventos e join public.saas_monitores m on m.id=e.monitor_id
     where m.company_id=v_company and not exists(
       select 1 from public.saas_inbox_event_receipts er where er.company_id=v_company and er.event_key='MONITOR_EVENT:'||e.id)
     order by e.criado_em desc limit least(greatest(p_limit,1),1000)
  loop perform public.saas_inbox_from_monitor_event_materialized(rec.id); end loop;

  for rec in
    select distinct on(ce.id) ce.id,ce.event_key,ce.procurement_id,ce.event_type,ce.source_type,ce.source_id,
      ce.diff,ce.importance,ce.materiality,ce.occurred_at,ce.detected_at,coalesce(m.owner_user_id,m.user_id) audience_user
      from bolsa.change_events ce
      join public.saas_monitor_matches mm on mm.entidade='licitacao' and mm.chave=ce.procurement_id
      join public.saas_monitores m on m.id=mm.monitor_id and m.company_id=v_company
     where not exists(select 1 from public.saas_inbox_event_receipts er
       where er.company_id=v_company and er.event_key='LIVE_CHANGE:'||ce.event_key)
     order by ce.id,ce.detected_at desc limit least(greatest(p_limit,1),1000)
  loop
    perform public.saas_inbox_route_event(v_company,'LIVE_CHANGE:'||rec.event_key,'CHANGE_EVENT',rec.id::text,
      'PROCUREMENT',rec.procurement_id,
      case when rec.event_type like '%DOCUMENT%' then 'DOCUMENT'
        when rec.diff ?| array['data_encerramento_proposta','data_abertura_proposta'] then 'DEADLINE' else 'CHANGE' end,
      rec.importance,
      case when rec.event_type like '%DOCUMENT%' then 'Novo documento em licitação acompanhada'
        when rec.diff ?| array['data_encerramento_proposta','data_abertura_proposta'] then 'Prazo alterado em licitação acompanhada'
        else 'Licitação acompanhada foi atualizada' end,
      rec.diff::text,'A Memória Viva detectou uma mudança oficial. Revise os campos alterados e os impactos dependentes.',
      coalesce(rec.occurred_at,rec.detected_at),rec.importance in ('HIGH','CRITICAL'),
      jsonb_build_array(jsonb_build_object('type',rec.source_type,'id',rec.source_id,'event',rec.id)),
      '/terminal/?procurement='||rec.procurement_id,jsonb_build_object('diff',rec.diff,'materiality',rec.materiality),
      'PROCUREMENT:'||rec.procurement_id||':CHANGE:'||date_trunc('hour',rec.detected_at)::text,rec.audience_user,null);
  end loop;

  for rec in
    select ae.id,ae.artifact_id,ae.event_type,ae.details,ae.created_at,a.title,a.procurement_id,a.owner_user_id
      from public.ai_artifact_events ae join public.ai_artifacts a on a.id=ae.artifact_id
     where ae.company_id=v_company and not exists(select 1 from public.saas_inbox_event_receipts er
       where er.company_id=v_company and er.event_key='ARTIFACT_EVENT:'||ae.id)
     order by ae.created_at desc limit least(greatest(p_limit,1),1000)
  loop
    perform public.saas_inbox_route_event(v_company,'ARTIFACT_EVENT:'||rec.id,'ARTIFACT_EVENT',rec.id::text,
      'ARTIFACT',rec.artifact_id::text,'ARTIFACT',
      case when rec.event_type in ('APPROVAL_REQUESTED','COMMENTED','MENTIONED','OUTDATED') then 'HIGH' else 'MEDIUM' end,
      case when rec.event_type='APPROVED' then 'Análise aprovada: ' else 'Análise atualizada: ' end||rec.title,
      'O artefato recebeu uma nova movimentação.','Abra a análise para consultar versão, fontes, comentários e próxima ação.',
      rec.created_at,rec.event_type in ('APPROVAL_REQUESTED','COMMENTED','MENTIONED','OUTDATED'),
      jsonb_build_array(jsonb_build_object('type','artifact','id',rec.artifact_id)),
      '/terminal/?procurement='||rec.procurement_id||'&section=strategy',rec.details,
      'ARTIFACT:'||rec.artifact_id||':'||date_trunc('hour',rec.created_at)::text,rec.owner_user_id,null);
  end loop;
  perform public.saas_inbox_deadline_sweep(v_company);
  select count(*) into v_after from public.saas_inbox_messages where company_id=v_company;
  return jsonb_build_object('company_id',v_company,'created',greatest(v_after-v_before,0),'total',v_after,'data_source','REAL_EVENTS');
end $$;
grant execute on function public.saas_inbox_materialize_real(integer) to authenticated;

create or replace function public.saas_inbox_list(
  p_box text default 'INBOX',p_search text default null,p_category text default null,
  p_priority text default null,p_limit integer default 50,p_before timestamptz default null
) returns jsonb language plpgsql stable security definer set search_path=public,bolsa as $$
declare v_uid uuid:=auth.uid(); v_company uuid; v_items jsonb; v_summary jsonb; v_box text:=upper(coalesce(p_box,'INBOX'));
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;
  select company_id into v_company from public.saas_empresa_membros where user_id=v_uid order by criado_em limit 1;
  if v_company is null then return jsonb_build_object('items','[]'::jsonb,'summary',jsonb_build_object('unread',0,'critical',0,'action_required',0)); end if;
  with filtered as (
    select m.id,m.entity_type,m.entity_id,m.category,m.priority,m.importance_score,m.subject,m.preview,m.body,
      m.occurred_at,m.created_at,m.updated_at,m.requires_action,m.source,m.related_url,m.metadata,m.group_count,
      r.seen_at,r.read_at,r.archived_at,r.snoozed_until,r.is_important,r.assigned_to,r.action_status,r.resolved_at,
      nullif(trim(concat_ws(' ',p.nome,p.sobrenome)),'') assigned_name
    from public.saas_inbox_messages m join public.saas_inbox_recipients r on r.message_id=m.id and r.user_id=v_uid
    left join public.saas_perfis p on p.user_id=r.assigned_to
    where m.company_id=v_company and (p_before is null or m.created_at<p_before)
      and (p_search is null or concat_ws(' ',m.subject,m.preview,m.body,m.entity_id) ilike '%'||p_search||'%')
      and (p_category is null or m.category=upper(p_category)) and (p_priority is null or m.priority=upper(p_priority))
      and case v_box
        when 'ALL' then true
        when 'UNREAD' then r.archived_at is null and r.read_at is null and coalesce(r.snoozed_until,now())<=now()
        when 'PRIORITY' then r.archived_at is null and m.priority in ('CRITICAL','HIGH') and coalesce(r.snoozed_until,now())<=now()
        when 'ACTION' then r.archived_at is null and r.action_status in ('ACTION_REQUIRED','IN_PROGRESS') and coalesce(r.snoozed_until,now())<=now()
        when 'ASSIGNED' then r.archived_at is null and r.assigned_to=v_uid and coalesce(r.snoozed_until,now())<=now()
        when 'SNOOZED' then r.archived_at is null and r.snoozed_until>now()
        when 'IMPORTANT' then r.archived_at is null and r.is_important and coalesce(r.snoozed_until,now())<=now()
        when 'ARCHIVED' then r.archived_at is not null
        else r.archived_at is null and coalesce(r.snoozed_until,now())<=now() end
    order by case m.priority when 'CRITICAL' then 4 when 'HIGH' then 3 when 'MEDIUM' then 2 else 1 end desc,m.created_at desc
    limit least(greatest(p_limit,1),100)
  ) select coalesce(jsonb_agg(to_jsonb(filtered)),'[]'::jsonb) into v_items from filtered;
  select jsonb_build_object(
    'unread',count(*) filter(where r.read_at is null and r.archived_at is null and coalesce(r.snoozed_until,now())<=now()),
    'critical',count(*) filter(where m.priority='CRITICAL' and r.archived_at is null and coalesce(r.snoozed_until,now())<=now()),
    'action_required',count(*) filter(where r.action_status in ('ACTION_REQUIRED','IN_PROGRESS') and r.archived_at is null),
    'important',count(*) filter(where r.is_important and r.archived_at is null),
    'snoozed',count(*) filter(where r.snoozed_until>now() and r.archived_at is null),
    'total',count(*) filter(where r.archived_at is null)
  ) into v_summary from public.saas_inbox_messages m join public.saas_inbox_recipients r on r.message_id=m.id
   where m.company_id=v_company and r.user_id=v_uid;
  return jsonb_build_object('items',v_items,'summary',v_summary,'box',v_box,'data_source','REAL_EVENTS');
end $$;
grant execute on function public.saas_inbox_list(text,text,text,text,integer,timestamptz) to authenticated;

create or replace function public.saas_inbox_action(p_message uuid,p_action text,p_value text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_company uuid; v_before jsonb; v_after jsonb; v_action text:=upper(p_action); v_assignee uuid;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED'; end if;
  select m.company_id,to_jsonb(r) into v_company,v_before from public.saas_inbox_messages m
    join public.saas_inbox_recipients r on r.message_id=m.id and r.user_id=v_uid
   where m.id=p_message and public.saas_company_can(m.company_id,'view');
  if v_company is null then raise exception 'NOT_FOUND_OR_FORBIDDEN'; end if;
  if v_action='ASSIGN' then
    v_assignee:=p_value::uuid;
    if not exists(select 1 from public.saas_empresa_membros where company_id=v_company and user_id=v_assignee) then raise exception 'INVALID_ASSIGNEE'; end if;
  end if;
  update public.saas_inbox_recipients set
    seen_at=case when v_action in ('SEEN','READ') then coalesce(seen_at,now()) else seen_at end,
    read_at=case when v_action='READ' then now() when v_action='UNREAD' then null else read_at end,
    archived_at=case when v_action='ARCHIVE' then now() when v_action='RESTORE' then null else archived_at end,
    snoozed_until=case when v_action='SNOOZE_1H' then now()+interval '1 hour'
      when v_action='SNOOZE_TOMORROW' then date_trunc('day',now())+interval '1 day 9 hours'
      when v_action='SNOOZE_CUSTOM' then p_value::timestamptz when v_action='UNSNOOZE' then null else snoozed_until end,
    is_important=case when v_action='IMPORTANT' then true when v_action='UNIMPORTANT' then false else is_important end,
    assigned_to=case when v_action='ASSIGN' then v_assignee else assigned_to end,
    action_status=case when v_action='RESOLVE' then 'RESOLVED' when v_action='START' then 'IN_PROGRESS'
      when v_action='REOPEN' then 'ACTION_REQUIRED' when v_action like 'SNOOZE_%' then 'SNOOZED'
      when v_action='ARCHIVE' then 'ARCHIVED' when v_action='RESTORE' then 'READ'
      when v_action='READ' and action_status='NEW' then 'READ' else action_status end,
    resolved_at=case when v_action='RESOLVE' then now() when v_action='REOPEN' then null else resolved_at end,updated_at=now()
   where message_id=p_message and user_id=v_uid;
  select to_jsonb(r) into v_after from public.saas_inbox_recipients r where message_id=p_message and user_id=v_uid;
  if v_action in ('ASSIGN','RESOLVE','REOPEN','ARCHIVE','RESTORE') then
    insert into public.saas_inbox_audit(company_id,message_id,user_id,action,previous_state,current_state)
    values(v_company,p_message,v_uid,v_action,v_before,v_after);
  end if;
  return v_after;
end $$;
grant execute on function public.saas_inbox_action(uuid,text,text) to authenticated;

create or replace function public.saas_inbox_bulk_action(p_messages uuid[],p_action text,p_value text default null)
returns integer language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_count integer:=0;
begin
  foreach v_id in array p_messages loop perform public.saas_inbox_action(v_id,p_action,p_value); v_count:=v_count+1; end loop;
  return v_count;
end $$;
grant execute on function public.saas_inbox_bulk_action(uuid[],text,text) to authenticated;

create or replace function public.saas_inbox_mark_all_read()
returns integer language plpgsql security definer set search_path=public as $$
declare v_count integer;
begin
  update public.saas_inbox_recipients r set read_at=now(),seen_at=coalesce(seen_at,now()),
    action_status=case when action_status='NEW' then 'READ' else action_status end,updated_at=now()
   where r.user_id=auth.uid() and r.read_at is null and r.archived_at is null
     and exists(select 1 from public.saas_inbox_messages m where m.id=r.message_id and m.priority<>'SILENT');
  get diagnostics v_count=row_count; return v_count;
end $$;
grant execute on function public.saas_inbox_mark_all_read() to authenticated;

comment on table public.saas_inbox_messages is 'Camada persistente de atencao. Nao substitui Timeline, Agenda ou eventos de origem.';
comment on column public.saas_inbox_messages.source is 'Proveniencia publica/privada; pode conter varias fontes quando houve deduplicacao.';
