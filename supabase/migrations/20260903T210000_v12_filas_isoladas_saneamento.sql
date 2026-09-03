-- ============================================================
-- BOLSA DE LICITAÇÕES — v12: filas isoladas por função + saneamento
-- Aplicada em produção em 2026-09-03 ~21:00 UTC (execute_sql).
--
-- Contexto (verificação "todos os dados subindo"):
-- 1) arquivos_historicos id=223 (compras_gov anual 2026) estava com
--    detalhe corrompido como ARRAY jsonb (append `array || objeto`):
--    lease_ate e mapa ilegíveis -> todo tick reivindicava o arquivo,
--    o guard resetava o cursor a 0 e o arquivo reimportava os mesmos
--    primeiros MB para sempre (cursor oscilando 6-17MB por horas,
--    contadores inflados a 3M+). Correção definitiva no CÓDIGO (v12):
--    todo merge de detalhe usa
--      (case when jsonb_typeof(detalhe)='object' then detalhe
--            else '{}'::jsonb end) || ...
--    e o claim trata detalhe não-objeto como reivindicável (auto-cura).
--    Resultado real: o próprio v12 curou a linha e completou o arquivo
--    (164.221.146 bytes = tamanho do Content-Range, mismatch=false,
--    COMPLETE às 20:59:04Z). Dados do período de loop eram upserts
--    idempotentes — nada duplicado, nada apagado.
-- 2) Transparência morria com HTTP 546 (CPU) em todos os ticks a partir
--    de ~20:00: as TRÊS filas rodavam no MESMO slug de edge function e
--    dividiam o orçamento de CPU do isolate. Cada fila agora tem seu
--    próprio slug (deploy do mesmo código):
--      coleta-historico-bulk      -> fila compras (historico_cg)
--      coleta-historico-transp    -> fila transparência (historico_transp)
--      coleta-historico-contratos -> fila contratos (historico_contratos)
-- 3) Aliases -latest.csv (ids 197/199) duplicavam o dado anual 2026
--    (ids 223/224): ficam com detalhe.hold (o claim ignora hold),
--    sem apagar nada (§4).
-- 4) v12 também: mapa nunca gravado como null; tamanho_bytes persiste
--    do Content-Range (valida coverage_mismatch por bytes); falha do
--    upload do bruto p/ memoria-bruta fica anotada em detalhe
--    (storage_upload_http/err) + console.log; lease transp 100s (< tick
--    de 120s) para focar um mês por vez; contagem_por_arquivo agora é
--    mesclada por chave (fases de invocações anteriores não se perdem).
-- ============================================================

-- (1) saneamento preventivo de qualquer detalhe não-objeto remanescente
--     (o v12 já cura no claim; isto cobre linhas fora das filas)
update bolsa.arquivos_historicos a
set detalhe = jsonb_build_object('saneamento', jsonb_build_object(
      'em', now(),
      'motivo', 'detalhe não-objeto (corrupção por merge em base array/string)',
      'contadores_preservados', jsonb_build_object(
        'linhas_processadas', a.linhas_processadas, 'inseridos', a.inseridos, 'erros', a.erros)))
where jsonb_typeof(a.detalhe) not in ('object') and a.detalhe is not null;

-- (2) aliases -latest fora da fila (mantidos como registro, com hold)
update bolsa.arquivos_historicos
set detalhe = (case when jsonb_typeof(detalhe) = 'object' then detalhe else '{}'::jsonb end)
              || jsonb_build_object('hold', 'alias -latest do CSV anual 2026; importação oficial via arquivo versionado (ids 223/224)')
where url in (
  'https://repositorio.dados.gov.br/seges/comprasgov/anual/comprasGOV-anual-VW_FT_PNCP_COMPRA-latest.csv',
  'https://repositorio.dados.gov.br/seges/comprasgov/anual/comprasGOV-anual-VW_DM_PNCP_ITEM_RESULTADO-latest.csv');

-- (3) cada fila histórica no seu próprio slug de edge function
select cron.alter_job(
  (select jobid from cron.job where jobname = 'bolsa_hist_transparencia'),
  command := 'select bolsa.checar_capacidade(), bolsa.disparar_fonte(''coleta-historico-transp'',''historico_transp'')');
select cron.alter_job(
  (select jobid from cron.job where jobname = 'bolsa_hist_contratos'),
  command := 'select bolsa.disparar_fonte(''coleta-historico-contratos'',''historico_contratos'')');
