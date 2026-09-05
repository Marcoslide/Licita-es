-- Wave 3 #6 — e-LIC SC (SRC0650): aprofundamento do achado da Wave 2
-- (token opaco em default.aspx?q=...) — testado tecnicamente a fundo,
-- pausado de novo por custo/benefício com uma causa mais precisa.
--
-- Hipótese testada: o token seria vinculado a um cookie de sessão
-- (ASP.NET_SessionId) emitido no GET de core/principal.aspx, bastando
-- reenviar esse cookie junto com o token no segundo request (mesma
-- técnica que resolveu Licitações-e/JSESSIONID). Testado tecnicamente:
-- core/principal.aspx NÃO emite nenhum Set-Cookie. Mesmo reusando o
-- token extraído na hora, na mesma cadeia de execução (sem cookie
-- envolvido, sem demora), default.aspx?q=<token> ainda devolve
-- "Ocorreu um erro na aplicação" — ou seja, não é um simples token de
-- sessão reutilizável por HTTP puro; depende de algum outro estado que
-- uma requisição HTTP simples não reproduz (possivelmente ligado ao
-- contexto de frameset/postback real do navegador). Sem captcha/WAF/
-- login clássico em nenhuma camada. Pausado por custo/benefício — mesmo
-- critério das demais fontes difíceis desta sessão.
update bolsa.fontes_registro
set discovery = jsonb_build_object(
      'testado_em', '2026-09-05',
      'hipotese_testada', 'token vinculado a cookie de sessao (Set-Cookie em core/principal.aspx)',
      'resultado_teste', 'core/principal.aspx NAO emite Set-Cookie; token reusado na mesma cadeia de execucao (sem demora) ainda falha com erro generico da aplicacao',
      'conclusao', 'nao e um token de sessao HTTP simples — depende de estado nao reproduzivel por requisicao HTTP pura (possivelmente contexto real de frameset/navegador)',
      'resultado', 'progresso_parcial_pausado_custo_beneficio'
    ),
    obs = obs || ' Wave 3 (2026-09-05): hipotese de cookie de sessao testada e descartada — core/principal.aspx nao emite Set-Cookie, e o token reusado imediatamente na mesma cadeia (sem cookie) ainda falha. Nao e um token de sessao HTTP simples. Sem bloqueio classico (captcha/WAF/login) em nenhuma camada. Pausado de novo por custo/beneficio, causa mais precisa que a da Wave 2.',
    atualizado_em = now()
where source_id = 'SRC0650';
