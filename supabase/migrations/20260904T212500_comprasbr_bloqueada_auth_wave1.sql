-- Wave 1 P0 — discovery real da Compras BR (2026-09-04). comprasbr.com.br
-- é o site institucional WordPress; a aplicação real é app.comprasbr.com.br,
-- rodando a plataforma "HAL" (AngularJS 1.x/ui-router + backend Spring
-- Boot/Spring Security — confirmado por "/hal/auth/j_spring_security_check"
-- e headers Whitelabel Error Page). Testado sem autenticação: "/licitacao"
-- e qualquer rota sob /hal/ redirecionam para a mesma tela de login
-- (auto-cadastro/), inclusive rota adivinhada /hal/licitacao/lista.
-- Não é captcha nem bloqueio de borda — é parede de autenticação
-- (mesma categoria da BBMNET), aplicada uniformemente. Não contornado
-- (nenhuma tentativa de login/token).
update bolsa.fontes_registro
set status = 'bloqueada',
    metodo = 'api',
    autenticacao = 'login_obrigatorio_spring_security',
    url = 'https://app.comprasbr.com.br/',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-04',
      'resultado', 'bloqueado_autenticacao',
      'dominio_institucional_wordpress', 'comprasbr.com.br',
      'plataforma_real', 'app.comprasbr.com.br — plataforma "HAL" (AngularJS 1.x/ui-router, backend Spring Boot/Spring Security)',
      'evidencia', jsonb_build_array(
        'GET /licitacao -> 302/redirect para tela de Login (auto-cadastro/)',
        'GET /hal/licitacao/lista -> 302/redirect para tela de Login',
        'GET /hal/public/licitacao/lista -> 404 Spring Whitelabel Error Page (rota não existe)',
        'form action de login: hal/auth/j_spring_security_check'
      ),
      'decisao', 'nao contornar (nenhuma tentativa de login/token) — capacidade marcada indisponivel sem autenticacao'
    ),
    obs = 'Site institucional (comprasbr.com.br) é WordPress comum. App real (app.comprasbr.com.br, plataforma HAL) exige login em toda rota testada relacionada a licitação — mesma categoria de bloqueio da BBMNET (autenticação obrigatória, não captcha/infra). Não contornado.',
    atualizado_em = now()
where source_id = 'SRC0008';
