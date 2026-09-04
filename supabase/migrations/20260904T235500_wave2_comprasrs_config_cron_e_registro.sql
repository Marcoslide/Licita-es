-- Wave 2 #3 — liga coleta contínua da Compras RS. Batch pequeno por tick
-- (300 registros = 3 páginas de 100), backfill controlado dentro da
-- janela de 12 meses permitida pela própria API.
insert into bolsa.coleta_config (job, cron, params, ativo)
values ('comprasrs', '20,50 * * * *', jsonb_build_object('job', 'listagem'), true)
on conflict (job) do update set cron = excluded.cron, params = excluded.params, ativo = true;

select cron.schedule('bolsa_comprasrs', '20,50 * * * *', $$select bolsa.disparar_fonte('coleta-comprasrs','comprasrs')$$);

update bolsa.fontes_registro
set status = 'ativa', metodo = 'api', conector = 'coleta-comprasrs', conector_versao = 'v2',
    autenticacao = 'nenhuma',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-04', 'resultado', 'ativo_producao',
      'mecanismo', 'POST /editais/pesquisa.json (DataTables server-side), campos publicationStartDate/publicationEndDate, janela maxima de 12 meses',
      'idempotencia', 'provada em 2 execucoes reais (cursor 0->300->600, paginacao por offset sem duplicar)',
      'canonicalizacao', 'reaproveitou bolsa.resolver_canonico_processo_disputa() sem modificacao — mesma entidade processo_disputa da familia BNC/BLL',
      'volume_real', '4427 editais no ultimo ano (janela de 12 meses)'
    ),
    obs = obs || ' Wave 2: conector real ativo desde 2026-09-04, 600 registros reais em 2 execucoes, 0 erros, 4427 editais totais no periodo de 12 meses, canonicalizacao provada (0 orfaos).',
    atualizado_em = now()
where source_id = 'SRC0015';
