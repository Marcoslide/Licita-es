-- ============================================================
-- PROMPT 01 (§13B) — separar explicitamente FONTE FÍSICA × CONECTOR ×
-- DATASET × CAPACIDADE, com dataset vindo do dado REAL observado
-- (bolsa.arquivos_historicos.dataset), não de texto livre digitado.
--
-- Modelo final dos 4 conceitos nesta plataforma:
--   fonte física  = bolsa.fontes_registro (uma linha por site/API/
--                   repositório do levantamento; ex.: "Portal da
--                   Transparência Federal")
--   conector      = bolsa.fontes_registro.conector (slug da edge
--                   function que realmente fala com a fonte; ex.:
--                   "coleta-historico-transp"). 1 fonte pode ter 0
--                   ou 1 conector hoje; 1 conector pode atender mais
--                   de 1 linha de fonte (ex.: PNCP tem 5 linhas no
--                   levantamento — contratações/PCA/contratos/atas/
--                   catálogo — servidas pelo mesmo conector coleta-pncp)
--   dataset       = o "arquivo/tabela lógica" que o conector baixa
--                   (bolsa.arquivos_historicos.dataset para as fontes
--                   bulk: 'licitacoes_zip', 'comprasgov_anual_compras',
--                   'contratos_anual' etc. — string REAL gravada a
--                   cada execução, não estimada)
--   capacidade    = bolsa.v_capacidades_comprovadas (o que o dataset
--                   efetivamente virou em linhas normalizadas, com
--                   contagem ao vivo)
-- Esta view só pode existir depois de 20260903T213000 (fontes_registro).
-- ============================================================
create or replace view bolsa.v_fontes_datasets_reais as
select fr.source_id, fr.nome as fonte_fisica, fr.conector,
       ah.dataset,
       count(*) as arquivos,
       count(*) filter (where ah.import_status = 'COMPLETE') as arquivos_completos,
       sum(ah.linhas_processadas) as linhas_processadas_total,
       max(ah.finalizado_em) as ultimo_completo_em
from bolsa.fontes_registro fr
join bolsa.arquivos_historicos ah
  on ah.fonte = case fr.conector
       when 'coleta-historico-transp'    then 'transparencia'
       when 'coleta-historico-bulk'      then 'compras_gov'
       when 'coleta-historico-contratos' then 'contratos_gov'
     end
where fr.conector in ('coleta-historico-transp','coleta-historico-bulk','coleta-historico-contratos')
group by fr.source_id, fr.nome, fr.conector, ah.dataset
order by fr.source_id, ah.dataset;
