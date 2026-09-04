-- Wave 1 P0 — discovery real da Licitar Digital (2026-09-04).
-- licitar.digital é o site institucional WordPress (marketing). A
-- aplicação real vive em subdomínios separados (app.licitardigital.com.br,
-- app2.licitardigital.com.br, api.licitardigital.com.br), TODOS
-- bloqueados por Cloudflare no nível de borda: /pesquisa retorna 403
-- com título "Just a moment..." (o desafio JS clássico do Cloudflare,
-- não uma página de erro comum), e app./app2./api. raiz retornam 403
-- "Acesso Restrito" de forma consistente em múltiplos subdomínios —
-- não é uma falha isolada de uma rota. Diferente do bloqueio de
-- infraestrutura da Licitanet (ALB simples) e da autenticação
-- obrigatória da BBMNET (Keycloak): aqui é especificamente um desafio
-- anti-bot comportamental do Cloudflare. Não contornado — nenhuma
-- tentativa de resolver o desafio JS ou simular um navegador real.
update bolsa.fontes_registro
set status = 'bloqueada',
    metodo = 'html',
    autenticacao = 'nao_testavel_cloudflare_challenge',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-04',
      'resultado', 'bloqueado_cloudflare_challenge',
      'dominio_institucional_wordpress', 'licitar.digital',
      'subdominios_aplicacao_testados', jsonb_build_array(
        'app2.licitardigital.com.br/pesquisa -> 403 "Just a moment..." (desafio JS Cloudflare)',
        'app.licitardigital.com.br/login/ -> 403 "Acesso Restrito"',
        'app2.licitardigital.com.br/ -> 403 "Acesso Restrito"',
        'app2.licitardigital.com.br/api/processos -> 403 "Acesso Restrito"',
        'api.licitardigital.com.br/ -> 403 "Acesso Restrito"'
      ),
      'decisao', 'nao contornar desafio Cloudflare (nao simular navegador, nao resolver challenge JS) — capacidade marcada indisponivel'
    ),
    obs = 'Bloqueio consistente em 5 rotas de 3 subdomínios diferentes (app/app2/api) — não é acidente pontual, é proteção deliberada de borda. Não contornado. Pulada na Wave 1, mesmo critério da Licitanet.',
    atualizado_em = now()
where source_id in ('SRC0004', 'SRC0055');
