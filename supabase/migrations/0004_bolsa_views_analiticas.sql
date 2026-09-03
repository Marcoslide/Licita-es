-- Views analíticas públicas (somente leitura) — a UI consome apenas isto (§64/§90).
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
  (select max(iniciado_em) from bolsa.coleta_log) as ultima_coleta_em;

create or replace view public.bolsa_vw_por_uf with (security_invoker = on) as
select uf, count(*) as processos,
       sum(valor_total_estimado) as valor_estimado,
       count(*) filter (where data_encerramento_proposta > now()) as recebendo_propostas,
       count(distinct orgao_cnpj) as orgaos
from bolsa.licitacoes where uf is not null
group by uf;

create or replace view public.bolsa_vw_top_orgaos with (security_invoker = on) as
select l.orgao_cnpj as cnpj, o.razao_social, o.esfera_id, count(*) as processos,
       sum(l.valor_total_estimado) as valor_estimado
from bolsa.licitacoes l join bolsa.orgaos o on o.cnpj = l.orgao_cnpj
group by l.orgao_cnpj, o.razao_social, o.esfera_id
order by valor_estimado desc nulls last limit 25;

create or replace view public.bolsa_vw_top_fornecedores with (security_invoker = on) as
select f.ni, f.nome, f.porte,
       count(distinct r.numero_controle_pncp || '#' || r.numero_item) as itens_homologados,
       sum(r.valor_total_homologado) as valor_homologado,
       (select count(*) from bolsa.contratos c where c.fornecedor_ni = f.ni) as contratos,
       (select sum(c.valor_global) from bolsa.contratos c where c.fornecedor_ni = f.ni) as valor_contratado
from bolsa.fornecedores f
left join bolsa.resultados_itens r on r.fornecedor_ni = f.ni
group by f.ni, f.nome, f.porte
order by valor_homologado desc nulls last limit 25;

create or replace view public.bolsa_vw_licitacoes with (security_invoker = on) as
select numero_controle_pncp, orgao_cnpj, ano_compra, numero_compra, processo,
       modalidade_nome, situacao_nome, srp, objeto, valor_total_estimado, valor_total_homologado,
       data_publicacao_pncp, data_abertura_proposta, data_encerramento_proposta,
       uf, municipio_nome, amparo_legal, link_sistema_origem,
       itens_coletados_em, resultados_coletados_em, first_seen_at, last_seen_at, source_updated_at
from bolsa.licitacoes;

create or replace view public.bolsa_vw_modalidades with (security_invoker = on) as
select modalidade_nome, count(*) as processos, sum(valor_total_estimado) as valor_estimado
from bolsa.licitacoes group by modalidade_nome order by processos desc;

create or replace view public.bolsa_vw_contratos_vencendo with (security_invoker = on) as
select numero_controle_pncp, objeto, orgao_cnpj, uf, municipio_nome, fornecedor_ni, fornecedor_nome,
       valor_global, vigencia_fim, (vigencia_fim - current_date) as dias_restantes
from bolsa.contratos
where vigencia_fim >= current_date
order by vigencia_fim asc limit 50;

create or replace view public.bolsa_vw_eventos_recentes with (security_invoker = on) as
select entidade, chave, tipo, campo, valor_anterior, valor_novo, detectado_em, fonte_id
from bolsa.eventos order by detectado_em desc limit 50;

create or replace view public.bolsa_vw_saude with (security_invoker = on) as
select f.id, f.nome, f.status, f.ultimo_sucesso_em, f.capabilities,
       (select count(*) from bolsa.coleta_log cl where cl.fonte_id = f.id) as execucoes,
       (select json_agg(x) from (
          select job, iniciado_em, finalizado_em, paginas, registros, inseridos, atualizados, ignorados, documentos, erros
          from bolsa.coleta_log cl where cl.fonte_id = f.id order by cl.id desc limit 8) x) as ultimas_execucoes
from bolsa.fontes f;

grant select on public.bolsa_vw_resumo, public.bolsa_vw_por_uf, public.bolsa_vw_top_orgaos,
  public.bolsa_vw_top_fornecedores, public.bolsa_vw_licitacoes, public.bolsa_vw_modalidades,
  public.bolsa_vw_contratos_vencendo, public.bolsa_vw_eventos_recentes, public.bolsa_vw_saude
to anon, authenticated;
