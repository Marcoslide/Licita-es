-- Wave 1 P0 — liga a coleta contínua da BNC (primeira fonte nova da Wave 1,
-- autorizada pelo usuário). Intervalo mais conservador que o PNCP (20min)
-- por ser fonte nova/scraping HTML, não API oficial — 30min.
insert into bolsa.coleta_config (job, cron, params, ativo)
values ('bnc', '*/30 * * * *', jsonb_build_object('job', 'listagem'), true)
on conflict (job) do update set cron = excluded.cron, params = excluded.params, ativo = true;

select cron.schedule('bolsa_bnc', '*/30 * * * *', $$select bolsa.disparar_fonte('coleta-bnc','bnc')$$);
