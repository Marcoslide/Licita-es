-- ============================================================
-- BUSCA PRECISA + MEMÓRIA HISTÓRICA v2
-- 1) Correção da busca: cada termo do monitor agora exige TODAS
--    as suas palavras no texto (E), sem depender de acentos;
--    termos diferentes continuam alternativas (OU). Corrige
--    "energia solar" trazendo "energia elétrica" etc.
-- 2) Memória: cobertura por fonte, arquivos históricos em lote com
--    retomada por byte, participações (participar ≠ vencer),
--    entidades legadas multifonte, erros de importação e aceite
--    por ano.
-- ============================================================

create extension if not exists unaccent with schema extensions;

-- wrapper imutável (dicionário fixado) para usar em expressões
create or replace function bolsa.sem_acento(t text)
returns text language sql immutable parallel safe as $$
  select extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(t, ''));
$$;

-- um TEXTO corresponde a um conjunto de TERMOS?
-- regra: para algum termo, TODAS as palavras do termo aparecem no texto
-- (ordem livre), comparação sem acento e sem caixa.
create or replace function public.saas_mon_texto_ok(p_texto text, p_termos text[])
returns boolean language sql immutable parallel safe as $$
  select case when p_termos is null or cardinality(p_termos) = 0 then false else exists (
    select 1 from unnest(p_termos) termo
    where (
      select bool_and(bolsa.sem_acento(lower(p_texto)) like '%' || w || '%')
      from unnest(regexp_split_to_array(bolsa.sem_acento(lower(trim(termo))), '\s+')) w
      where length(w) > 1
    )
  ) end;
$$;

-- termos efetivos do monitor: incluir + expansões aprovadas (§6)
create or replace function public.saas_mon_termos(p_regras public.saas_monitor_regras)
returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct t), '{}') from (
    select unnest(p_regras.incluir) as t
    union
    select jsonb_array_elements_text(coalesce(p_regras.expansoes->'aprovadas', '[]'::jsonb))
  ) x where length(trim(t)) > 1;
$$;

-- ============================================================
-- MEMÓRIA v2 — estruturas
-- ============================================================

create table bolsa.fontes_cobertura (
  id bigint generated always as identity primary key,
  fonte text not null,
  dataset text not null,
  earliest_available text,
  latest_available text,
  metodo text,
  verificado_em timestamptz not null default now(),
  detalhe jsonb not null default '{}'::jsonb,
  unique (fonte, dataset)
);

create table bolsa.arquivos_historicos (
  id bigint generated always as identity primary key,
  fonte text not null,
  dataset text not null,
  ano int,
  mes int,
  url text not null unique,
  tamanho_bytes bigint,
  sha256 text,
  aceita_range boolean,
  import_status text not null default 'DESCOBERTO'
    check (import_status in ('DESCOBERTO','AGENDADO','IMPORTANDO','IMPORTADO','ERRO','IGNORADO')),
  parser_version int not null default 1,
  cursor_bytes bigint not null default 0,
  resto_linha text,
  linhas_processadas bigint not null default 0,
  inseridos bigint not null default 0,
  atualizados bigint not null default 0,
  erros bigint not null default 0,
  baixado_em timestamptz,
  finalizado_em timestamptz,
  detalhe jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now()
);
create index arq_hist_fila_idx on bolsa.arquivos_historicos (import_status, fonte, ano desc, mes desc);

create table bolsa.licitacoes_legado (
  id bigint generated always as identity primary key,
  fonte text not null,
  chave_fonte text not null,
  ano int,
  modalidade text,
  numero text,
  processo text,
  orgao_codigo text,
  orgao_nome text,
  ug_codigo text,
  ug_nome text,
  uf text,
  municipio text,
  objeto text,
  situacao text,
  valor numeric,
  data_resultado date,
  data_abertura date,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  possivel_duplicado_pncp text,
  unique (fonte, chave_fonte)
);
create index lic_legado_objeto_trgm on bolsa.licitacoes_legado using gin (objeto extensions.gin_trgm_ops);
create index lic_legado_ano_idx on bolsa.licitacoes_legado (ano, fonte);

create table bolsa.itens_legado (
  id bigint generated always as identity primary key,
  fonte text not null,
  licitacao_chave text not null,
  numero_item text,
  descricao text,
  quantidade numeric,
  valor_unitario numeric,
  valor_total numeric,
  vencedor_ni text,
  vencedor_nome text,
  ano int,
  item_key text generated always as (coalesce(numero_item, '')) stored,
  vend_key text generated always as (coalesce(vencedor_ni, '')) stored,
  unique (fonte, licitacao_chave, item_key, vend_key)
);
create index itens_legado_lic_idx on bolsa.itens_legado (fonte, licitacao_chave);

-- participações (§13-14): participar ≠ vencer
create table bolsa.participacoes (
  id bigint generated always as identity primary key,
  fonte text not null,
  licitacao_chave text not null,
  item_numero text,
  fornecedor_ni text,
  fornecedor_nome text,
  situacao text not null default 'participou'
    check (situacao in ('participou','classificado','desclassificado','vencedor')),
  data_referencia date,
  ano int,
  criado_em timestamptz not null default now(),
  item_key text generated always as (coalesce(item_numero, '')) stored,
  forn_key text generated always as (coalesce(fornecedor_ni, '')) stored,
  unique (fonte, licitacao_chave, item_key, forn_key, situacao)
);
create index part_forn_idx on bolsa.participacoes (fornecedor_ni, ano);
create index part_lic_idx on bolsa.participacoes (fonte, licitacao_chave);

create table bolsa.empenhos_licitacao (
  id bigint generated always as identity primary key,
  fonte text not null default 'transparencia',
  licitacao_chave text not null,
  empenho_codigo text not null,
  data_emissao date,
  valor numeric,
  favorecido_ni text,
  favorecido_nome text,
  ano int,
  unique (fonte, licitacao_chave, empenho_codigo)
);

create table bolsa.import_erros (
  id bigint generated always as identity primary key,
  arquivo_id bigint references bolsa.arquivos_historicos(id) on delete cascade,
  linha_num bigint,
  erro text,
  conteudo text,
  criado_em timestamptz not null default now()
);

create table bolsa.memoria_anos (
  ano int not null,
  fonte text not null,
  status text not null default 'PARCIAL' check (status in ('PARCIAL','VALIDADO')),
  relatorio jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now(),
  primary key (ano, fonte)
);

-- ============================================================
-- ESTATÍSTICAS DE PREÇO com amostra obrigatória (§33-34)
-- ============================================================
create or replace function public.bolsa_precos_estatisticas(p_termo text)
returns jsonb language sql stable security definer set search_path = public, bolsa as $$
  select coalesce(jsonb_agg(row_to_json(s)), '[]'::jsonb) from (
    select fase, unidade,
           count(*) as n,
           round(avg(preco_unitario)::numeric, 2) media,
           percentile_cont(0.5) within group (order by preco_unitario) mediana,
           min(preco_unitario) minimo, max(preco_unitario) maximo,
           percentile_cont(0.10) within group (order by preco_unitario) p10,
           percentile_cont(0.25) within group (order by preco_unitario) p25,
           percentile_cont(0.75) within group (order by preco_unitario) p75,
           percentile_cont(0.90) within group (order by preco_unitario) p90
    from public.bolsa_vw_precos_historicos
    where public.saas_mon_texto_ok(item, array[p_termo])
    group by fase, unidade
    having count(*) >= 3
    order by fase, count(*) desc
  ) s;
$$;
grant execute on function public.bolsa_precos_estatisticas(text) to authenticated;

-- ============================================================
-- MOTOR DO MONITOR: matching preciso (recriação de avaliar/sugestões)
-- ============================================================
create or replace function public.saas_monitor_sugerir_expansoes(p_termos jsonb)
returns jsonb language plpgsql security definer set search_path = public, bolsa as $$
declare v_arr text[]; v jsonb;
begin
  select coalesce(array_agg(t), '{}') into v_arr
  from jsonb_array_elements_text(p_termos) t where length(trim(t)) > 1;
  if cardinality(v_arr) = 0 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(row_to_json(s)), '[]'::jsonb) into v from (
    select lower(left(trim(i.descricao), 80)) as sugestao, count(*) as ocorrencias,
           max(i.catalogo_codigo) filter (where i.catalogo_codigo is not null) as catalogo_codigo
    from bolsa.itens i
    where public.saas_mon_texto_ok(i.descricao, v_arr)
    group by 1 order by count(*) desc limit 20) s;
  return v;
end $$;

create or replace function public.saas_monitor_avaliar(p_monitor bigint, p_inicial boolean default false)
returns jsonb language plpgsql security definer set search_path = public, bolsa as $$
declare
  r public.saas_monitor_regras;
  m public.saas_monitores;
  v_termos text[];
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
  v_termos := public.saas_mon_termos(r);

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
    where (cardinality(v_termos) = 0 or public.saas_mon_texto_ok(l.objeto, v_termos))
      and (cardinality(r.excluir) = 0 or not public.saas_mon_texto_ok(l.objeto, r.excluir))
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

  -- ---------- VENCEDORES / CONCORRENTES ----------
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

  -- ---------- CONTRATOS VENCENDO ----------
  if r.monitorar_contratos then
    for rec in
      select 'pncp:' || c.numero_controle_pncp as chave,
             jsonb_build_object('objeto', left(c.objeto, 200), 'valor', c.valor_global,
               'vigencia_fim', c.vigencia_fim, 'fornecedor', c.fornecedor_nome, 'uf', c.uf) as snap,
             c.vigencia_fim, c.valor_global
      from bolsa.contratos c
      where c.vigencia_fim between current_date and current_date + coalesce(r.contratos_vencendo_dias, 180)
        and ((cardinality(v_termos) > 0 and public.saas_mon_texto_ok(c.objeto, v_termos))
             or (cardinality(r.fornecedores) > 0 and c.fornecedor_ni = any (r.fornecedores)))
        and (cardinality(r.excluir) = 0 or not public.saas_mon_texto_ok(c.objeto, r.excluir))
        and (cardinality(r.ufs) = 0 or c.uf = any (r.ufs))
      union all
      select 'gov:' || cg.id_fonte::text,
             jsonb_build_object('objeto', left(cg.objeto, 200), 'valor', cg.valor_global,
               'vigencia_fim', cg.vigencia_fim, 'fornecedor', cg.fornecedor_nome, 'uf', null),
             cg.vigencia_fim, cg.valor_global
      from bolsa.contratos_gov cg
      where cg.vigencia_fim between current_date and current_date + coalesce(r.contratos_vencendo_dias, 180)
        and ((cardinality(v_termos) > 0 and public.saas_mon_texto_ok(cg.objeto, v_termos))
             or (cardinality(r.fornecedores) > 0 and cg.fornecedor_ni = any (r.fornecedores)))
        and (cardinality(r.excluir) = 0 or not public.saas_mon_texto_ok(cg.objeto, r.excluir))
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

  -- ---------- ATAS ----------
  if r.monitorar_atas and cardinality(v_termos) > 0 then
    for rec in
      select a.numero_controle_pncp_ata as chave,
             jsonb_build_object('objeto', left(a.objeto, 200), 'vigencia_fim', a.vigencia_fim, 'uf', a.uf) as snap
      from bolsa.atas a
      where public.saas_mon_texto_ok(a.objeto, v_termos)
        and (cardinality(r.excluir) = 0 or not public.saas_mon_texto_ok(a.objeto, r.excluir))
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

  -- ---------- PCA ----------
  if r.monitorar_pca and cardinality(v_termos) > 0 then
    for rec in
      select p.chave_dedup as chave,
             jsonb_build_object('descricao', left(p.descricao, 200), 'valor', p.valor_total,
               'ano', p.ano_pca, 'data_desejada', p.data_desejada, 'orgao', p.orgao_cnpj) as snap
      from bolsa.pca_itens p
      where public.saas_mon_texto_ok(p.descricao, v_termos)
        and (cardinality(r.excluir) = 0 or not public.saas_mon_texto_ok(p.descricao, r.excluir))
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
revoke execute on function public.saas_monitor_avaliar(bigint, boolean) from public, anon, authenticated;

-- ============================================================
-- VISÕES / ADMIN
-- ============================================================
create or replace view public.bolsa_vw_memoria_fontes with (security_invoker = on) as
select 'pncp'::text fonte, x.ano::int, count(*) registros, 'licitacoes'::text tipo
from (select extract(year from data_publicacao_pncp) ano from bolsa.licitacoes where data_publicacao_pncp is not null) x
group by 1, 2
union all
select fonte, ano, count(*), 'licitacoes_legado' from bolsa.licitacoes_legado where ano is not null group by 1, 2
union all
select fonte, ano, count(*), 'participacoes' from bolsa.participacoes where ano is not null group by 1, 2
union all
select fonte, ano, count(*), 'empenhos' from bolsa.empenhos_licitacao where ano is not null group by 1, 2
order by 2 desc, 1;
grant select on public.bolsa_vw_memoria_fontes to anon, authenticated;

create or replace function public.saas_admin_memoria()
returns jsonb language plpgsql stable security definer set search_path = public, bolsa as $$
begin
  if not public.saas_is_admin() then raise exception 'acesso restrito a administradores'; end if;
  return jsonb_build_object(
    'cobertura', (select coalesce(jsonb_agg(row_to_json(c)), '[]'::jsonb) from public.bolsa_vw_memoria c),
    'cobertura_fontes', (select coalesce(jsonb_agg(row_to_json(cf)), '[]'::jsonb) from public.bolsa_vw_memoria_fontes cf),
    'descobertas', (select coalesce(jsonb_agg(row_to_json(d)), '[]'::jsonb) from (
       select fonte, dataset, earliest_available, latest_available, metodo, verificado_em
       from bolsa.fontes_cobertura order by fonte, dataset) d),
    'arquivos', (select coalesce(jsonb_agg(row_to_json(a)), '[]'::jsonb) from (
       select fonte, dataset, ano, mes, import_status, tamanho_bytes, cursor_bytes,
              linhas_processadas, inseridos, erros, url
       from bolsa.arquivos_historicos
       order by import_status = 'IMPORTANDO' desc, ano desc, mes desc limit 100) a),
    'fila', (select coalesce(jsonb_agg(row_to_json(f)), '[]'::jsonb) from (
       select fonte, dataset, ano, mes, status, processed_records, inserted, updated, errors,
              cursor, detalhe, started_at, finished_at
       from bolsa.backfill_jobs
       order by status = 'RUNNING' desc, prioridade, ano desc, mes desc limit 120) f),
    'resumo_fila', (select jsonb_object_agg(status, n) from (
       select status, count(*) n from bolsa.backfill_jobs group by status) s),
    'anos', (select coalesce(jsonb_agg(row_to_json(ma)), '[]'::jsonb) from (
       select ano, fonte, status, relatorio, atualizado_em from bolsa.memoria_anos order by ano desc) ma),
    'metodologia', 'Cobertura % = meses com ≥1 registro / meses do ano (PNCP). Fontes legadas mostram contagens absolutas por ano — sem % quando o denominador da fonte não é conhecido (§59). Dados CALCULADOS sobre registros reais.');
end $$;
