-- Wave 3 #1 — CEPIM: causa raiz real do 403 (Wave 2) era atraso de
-- publicação do arquivo do dia, não bloqueio. Confirmado em 2026-09-05:
-- ceis/20260905 (hoje) também devolveu 403 AccessDenied real do S3 —
-- mesmo comportamento do cepim, só que o atraso do cepim é maior
-- (hoje e D-1 falharam, D-2 funcionou com zip real: 300 registros,
-- 0 erros, campos reais cnpj_entidade/nome_entidade/numero_convenio/
-- orgao_concedente/motivo_do_impedimento).
--
-- coleta-ceis foi generalizado para tentar hoje e recuar até 4 dias,
-- usando o primeiro que responder OK — corrige o mesmo problema latente
-- para ceis/cnep também (ambos já tinham sido vistos falhando em "hoje"
-- nesta sessão), não é um hack específico do cepim.
insert into bolsa.coleta_config (job, cron, params, ativo)
values ('sancoes_cepim', '25,55 * * * *', jsonb_build_object('dataset','cepim'), true)
on conflict (job) do update set cron = excluded.cron, params = excluded.params, ativo = true;

select cron.schedule('bolsa_sancoes_cepim', '25,55 * * * *', $$select bolsa.disparar_fonte('coleta-ceis','sancoes_cepim')$$);

update bolsa.fontes_registro
set status = 'ativa',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-05',
      'resultado', 'conector_ativo_provado',
      'causa_raiz_403_wave2', 'atraso de publicacao do arquivo do dia (S3 AccessDenied generico), nao bloqueio — confirmado comparando com ceis/cnep no mesmo dia',
      'lookback_implementado', 'tenta hoje e recua ate 4 dias, usa o primeiro que responder 200',
      'execucao_real', '300 registros, 300 novos, 0 erros, ymd_usado=20260903 (2 dias antes do teste)',
      'campos_reais', 'cnpj_entidade, nome_entidade, numero_convenio, orgao_concedente, motivo_do_impedimento'
    ),
    obs = obs || ' Wave 3 (2026-09-05): causa raiz do 403 identificada — atraso real de publicacao (confirmado comparando com ceis/cnep no mesmo dia, nao e bloqueio especifico do cepim). Conector generalizado com lookback de ate 4 dias. Testado com sucesso real (300 registros, 0 erros). Cron bolsa_sancoes_cepim ativado (25,55 * * * *).',
    atualizado_em = now()
where source_id = 'SRC0158';
