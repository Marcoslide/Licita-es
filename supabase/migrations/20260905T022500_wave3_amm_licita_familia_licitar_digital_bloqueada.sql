-- Wave 3 #5 — AMM Licita: descoberta conclusiva — é um white-label da
-- MESMA plataforma "Licitar Digital" já bloqueada na Wave 1 (SRC0004),
-- não uma fonte tecnicamente independente.
--
-- ammlicita.org.br é WordPress institucional (confirmado na Wave 2), mas
-- tem botões reais para o sistema transacional em app2.ammlicita.org.br
-- (busca pública /pesquisa) e app.ammlicita.org.br (login). A SPA de
-- app2 carrega /env-config.js (padrão de runtime-config de app React/
-- Vite), que revelou: MANAGER_API_URL=manager-api.licitardigital.com.br,
-- PRICE_BASE_API_URL=api-pricebase.licitardigital.com.br,
-- OAUTH2_CLIENT_ID=php-manager, DISPUTE_CLIENT_ID=disputa-licitar,
-- AWS_USER_POOL_ID (Cognito) — inequivocamente a MESMA infraestrutura
-- documentada para Licitar Digital na Wave 1/PARTE J.
--
-- Testado diretamente: GET manager-api.licitardigital.com.br/ (mesmo
-- domínio da API usada por este white-label) devolveu 403 "Acesso
-- Restrito" — página de bloqueo Cloudflare idêntica em estilo à
-- documentada para app/app2/api.licitar.digital na Wave 1. Mesmo
-- mecanismo de proteção, mesma decisão: não contornado.
update bolsa.fontes_registro
set status = 'bloqueada',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-05',
      'resultado', 'mesma_plataforma_licitar_digital_ja_bloqueada',
      'evidencia', 'env-config.js de app2.ammlicita.org.br revela MANAGER_API_URL=manager-api.licitardigital.com.br, OAUTH2_CLIENT_ID=php-manager, DISPUTE_CLIENT_ID=disputa-licitar, AWS Cognito user pool — mesma infraestrutura do SRC0004 (Licitar Digital)',
      'teste_direto', 'GET manager-api.licitardigital.com.br/ com Origin correto -> 403 Cloudflare "Acesso Restrito", mesmo padrao ja documentado na Wave 1'
    ),
    obs = obs || ' Wave 3 (2026-09-05): descoberta conclusiva — AMM Licita (app2.ammlicita.org.br) e um white-label da plataforma Licitar Digital (SRC0004), confirmado via env-config.js (MANAGER_API_URL=manager-api.licitardigital.com.br, mesmo OAUTH2_CLIENT_ID/DISPUTE_CLIENT_ID/Cognito pool). Testado diretamente: mesmo bloqueio Cloudflare "Acesso Restrito" ja documentado para Licitar Digital na Wave 1. Nao contornado. Fonte reclassificada de "precisa investigacao adicional" para "bloqueada" (mesma familia/mesma causa de SRC0004) — nao e mais um item em aberto, e um caso resolvido (negativamente).',
    atualizado_em = now()
where source_id = 'SRC0012';
