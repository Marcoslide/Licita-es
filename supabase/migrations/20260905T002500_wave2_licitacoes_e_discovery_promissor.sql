-- Wave 2 #6 — Licitações-e (Banco do Brasil): discovery de 2ª camada
-- achado positivo. A raiz (licitacoes-e.com.br/) só redireciona para a
-- app real /aop/index.jsp (200, 34KB, formulário PesquisarLicitacaoForm
-- com campos reais NumeroLicitacao/CodigoTipoEstadoLicitacao). App é
-- JSP antigo (tecnologia Java, "com.bb.comercioeletronico.aop"), mesma
-- classe de complexidade que PE Integrado (formulário real, endpoint de
-- resultado ainda não confirmado — listar-licitacoes-comprador.aop
-- devolveu 500 sem parâmetros). Nenhum bloqueio (sem captcha/WAF/login).
-- Mais promissor que os 3 pausados por já ter confirmado a app real e
-- os nomes de campo — falta só descobrir os parâmetros corretos do POST.
update bolsa.fontes_registro
set status = 'pronta_para_dev',
    obs = obs || ' Wave 2 discovery 2a camada (2026-09-04): app real confirmada em /aop/index.jsp (200, JSP/Java "com.bb.comercioeletronico.aop"), formulario PesquisarLicitacaoForm com campos reais (NumeroLicitacao, CodigoTipoEstadoLicitacao). listar-licitacoes-comprador.aop existe mas devolveu 500 sem parametros corretos ainda. Sem bloqueio algum. Mais promissora que e-LIC/Compras ES/PE Integrado por ja ter app+campos confirmados — falta descobrir os parametros exatos do POST antes de construir o conector.',
    atualizado_em = now()
where source_id = 'SRC0006';
