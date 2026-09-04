-- Wave 2 #2 — e-LIC Santa Catarina: discovery de 2ª camada revelou
-- complexidade maior que a 1ª camada sugeria. Não é bloqueio (sem
-- captcha/WAF/auth), é arquitetura antiga baseada em frameset + token
-- opaco por sessão — precisa mais investigação antes de valer o
-- desenvolvimento. Pausado por decisão de custo/benefício, não por
-- impedimento técnico definitivo.
update bolsa.fontes_registro
set obs = obs || ' Wave 2 discovery 2a camada (2026-09-04): raiz é frameset antigo (Portal de Compras - CIASC) que carrega core/principal.aspx, que por sua vez redireciona via JS para default.aspx?q=<token opaco> — parece token de sessão gerado a cada carga, não uma URL estável/bookmarkable. Sem captcha/WAF/login classico, mas a navegação real exige mais engenharia reversa (equivalente a ASP.NET WebForms com estado de sessão) do que os outros candidatos da Wave 2. Pausado por custo/benefício — revisitar com mais tempo dedicado se prioridade for confirmada.',
    atualizado_em = now()
where source_id = 'SRC0016' or (nome ilike '%santa catarina%' and metodo is null);
