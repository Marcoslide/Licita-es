-- PARTE B/C/D — discovery em lote (28 fontes P0 já com URL no seed).
-- Achado honesto: a MAIORIA das URLs do seed são sites institucionais
-- genéricos (WordPress/Drupal corporativo), não a aplicação real de
-- licitação — mesmo padrão já visto na Wave 1 (BNC/Licitar Digital: site
-- institucional != app). Só 3 confirmaram ser o portal real de compras
-- na própria home (PE Integrado, Compras RS, Compras ES). Nenhuma
-- proteção foi contornada.
update bolsa.fontes_registro t set
  status = v.status,
  obs = v.obs,
  discovery = jsonb_build_object(
    'testado_em', '2026-09-04',
    'resultado', v.resultado,
    'http_status', v.http_status,
    'server', v.server,
    'frameworks', v.frameworks,
    'anti_bot', v.anti_bot
  ),
  atualizado_em = now()
from (values
  ('SRC0014','descoberta',200,'-','[]'::jsonb,'[]'::jsonb,'homepage_institucional','URL do seed (banrisul.com.br) é a home do banco, sem sinal de licitação/compras. Precisa localizar seção específica ou é publicado só via PNCP.'),
  ('SRC0023','descoberta',200,'nginx','["jquery"]'::jsonb,'[]'::jsonb,'homepage_institucional','Portal corporativo Lumis CMS da FIRJAN, sem sinal de compras/licitações na home. Sistema S tem regulamento próprio (RLC) — precisa localizar subdomínio/seção específica.'),
  ('SRC0024','descoberta',200,'Microsoft-IIS/10.0','[]'::jsonb,'[]'::jsonb,'homepage_institucional','Home institucional do SEST SENAT, sem sinal de compras/licitações.'),
  ('SRC0025','descoberta',200,'cloudflare','["jquery"]'::jsonb,'["recaptcha"]'::jsonb,'homepage_institucional','Home institucional da FIERGS (Drupal), recaptcha é do formulário de busca geral, não de um fluxo de licitação.'),
  ('SRC0026','descoberta',200,'-','["jquery"]'::jsonb,'[]'::jsonb,'homepage_institucional','Home institucional da FIEMS, sem sinal de compras/licitações.'),
  ('SRC0027','descoberta',200,'cloudflare','["jquery","wordpress"]'::jsonb,'[]'::jsonb,'homepage_institucional','Home institucional da FIEMG (WordPress), sem sinal de compras/licitações.'),
  ('SRC0028','descoberta',null,null,'[]'::jsonb,'[]'::jsonb,'erro_certificado','Erro de certificado TLS (invalid peer certificate: UnknownIssuer) — problema de infraestrutura do próprio site institucional, não é bloqueio deliberado.'),
  ('SRC0029','descoberta',200,'cloudflare','["jquery"]'::jsonb,'[]'::jsonb,'homepage_institucional','Home institucional da FIESC (Drupal), sem sinal de compras/licitações.'),
  ('SRC0030','descoberta',200,'nginx/1.28.0','["jquery"]'::jsonb,'[]'::jsonb,'homepage_institucional','Home institucional da FIEMT, sem sinal de compras/licitações.'),
  ('SRC0031','descoberta',200,'-','["jquery"]'::jsonb,'[]'::jsonb,'homepage_institucional','Home institucional do Sistema FIEC, sem sinal de compras/licitações.'),
  ('SRC0032','descoberta',null,null,'[]'::jsonb,'[]'::jsonb,'erro_certificado','Erro de certificado TLS (invalid peer certificate: NotValidForName) — infraestrutura do site, não bloqueio deliberado.'),
  ('SRC0033','descoberta',200,'cloudflare','["jquery","wordpress"]'::jsonb,'["recaptcha"]'::jsonb,'homepage_institucional','Home institucional da Itaipu Binacional (WordPress), recaptcha é de formulário geral. Itaipu tem regime de compras próprio (binacional) — precisa localizar seção/subdomínio específico de licitações.'),
  ('SRC0006','descoberta',200,'cloudflare','[]'::jsonb,'[]'::jsonb,'redirecionamento_vazio','licitacoes-e.com.br devolveu só uma página de 623 bytes "Banco do Brasil S.A" — provável redirecionamento via SSO/JS do BB. Precisa investigação adicional para achar a URL real do sistema.'),
  ('SRC0010','descoberta',200,'-','["jquery"]'::jsonb,'["recaptcha"]'::jsonb,'portal_real_confirmado','PE-Integrado confirmado como portal real de contratações públicas de PE (ASP.NET WebForms). recaptcha presente. Candidata forte para discovery de 2ª camada (endpoint de listagem).'),
  ('SRC0015','descoberta',200,'Apache','[]'::jsonb,'[]'::jsonb,'portal_real_confirmado','Compras Eletrônicas RS confirmado como portal real (form action /editais/pesquisar). Sem recaptcha detectado na home. Candidata forte para discovery de 2ª camada.'),
  ('SRC0020','descoberta',200,'-','["jquery","wordpress"]'::jsonb,'[]'::jsonb,'homepage_institucional','ComprasMG devolveu uma página WordPress informativa sobre o programa, não claramente a aplicação transacional. Precisa investigação adicional para achar o sistema real por trás.'),
  ('SRC0034','descoberta',200,'nginx','["jquery","wordpress"]'::jsonb,'[]'::jsonb,'homepage_institucional','Portal institucional da Prefeitura de Piracicaba (WordPress), sem sinal de licitações na home.'),
  ('SRC0036','descoberta',200,'-','[]'::jsonb,'["recaptcha"]'::jsonb,'homepage_institucional','Home institucional do Banpará, sem sinal de licitações.'),
  ('SRC0038','descoberta',200,'Microsoft-IIS/10.0','[]'::jsonb,'[]'::jsonb,'homepage_institucional','Portal institucional da Prefeitura de Barueri, sem sinal de licitações na home.'),
  ('SRC0039','descoberta',200,'Apache','["jquery"]'::jsonb,'[]'::jsonb,'homepage_institucional','Portal institucional da Prefeitura de São Bernardo do Campo (Liferay), sem sinal de licitações na home.'),
  ('SRC0040','descoberta',200,'-','["jquery","wordpress"]'::jsonb,'[]'::jsonb,'homepage_institucional','Home institucional do SESC-RS, sem sinal de compras/licitações.'),
  ('SRC0041','descoberta',200,'Apache','["jquery","wordpress"]'::jsonb,'[]'::jsonb,'homepage_institucional','Portal institucional da Prefeitura de Diadema (WordPress), sem sinal de licitações na home.'),
  ('SRC0042','descoberta',200,'Apache','["react","jquery","wordpress"]'::jsonb,'[]'::jsonb,'homepage_institucional','Home institucional do SESC-SP, sem sinal de compras/licitações.'),
  ('SRC0044','descoberta',200,'Kestrel','["jquery"]'::jsonb,'[]'::jsonb,'portal_real_confirmado','Portal de Compras ES confirmado como portal real (ASP.NET Core/Kestrel, OrchardCore CMS, form /search). Candidata forte para discovery de 2ª camada.'),
  ('SRC0045','descoberta',null,null,'[]'::jsonb,'[]'::jsonb,'erro_conexao','famesp.org.br: connection reset by peer — infraestrutura instável ou fora do ar no momento do teste.'),
  ('SRC0043','descoberta',403,'-','[]'::jsonb,'[]'::jsonb,'bloqueado_borda_akamai','curitiba.pr.gov.br devolveu 403 "Access Denied" de borda Akamai (errors.edgesuite.net) — 5º mecanismo de bloqueio distinto catalogado nesta sessão (diferente de AWS ELB, Keycloak, Cloudflare JS challenge, Spring Security). Não contornado. "e-Compras Curitiba" real ainda não localizado.'),
  ('SRC0046','descoberta',200,'cloudflare','["react","jquery","wordpress"]'::jsonb,'[]'::jsonb,'homepage_institucional','Portal institucional da Prefeitura de São José-SC (WordPress), sem sinal de licitações na home.')
) as v(source_id, status, http_status, server, frameworks, anti_bot, resultado, obs)
where t.source_id = v.source_id;
