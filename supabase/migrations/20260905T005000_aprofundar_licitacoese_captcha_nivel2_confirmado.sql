-- Aprofundamento Licitações-e (Banco do Brasil), SRC0006 — confirmação real
-- via HTTP (não leitura de JS apenas) de que o nível 2 (detalhe individual
-- de licitações por comprador+situação) é protegido por CAPTCHA de imagem.
--
-- Nível 1 (censo agregado): POST /aop/listar-licitacoes-comprador.aop com
-- opcao=listarLicitacoesComprador — 200 OK, HTML real com lista nacional de
-- compradores (Banco do Brasil, Correios, BAHIAGAS, dezenas de estados e
-- municípios) e contagem de licitações por situação. Sem bloqueio.
--
-- Nível 2 (detalhe): o próprio JS da página (função listarLicitacoesAcompanhaveis)
-- chama opcao=listarLicitacoesAcompanhaveisPreCaptcha em
-- /aop/licitacoes-acompanhaveis.aop. Testado diretamente (POST real,
-- codigoComprador=3/BANCO DO BRASIL, codigoSituacao=3, quantidade=32,
-- valores reais extraídos do HTML do nível 1): 200 OK, retorna formulário
-- com <img src=".../aop/captchaServletAux.png"> e campo
-- inputCaptchaLicitacoesAcompanhaveis exigindo digitação do texto da
-- imagem antes de prosseguir (listarLicitacoesAcompanhaveisVerificaCaptcha).
-- CAPTCHA real confirmado, não contornado — parado aqui por política.
update bolsa.fontes_registro
set discovery = jsonb_build_object(
      'testado_em', '2026-09-04',
      'nivel1_censo_agregado', 'aberto, sem bloqueio, dados reais nacionais (comprador + situacao + quantidade)',
      'nivel2_detalhe_individual', 'bloqueado por CAPTCHA de imagem real (captchaServletAux.png), confirmado via POST direto a /aop/licitacoes-acompanhaveis.aop opcao=listarLicitacoesAcompanhaveisPreCaptcha',
      'resultado', 'parcialmente_viavel_nivel1_apenas',
      'decisao', 'nao contornar captcha (politica). Nivel 1 (censo agregado por comprador/situacao) pode virar conector real; nivel 2 (licitacoes individuais, objeto, datas, documentos) inacessivel sem resolver captcha manualmente.'
    ),
    obs = obs || ' Aprofundamento (2026-09-04): nivel 1 (lista de compradores + contagem por situacao) 100% aberto e confirmado com dados reais (Banco do Brasil=32, Correios, BAHIAGAS, dezenas de orgaos federais/estaduais/municipais). Nivel 2 (licitacao individual por comprador+situacao) exige CAPTCHA de imagem real (captchaServletAux.png) — confirmado via chamada HTTP direta, nao contornado. Conector completo (nivel individual) inviavel sem quebrar captcha; conector de censo agregado (nivel 1) e tecnicamente viavel se houver interesse, mas muda o escopo do que foi originalmente proposto para esta fonte.',
    atualizado_em = now()
where source_id = 'SRC0006';
