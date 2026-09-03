-- ============================================================
-- RECONSTITUÍDA a partir de supabase_migrations.schema_migrations
-- (version 20260903022405, name "bolsa_resumo_v2_multifonte") em
-- 2026-09-03 ~22:40 UTC: esta migração foi aplicada em produção via
-- apply_migration mas o arquivo nunca chegou a existir neste
-- repositório (gap encontrado durante a reconciliação repositório ×
-- histórico × schema real pedida pelo usuário). O texto abaixo é
-- CÓPIA LITERAL da coluna `statements` já gravada no histórico —
-- não foi reconstruído/adivinhado a partir do schema. A view
-- public.bolsa_vw_resumo já existe e está em uso; este arquivo só
-- documenta no repo o que já é real, sem alterar nada.
-- ============================================================
create or replace view public.bolsa_vw_resumo with (security_invoker = on) as
select
  (select count(*) from bolsa.licitacoes) as licitacoes,
  (select count(*) from bolsa.licitacoes where data_encerramento_proposta > now()) as recebendo_propostas,
  (select count(*) from bolsa.licitacoes where data_publicacao_pncp::date = current_date) as publicadas_hoje,
  (select sum(valor_total_estimado) from bolsa.licitacoes) as valor_estimado_total,
  (select count(*) from bolsa.itens) as itens,
  (select count(*) from bolsa.documentos) as documentos,
  (select count(*) from bolsa.resultados_itens) as resultados,
  (select sum(valor_total_homologado) from bolsa.resultados_itens) as valor_homologado_total,
  (select count(*) from bolsa.fornecedores) as fornecedores,
  (select count(*) from bolsa.orgaos) as orgaos,
  (select count(*) from bolsa.contratos) as contratos,
  (select sum(valor_global) from bolsa.contratos) as valor_contratado_total,
  (select count(*) from bolsa.contratos where vigencia_fim between current_date and current_date + 180) as contratos_vencendo_180d,
  (select count(*) from bolsa.eventos) as eventos,
  (select count(*) from bolsa.eventos where tipo <> 'NOVO_REGISTRO') as eventos_alteracao,
  (select count(*) from bolsa.raw_payloads) as raw_payloads,
  (select max(iniciado_em) from bolsa.coleta_log) as ultima_coleta_em,
  -- v2: multi-fonte
  (select count(*) from bolsa.atas) as atas,
  (select count(*) from bolsa.atas where vigencia_fim between current_date and current_date + 180) as atas_vencendo_180d,
  (select count(*) from bolsa.pca_itens) as pca_itens,
  (select count(*) from bolsa.catalogo where situacao is distinct from 'NAO_ENCONTRADO_NA_FONTE') as catalogo_itens,
  (select count(*) from bolsa.precos_praticados) as precos_praticados,
  (select count(*) from bolsa.contratos_gov) as contratos_gov,
  (select sum(valor_global) from bolsa.contratos_gov) as valor_contratos_gov,
  (select count(*) from bolsa.empenhos) as empenhos,
  (select coalesce(sum(valor_empenhado),0) from bolsa.empenhos) as valor_empenhado_total,
  (select coalesce(sum(valor_pago),0) from bolsa.empenhos) as valor_pago_total,
  (select count(*) from bolsa.faturas) as faturas,
  (select count(*) from bolsa.garantias) as garantias,
  (select count(*) from bolsa.ocorrencias_contrato) as ocorrencias,
  (select count(*) from bolsa.arp_saldos where chave_dedup <> 'sem-registros') as arp_saldos,
  (select count(*) from bolsa.pagamentos_transparencia) as pagamentos_transparencia,
  (select count(*) from bolsa.fontes where status = 'ATIVA') as fontes_ativas,
  (select count(*) from bolsa.fontes) as fontes_total;
