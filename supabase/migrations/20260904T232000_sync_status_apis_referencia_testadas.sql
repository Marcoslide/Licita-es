-- Sincroniza status das fontes de referência que já têm discovery real
-- registrado (migration parte_bcd_discovery_apis_referencia_nacionais)
-- mas ainda estavam com status='em_analise' por omissão.
update bolsa.fontes_registro
set status = 'descoberta', atualizado_em = now()
where source_id in ('SRC0147','SRC0151','SRC0153','SRC0155','SRC0156','SRC0157','SRC0158','SRC0160','SRC0162','SRC0163','SRC0164','SRC0172','SRC0173','SRC0174')
  and status = 'em_analise';
