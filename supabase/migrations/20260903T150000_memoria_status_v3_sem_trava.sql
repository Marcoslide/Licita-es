-- MEMÓRIA HISTÓRICA v3: estados novos, fim da trava de 450MB (alertas 70/80/90%),
-- matriz de cobertura, relatório diário, PG × object storage.
-- Aplicada em produção (rxcfbbzosbfiwyloqtdk) em 2026-09-03 como
-- "memoria_status_v3_sem_trava".

alter table bolsa.arquivos_historicos drop constraint if exists arquivos_historicos_import_status_check;

alter table bolsa.arquivos_historicos alter column detalhe set default '{}'::jsonb;
update bolsa.arquivos_historicos set detalhe = '{}'::jsonb where detalhe is null;

update bolsa.arquivos_historicos set import_status = case import_status
  when 'IMPORTADO' then 'COMPLETE'
  when 'ERRO' then 'FAILED'
  when 'IGNORADO' then 'SOURCE_NOT_AVAILABLE'
  when 'AGENDADO' then case when linhas_processadas>0 or cursor_bytes>0 or (detalhe ? 'cursor') then 'PARTIAL' else 'PENDING' end
  when 'IMPORTANDO' then case when linhas_processadas>0 or cursor_bytes>0 or (detalhe ? 'cursor') then 'PARTIAL' else 'PENDING' end
  when 'DESCOBERTO' then 'PENDING'
  else import_status end
where import_status in ('IMPORTADO','ERRO','IGNORADO','AGENDADO','IMPORTANDO','DESCOBERTO');

alter table bolsa.arquivos_historicos add constraint arquivos_historicos_import_status_check
  check (import_status in ('PENDING','DOWNLOADING','IMPORTING','VALIDATING','COMPLETE','PARTIAL','SOURCE_NOT_AVAILABLE','FAILED'));

update bolsa.arquivos_historicos
   set import_status='PENDING', detalhe = coalesce(detalhe,'{}'::jsonb) || '{"hold":"substituido_por_ano"}'::jsonb
 where url like '%-latest.csv' and dataset in ('comprasgov_anual_compras','comprasgov_anual_resultados','comprasgov_anual_itens',
                                               'contratos_anual','contratos_anual_empenhos');
update bolsa.arquivos_historicos
   set detalhe = coalesce(detalhe,'{}'::jsonb) || '{"hold":"parser_pendente"}'::jsonb
 where fonte='contratos_gov' and url not like '%-latest.csv';
update bolsa.arquivos_historicos set detalhe = detalhe - 'hold'
 where dataset='comprasgov_anual_itens' and url not like '%-latest.csv';

-- reset limpo do compras-2026 (bug mapa null + multiline): reimport integral idempotente
delete from bolsa.licitacoes_legado where fonte='compras_gov';
update bolsa.arquivos_historicos set cursor_bytes=0, resto_linha=null, linhas_processadas=0,
  inseridos=0, erros=0, import_status='PENDING',
  detalhe = (coalesce(detalhe,'{}'::jsonb) - 'mapa' - 'cursor' - 'sep')
            || jsonb_build_object('reset_em', now(), 'motivo_reset',
               'bug: detalhe NULL engolia o mapa de colunas + campos multiline; reimport integral',
               'erros_de_bug_expurgados', (select count(*) from bolsa.import_erros where arquivo_id=223))
 where id=223;
delete from bolsa.import_erros where arquivo_id=223;

-- capacidade: SEM pausa; alertas 70/80/90% de limite configurável
create table if not exists bolsa.capacidade_config(
  id int primary key default 1, limite_bytes bigint not null,
  observacao text, atualizado_em timestamptz default now());
insert into bolsa.capacidade_config(id, limite_bytes, observacao)
 values (1, 524288000, 'Plano atual (500MB). ATUALIZAR após upgrade — alertas de 70/80/90% derivam deste valor. A ingestão NUNCA é pausada por esta config.')
 on conflict (id) do nothing;
create table if not exists bolsa.capacidade_alertas(
  id bigserial primary key, em timestamptz default now(),
  nivel int not null, db_bytes bigint not null, limite_bytes bigint not null);

create or replace function bolsa.checar_capacidade() returns void language plpgsql as $fn$
declare v_db bigint := pg_database_size(current_database());
        v_lim bigint; v_pct numeric; v_nivel int; v_ultimo int;
begin
  select limite_bytes into v_lim from bolsa.capacidade_config where id=1;
  if coalesce(v_lim,0)=0 then return; end if;
  v_pct := 100.0*v_db/v_lim;
  v_nivel := case when v_pct>=90 then 90 when v_pct>=80 then 80 when v_pct>=70 then 70 else 0 end;
  if v_nivel=0 then return; end if;
  select nivel into v_ultimo from bolsa.capacidade_alertas order by id desc limit 1;
  if v_ultimo is distinct from v_nivel then
    insert into bolsa.capacidade_alertas(nivel, db_bytes, limite_bytes) values (v_nivel, v_db, v_lim);
    insert into bolsa.fontes_cobertura (fonte, dataset, metodo, detalhe)
    values ('sistema','capacidade_db',
            format('ALERTA %s%%: banco em %s de %s configurados. A ingestão CONTINUA (nada é apagado nem pausado). Após upgrade, atualize bolsa.capacidade_config.', v_nivel, pg_size_pretty(v_db), pg_size_pretty(v_lim)),
            jsonb_build_object('db_bytes', v_db, 'limite_bytes', v_lim, 'pct', round(v_pct,1), 'em', now()))
    on conflict (fonte, dataset) do update set metodo=excluded.metodo, detalhe=excluded.detalhe, verificado_em=now();
  end if;
end $fn$;

do $$ begin
  if exists (select 1 from cron.job where jobname='bolsa_historico_tick') then perform cron.unschedule('bolsa_historico_tick'); end if;
  if exists (select 1 from cron.job where jobname='bolsa_backfill_tick') then perform cron.unschedule('bolsa_backfill_tick'); end if;
  perform cron.schedule('bolsa_historico_tick','*/5 * * * *',
    $c$select bolsa.checar_capacidade(), bolsa.disparar_fonte('coleta-historico-bulk','historico_bulk')$c$);
  perform cron.schedule('bolsa_backfill_tick','*/10 * * * *',
    $c$select bolsa.checar_capacidade(), bolsa.disparar_fonte('coleta-pncp-backfill','pncp_backfill')$c$);
end $$;

-- PG × object storage
insert into storage.buckets (id, name, public)
 values ('memoria-bruta','memoria-bruta', false) on conflict (id) do nothing;
alter table bolsa.arquivos_historicos add column if not exists storage_path text;

-- relatório diário (criado ANTES da matriz, que o referencia)
create table if not exists bolsa.relatorios_diarios(
  dia date primary key, gerado_em timestamptz default now(), dados jsonb not null);
create or replace function bolsa.gerar_relatorio_diario() returns void language plpgsql as $fn$
declare v jsonb; ant jsonb; d jsonb;
begin
  v := jsonb_build_object(
    'licitacoes_historicas', (select count(*) from bolsa.licitacoes_legado),
    'itens', (select count(*) from bolsa.itens_legado),
    'participantes', (select count(*) from bolsa.participacoes),
    'empenhos', (select count(*) from bolsa.empenhos_licitacao),
    'pncp_atuais', (select count(*) from bolsa.licitacoes),
    'contratos', (select count(*) from bolsa.contratos) + (select count(*) from bolsa.contratos_gov),
    'erros', (select count(*) from bolsa.import_erros),
    'meses_completos', (select count(*) from bolsa.arquivos_historicos where fonte='transparencia' and import_status='COMPLETE'),
    'anos_fechados', (select count(*) from (
        select ano from bolsa.arquivos_historicos
        where fonte='transparencia' and (detalhe->>'hold') is null group by ano
        having count(*) = count(*) filter (where import_status in ('COMPLETE','SOURCE_NOT_AVAILABLE'))) q),
    'db_bytes', pg_database_size(current_database()));
  select dados into ant from bolsa.relatorios_diarios where dia < current_date order by dia desc limit 1;
  if ant is not null then
    select jsonb_object_agg(e.key, (e.value)::bigint - coalesce((ant->>e.key)::bigint, 0)) into d
    from jsonb_each_text(v) e where e.value ~ '^[0-9]+$';
    v := v || jsonb_build_object('delta_24h', d);
  end if;
  insert into bolsa.relatorios_diarios(dia, dados) values (current_date, v)
  on conflict (dia) do update set dados = excluded.dados, gerado_em = now();
end $fn$;
do $$ begin
  if exists (select 1 from cron.job where jobname='bolsa_relatorio_diario') then perform cron.unschedule('bolsa_relatorio_diario'); end if;
  perform cron.schedule('bolsa_relatorio_diario','15 6 * * *', 'select bolsa.gerar_relatorio_diario()');
end $$;
select bolsa.gerar_relatorio_diario();

-- matriz de cobertura p/ o Admin (§16, §17, §18, §24)
create or replace function public.bolsa_admin_matriz()
returns jsonb language sql stable security definer set search_path = public, bolsa as $fn$
select jsonb_build_object(
 'gerado_em', now(),
 'db', jsonb_build_object('bytes', pg_database_size(current_database()),
        'limite_bytes', (select limite_bytes from bolsa.capacidade_config where id=1),
        'pct', round(100.0*pg_database_size(current_database())/(select limite_bytes from bolsa.capacidade_config where id=1),1)),
 'transparencia', (select jsonb_agg(to_jsonb(a) order by a.ano desc) from (
    select ano,
      jsonb_object_agg(lpad(mes::text,2,'0'),
        jsonb_build_object('s', import_status, 'linhas', linhas_processadas, 'erros', erros,
                           'mismatch', coalesce((detalhe->>'coverage_mismatch')::bool, false)) order by mes) meses,
      count(*) filter (where import_status='COMPLETE') completos,
      count(*) filter (where import_status in ('PARTIAL','IMPORTING','VALIDATING','DOWNLOADING')) parciais,
      count(*) filter (where import_status='PENDING') pendentes,
      count(*) filter (where import_status='SOURCE_NOT_AVAILABLE') fonte_indisponivel,
      count(*) filter (where import_status='FAILED') falhas,
      (count(*) filter (where import_status in ('COMPLETE','SOURCE_NOT_AVAILABLE')) = count(*)) ano_fechado
    from bolsa.arquivos_historicos
    where fonte='transparencia' and (detalhe->>'hold') is null
    group by ano) a),
 'compras_gov', (select jsonb_agg(to_jsonb(a) order by a.dataset, a.ano desc) from (
    select dataset, ano, import_status s, cursor_bytes, tamanho_bytes,
      case when coalesce(tamanho_bytes,0)>0 then round(100.0*cursor_bytes/tamanho_bytes,1) end pct,
      inseridos, erros
    from bolsa.arquivos_historicos
    where fonte='compras_gov' and dataset like 'comprasgov_anual%' and (detalhe->>'hold') is null) a),
 'contratos_gov', (select jsonb_agg(to_jsonb(a) order by a.dataset, a.ano desc) from (
    select dataset, ano, import_status s, coalesce(detalhe->>'hold','') hold
    from bolsa.arquivos_historicos where fonte='contratos_gov' and url not like '%-latest.csv') a),
 'pncp', jsonb_build_object(
    'por_mes', (select jsonb_agg(to_jsonb(a) order by a.ym) from (
       select to_char(date_trunc('month', data_publicacao_pncp),'YYYY-MM') ym, count(*) n
       from bolsa.licitacoes where data_publicacao_pncp is not null group by 1) a)),
 'totais_ano', (select jsonb_agg(to_jsonb(t) order by t.ano desc) from (
    select ano,
      sum(n_lics)::bigint licitacoes, sum(vl)::numeric valor_estimado,
      sum(n_itens)::bigint itens, sum(n_parts)::bigint participantes,
      sum(n_venc)::bigint vencedores, max(n_forn)::bigint fornecedores,
      sum(n_emps)::bigint empenhos
    from (
      select ano, count(*)::bigint n_lics, sum(valor)::numeric vl, 0::bigint n_itens, 0::bigint n_parts, 0::bigint n_venc, 0::bigint n_forn, 0::bigint n_emps
        from bolsa.licitacoes_legado group by ano
      union all
      select ano, 0, 0, count(*)::bigint, 0, 0, 0, 0 from bolsa.itens_legado group by ano
      union all
      select ano, 0, 0, 0, count(*)::bigint, (count(*) filter (where situacao='vencedor'))::bigint,
             (count(distinct fornecedor_ni))::bigint, 0 from bolsa.participacoes group by ano
      union all
      select ano, 0, 0, 0, 0, 0, 0, count(*)::bigint from bolsa.empenhos_licitacao group by ano
    ) u where ano is not null group by ano) t),
 'canonicas', jsonb_build_object(
    'registros_fonte', (select count(*) from bolsa.licitacoes_legado) + (select count(*) from bolsa.licitacoes),
    'duplicatas_pncp_marcadas', (select count(*) from bolsa.licitacoes_legado where possivel_duplicado_pncp is not null),
    'entidades_canonicas_estimadas', (select count(*) from bolsa.licitacoes_legado where possivel_duplicado_pncp is null)
                                     + (select count(*) from bolsa.licitacoes)),
 'gaps', (select jsonb_agg(to_jsonb(g) order by g.ano) from (
    select 'transparencia' fonte, ano,
           count(*) filter (where import_status not in ('COMPLETE','SOURCE_NOT_AVAILABLE')) meses_abertos
    from bolsa.arquivos_historicos where fonte='transparencia' and (detalhe->>'hold') is null
    group by ano
    having count(*) filter (where import_status not in ('COMPLETE','SOURCE_NOT_AVAILABLE')) > 0) g),
 'alertas_capacidade', (select jsonb_agg(to_jsonb(x) order by x.id desc) from (
    select id, em, nivel, db_bytes from bolsa.capacidade_alertas order by id desc limit 5) x),
 'relatorio_diario', (select dados from bolsa.relatorios_diarios order by dia desc limit 1)
);
$fn$;
grant execute on function public.bolsa_admin_matriz() to authenticated;

insert into bolsa.memoria_anos (ano, fonte, status, relatorio)
select ano, 'compras_gov', 'PARCIAL', jsonb_build_object('origem','arquivos anuais oficiais SEGES', 'em', now())
from generate_series(2021, 2026) ano
on conflict (ano, fonte) do nothing;

update bolsa.coleta_config set params = jsonb_set(params, '{orcamentoMs}', '20000') where job='historico_bulk';
-- ajuste posterior aplicado direto: orcamentoMs=12000 (limite de CPU do worker free)
