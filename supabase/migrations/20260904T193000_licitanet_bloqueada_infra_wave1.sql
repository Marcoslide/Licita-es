-- Wave 1 P0 — discovery real da Licitanet (2026-09-04): bloqueio de
-- infraestrutura (AWS ELB/WAF), 403 servido pelo próprio load balancer
-- em TODO caminho testado (/, /robots.txt, /sitemap.xml, /api,
-- /swagger, /sobre), com e sem "www.", usando User-Agent honesto/
-- autoidentificado. Não é um captcha pontual numa ação específica —
-- é bloqueio indiscriminado de tráfego automatizado na borda. Por
-- instrução explícita de nunca contornar proteção anti-bot (inclui
-- não forjar User-Agent de navegador para escapar de WAF), a fonte
-- fica marcada BLOQUEADA e não avança para conector agora. Usuário
-- decidiu pular para BBMNET e não investir mais tempo aqui por ora.
update bolsa.fontes_registro
set status = 'bloqueada',
    metodo = 'html',
    autenticacao = 'nao_testavel_bloqueio_borda',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-04',
      'resultado', 'bloqueado_infraestrutura',
      'detalhe', '403 Forbidden servido por awselb/2.0 (load balancer, não a aplicação) em todos os caminhos testados, com e sem www',
      'urls_testadas', jsonb_build_array(
        'https://www.licitanet.com.br/', 'https://www.licitanet.com.br/robots.txt',
        'https://www.licitanet.com.br/sitemap.xml', 'https://www.licitanet.com.br/swagger/index.html',
        'https://www.licitanet.com.br/api', 'https://www.licitanet.com.br/sobre',
        'https://licitanet.com.br/'
      ),
      'user_agent_usado', 'BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es) — autoidentificado, nao contornado',
      'decisao', 'nao contornar (nao forjar User-Agent de navegador) — capacidade marcada indisponivel'
    ),
    obs = 'Bloqueio de infraestrutura (AWS ELB/WAF) em toda a superfície pública testada — não é captcha isolado, é acesso automatizado negado na borda. Não contornado. Pulado na Wave 1 por decisão do usuário em 2026-09-04; retomar apenas se houver via de acesso legítima (ex.: parceria/API oficial) no futuro.',
    atualizado_em = now()
where source_id in ('SRC0002', 'SRC0054');
