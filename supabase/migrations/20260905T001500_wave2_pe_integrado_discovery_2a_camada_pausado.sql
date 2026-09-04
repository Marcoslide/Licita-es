-- Wave 2 #5 — PE Integrado: discovery de 2ª camada achou a página real
-- de listagem (Portal/Pages/LicitacoesEmAndamento.aspx, tbody id=
-- trListaMuralProcesso, populado via AJAX) e os enums de filtro no bundle
-- portaljs3 (enumTipoMuralProcesso, enumTipoMuralModalidadeProcesso), mas
-- não o endpoint exato do AJAX em 5 tentativas (não é PageMethod .aspx/,
-- não achado em portaljs3 — pode estar em portaljs1/portaljs2 ou usar
-- __doPostBack do WebForms, o que seria mais complexo que REST simples).
-- Sem bloqueio (recaptcha presente na home mas não confirmado na
-- listagem em si). Pausado por custo/benefício.
update bolsa.fontes_registro
set obs = obs || ' Wave 2 discovery 2a camada (2026-09-04): achada a pagina real (LicitacoesEmAndamento.aspx, tbody trListaMuralProcesso vazio/AJAX) e os enums de filtro (enumTipoMuralProcesso, enumTipoMuralModalidadeProcesso) no bundle portaljs3, mas nao o endpoint exato do AJAX em 5 tentativas — pode estar em portaljs1/portaljs2 ou usar __doPostBack (WebForms postback, mais complexo que REST). Sem bloqueio confirmado nesta camada. Pausado por custo/beneficio, mesmo criterio de e-LIC SC e Compras ES.',
    atualizado_em = now()
where source_id = 'SRC0010';
