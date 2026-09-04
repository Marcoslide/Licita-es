-- Wave 2 #4 — Compras ES/SIADES: discovery de 2ª camada não achou
-- listagem agregada de editais. /search é busca genérica do CMS
-- (OrchardCore), /centraldecompras/ é um menu que aponta para 7
-- subseções por secretaria (der/prodest/seag/sedu/seger/sesa/sesp) sem
-- nenhuma menção a "licita" nos 200KB da própria página de menu — a
-- listagem real (se existir) está dentro de cada subseção, não
-- investigado ainda. Sem bloqueio (sem captcha/WAF/auth), pausado por
-- custo/benefício — mesmo critério do e-LIC SC.
update bolsa.fontes_registro
set obs = obs || ' Wave 2 discovery 2a camada (2026-09-04): /search é busca geral do CMS OrchardCore (nao licitacao-especifica). /centraldecompras/ é menu com links para 7 subsecoes por secretaria (der/prodest/seag/sedu/seger/sesa/sesp), sem listagem agregada nem mencao a "licita" na propria pagina de menu (200KB). Listagem real, se existir, esta dentro de cada subsecao — nao investigado ainda. Sem bloqueio algum, pausado por custo/beneficio (mesmo criterio do e-LIC SC).',
    atualizado_em = now()
where source_id = 'SRC0044';
