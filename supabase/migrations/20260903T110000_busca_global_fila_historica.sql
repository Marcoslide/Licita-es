-- ============================================================
-- BUSCA GLOBAL REAL + FILA HISTÓRICA DA TRANSPARÊNCIA
-- 1) bolsa_buscar: busca pública (terminal/portal) com a regra
--    corrigida — todas as palavras do termo, sem acento — sobre a
--    base atual (PNCP) e o histórico legado, com contagem por ano.
-- 2) Fila mês a mês da Transparência (licitações/participantes/
--    empenhos, downloads públicos sem chave) + cron do importador.
-- Ajuste posterior (aplicado direto): meses > 2024-01 IGNORADO
-- (dataset SIASG encerrado; fonte responde 403) e fila estendida
-- até 2013-01 — cobertura real descoberta por sondagem.
-- ============================================================

create or replace function public.bolsa_buscar(p_q text, p_limite int default 20)
returns jsonb language sql stable security definer set search_path = public, bolsa as $$
  select jsonb_build_object(
    'q', p_q,
    'atuais', coalesce((select jsonb_agg(row_to_json(a)) from (
       select numero_controle_pncp, left(objeto, 180) objeto, uf, municipio_nome,
              valor_total_estimado, data_encerramento_proposta, situacao_nome,
              extract(year from data_publicacao_pncp)::int ano, link_sistema_origem
       from bolsa.licitacoes
       where public.saas_mon_texto_ok(objeto, array[p_q])
       order by data_publicacao_pncp desc nulls last
       limit least(coalesce(p_limite, 20), 50)) a), '[]'::jsonb),
    'historico', coalesce((select jsonb_agg(row_to_json(h)) from (
       select chave_fonte, left(objeto, 180) objeto, uf, municipio, valor, ano, situacao, fonte
       from bolsa.licitacoes_legado
       where public.saas_mon_texto_ok(objeto, array[p_q])
       order by ano desc nulls last
       limit least(coalesce(p_limite, 20), 50)) h), '[]'::jsonb),
    'por_ano', coalesce((select jsonb_object_agg(ano, n) from (
       select ano, count(*) n from (
         select extract(year from data_publicacao_pncp)::int ano from bolsa.licitacoes
         where public.saas_mon_texto_ok(objeto, array[p_q])
         union all
         select ano from bolsa.licitacoes_legado where public.saas_mon_texto_ok(objeto, array[p_q])
       ) t where ano is not null group by ano) y), '{}'::jsonb));
$$;
grant execute on function public.bolsa_buscar(text, int) to anon, authenticated;

insert into bolsa.coleta_config (job, cron, params, ativo) values
 ('historico_bulk', '*/10 * * * *', '{"job":"auto","orcamentoMs":50000}'::jsonb, true)
on conflict (job) do update set params = excluded.params, ativo = true;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'bolsa_historico_tick') then
    perform cron.unschedule('bolsa_historico_tick');
  end if;
  perform cron.schedule('bolsa_historico_tick', '*/10 * * * *',
    $cmd$select bolsa.disparar_fonte('coleta-historico-bulk','historico_bulk')$cmd$);
end $$;

update bolsa.backfill_jobs
   set detalhe = detalhe || '{"motivo":"substituído: downloads mensais públicos importados via coleta-historico-bulk (sem chave). A chave de API segue necessária só para os endpoints de consulta."}'::jsonb
 where fonte = 'transparencia' and dataset = 'licitacoes_downloads';

-- fila mês a mês (o importador roda em ordem decrescente: recente primeiro §68;
-- depois de 2021 segue sozinho para o legado 2020→2013 §69)
insert into bolsa.arquivos_historicos (fonte, dataset, ano, mes, url, import_status)
select 'transparencia', 'licitacoes_zip',
       extract(year from d)::int, extract(month from d)::int,
       'https://portaldatransparencia.gov.br/download-de-dados/licitacoes/' || to_char(d, 'YYYYMM'),
       'AGENDADO'
from generate_series(date '2013-01-01',
                     (date_trunc('month', current_date) - interval '1 month')::date,
                     interval '1 month') d
on conflict (url) do nothing;
