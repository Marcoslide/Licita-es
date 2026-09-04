-- Wave 1 P0 — liga a coleta contínua da BLL Compras (mesma família de
-- tecnologia da BNC). Offset de 10min em relação ao bolsa_bnc
-- (*/30 min) para não bater os dois exatamente no mesmo minuto.
insert into bolsa.coleta_config (job, cron, params, ativo)
values ('bll', '10,40 * * * *', jsonb_build_object('job', 'listagem'), true)
on conflict (job) do update set cron = excluded.cron, params = excluded.params, ativo = true;

select cron.schedule('bolsa_bll', '10,40 * * * *', $$select bolsa.disparar_fonte('coleta-bll','bll')$$);
