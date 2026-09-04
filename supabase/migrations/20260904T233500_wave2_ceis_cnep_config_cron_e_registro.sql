-- Wave 2 #1 — liga coleta contínua de CEIS e CNEP (Portal Transparência).
-- Batch pequeno por tick (300 registros, ~5 round-trips SQL cada) para
-- caber no timeout de disparar_fonte (55s) e ser "backfill controlado"
-- (regra L da Wave 2 — não é um backfill pesado).
insert into bolsa.coleta_config (job, cron, params, ativo)
values
  ('sancoes_ceis', '15,45 * * * *', jsonb_build_object('dataset', 'ceis'), true),
  ('sancoes_cnep', '5,35 * * * *', jsonb_build_object('dataset', 'cnep'), true)
on conflict (job) do update set cron = excluded.cron, params = excluded.params, ativo = true;

select cron.schedule('bolsa_sancoes_ceis', '15,45 * * * *', $$select bolsa.disparar_fonte('coleta-ceis','sancoes_ceis')$$);
select cron.schedule('bolsa_sancoes_cnep', '5,35 * * * *', $$select bolsa.disparar_fonte('coleta-ceis','sancoes_cnep')$$);

update bolsa.fontes_registro
set status = 'ativa', metodo = 'api', conector = 'coleta-ceis', conector_versao = 'v1',
    autenticacao = 'nenhuma',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-04', 'resultado', 'ativo_producao',
      'mecanismo', 'download-de-dados/ceis/YYYYMMDD redireciona para bucket S3 publico (dadosabertos-download.cgu.gov.br) sem WAF/captcha',
      'idempotencia', 'provada em 2 execucoes reais (cursor 0->300->600, sem reiniciar do zero)',
      'canonicalizacao', 'canonico direto por documento (sem contrapartida no PNCP), 100 porcento sem orfaos'
    ),
    obs = obs || ' Wave 2: conector real ativo desde 2026-09-04, 584 registros reais em 2 execucoes, 0 erros, 0 corrompidos.',
    atualizado_em = now()
where source_id = 'SRC0156';

update bolsa.fontes_registro
set status = 'ativa', metodo = 'api', conector = 'coleta-ceis', conector_versao = 'v1',
    autenticacao = 'nenhuma',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-04', 'resultado', 'ativo_producao',
      'mecanismo', 'mesma familia tecnica de SRC0156 (CEIS)',
      'idempotencia', 'provada em 2 execucoes reais (cursor 0->300->600)'
    ),
    obs = obs || ' Wave 2: conector real ativo desde 2026-09-04, 600 registros reais em 2 execucoes, 0 erros.',
    atualizado_em = now()
where source_id = 'SRC0157';

update bolsa.fontes_registro
set obs = obs || ' Wave 2: testado 2026-09-04, download-de-dados/cepim/YYYYMMDD devolveu 403 (nao eh WAF/captcha, parece arquivo do dia nao publicado — CEPIM provavelmente atualiza com frequencia diferente de CEIS/CNEP). Nao investigado a fundo ainda, conector coleta-ceis ja aceita dataset=cepim quando o padrao de URL for confirmado.',
    atualizado_em = now()
where source_id = 'SRC0158';
