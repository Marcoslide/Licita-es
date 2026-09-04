-- PARTE B/C/D — discovery real do cluster de APIs/catálogos de referência
-- nacional (SICAF, CATMAT/CATSER, BPS, Portal Transparência sub-datasets,
-- Receita CNPJ, CAPAG, SICONFI, SINAPI, SICRO). Natureza diferente dos
-- portais de licitação: são bases de dados abertos oficiais já
-- documentadas, não "novos portais" a descobrir do zero.
update bolsa.fontes_registro t set
  obs = v.obs,
  discovery = jsonb_build_object('testado_em', '2026-09-04', 'resultado', v.resultado),
  atualizado_em = now()
from (values
  ('SRC0147','pagina_publica_sistema_exige_login','Página informativa do SICAF Digital carrega (200), mas o sistema transacional exige login (redirect para credentials_cookie_auth/require_login). Cadastro de fornecedores, não uma listagem pública de dados.'),
  ('SRC0151','confirmado_acessivel','Portal de Dados Abertos do SUS (Next.js) confirmado acessível (200), dataset BPS listado. Sem autenticação.'),
  ('SRC0153','pagina_docs_atras_de_waf','Raiz /api-de-dados devolveu 405 + "Human Verification" (AWS WAF captcha.js/challenge.js) — página de documentação, não necessariamente a chamada de API real com header de chave. Não contornado. Comportamento da API real (com api-key) não testado nesta camada — mesma família técnica de SRC0154-0158.'),
  ('SRC0154','pagina_docs_atras_de_waf','Mesma família de SRC0153 (Portal da Transparência api-de-dados) — raiz protegida por AWS WAF captcha. API real com chave não testada.'),
  ('SRC0155','pagina_docs_atras_de_waf','Mesma família de SRC0153. API real com chave não testada.'),
  ('SRC0156','pagina_docs_atras_de_waf','Mesma família de SRC0153 (CEIS). API real com chave não testada.'),
  ('SRC0157','pagina_docs_atras_de_waf','Mesma família de SRC0153 (CNEP). API real com chave não testada.'),
  ('SRC0158','pagina_docs_atras_de_waf','Mesma família de SRC0153 (CEPIM). API real com chave não testada.'),
  ('SRC0160','confirmado_acessivel','Página informativa de dados abertos de CNPJ da Receita Federal confirmada acessível (200), sem autenticação.'),
  ('SRC0162','confirmado_acessivel','Página CAPAG Municípios (Tesouro Transparente) confirmada acessível (200).'),
  ('SRC0163','confirmado_acessivel','Página CAPAG Estados/DF (mesma URL de SRC0162) confirmada acessível (200).'),
  ('SRC0164','confirmado_acessivel','SICONFI confirmado acessível — raiz redireciona (200, meta-refresh) para /siconfi (SPA Angular).'),
  ('SRC0172','bloqueado_cdn_azion','SINAPI via CAIXA devolveu 403 "Azion - Default error page" — 6º mecanismo de bloqueio distinto catalogado nesta sessão (CDN Azion, diferente de AWS ELB/Keycloak/Cloudflare JS/Spring Security/Akamai). Não contornado. SRC0173 (via IBGE) é caminho alternativo mais promissor para os mesmos dados.'),
  ('SRC0173','confirmado_acessivel','Página do IBGE sobre SINAPI confirmada acessível (200) — caminho alternativo ao bloqueio de SRC0172 (CAIXA/Azion), mesmos dados históricos.'),
  ('SRC0174','confirmado_acessivel','Página de manuais de custos SICRO (DNIT) confirmada acessível (200).')
) as v(source_id, resultado, obs)
where t.source_id = v.source_id;
