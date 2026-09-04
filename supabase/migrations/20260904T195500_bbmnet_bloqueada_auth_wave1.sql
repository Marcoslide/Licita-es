-- Wave 1 P0 — discovery real da BBMNET (2026-09-04). Domínio comercial
-- (bbmnet.com.br) é site institucional WordPress; a plataforma real de
-- licitações é uma SPA Angular em sistema.bbmnet.com.br. Reverse-
-- engineering do bundle JS público (mesmo arquivo que o navegador
-- baixa e executa — não é acesso a código-fonte privado) revelou a
-- config de ambiente com a API real: apiLicitacoes = Cloud Run
-- (bbmnet-cadastro-editais-backend-*.run.app), auth via Keycloak
-- (auth.bbmnet.com.br). Endpoints REAIS extraídos do próprio código de
-- uso (não adivinhados às cegas): /api/Editais, /api/editais/
-- orgaospromotores, /api/Editais/{id}/Documentos/{id}/Download,
-- /api/Editais/{id}/DocumentosComplementares/{id}/Download,
-- /api/RelatorioComissao/..., /api/AtualizacaoDataPublicacao/... —
-- todos testados e retornam 401 Unauthorized (rota existe, exige JWT
-- Keycloak), não 404. /health retorna 200 "Healthy" (API está viva).
-- Sem captcha — é parede de autenticação, não anti-bot comportamental.
-- Texto legal embutido no próprio bundle confirma que a BBMNET publica
-- no PNCP também (overlap real, sem precisar login pra confirmar isso
-- especificamente). Não foi encontrado nenhum endpoint público/anônimo
-- equivalente. Não tentei contornar (não forjar/obter token de
-- autenticação) — mesma régua do captcha e do bloqueio de
-- infraestrutura da Licitanet.
update bolsa.fontes_registro
set status = 'bloqueada',
    metodo = 'api',
    autenticacao = 'oauth2_keycloak_obrigatorio',
    url = 'https://sistema.bbmnet.com.br/',
    url_api = 'https://bbmnet-cadastro-editais-backend-z7knklmt7a-rj.a.run.app',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-04',
      'resultado', 'bloqueado_autenticacao',
      'plataforma_real', 'sistema.bbmnet.com.br (Angular SPA)',
      'dominio_comercial_wordpress', 'bbmnet.com.br',
      'dominio_legado_redirect_loop', 'www2.bbmnet.com.br (Default.aspx?s=LICPUBAP — 20 redirects, provavelmente descontinuado após "Novo Portal" de 2023)',
      'auth_server', 'https://auth.bbmnet.com.br/ (Keycloak, realm BBM)',
      'api_base', 'https://bbmnet-cadastro-editais-backend-z7knklmt7a-rj.a.run.app',
      'endpoints_reais_extraidos_do_bundle', jsonb_build_array(
        'GET /api/Editais -> 401', 'GET /api/editais/orgaospromotores -> 401',
        'GET /api/Editais/{id}/Documentos/{docId}/Download -> auth necessária',
        'GET /api/Editais/{id}/DocumentosComplementares/{docId}/Download -> auth necessária',
        'GET /api/RelatorioComissao/RelatorioSinteticoMeusGanho -> auth necessária',
        'GET /health -> 200 Healthy (sem auth)'
      ),
      'overlap_pncp', 'confirmado pelo próprio texto legal embutido no bundle: publicações de licitações no PNCP continuam ocorrendo normalmente junto com a BBMNET',
      'decisao', 'nao contornar (nao obter/forjar token Keycloak) — capacidade marcada indisponivel sem autenticacao'
    ),
    obs = 'API real (Cloud Run + Keycloak) encontrada via engenharia reversa do bundle Angular público — endpoints existem (401, não 404) mas exigem login OAuth2/Keycloak. Sem captcha, mas parede de autenticação equivalente para fins de coleta backend anônima. Não contornado. Pulada/pausada na Wave 1 aguardando decisão do usuário em 2026-09-04.',
    atualizado_em = now()
where source_id in ('SRC0009', 'SRC0050', 'SRC0089');
