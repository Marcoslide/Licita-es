-- Plano 8GB assinado: capacidade recalibrada (8589934592 bytes em
-- bolsa.capacidade_config), filas independentes por fonte (§22), parser
-- Contratos.gov (§13), PNCP a cada 5min (§14). Brutos da Transparência
-- passam a ser gravados no bucket memoria-bruta pela função v10 (§5).
-- Aplicada em produção como "contratos_legado_filas_paralelas".

create table if not exists bolsa.contratos_legado (
  id bigserial primary key,
  fonte text not null,
  chave_fonte text not null,
  numero text, processo text, tipo text, categoria text, situacao text,
  orgao_nome text, unidade_codigo text,
  fornecedor_ni text, fornecedor_nome text,
  objeto text, valor_global numeric,
  vigencia_inicio date, vigencia_fim date,
  ano int,
  criado_em timestamptz default now(),
  last_seen_at timestamptz default now(),
  unique (fonte, chave_fonte));
create index if not exists contratos_legado_forn_idx on bolsa.contratos_legado (fornecedor_ni, ano);

create table if not exists bolsa.contrato_empenhos_legado (
  id bigserial primary key,
  fonte text not null,
  contrato_chave text not null,
  empenho_codigo text not null,
  data_emissao date, credor_ni text, credor_nome text,
  valor_empenhado numeric, valor_liquidado numeric, valor_pago numeric,
  ano int,
  criado_em timestamptz default now(),
  unique (fonte, contrato_chave, empenho_codigo));

-- contratos.gov entra na fila de verdade (parser implantado na v10)
update bolsa.arquivos_historicos set detalhe = detalhe - 'hold'
 where fonte='contratos_gov' and url not like '%-latest.csv';

-- filas independentes por fonte
insert into bolsa.coleta_config (job, cron, params, ativo) values
 ('historico_transp','*/2 * * * *','{"job":"auto","fonte":"transparencia","orcamentoMs":12000}'::jsonb, true),
 ('historico_cg','* * * * *','{"job":"auto","fonte":"compras","orcamentoMs":12000}'::jsonb, true),
 ('historico_contratos','1-59/2 * * * *','{"job":"auto","fonte":"contratos","orcamentoMs":12000}'::jsonb, true)
on conflict (job) do update set cron=excluded.cron, params=excluded.params, ativo=true;
update bolsa.coleta_config set ativo=false where job='historico_bulk';

do $$ begin
  if exists (select 1 from cron.job where jobname='bolsa_historico_tick') then perform cron.unschedule('bolsa_historico_tick'); end if;
  if exists (select 1 from cron.job where jobname='bolsa_hist_transparencia') then perform cron.unschedule('bolsa_hist_transparencia'); end if;
  if exists (select 1 from cron.job where jobname='bolsa_hist_comprasgov') then perform cron.unschedule('bolsa_hist_comprasgov'); end if;
  if exists (select 1 from cron.job where jobname='bolsa_hist_contratos') then perform cron.unschedule('bolsa_hist_contratos'); end if;
  if exists (select 1 from cron.job where jobname='bolsa_backfill_tick') then perform cron.unschedule('bolsa_backfill_tick'); end if;
  perform cron.schedule('bolsa_hist_transparencia','*/2 * * * *',
    $c$select bolsa.checar_capacidade(), bolsa.disparar_fonte('coleta-historico-bulk','historico_transp')$c$);
  perform cron.schedule('bolsa_hist_comprasgov','* * * * *',
    $c$select bolsa.disparar_fonte('coleta-historico-bulk','historico_cg')$c$);
  perform cron.schedule('bolsa_hist_contratos','1-59/2 * * * *',
    $c$select bolsa.disparar_fonte('coleta-historico-bulk','historico_contratos')$c$);
  perform cron.schedule('bolsa_backfill_tick','*/5 * * * *',
    $c$select bolsa.disparar_fonte('coleta-pncp-backfill','pncp_backfill')$c$);
end $$;

-- (a matriz do admin foi recriada na mesma migração em produção para
--  incluir contratos com % de progresso e totais empenhado/pago por ano)
