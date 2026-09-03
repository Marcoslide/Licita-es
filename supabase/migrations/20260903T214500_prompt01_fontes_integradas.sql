-- ============================================================
-- PROMPT 01 (vínculo honesto §35) — somente fontes REALMENTE
-- integradas e testadas recebem conector/status operacional.
-- Rodar DEPOIS de 20260903T213000 (estrutura) e 20260903T214000
-- (seed das 765). Contadores reais são computados ao vivo pela
-- view bolsa.v_capacidades_comprovadas — aqui só o vínculo.
-- ============================================================

-- Contratos.gov (comprasnet-contratos, séries anuais SEGES) não tinha
-- linha própria no levantamento — registrada como fonte adicional real.
insert into bolsa.fontes_registro
  (source_id, nome, camada, tipo_entidade, esfera, url, url_descoberta, entrega_declarada,
   metodo_preferencial, metodo, prioridade, status, capacidades, conector, conector_versao,
   tem_historico, historico_desde, freq_recomendada, autenticacao, origem_levantamento, obs)
values
  ('SRC0766', 'Contratos.gov.br — comprasnet-contratos (séries anuais SEGES)', 'Contratos',
   'Repositório oficial de dados abertos', 'Federal',
   'https://repositorio.dados.gov.br/seges/comprasnet_contratos/',
   'https://repositorio.dados.gov.br/seges/comprasnet_contratos/anual/',
   'Contratos administrativos federais e empenhos por contrato (CSV anual, 2021-2026).',
   'CSV oficial por HTTP Range (retomada por byte)', 'csv', 'P0', 'ativa',
   '{"contratos": true, "empenhos": true, "historico": true}'::jsonb,
   'coleta-historico-contratos', 'v12', true, '2021',
   'contínua (cron 1-59/2 min) até esgotar a fila; depois diária',
   'nenhuma (dados abertos)', 'conector já implementado nesta plataforma',
   'Fonte descoberta programaticamente via listagem do repositório SEGES; 4 anos COMPLETE em 03/09/2026.')
on conflict (source_id) do update set status = excluded.status,
  conector = excluded.conector, conector_versao = excluded.conector_versao;

-- PNCP (conectores coleta-pncp/coleta-backfill: contratações, itens,
-- documentos, resultados, atas, PCA, órgãos, timeline — dados reais)
update bolsa.fontes_registro set
  status = 'ativa', conector = 'coleta-pncp', conector_versao = 'produção',
  url_api = 'https://pncp.gov.br/api/consulta', metodo = 'api', tem_historico = true,
  freq_recomendada = 'delta */20 min + detalhes 3x/h + backfill */10 min',
  autenticacao = 'nenhuma (API pública de consulta)',
  discovery = discovery || jsonb_build_object(
    'api_validada', true, 'paginacao', 'pagina/tamanhoPagina',
    'endpoints', jsonb_build_array('/v1/contratacoes/publicacao', '/v1/contratacoes/atualizacao',
                                   '/v1/atas', '/v1/contratos', '/v1/pca'),
    'validado_em', '2026-08-30')
where source_id = 'SRC0141';

update bolsa.fontes_registro set
  status = 'ativa', conector = 'coleta-pncp', conector_versao = 'produção',
  metodo = 'api', obs = coalesce(obs,'') || ' | PCA coletado diariamente (cron 52 6 * * *).'
where source_id = 'SRC0142';

update bolsa.fontes_registro set
  status = 'ativa', conector = 'coleta-contratos', conector_versao = 'produção', metodo = 'api'
where source_id = 'SRC0143';

update bolsa.fontes_registro set
  status = 'ativa', conector = 'coleta-pncp', conector_versao = 'produção', metodo = 'api',
  obs = coalesce(obs,'') || ' | Atas coletadas a cada 2h (cron 37 */2).'
where source_id = 'SRC0144';

-- Compras.gov: dados abertos anuais (bulk Range) + APIs de catálogo/
-- preços/ARP já implementadas e com dados reais
update bolsa.fontes_registro set
  status = 'ativa', conector = 'coleta-historico-bulk', conector_versao = 'v12',
  url_api = 'https://repositorio.dados.gov.br/seges/comprasgov/', metodo = 'misto',
  tem_historico = true, historico_desde = '2021',
  freq_recomendada = 'bulk contínuo (cron 1/min) até esgotar; APIs horárias',
  autenticacao = 'nenhuma (dados abertos)',
  discovery = discovery || jsonb_build_object(
    'range_aceito', true, 'formato', 'CSV anual VW_FT_PNCP_COMPRA / VW_DM_PNCP_ITEM_RESULTADO / VW_FT_PNCP_COMPRA_ITEM',
    'alias_latest', 'duplicata do anual versionado (hold aplicado)', 'validado_em', '2026-09-03')
where source_id = 'SRC0146';

-- ComprasNet portal de disputa (sessão/lances/chat): NÃO integrado —
-- o que temos do Compras.gov vem do SRC0146 (dados abertos). Honesto:
update bolsa.fontes_registro set
  status = 'em_analise',
  obs = coalesce(obs,'') || ' | Sessão/lances/chat em tempo real ainda NÃO integrados; dados estruturados chegam via SRC0146 (dados abertos SEGES).'
where source_id = 'SRC0001';

-- Portal da Transparência — licitações (ZIP mensal, SIASG): ativa
update bolsa.fontes_registro set
  status = 'ativa', conector = 'coleta-historico-transp', conector_versao = 'v12',
  url_api = 'https://portaldatransparencia.gov.br/download-de-dados/licitacoes', metodo = 'csv',
  tem_historico = true, historico_desde = '2013 (série SIASG encerra 2024-01)',
  freq_recomendada = 'backfill contínuo (cron */2 min) até esgotar a série',
  autenticacao = 'nenhuma no download; API de consulta exige chave cadastrada',
  discovery = discovery || jsonb_build_object(
    'zip_mensal', true, 'arquivos', jsonb_build_array('Licitação', 'ItemLicitação', 'ParticipantesLicitação', 'EmpenhosRelacionados'),
    'serie_encerrada_em', '2024-01', 'motivo', 'migração SIASG para Compras.gov/PNCP', 'validado_em', '2026-09-03')
where source_id = 'SRC0152';

-- Portal da Transparência — empenhos/liquidações/pagamentos:
-- integração existe (fase emp do ZIP + API de consulta), dado ainda
-- escasso (arquivos-fonte de empenho vieram vazios nos meses testados).
update bolsa.fontes_registro set
  status = 'desenvolvimento', conector = 'coleta-transparencia', conector_versao = 'produção',
  obs = coalesce(obs,'') || ' | Fase de empenhos do ZIP implementada; EmpenhosRelacionados veio vazio da fonte em 2023-09/2024-01. API de consulta coleta pagamentos (45 reais na base).'
where source_id = 'SRC0154';

-- Transparência contratos / NF-e: sem conector ainda (não inventar §35)
update bolsa.fontes_registro set status = 'em_analise'
where source_id in ('SRC0153', 'SRC0155') and status = 'descoberta';

-- Popular identidade canônica com dados reais (idempotente)
select bolsa.resolver_canonico_pncp();
