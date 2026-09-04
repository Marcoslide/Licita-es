-- ============================================================
-- FASE DE ESTABILIZAÇÃO — PRIORIDADE 1: proteger a base bolsa.
-- Access map completo feito antes desta migration (P1-A): nenhuma
-- tela do frontend (público ou admin) consulta estas 14 tabelas nem
-- as 2 views que dependem delas — todas as views públicas usadas
-- pelo app são agregações independentes. RLS sem policy = deny-all
-- para anon/authenticated; service_role e o dono das funções
-- SECURITY DEFINER (bolsa_buscar, bolsa_admin_*, resolver_canonico_pncp
-- quando chamado por role privilegiada) continuam funcionando, pois
-- RLS não afeta o superuser/dono nem SECURITY DEFINER rodando como
-- postgres. Nenhum dado foi alterado ou apagado.
-- ============================================================

alter table bolsa.itens_legado enable row level security;
alter table bolsa.participacoes enable row level security;
alter table bolsa.import_erros enable row level security;
alter table bolsa.licitacoes_legado enable row level security;
alter table bolsa.contratos_legado enable row level security;
alter table bolsa.contrato_empenhos_legado enable row level security;
alter table bolsa.arquivos_historicos enable row level security;
alter table bolsa.backfill_jobs enable row level security;
alter table bolsa.empenhos_licitacao enable row level security;
alter table bolsa.fontes_cobertura enable row level security;
alter table bolsa.capacidade_config enable row level security;
alter table bolsa.relatorios_diarios enable row level security;
alter table bolsa.memoria_anos enable row level security;
alter table bolsa.capacidade_alertas enable row level security;

-- Nenhuma policy criada de propósito: acesso só via SECURITY DEFINER
-- (bolsa_buscar, bolsa_admin_fontes, bolsa_admin_matriz, conectores via
-- conexão direta postgres) ou service_role, igual ao padrão já usado em
-- fontes_registro/proc_canonico/proveniencia desde o PROMPT 01.

-- Fecha o mesmo tipo de vazamento já corrigido antes (grant PUBLIC/anon
-- implícito) para as 3 RPCs achadas no access map que tocam essas
-- tabelas e ainda estavam abertas para anon:
revoke all on function bolsa.backfill_reivindicar(text) from public;
revoke all on function bolsa.backfill_reivindicar(text) from anon;
grant execute on function bolsa.backfill_reivindicar(text) to authenticated, service_role;

revoke all on function bolsa.checar_capacidade() from public;
revoke all on function bolsa.checar_capacidade() from anon;
grant execute on function bolsa.checar_capacidade() to service_role;

revoke all on function bolsa.resolver_canonico_pncp() from public;
revoke all on function bolsa.resolver_canonico_pncp() from anon;
grant execute on function bolsa.resolver_canonico_pncp() to authenticated, service_role;
