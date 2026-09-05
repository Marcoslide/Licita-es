-- Wave 3 #2 — SIADES / Compras ES: conector real construído e provado.
--
-- compras.es.gov.br é só o portal institucional (OrchardCore) — a app
-- real do estado está em siades.es.gov.br (achada via link "Manual do
-- SIADES para fornecedores" no menu de compras.es.gov.br). A UI é uma SPA
-- Vue (licitacao-pub); a API pública real foi extraída do bundle JS
-- (mesma técnica de BBMNET/Compras BR/Compras RS):
-- GET /licitacao/api/public/v1/licitacoes/?page=N&size=M — paginação
-- Spring Data padrão, JSON limpo, 1.359 licitações totais confirmadas.
-- Confirmado via /licitacao/api/public/v1/parametros-publicos que
-- recaptchaDownloadPubAtivo=false — reCAPTCHA nesta plataforma só
-- protege o formulário de impugnação/esclarecimento (escrita), não a
-- leitura pública. Nenhum captcha contornado.
--
-- Achado de alto valor (não coletado nesta v1, registrado para o futuro):
-- exibirRelatorioHistoricoLancesAreaPublica=true e
-- exibirRelatorioParticipantesAreaPublica=true — histórico de lances e
-- lista de participantes são públicos nesta instância.
--
-- Provado com 2 execuções reais sequenciais (600 processados, 541
-- chaves distintas — a diferença são reaparições legítimas de itens ao
-- paginar um dataset vivo sem ordenação estável, não duplicação: mesma
-- chave, mesmo conteúdo, registrado como sem_mudanca pelo motor), 0
-- erros. Idempotência confirmada (reenvio -> novo:false, mudancas:[]).
-- Canonicalização real via bolsa.resolver_canonico_processo_disputa()
-- (reaproveitada sem modificação): 541/541 com canonico_id, 0
-- review_required, rerun idempotente (0/0/0/0).
insert into bolsa.coleta_config (job, cron, params, ativo)
values ('siades', '10,40 * * * *', '{}'::jsonb, true)
on conflict (job) do update set cron = excluded.cron, params = excluded.params, ativo = true;

update bolsa.fontes_registro
set status = 'ativa',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-05',
      'app_real', 'siades.es.gov.br (distinta de compras.es.gov.br, que e so portal institucional)',
      'endpoint_real', '/licitacao/api/public/v1/licitacoes/?page=N&size=M',
      'formato', 'JSON limpo, paginacao Spring Data (items, totalElements, totalPages)',
      'volume_real', '1359 licitacoes totais',
      'resultado', 'conector_ativo_provado',
      'execucoes_reais', 2, 'registros_distintos', 541, 'erros', 0,
      'canonicalizacao', '541/541 com canonico_id, 0 review_required, rerun idempotente (0/0/0/0)',
      'dados_de_alto_valor_nao_coletados_ainda', 'historico de lances publico e lista de participantes publica (confirmado via flags em parametros-publicos, nao implementado nesta v1)',
      'cnpj_exato_disponivel', 'campo cnpjOrgaoSuperiorPncp real por licitacao, mais preciso que matching por nome — guardado como metadado, resolver_canonico ainda nao usa CNPJ como criterio de match'
    ),
    obs = obs || ' Wave 3 (2026-09-05): app real achada em siades.es.gov.br (nao em compras.es.gov.br, que e so portal institucional OrchardCore). API publica real extraida do bundle JS da SPA Vue: /licitacao/api/public/v1/licitacoes/. 1359 licitacoes totais. Conector ativo, provado com 2 execucoes reais (541 registros distintos, 0 erros) e canonicalizacao (541/541, idempotente). Cron bolsa_siades ativado (10,40 * * * *). reCAPTCHA presente na plataforma mas confirmado (recaptchaDownloadPubAtivo=false) que so protege o formulario de impugnacao/esclarecimento, nao a leitura publica — nenhum captcha contornado.',
    atualizado_em = now()
where source_id = 'SRC0044';
