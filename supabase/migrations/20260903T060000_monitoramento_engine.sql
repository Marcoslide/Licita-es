-- ============================================================
-- MODO MONITORAMENTO — motor + tabelas (PARTE A do prompt)
-- Monitores por usuário sobre a base real (schema bolsa), com
-- matches persistentes (novidade ≠ match, §31), diff (§32),
-- eventos tipados (§30), baseline histórico (§37) e tick ~10min.
-- ============================================================

-- ---------- monitores (§19) ----------
create table public.saas_monitores (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  nome text not null,
  descricao text,
  nicho text,                                          -- texto livre (§4)
  status text not null default 'ativo' check (status in ('ativo','pausado')),
  refresh_minutos int not null default 10 check (refresh_minutos >= 10),
  last_run_at timestamptz,
  next_run_at timestamptz not null default now(),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index saas_mon_user_idx on public.saas_monitores (user_id);
create index saas_mon_due_idx on public.saas_monitores (next_run_at) where status = 'ativo';

-- ---------- regras estruturadas (§20 — nunca uma string única) ----------
create table public.saas_monitor_regras (
  monitor_id bigint primary key references public.saas_monitores(id) on delete cascade,
  semantic_query text,
  incluir text[] not null default '{}',
  excluir text[] not null default '{}',
  -- expansões visíveis e controláveis (§6): nada expande silenciosamente
  expansoes jsonb not null default '{"sugeridas":[],"aprovadas":[],"bloqueadas":[]}'::jsonb,
  catmat text[] not null default '{}',
  catser text[] not null default '{}',
  categorias text[] not null default '{}',
  ufs text[] not null default '{}',
  municipios text[] not null default '{}',
  orgaos_incluir text[] not null default '{}',         -- CNPJs
  orgaos_excluir text[] not null default '{}',
  fornecedores text[] not null default '{}',           -- CNPJs de concorrentes monitorados (§15)
  modalidades text[] not null default '{}',
  situacoes text[] not null default '{}',
  valor_min numeric, valor_max numeric,                -- valor TOTAL da licitação (§8)
  preco_unit_min numeric, preco_unit_max numeric,      -- preço UNITÁRIO do item (§9)
  abertura_ate_dias int,                               -- abre nas próximas N dias (§14)
  contratos_vencendo_dias int default 180,             -- janela de vencimento (§16)
  monitorar_pca boolean not null default true,
  monitorar_atas boolean not null default true,
  monitorar_contratos boolean not null default true,
  monitorar_desertos boolean not null default true,
  monitorar_fracassados boolean not null default true,
  atualizado_em timestamptz not null default now()
);

-- histórico de configurações (§94: saber antes vs depois)
create table public.saas_monitor_config_hist (
  id bigint generated always as identity primary key,
  monitor_id bigint not null references public.saas_monitores(id) on delete cascade,
  config jsonb not null,
  alterado_por uuid,
  alterado_em timestamptz not null default now()
);

-- ---------- matches persistentes (§31) ----------
create table public.saas_monitor_matches (
  id bigint generated always as identity primary key,
  monitor_id bigint not null references public.saas_monitores(id) on delete cascade,
  entidade text not null check (entidade in ('licitacao','contrato','contrato_gov','ata','pca','resultado')),
  chave text not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  last_checked_at timestamptz not null default now(),
  snapshot jsonb not null default '{}'::jsonb,         -- para diff (§32)
  unique (monitor_id, entidade, chave)
);
create index saas_mm_mon_idx on public.saas_monitor_matches (monitor_id, entidade);

-- ---------- eventos do monitor (§30) ----------
create table public.saas_monitor_eventos (
  id bigint generated always as identity primary key,
  monitor_id bigint not null references public.saas_monitores(id) on delete cascade,
  tipo text not null check (tipo in (
    'NEW_PROCUREMENT','PROCUREMENT_UPDATED','DEADLINE_CHANGED','NEW_DOCUMENT','NEW_RESULT',
    'NEW_WINNER','PRICE_CHANGE','NEW_CONTRACT','CONTRACT_EXPIRING','NEW_PCA','NEW_ATA',
    'NEW_SUPPLIER','DESERTED','FAILED','REPUBLISHED','MARKET_TREND_CHANGE','COMPETITOR_PATTERN_CHANGE',
    'BASELINE_READY')),
  entidade text,
  chave text,
  titulo text not null,                                -- alerta legível (§33), nunca "encontramos resultado"
  dados jsonb not null default '{}'::jsonb,
  importancia text not null default 'media' check (importancia in ('baixa','media','alta','critica')),
  lido boolean not null default false,
  criado_em timestamptz not null default now()
);
create index saas_me_mon_idx on public.saas_monitor_eventos (monitor_id, criado_em desc);

-- ---------- baseline histórico (§37) ----------
create table public.saas_monitor_baseline (
  monitor_id bigint primary key references public.saas_monitores(id) on delete cascade,
  stats jsonb not null default '{}'::jsonb,
  calculado_em timestamptz not null default now()
);

-- ---------- limites por plano (§96 — números configuráveis no admin) ----------
update public.saas_planos set entitlements = entitlements || '{"max_monitores":1}'::jsonb  where id = 'explorar';
update public.saas_planos set entitlements = entitlements || '{"max_monitores":10}'::jsonb where id = 'profissional';
update public.saas_planos set entitlements = entitlements || '{"max_monitores":50}'::jsonb where id = 'inteligencia';
update public.saas_planos set entitlements = entitlements || '{"max_monitores":-1}'::jsonb where id = 'business'; -- -1 = ilimitado/fair use

-- ============================================================
-- RLS
-- ============================================================
alter table public.saas_monitores enable row level security;
alter table public.saas_monitor_regras enable row level security;
alter table public.saas_monitor_config_hist enable row level security;
alter table public.saas_monitor_matches enable row level security;
alter table public.saas_monitor_eventos enable row level security;
alter table public.saas_monitor_baseline enable row level security;

create policy mon_sel on public.saas_monitores for select to authenticated
  using (user_id = auth.uid() or public.saas_is_admin());
create policy mon_upd on public.saas_monitores for update to authenticated
  using (user_id = auth.uid() or public.saas_is_admin());
create policy mon_del on public.saas_monitores for delete to authenticated
  using (user_id = auth.uid() or public.saas_is_admin());

create policy monr_sel on public.saas_monitor_regras for select to authenticated
  using (exists (select 1 from public.saas_monitores m where m.id = monitor_id and (m.user_id = auth.uid() or public.saas_is_admin())));
create policy monh_sel on public.saas_monitor_config_hist for select to authenticated
  using (exists (select 1 from public.saas_monitores m where m.id = monitor_id and (m.user_id = auth.uid() or public.saas_is_admin())));
create policy monm_sel on public.saas_monitor_matches for select to authenticated
  using (exists (select 1 from public.saas_monitores m where m.id = monitor_id and (m.user_id = auth.uid() or public.saas_is_admin())));
create policy mone_sel on public.saas_monitor_eventos for select to authenticated
  using (exists (select 1 from public.saas_monitores m where m.id = monitor_id and (m.user_id = auth.uid() or public.saas_is_admin())));
create policy mone_upd on public.saas_monitor_eventos for update to authenticated
  using (exists (select 1 from public.saas_monitores m where m.id = monitor_id and (m.user_id = auth.uid() or public.saas_is_admin())));
create policy monb_sel on public.saas_monitor_baseline for select to authenticated
  using (exists (select 1 from public.saas_monitores m where m.id = monitor_id and (m.user_id = auth.uid() or public.saas_is_admin())));
-- inserções/alterações de regras, matches, eventos e baseline: apenas via funções SECURITY DEFINER

-- ============================================================
-- FUNÇÕES DO MOTOR
-- ============================================================

-- padrões ILIKE a partir de termos (inclui + expansões aprovadas)
create or replace function public.saas_mon_padroes(p_regras public.saas_monitor_regras)
returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct '%' || t || '%'), '{}')
  from (
    select unnest(p_regras.incluir) as t
    union
    select jsonb_array_elements_text(coalesce(p_regras.expansoes->'aprovadas', '[]'::jsonb))
  ) x where length(trim(t)) > 1;
$$;

create or replace function public.saas_mon_padroes_exc(p_regras public.saas_monitor_regras)
returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct '%' || t || '%'), '{}')
  from unnest(p_regras.excluir) t where length(trim(t)) > 1;
$$;

-- avaliação de um monitor: matches novos, diffs e eventos (§21, §31-34, §36)
create or replace function public.saas_monitor_avaliar(p_monitor bigint, p_inicial boolean default false)
returns jsonb language plpgsql security definer set search_path = public, bolsa as $$
declare
  r public.saas_monitor_regras;
  m public.saas_monitores;
  v_inc text[]; v_exc text[];
  v_novos int := 0; v_diffs int := 0; v_eventos int := 0; v_total int;
  v_t0 timestamptz := clock_timestamp();
  rec record;
  mt record;
  v_pct numeric;
begin
  select * into m from public.saas_monitores where id = p_monitor;
  if not found then raise exception 'monitor % não existe', p_monitor; end if;
  select * into r from public.saas_monitor_regras where monitor_id = p_monitor;
  if not found then raise exception 'monitor % sem regras', p_monitor; end if;
  v_inc := public.saas_mon_padroes(r);
  v_exc := public.saas_mon_padroes_exc(r);

  -- ---------- LICITAÇÕES ----------
  for rec in
    select l.numero_controle_pncp as chave,
           jsonb_build_object(
             'objeto', left(l.objeto, 300), 'valor', l.valor_total_estimado,
             'situacao', l.situacao_nome, 'situacao_fonte', l.situacao_fonte,
             'encerramento', l.data_encerramento_proposta, 'uf', l.uf,
             'municipio', l.municipio_nome, 'orgao', l.orgao_cnpj,
             'modalidade', l.modalidade_nome, 'homologado', l.valor_total_homologado) as snap
    from bolsa.licitacoes l
    where (cardinality(v_inc) = 0 or l.objeto ilike any (v_inc))
      and (cardinality(v_exc) = 0 or not (l.objeto ilike any (v_exc)))
      and (cardinality(r.ufs) = 0 or l.uf = any (r.ufs))
      and (cardinality(r.municipios) = 0 or l.municipio_nome ilike any (r.municipios))
      and (cardinality(r.orgaos_incluir) = 0 or l.orgao_cnpj = any (r.orgaos_incluir))
      and (cardinality(r.orgaos_excluir) = 0 or l.orgao_cnpj is null or not (l.orgao_cnpj = any (r.orgaos_excluir)))
      and (cardinality(r.modalidades) = 0 or l.modalidade_nome ilike any (r.modalidades))
      and (cardinality(r.situacoes) = 0 or coalesce(l.situacao_nome, l.situacao_fonte, '') ilike any (r.situacoes))
      and (r.valor_min is null or l.valor_total_estimado >= r.valor_min)
      and (r.valor_max is null or l.valor_total_estimado <= r.valor_max)
      and (r.abertura_ate_dias is null or
           (l.data_encerramento_proposta between now() and now() + make_interval(days => r.abertura_ate_dias)))
      and ((r.preco_unit_min is null and r.preco_unit_max is null) or exists (
             select 1 from bolsa.itens i
             where i.numero_controle_pncp = l.numero_controle_pncp
               and (r.preco_unit_min is null or i.valor_unitario_estimado >= r.preco_unit_min)
               and (r.preco_unit_max is null or i.valor_unitario_estimado <= r.preco_unit_max)))
      and (cardinality(r.catmat) = 0 or exists (
             select 1 from bolsa.itens i2
             where i2.numero_controle_pncp = l.numero_controle_pncp
               and i2.catalogo_codigo = any (r.catmat)))
  loop
    select * into mt from public.saas_monitor_matches
     where monitor_id = p_monitor and entidade = 'licitacao' and chave = rec.chave;
    if not found then
      insert into public.saas_monitor_matches (monitor_id, entidade, chave, snapshot)
      values (p_monitor, 'licitacao', rec.chave, rec.snap);
      v_novos := v_novos + 1;
      if not p_inicial then
        insert into public.saas_monitor_eventos (monitor_id, tipo, entidade, chave, titulo, dados, importancia)
        values (p_monitor, 'NEW_PROCUREMENT', 'licitacao', rec.chave,
          '🚨 Nova oportunidade de ' || coalesce('R$ ' || to_char((rec.snap->>'valor')::numeric, 'FM999G999G999G990'), 'valor não informado')
            || ' encontrada' || coalesce(' em ' || (rec.snap->>'uf'), ''),
          rec.snap,
          case when (rec.snap->>'encerramento') is not null
                    and (rec.snap->>'encerramento')::timestamptz < now() + interval '48 hours' then 'critica'
               when coalesce((rec.snap->>'valor')::numeric, 0) >= 1000000 then 'alta'
               else 'media' end);
        v_eventos := v_eventos + 1;
      end if;
      -- desertos/fracassados já na chegada (§13)
      if r.monitorar_desertos and coalesce(rec.snap->>'situacao', rec.snap->>'situacao_fonte', '') ilike '%desert%' then
        insert into public.saas_monitor_eventos (monitor_id, tipo, entidade, chave, titulo, dados, importancia)
        values (p_monitor, 'DESERTED', 'licitacao', rec.chave,
          '💎 Processo deserto identificado — possível recompra à frente', rec.snap, 'media');
        v_eventos := v_eventos + 1;
      elsif r.monitorar_fracassados and coalesce(rec.snap->>'situacao', rec.snap->>'situacao_fonte', '') ilike '%fracass%' then
        insert into public.saas_monitor_eventos (monitor_id, tipo, entidade, chave, titulo, dados, importancia)
        values (p_monitor, 'FAILED', 'licitacao', rec.chave,
          '💎 Processo fracassado identificado — possível republicação', rec.snap, 'media');
        v_eventos := v_eventos + 1;
      end if;
    else
      -- diff (§32): compara snapshot conhecido com estado atual
      if (mt.snapshot->>'valor') is distinct from (rec.snap->>'valor') then
        v_pct := case when coalesce((mt.snapshot->>'valor')::numeric, 0) > 0
                 then round((((rec.snap->>'valor')::numeric - (mt.snapshot->>'valor')::numeric)
                      / (mt.snapshot->>'valor')::numeric) * 100, 1) end;
        insert into public.saas_monitor_eventos (monitor_id, tipo, entidade, chave, titulo, dados, importancia)
        values (p_monitor, 'PRICE_CHANGE', 'licitacao', rec.chave,
          '💰 Valor estimado alterado' || coalesce(' em ' || (case when v_pct > 0 then '+' else '' end) || v_pct || '%', ''),
          jsonb_build_object('antes', mt.snapshot->>'valor', 'depois', rec.snap->>'valor', 'variacao_pct', v_pct),
          case when abs(coalesce(v_pct, 0)) >= 20 then 'alta' else 'media' end);
        v_diffs := v_diffs + 1; v_eventos := v_eventos + 1;
      end if;
      if (mt.snapshot->>'encerramento') is distinct from (rec.snap->>'encerramento') then
        insert into public.saas_monitor_eventos (monitor_id, tipo, entidade, chave, titulo, dados, importancia)
        values (p_monitor, 'DEADLINE_CHANGED', 'licitacao', rec.chave,
          '⏰ Prazo de propostas alterado',
          jsonb_build_object('antes', mt.snapshot->>'encerramento', 'depois', rec.snap->>'encerramento'),
          case when (rec.snap->>'encerramento') is not null
                    and (rec.snap->>'encerramento')::timestamptz < now() + interval '48 hours'
               then 'critica' else 'alta' end);
        v_diffs := v_diffs + 1; v_eventos := v_eventos + 1;
      end if;
      if (mt.snapshot->>'situacao') is distinct from (rec.snap->>'situacao')
         or (mt.snapshot->>'homologado') is distinct from (rec.snap->>'homologado') then
        insert into public.saas_monitor_eventos (monitor_id, tipo, entidade, chave, titulo, dados, importancia)
        values (p_monitor, 'PROCUREMENT_UPDATED', 'licitacao', rec.chave,
          '📌 Situação do processo atualizada' ||
            coalesce(': ' || nullif(rec.snap->>'situacao', mt.snapshot->>'situacao'), ''),
          jsonb_build_object('antes', mt.snapshot, 'depois', rec.snap), 'media');
        v_diffs := v_diffs + 1; v_eventos := v_eventos + 1;
      end if;
      if mt.snapshot is distinct from rec.snap then
        update public.saas_monitor_matches
           set snapshot = rec.snap, last_seen_at = now(), last_checked_at = now()
         where id = mt.id;
      else
        update public.saas_monitor_matches set last_checked_at = now() where id = mt.id;
      end if;
    end if;
  end loop;

  -- ---------- VENCEDORES / CONCORRENTES (§15) ----------
  for rec in
    select ri.numero_controle_pncp || ':' || ri.numero_item || ':' || coalesce(ri.fornecedor_ni, '?') as chave,
           jsonb_build_object('fornecedor', ri.fornecedor_nome, 'ni', ri.fornecedor_ni,
             'valor_unit', ri.valor_unitario_homologado, 'valor_total', ri.valor_total_homologado,
             'processo', ri.numero_controle_pncp) as snap,
           ri.fornecedor_nome, ri.fornecedor_ni
    from bolsa.resultados_itens ri
    join public.saas_monitor_matches mm
      on mm.monitor_id = p_monitor and mm.entidade = 'licitacao' and mm.chave = ri.numero_controle_pncp
  loop
    if not exists (select 1 from public.saas_monitor_matches
                   where monitor_id = p_monitor and entidade = 'resultado' and chave = rec.chave) then
      insert into public.saas_monitor_matches (monitor_id, entidade, chave, snapshot)
      values (p_monitor, 'resultado', rec.chave, rec.snap);
      if not p_inicial then
        insert into public.saas_monitor_eventos (monitor_id, tipo, entidade, chave, titulo, dados, importancia)
        values (p_monitor, 'NEW_WINNER', 'resultado', rec.chave,
          '🏆 ' || coalesce(rec.fornecedor_nome, 'Fornecedor') || ' homologado em processo deste monitor',
          rec.snap,
          case when cardinality(r.fornecedores) > 0 and rec.fornecedor_ni = any (r.fornecedores)
               then 'alta' else 'media' end);
        v_eventos := v_eventos + 1;
      end if;
      v_novos := v_novos + 1;
    end if;
  end loop;

  -- ---------- CONTRATOS VENCENDO (§16) ----------
  if r.monitorar_contratos then
    for rec in
      select 'pncp:' || c.numero_controle_pncp as chave,
             jsonb_build_object('objeto', left(c.objeto, 200), 'valor', c.valor_global,
               'vigencia_fim', c.vigencia_fim, 'fornecedor', c.fornecedor_nome, 'uf', c.uf) as snap,
             c.vigencia_fim, c.valor_global
      from bolsa.contratos c
      where c.vigencia_fim between current_date and current_date + coalesce(r.contratos_vencendo_dias, 180)
        and ((cardinality(v_inc) > 0 and c.objeto ilike any (v_inc))
             or (cardinality(r.fornecedores) > 0 and c.fornecedor_ni = any (r.fornecedores)))
        and (cardinality(v_exc) = 0 or not (c.objeto ilike any (v_exc)))
        and (cardinality(r.ufs) = 0 or c.uf = any (r.ufs))
      union all
      select 'gov:' || cg.id_fonte::text,
             jsonb_build_object('objeto', left(cg.objeto, 200), 'valor', cg.valor_global,
               'vigencia_fim', cg.vigencia_fim, 'fornecedor', cg.fornecedor_nome, 'uf', null),
             cg.vigencia_fim, cg.valor_global
      from bolsa.contratos_gov cg
      where cg.vigencia_fim between current_date and current_date + coalesce(r.contratos_vencendo_dias, 180)
        and ((cardinality(v_inc) > 0 and cg.objeto ilike any (v_inc))
             or (cardinality(r.fornecedores) > 0 and cg.fornecedor_ni = any (r.fornecedores)))
        and (cardinality(v_exc) = 0 or not (cg.objeto ilike any (v_exc)))
    loop
      if not exists (select 1 from public.saas_monitor_matches
                     where monitor_id = p_monitor and entidade = 'contrato' and chave = rec.chave) then
        insert into public.saas_monitor_matches (monitor_id, entidade, chave, snapshot)
        values (p_monitor, 'contrato', rec.chave, rec.snap);
        v_novos := v_novos + 1;
        if not p_inicial then
          insert into public.saas_monitor_eventos (monitor_id, tipo, entidade, chave, titulo, dados, importancia)
          values (p_monitor, 'CONTRACT_EXPIRING', 'contrato', rec.chave,
            '🔮 Contrato de ' || coalesce('R$ ' || to_char(rec.valor_global, 'FM999G999G999G990'), 'valor n/i')
              || ' vence em ' || (rec.vigencia_fim - current_date) || ' dias',
            rec.snap,
            case when rec.vigencia_fim - current_date <= 30 then 'alta' else 'media' end);
          v_eventos := v_eventos + 1;
        end if;
      end if;
    end loop;
  end if;

  -- ---------- ATAS (§18) ----------
  if r.monitorar_atas and cardinality(v_inc) > 0 then
    for rec in
      select a.numero_controle_pncp_ata as chave,
             jsonb_build_object('objeto', left(a.objeto, 200), 'vigencia_fim', a.vigencia_fim, 'uf', a.uf) as snap
      from bolsa.atas a
      where a.objeto ilike any (v_inc)
        and (cardinality(v_exc) = 0 or not (a.objeto ilike any (v_exc)))
        and (cardinality(r.ufs) = 0 or a.uf = any (r.ufs))
        and coalesce(a.cancelado, false) = false
    loop
      if not exists (select 1 from public.saas_monitor_matches
                     where monitor_id = p_monitor and entidade = 'ata' and chave = rec.chave) then
        insert into public.saas_monitor_matches (monitor_id, entidade, chave, snapshot)
        values (p_monitor, 'ata', rec.chave, rec.snap);
        v_novos := v_novos + 1;
        if not p_inicial then
          insert into public.saas_monitor_eventos (monitor_id, tipo, entidade, chave, titulo, dados, importancia)
          values (p_monitor, 'NEW_ATA', 'ata', rec.chave,
            '📜 Nova ata de registro de preços no seu mercado', rec.snap, 'media');
          v_eventos := v_eventos + 1;
        end if;
      end if;
    end loop;
  end if;

  -- ---------- PCA (§17 — compra futura antes do edital) ----------
  if r.monitorar_pca and cardinality(v_inc) > 0 then
    for rec in
      select p.chave_dedup as chave,
             jsonb_build_object('descricao', left(p.descricao, 200), 'valor', p.valor_total,
               'ano', p.ano_pca, 'data_desejada', p.data_desejada, 'orgao', p.orgao_cnpj) as snap
      from bolsa.pca_itens p
      where p.descricao ilike any (v_inc)
        and (cardinality(v_exc) = 0 or not (p.descricao ilike any (v_exc)))
        and (cardinality(r.orgaos_incluir) = 0 or p.orgao_cnpj = any (r.orgaos_incluir))
    loop
      if not exists (select 1 from public.saas_monitor_matches
                     where monitor_id = p_monitor and entidade = 'pca' and chave = rec.chave) then
        insert into public.saas_monitor_matches (monitor_id, entidade, chave, snapshot)
        values (p_monitor, 'pca', rec.chave, rec.snap);
        v_novos := v_novos + 1;
        if not p_inicial then
          insert into public.saas_monitor_eventos (monitor_id, tipo, entidade, chave, titulo, dados, importancia)
          values (p_monitor, 'NEW_PCA', 'pca', rec.chave,
            '📅 Item de plano de contratações (PCA) relacionado ao seu monitor — compra futura sinalizada',
            rec.snap, 'media');
          v_eventos := v_eventos + 1;
        end if;
      end if;
    end loop;
  end if;

  select count(*) into v_total from public.saas_monitor_matches where monitor_id = p_monitor;

  update public.saas_monitores
     set last_run_at = now(),
         next_run_at = now() + make_interval(mins => refresh_minutos),
         atualizado_em = now()
   where id = p_monitor;

  return jsonb_build_object(
    'monitor', p_monitor, 'inicial', p_inicial,
    'novos_matches', v_novos, 'alteracoes', v_diffs, 'eventos_gerados', v_eventos,
    'total_matches', v_total,
    'duracao_ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000));
end $$;

-- baseline histórico do monitor (§37): calculado sobre a base real
create or replace function public.saas_monitor_baseline_calc(p_monitor bigint)
returns jsonb language plpgsql security definer set search_path = public, bolsa as $$
declare v jsonb;
begin
  with lic as (
    select l.* from bolsa.licitacoes l
    join public.saas_monitor_matches mm
      on mm.monitor_id = p_monitor and mm.entidade = 'licitacao' and mm.chave = l.numero_controle_pncp
  ),
  res as (
    select ri.* from bolsa.resultados_itens ri
    join public.saas_monitor_matches mm
      on mm.monitor_id = p_monitor and mm.entidade = 'licitacao' and mm.chave = ri.numero_controle_pncp
  )
  select jsonb_build_object(
    'amostra', jsonb_build_object(
       'processos', (select count(*) from lic),
       'periodo_inicio', (select min(data_publicacao_pncp)::date from lic),
       'periodo_fim', (select max(data_publicacao_pncp)::date from lic)),
    'valor_total_estimado', (select sum(valor_total_estimado) from lic),
    'valor_mediano_processo', (select percentile_cont(0.5) within group (order by valor_total_estimado)
                               from lic where valor_total_estimado > 0),
    'processos_por_mes', (select coalesce(jsonb_object_agg(mes, n), '{}'::jsonb) from (
       select to_char(data_publicacao_pncp, 'YYYY-MM') mes, count(*) n from lic
       where data_publicacao_pncp is not null group by 1 order by 1) x),
    'preco_unitario', jsonb_build_object(
       'mediana_homologada', (select percentile_cont(0.5) within group (order by valor_unitario_homologado)
                              from res where valor_unitario_homologado > 0),
       'p25', (select percentile_cont(0.25) within group (order by valor_unitario_homologado)
               from res where valor_unitario_homologado > 0),
       'p75', (select percentile_cont(0.75) within group (order by valor_unitario_homologado)
               from res where valor_unitario_homologado > 0),
       'amostra_itens', (select count(*) from res where valor_unitario_homologado > 0)),
    'concorrentes_top', (select coalesce(jsonb_agg(row_to_json(c)), '[]'::jsonb) from (
       select fornecedor_ni as ni, max(fornecedor_nome) nome, count(*) vitorias,
              sum(valor_total_homologado) valor
       from res where fornecedor_ni is not null
       group by fornecedor_ni order by count(*) desc limit 10) c),
    'orgaos_top', (select coalesce(jsonb_agg(row_to_json(o)), '[]'::jsonb) from (
       select orgao_cnpj, count(*) processos, sum(valor_total_estimado) valor
       from lic group by orgao_cnpj order by count(*) desc limit 10) o),
    'ufs', (select coalesce(jsonb_object_agg(uf, n), '{}'::jsonb) from (
       select uf, count(*) n from lic where uf is not null group by uf order by n desc) u),
    'desertos', (select count(*) from lic where coalesce(situacao_nome, situacao_fonte, '') ilike '%desert%'),
    'fracassados', (select count(*) from lic where coalesce(situacao_nome, situacao_fonte, '') ilike '%fracass%'),
    'concorrencia_media', (select round(avg(n), 1) from (
       select numero_controle_pncp, count(distinct fornecedor_ni) n from res group by 1) x),
    'metodologia', 'Calculado exclusivamente sobre registros reais coletados das fontes oficiais; a janela reflete a cobertura atual da base (dado CALCULADO, §109).'
  ) into v;

  insert into public.saas_monitor_baseline (monitor_id, stats, calculado_em)
  values (p_monitor, v, now())
  on conflict (monitor_id) do update set stats = excluded.stats, calculado_em = now();

  insert into public.saas_monitor_eventos (monitor_id, tipo, titulo, dados, importancia)
  values (p_monitor, 'BASELINE_READY',
    '📊 Perfil histórico do monitor calculado sobre ' || coalesce((v->'amostra'->>'processos'), '0') || ' processos reais',
    v->'amostra', 'baixa');

  return v;
end $$;

-- criação de monitor com limite por plano (§96) + primeira análise histórica (§21)
create or replace function public.saas_monitor_criar(p_nome text, p_regras jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_max int;
  v_qtd int;
  v_id bigint;
  v_res jsonb;
  v_base jsonb;
begin
  if v_uid is null then raise exception 'autenticação necessária'; end if;

  select coalesce((public.saas_meu_acesso()->'entitlements'->>'max_monitores')::int, 1) into v_max;
  select count(*) into v_qtd from public.saas_monitores where user_id = v_uid;
  if v_max >= 0 and v_qtd >= v_max then
    raise exception 'LIMITE_PLANO: seu plano permite % monitor(es). Faça upgrade para criar mais.', v_max;
  end if;

  insert into public.saas_monitores (user_id, nome, descricao, nicho, refresh_minutos)
  values (v_uid, p_nome, p_regras->>'descricao', p_regras->>'nicho',
          greatest(coalesce((p_regras->>'refresh_minutos')::int, 10), 10))
  returning id into v_id;

  insert into public.saas_monitor_regras (
    monitor_id, semantic_query, incluir, excluir, expansoes, catmat, catser, categorias,
    ufs, municipios, orgaos_incluir, orgaos_excluir, fornecedores, modalidades, situacoes,
    valor_min, valor_max, preco_unit_min, preco_unit_max, abertura_ate_dias, contratos_vencendo_dias,
    monitorar_pca, monitorar_atas, monitorar_contratos, monitorar_desertos, monitorar_fracassados)
  values (
    v_id, p_regras->>'semantic_query',
    coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'incluir') x), '{}'),
    coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'excluir') x), '{}'),
    coalesce(p_regras->'expansoes', '{"sugeridas":[],"aprovadas":[],"bloqueadas":[]}'::jsonb),
    coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'catmat') x), '{}'),
    coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'catser') x), '{}'),
    coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'categorias') x), '{}'),
    coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'ufs') x), '{}'),
    coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'municipios') x), '{}'),
    coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'orgaos_incluir') x), '{}'),
    coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'orgaos_excluir') x), '{}'),
    coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'fornecedores') x), '{}'),
    coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'modalidades') x), '{}'),
    coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'situacoes') x), '{}'),
    (p_regras->>'valor_min')::numeric, (p_regras->>'valor_max')::numeric,
    (p_regras->>'preco_unit_min')::numeric, (p_regras->>'preco_unit_max')::numeric,
    (p_regras->>'abertura_ate_dias')::int,
    coalesce((p_regras->>'contratos_vencendo_dias')::int, 180),
    coalesce((p_regras->>'monitorar_pca')::boolean, true),
    coalesce((p_regras->>'monitorar_atas')::boolean, true),
    coalesce((p_regras->>'monitorar_contratos')::boolean, true),
    coalesce((p_regras->>'monitorar_desertos')::boolean, true),
    coalesce((p_regras->>'monitorar_fracassados')::boolean, true));

  insert into public.saas_monitor_config_hist (monitor_id, config, alterado_por)
  values (v_id, p_regras || jsonb_build_object('nome', p_nome, 'acao', 'criacao'), v_uid);

  -- primeira execução: análise histórica imediata (§21)
  v_res := public.saas_monitor_avaliar(v_id, true);
  v_base := public.saas_monitor_baseline_calc(v_id);

  return jsonb_build_object('id', v_id, 'analise_inicial', v_res, 'baseline', v_base);
end $$;

-- edição preservando histórico de configuração (§94)
create or replace function public.saas_monitor_atualizar(p_monitor bigint, p_regras jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_res jsonb;
begin
  if not exists (select 1 from public.saas_monitores
                 where id = p_monitor and (user_id = v_uid or public.saas_is_admin())) then
    raise exception 'monitor não encontrado ou sem permissão';
  end if;

  insert into public.saas_monitor_config_hist (monitor_id, config, alterado_por)
  select p_monitor, to_jsonb(r) || jsonb_build_object('acao', 'antes_da_edicao'), v_uid
  from public.saas_monitor_regras r where r.monitor_id = p_monitor;

  update public.saas_monitor_regras set
    incluir = coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'incluir') x), incluir),
    excluir = coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'excluir') x), excluir),
    expansoes = coalesce(p_regras->'expansoes', expansoes),
    ufs = coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'ufs') x), ufs),
    modalidades = coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'modalidades') x), modalidades),
    fornecedores = coalesce((select array_agg(x) from jsonb_array_elements_text(p_regras->'fornecedores') x), fornecedores),
    valor_min = coalesce((p_regras->>'valor_min')::numeric, valor_min),
    valor_max = coalesce((p_regras->>'valor_max')::numeric, valor_max),
    preco_unit_min = coalesce((p_regras->>'preco_unit_min')::numeric, preco_unit_min),
    preco_unit_max = coalesce((p_regras->>'preco_unit_max')::numeric, preco_unit_max),
    contratos_vencendo_dias = coalesce((p_regras->>'contratos_vencendo_dias')::int, contratos_vencendo_dias),
    atualizado_em = now()
  where monitor_id = p_monitor;

  insert into public.saas_monitor_config_hist (monitor_id, config, alterado_por)
  values (p_monitor, p_regras || jsonb_build_object('acao', 'edicao'), v_uid);

  v_res := public.saas_monitor_avaliar(p_monitor, false);
  perform public.saas_monitor_baseline_calc(p_monitor);
  return v_res;
end $$;

-- duplicar monitor (§95)
create or replace function public.saas_monitor_duplicar(p_monitor bigint, p_novo_nome text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_novo bigint;
begin
  if not exists (select 1 from public.saas_monitores where id = p_monitor and user_id = v_uid) then
    raise exception 'monitor não encontrado';
  end if;
  insert into public.saas_monitores (user_id, nome, descricao, nicho, refresh_minutos)
  select user_id, p_novo_nome, descricao, nicho, refresh_minutos
  from public.saas_monitores where id = p_monitor
  returning id into v_novo;
  insert into public.saas_monitor_regras
  select v_novo, semantic_query, incluir, excluir, expansoes, catmat, catser, categorias,
         ufs, municipios, orgaos_incluir, orgaos_excluir, fornecedores, modalidades, situacoes,
         valor_min, valor_max, preco_unit_min, preco_unit_max, abertura_ate_dias, contratos_vencendo_dias,
         monitorar_pca, monitorar_atas, monitorar_contratos, monitorar_desertos, monitorar_fracassados, now()
  from public.saas_monitor_regras where monitor_id = p_monitor;
  insert into public.saas_monitor_config_hist (monitor_id, config, alterado_por)
  values (v_novo, jsonb_build_object('acao', 'duplicado_de', 'origem', p_monitor), v_uid);
  perform public.saas_monitor_avaliar(v_novo, true);
  perform public.saas_monitor_baseline_calc(v_novo);
  return v_novo;
end $$;

-- sugestões de expansão a partir da base real (§6): nada inventado,
-- vem das descrições de itens e do catálogo efetivamente coletados
create or replace function public.saas_monitor_sugerir_expansoes(p_termos jsonb)
returns jsonb language plpgsql security definer set search_path = public, bolsa as $$
declare v_pats text[]; v jsonb;
begin
  select coalesce(array_agg('%' || t || '%'), '{}')
    into v_pats from jsonb_array_elements_text(p_termos) t where length(trim(t)) > 1;
  if cardinality(v_pats) = 0 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(row_to_json(s)), '[]'::jsonb) into v from (
    select lower(left(trim(i.descricao), 80)) as sugestao, count(*) as ocorrencias,
           max(i.catalogo_codigo) filter (where i.catalogo_codigo is not null) as catalogo_codigo
    from bolsa.itens i
    where i.descricao ilike any (v_pats)
    group by 1 order by count(*) desc limit 20) s;
  return v;
end $$;

-- painel completo do monitor em uma chamada (§22, §38, §87)
create or replace function public.saas_monitor_painel(p_monitor bigint)
returns jsonb language plpgsql stable security definer set search_path = public, bolsa as $$
declare v jsonb; v_uid uuid := auth.uid();
begin
  if not exists (select 1 from public.saas_monitores
                 where id = p_monitor and (user_id = v_uid or public.saas_is_admin())) then
    raise exception 'monitor não encontrado ou sem permissão';
  end if;

  with lic as (
    select l.* from bolsa.licitacoes l
    join public.saas_monitor_matches mm
      on mm.monitor_id = p_monitor and mm.entidade = 'licitacao' and mm.chave = l.numero_controle_pncp
  )
  select jsonb_build_object(
    'monitor', (select row_to_json(m) from public.saas_monitores m where m.id = p_monitor),
    'regras', (select row_to_json(r) from public.saas_monitor_regras r where r.monitor_id = p_monitor),
    'agora', jsonb_build_object(
      'abertas', (select count(*) from lic where data_encerramento_proposta > now()),
      'valor_aberto', (select sum(valor_total_estimado) from lic where data_encerramento_proposta > now()),
      'total_matches', (select count(*) from public.saas_monitor_matches where monitor_id = p_monitor),
      'valor_mercado', (select sum(valor_total_estimado) from lic),
      'novidades_24h', (select count(*) from public.saas_monitor_eventos
                        where monitor_id = p_monitor and criado_em > now() - interval '24 hours')),
    'oportunidades_abertas', (select coalesce(jsonb_agg(row_to_json(o)), '[]'::jsonb) from (
      select numero_controle_pncp, left(objeto, 160) objeto, valor_total_estimado, uf, municipio_nome,
             modalidade_nome, data_encerramento_proposta, link_sistema_origem
      from lic where data_encerramento_proposta > now()
      order by data_encerramento_proposta asc limit 30) o),
    'concorrentes', (select coalesce(jsonb_agg(row_to_json(c)), '[]'::jsonb) from (
      select ri.fornecedor_ni ni, max(ri.fornecedor_nome) nome, count(*) vitorias,
             sum(ri.valor_total_homologado) valor,
             percentile_cont(0.5) within group (order by ri.valor_unitario_homologado) preco_mediano
      from bolsa.resultados_itens ri
      join public.saas_monitor_matches mm
        on mm.monitor_id = p_monitor and mm.entidade = 'licitacao' and mm.chave = ri.numero_controle_pncp
      where ri.fornecedor_ni is not null
      group by ri.fornecedor_ni order by count(*) desc limit 10) c),
    'orgaos', (select coalesce(jsonb_agg(row_to_json(o)), '[]'::jsonb) from (
      select orgao_cnpj, count(*) processos, sum(valor_total_estimado) valor, max(uf) uf
      from lic group by orgao_cnpj order by count(*) desc limit 10) o),
    'mapa_ufs', (select coalesce(jsonb_object_agg(uf, v2), '{}'::jsonb) from (
      select uf, sum(valor_total_estimado) v2 from lic where uf is not null group by uf) u),
    'serie_mensal', (select coalesce(jsonb_object_agg(mes, j), '{}'::jsonb) from (
      select to_char(data_publicacao_pncp, 'YYYY-MM') mes,
             jsonb_build_object('processos', count(*), 'valor', sum(valor_total_estimado)) j
      from lic where data_publicacao_pncp is not null group by 1 order by 1) s),
    'futuro', jsonb_build_object(
      'contratos_vencendo', (select coalesce(jsonb_agg(row_to_json(cv)), '[]'::jsonb) from (
        select mm.chave, mm.snapshot from public.saas_monitor_matches mm
        where mm.monitor_id = p_monitor and mm.entidade = 'contrato'
        order by (mm.snapshot->>'vigencia_fim') asc limit 20) cv),
      'valor_contratos_vencendo', (select sum((snapshot->>'valor')::numeric)
        from public.saas_monitor_matches where monitor_id = p_monitor and entidade = 'contrato'),
      'pca', (select coalesce(jsonb_agg(row_to_json(pc)), '[]'::jsonb) from (
        select mm.chave, mm.snapshot from public.saas_monitor_matches mm
        where mm.monitor_id = p_monitor and mm.entidade = 'pca' limit 20) pc),
      'atas', (select coalesce(jsonb_agg(row_to_json(a2)), '[]'::jsonb) from (
        select mm.chave, mm.snapshot from public.saas_monitor_matches mm
        where mm.monitor_id = p_monitor and mm.entidade = 'ata' limit 20) a2)),
    'timeline', (select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) from (
      select id, tipo, titulo, importancia, criado_em, lido, dados
      from public.saas_monitor_eventos where monitor_id = p_monitor
      order by criado_em desc limit 40) t),
    'baseline', (select stats from public.saas_monitor_baseline where monitor_id = p_monitor)
  ) into v;
  return v;
end $$;

-- resumo dos monitores do usuário (cards da central, §91-92)
create or replace function public.saas_meus_monitores()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(row_to_json(x)), '[]'::jsonb) from (
    select m.id, m.nome, m.nicho, m.status, m.refresh_minutos, m.last_run_at, m.next_run_at,
      (select count(*) from public.saas_monitor_matches mm where mm.monitor_id = m.id) matches,
      (select count(*) from public.saas_monitor_matches mm
        where mm.monitor_id = m.id and mm.entidade = 'licitacao') licitacoes,
      (select count(*) from public.saas_monitor_eventos e
        where e.monitor_id = m.id and e.criado_em > now() - interval '24 hours') novidades_24h,
      (select count(*) from public.saas_monitor_eventos e
        where e.monitor_id = m.id and not e.lido and e.importancia in ('alta','critica')) alertas_nao_lidos,
      (select r.incluir from public.saas_monitor_regras r where r.monitor_id = m.id) termos
    from public.saas_monitores m
    where m.user_id = auth.uid()
    order by m.criado_em desc) x;
$$;

-- tick global chamado pelo cron (~10 min, §23): reavalia monitores vencidos
create or replace function public.saas_monitor_tick()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v jsonb := '[]'::jsonb; v_res jsonb;
begin
  for r in select id from public.saas_monitores
           where status = 'ativo' and next_run_at <= now()
           order by next_run_at asc limit 25
  loop
    begin
      v_res := public.saas_monitor_avaliar(r.id, false);
      v := v || jsonb_build_array(v_res);
    exception when others then
      v := v || jsonb_build_array(jsonb_build_object('monitor', r.id, 'erro', sqlerrm));
      update public.saas_monitores set next_run_at = now() + interval '30 minutes' where id = r.id;
    end;
  end loop;
  return jsonb_build_object('avaliados', jsonb_array_length(v), 'resultados', v);
end $$;

-- métricas de monitoramento para o admin (§97)
create or replace function public.saas_admin_monitor_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.saas_is_admin() then raise exception 'acesso restrito a administradores'; end if;
  return jsonb_build_object(
    'monitores_total', (select count(*) from public.saas_monitores),
    'monitores_ativos', (select count(*) from public.saas_monitores where status = 'ativo'),
    'matches_total', (select count(*) from public.saas_monitor_matches),
    'eventos_24h', (select count(*) from public.saas_monitor_eventos where criado_em > now() - interval '24 hours'),
    'eventos_criticos_24h', (select count(*) from public.saas_monitor_eventos
                             where criado_em > now() - interval '24 hours' and importancia = 'critica'),
    'proxima_execucao', (select min(next_run_at) from public.saas_monitores where status = 'ativo'));
end $$;

grant execute on function public.saas_monitor_criar(text, jsonb) to authenticated;
grant execute on function public.saas_monitor_atualizar(bigint, jsonb) to authenticated;
grant execute on function public.saas_monitor_duplicar(bigint, text) to authenticated;
grant execute on function public.saas_monitor_painel(bigint) to authenticated;
grant execute on function public.saas_meus_monitores() to authenticated;
grant execute on function public.saas_monitor_sugerir_expansoes(jsonb) to authenticated;
grant execute on function public.saas_admin_monitor_stats() to authenticated;
-- avaliar/baseline/tick não são expostos a clientes (rodam via cron/criação)
revoke execute on function public.saas_monitor_avaliar(bigint, boolean) from public, anon, authenticated;
revoke execute on function public.saas_monitor_baseline_calc(bigint) from public, anon, authenticated;
revoke execute on function public.saas_monitor_tick() from public, anon, authenticated;

-- cron: reavaliação a cada 10 minutos (§23). A ingestão das fontes mantém
-- as frequências próprias já configuradas; aqui só reavaliamos nossa base.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'saas_monitores_tick') then
    perform cron.unschedule('saas_monitores_tick');
  end if;
  perform cron.schedule('saas_monitores_tick', '*/10 * * * *', 'select public.saas_monitor_tick()');
end $$;
