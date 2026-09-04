-- Wave 2 #7 — discovery técnico real de M2A Compras, AMM Licita e
-- LicitaMais Brasil (nunca testados tecnicamente antes, só confirmados
-- por URL na Parte H).
update bolsa.fontes_registro
set status = 'pronta_para_dev',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-04', 'resultado', 'portal_real_confirmado',
      'evidencia', 'home real "M2A Compras" (nao institucional), forms_action=/processos/index/, testado diretamente: 200 OK, 30784 bytes, sem anti-bot'
    ),
    obs = obs || ' Wave 2 discovery tecnico (2026-09-04): portal real confirmado, /processos/index/ acessivel (200, sem captcha/WAF). Candidata forte para Wave 3, estrutura da listagem ainda nao mapeada em detalhe.',
    atualizado_em = now()
where source_id = 'SRC0011';

update bolsa.fontes_registro
set discovery = jsonb_build_object(
      'testado_em', '2026-09-04', 'resultado', 'provavel_homepage_institucional',
      'evidencia', 'ammlicita.org.br e WordPress/Elementor (wp-includes, tema hello-elementor) — mesmo padrao de outras homepages institucionais desta sessao (FIRJAN, ComprasMG). Sistema transacional real provavelmente em subdominio/app separado, nao localizado ainda.'
    ),
    obs = obs || ' Wave 2 discovery tecnico (2026-09-04): ammlicita.org.br e WordPress institucional, nao a aplicacao transacional. Precisa investigacao adicional para achar o sistema real.',
    atualizado_em = now()
where source_id = 'SRC0012';

update bolsa.fontes_registro
set discovery = jsonb_build_object(
      'testado_em', '2026-09-04', 'resultado', 'spa_client_rendered',
      'evidencia', 'licitamaisbrasil.com.br e SPA (bundles vendors.js/app.js hasheados, Google Frontend/GCS), sem HTML server-rendered. Precisa extrair base da API do bundle JS (mesma tecnica usada em BBMNET/Compras BR nesta sessao) — nao feito ainda.'
    ),
    obs = obs || ' Wave 2 discovery tecnico (2026-09-04): SPA client-rendered, precisa investigacao adicional (extrair endpoints do bundle JS) antes de saber se e viavel.',
    atualizado_em = now()
where source_id = 'SRC0013';
