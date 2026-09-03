-- ============================================================
-- MEMÓRIA HISTÓRICA NACIONAL — backfill particionado (PARTE B)
-- Fonte → dataset → ano → mês, com cursor de retomada (§55-59),
-- fila controlada, cobertura real (§64-65), memória de preços (§68)
-- e agregações analíticas (§81-82).
-- ============================================================

-- ---------- controle de backfill (§57) ----------
create table bolsa.backfill_jobs (
  id bigint generated always as identity primary key,
  fonte text not null,                                  -- pncp, compras_gov, transparencia, contratos_gov
  dataset text not null,                                -- contratacoes, contratos, atas, ...
  ano int not null,
  mes int check (mes between 1 and 12),
  particao text,                                        -- detalhe extra da partição quando houver
  status text not null default 'QUEUED'
    check (status in ('QUEUED','RUNNING','PAUSED','COMPLETED','FAILED','PARTIAL')),
  prioridade int not null default 100,                  -- menor = primeiro (§103: recente primeiro)
  cursor jsonb not null default '{}'::jsonb,            -- retomada exata (§59)
  expected_records int,
  processed_records int not null default 0,
  inserted int not null default 0,
  updated int not null default 0,
  errors int not null default 0,
  started_at timestamptz,
  finished_at timestamptz,
  detalhe jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now(),
  unique nulls not distinct (fonte, dataset, ano, mes, particao)
);
create index backfill_fila_idx on bolsa.backfill_jobs (status, prioridade, ano desc, mes desc);

-- reivindica o próximo job da fila (atômico — usado pela Edge Function)
create or replace function bolsa.backfill_reivindicar(p_fonte text default 'pncp')
returns bolsa.backfill_jobs language plpgsql security definer set search_path = bolsa as $$
declare j bolsa.backfill_jobs;
begin
  -- PARTIAL antes de QUEUED: termina um mês começado antes de abrir outro
  select * into j from bolsa.backfill_jobs
   where fonte = p_fonte and status in ('QUEUED','PARTIAL')
   order by (status = 'PARTIAL') desc, prioridade, ano desc, mes desc
   for update skip locked limit 1;
  if found then
    update bolsa.backfill_jobs
       set status = 'RUNNING', started_at = coalesce(started_at, now())
     where id = j.id;
    j.status := 'RUNNING';
  end if;
  return j;
end $$;

-- ---------- fila de partições PNCP (contratações por mês de publicação) ----------
-- Prioridade: 2026 → 2025 → 2024 → 2023 → 2022 → 2021 (§103). O PNCP nasceu com a
-- Lei 14.133 em 2021; meses sem dados serão COMPLETED com 0 registros — evidência
-- honesta da cobertura real da fonte (§47: testar, não presumir).
insert into bolsa.backfill_jobs (fonte, dataset, ano, mes, prioridade)
select 'pncp', 'contratacoes', a.ano, m.mes,
       (2026 - a.ano) * 100 + (12 - m.mes)
from (values (2026),(2025),(2024),(2023),(2022),(2021)) a(ano)
cross join generate_series(1, 12) m(mes)
where make_date(a.ano, m.mes, 1) <= date_trunc('month', current_date)::date
  and make_date(a.ano, m.mes, 1) >= date '2021-01-01'
on conflict do nothing;

-- contratos históricos do PNCP (dataset separado, prioridade menor que contratações §100)
insert into bolsa.backfill_jobs (fonte, dataset, ano, mes, prioridade)
select 'pncp', 'contratos', a.ano, m.mes,
       5000 + (2026 - a.ano) * 100 + (12 - m.mes)
from (values (2026),(2025)) a(ano)
cross join generate_series(1, 12) m(mes)
where make_date(a.ano, m.mes, 1) <= date_trunc('month', current_date)::date
on conflict do nothing;

-- fontes que dependem de outra via (registradas na fila com o motivo — nada fica invisível):
insert into bolsa.backfill_jobs (fonte, dataset, ano, mes, prioridade, status, detalhe) values
 ('compras_gov', 'csv_anuais_14133', 2025, null, 9000, 'PAUSED',
  '{"motivo":"repositório CSV oficial exige avaliação de volume/latência a partir do ambiente de execução; API módulo legado instável (TEMPORARILY_UNAVAILABLE). Destravar após validar acesso em lote."}'),
 ('compras_gov', 'csv_anuais_14133', 2024, null, 9001, 'PAUSED',
  '{"motivo":"idem 2025 — importação em lote planejada (§48-50)"}'),
 ('transparencia', 'licitacoes_downloads', 2025, null, 9100, 'PAUSED',
  '{"motivo":"AGUARDANDO_CHAVE: chave de API do Portal da Transparência ainda não cadastrada em bolsa.segredos (usuário fará o cadastro)"}'),
 ('contratos_gov', 'contratos_historico', 2025, null, 9200, 'PAUSED',
  '{"motivo":"API atual pagina por vigência corrente; backfill histórico usará filtros de período após validação de parâmetros no OpenAPI"}')
on conflict do nothing;

-- parâmetros usados pelo disparo automático do backfill (mesmo mecanismo dos crons de coleta)
insert into bolsa.coleta_config (job, cron, params, ativo) values
 ('pncp_backfill', '*/10 * * * *', '{"job":"backfill_tick","orcamentoMs":45000}'::jsonb, true)
on conflict (job) do update set params = excluded.params, ativo = true;

-- ---------- cobertura real — MEMÓRIA DA BOLSA (§64-65) ----------
-- Metodologia declarada: % = meses com ≥1 registro gravado / meses esperados do ano
-- (12, ou meses decorridos no ano corrente). Mede presença de dados por mês, não
-- completude absoluta da fonte (dado CALCULADO, §109).
create or replace view public.bolsa_vw_memoria with (security_invoker = on) as
with meses as (
  select extract(year from d)::int ano, extract(month from d)::int mes
  from generate_series(date '2021-01-01', date_trunc('month', current_date), interval '1 month') d
),
lic as (
  select extract(year from data_publicacao_pncp)::int ano,
         extract(month from data_publicacao_pncp)::int mes,
         count(*) n
  from bolsa.licitacoes where data_publicacao_pncp is not null
  group by 1, 2
)
select m.ano,
       count(*) filter (where l.n > 0) as meses_com_dados,
       count(*) as meses_esperados,
       round(100.0 * count(*) filter (where l.n > 0) / count(*), 1) as cobertura_pct,
       coalesce(sum(l.n), 0) as licitacoes,
       (select count(*) from bolsa.itens i join bolsa.licitacoes li on li.numero_controle_pncp = i.numero_controle_pncp
         where extract(year from li.data_publicacao_pncp)::int = m.ano) as itens,
       (select count(*) from bolsa.resultados_itens ri join bolsa.licitacoes li on li.numero_controle_pncp = ri.numero_controle_pncp
         where extract(year from li.data_publicacao_pncp)::int = m.ano) as resultados,
       (select count(*) from bolsa.contratos c where extract(year from c.data_publicacao_pncp)::int = m.ano) as contratos,
       (select min(li.data_publicacao_pncp)::date from bolsa.licitacoes li
         where extract(year from li.data_publicacao_pncp)::int = m.ano) as primeiro_registro,
       (select max(li.data_publicacao_pncp)::date from bolsa.licitacoes li
         where extract(year from li.data_publicacao_pncp)::int = m.ano) as ultimo_registro
from meses m
left join lic l on l.ano = m.ano and l.mes = m.mes
group by m.ano
order by m.ano desc;

-- fila de backfill visível (para o admin; leitura via RPC com gate — ver saas_admin_memoria)
create or replace view public.bolsa_vw_backfill with (security_invoker = on) as
select id, fonte, dataset, ano, mes, particao, status, prioridade,
       processed_records, inserted, updated, errors, cursor, detalhe,
       started_at, finished_at, criado_em
from bolsa.backfill_jobs
order by status = 'RUNNING' desc, prioridade, ano desc, mes desc;

-- ---------- memória de preços (§68) ----------
-- Fases hoje disponíveis na base: estimado (itens) e homologado (resultados).
-- Preços são POR UNIDADE DECLARADA NA FONTE (§69): compare apenas dentro da mesma
-- unidade; a coluna 'unidade' viaja junto exatamente por isso.
create or replace view public.bolsa_vw_precos_historicos with (security_invoker = on) as
select 'estimado'::text as fase, l.numero_controle_pncp, i.numero_item,
       left(i.descricao, 200) as item, i.catalogo_codigo, i.unidade, i.quantidade,
       i.valor_unitario_estimado as preco_unitario,
       null::text as fornecedor_ni, null::text as fornecedor_nome,
       l.orgao_cnpj, l.uf, l.municipio_nome,
       l.data_publicacao_pncp::date as data_referencia,
       'pncp'::text as fonte, 'DADO CONFIRMADO'::text as classificacao
from bolsa.itens i
join bolsa.licitacoes l on l.numero_controle_pncp = i.numero_controle_pncp
where i.valor_unitario_estimado > 0 and coalesce(i.orcamento_sigiloso, false) = false
union all
select 'homologado', r.numero_controle_pncp, r.numero_item,
       left(i.descricao, 200), i.catalogo_codigo, i.unidade, r.quantidade_homologada,
       r.valor_unitario_homologado,
       r.fornecedor_ni, r.fornecedor_nome,
       l.orgao_cnpj, l.uf, l.municipio_nome,
       coalesce(r.data_resultado::date, l.data_publicacao_pncp::date),
       'pncp', 'DADO CONFIRMADO'
from bolsa.resultados_itens r
join bolsa.licitacoes l on l.numero_controle_pncp = r.numero_controle_pncp
left join bolsa.itens i on i.numero_controle_pncp = r.numero_controle_pncp and i.numero_item = r.numero_item
where r.valor_unitario_homologado > 0;

-- ---------- agregações analíticas (§81-82) ----------
create materialized view if not exists bolsa.mv_mercado_mensal as
select date_trunc('month', data_publicacao_pncp)::date as mes,
       uf, modalidade_nome,
       count(*) as processos,
       sum(valor_total_estimado) as valor_estimado,
       sum(valor_total_homologado) as valor_homologado,
       count(*) filter (where coalesce(situacao_nome, situacao_fonte, '') ilike '%desert%') as desertos,
       count(*) filter (where coalesce(situacao_nome, situacao_fonte, '') ilike '%fracass%') as fracassados
from bolsa.licitacoes
where data_publicacao_pncp is not null
group by 1, 2, 3;
create unique index if not exists mv_mercado_mensal_pk on bolsa.mv_mercado_mensal (mes, uf, modalidade_nome);

create materialized view if not exists bolsa.mv_fornecedor_mensal as
select date_trunc('month', coalesce(r.data_resultado, l.data_publicacao_pncp))::date as mes,
       r.fornecedor_ni, max(r.fornecedor_nome) as fornecedor_nome, l.uf,
       count(*) as itens_vencidos,
       sum(r.valor_total_homologado) as valor_homologado
from bolsa.resultados_itens r
join bolsa.licitacoes l on l.numero_controle_pncp = r.numero_controle_pncp
where r.fornecedor_ni is not null
group by 1, 2, 4;
create unique index if not exists mv_fornecedor_mensal_pk on bolsa.mv_fornecedor_mensal (mes, fornecedor_ni, uf);

create or replace function bolsa.atualizar_agregados()
returns void language plpgsql security definer set search_path = bolsa as $$
begin
  -- refresh simples: volume atual não justifica 'concurrently' (que não roda em função)
  refresh materialized view bolsa.mv_mercado_mensal;
  refresh materialized view bolsa.mv_fornecedor_mensal;
end $$;

create or replace view public.bolsa_vw_mercado_mensal with (security_invoker = on) as
select * from bolsa.mv_mercado_mensal order by mes desc;

grant select on public.bolsa_vw_memoria, public.bolsa_vw_precos_historicos,
  public.bolsa_vw_mercado_mensal to anon, authenticated;
grant select on public.bolsa_vw_backfill to authenticated;

-- ---------- painel admin da memória (§98) ----------
create or replace function public.saas_admin_memoria()
returns jsonb language plpgsql stable security definer set search_path = public, bolsa as $$
begin
  if not public.saas_is_admin() then raise exception 'acesso restrito a administradores'; end if;
  return jsonb_build_object(
    'cobertura', (select coalesce(jsonb_agg(row_to_json(c)), '[]'::jsonb)
                  from public.bolsa_vw_memoria c),
    'fila', (select coalesce(jsonb_agg(row_to_json(f)), '[]'::jsonb) from (
       select fonte, dataset, ano, mes, status, processed_records, inserted, updated, errors,
              cursor, detalhe, started_at, finished_at
       from bolsa.backfill_jobs
       order by status = 'RUNNING' desc, prioridade, ano desc, mes desc limit 120) f),
    'resumo_fila', (select jsonb_object_agg(status, n) from (
       select status, count(*) n from bolsa.backfill_jobs group by status) s),
    'metodologia', 'Cobertura = meses com pelo menos 1 registro gravado / meses do ano. Mede presença mensal de dados reais na nossa base, não completude absoluta da fonte (dado CALCULADO).');
end $$;
grant execute on function public.saas_admin_memoria() to authenticated;

-- ---------- crons ----------
do $$
begin
  if exists (select 1 from cron.job where jobname = 'bolsa_backfill_tick') then
    perform cron.unschedule('bolsa_backfill_tick');
  end if;
  -- uma partição por vez, a cada 10 minutos: backfill controlado (§55, §102)
  perform cron.schedule('bolsa_backfill_tick', '*/10 * * * *',
    $cmd$select bolsa.disparar_fonte('coleta-pncp-backfill','pncp_backfill')$cmd$);
  if exists (select 1 from cron.job where jobname = 'bolsa_agregados_refresh') then
    perform cron.unschedule('bolsa_agregados_refresh');
  end if;
  perform cron.schedule('bolsa_agregados_refresh', '25 * * * *',
    $cmd$select bolsa.atualizar_agregados()$cmd$);
end $$;
