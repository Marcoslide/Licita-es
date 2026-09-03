-- ============================================================
-- CORREÇÃO DE SEGURANÇA — achada durante a validação da migração
-- 20260903T213000 (tarefa #26 da retomada controlada do PROMPT 01).
--
-- bolsa_admin_matriz() era SECURITY DEFINER, SEM nenhum check interno
-- de administrador, e `anon` (visitante não autenticado, só com a
-- chave pública) conseguia executá-la via
-- POST /rest/v1/rpc/bolsa_admin_matriz — vazando em produção, sem
-- login algum: tamanho do banco, totais reais de licitações/itens/
-- participações/empenhos/valor estimado/valor pago por ano, matriz
-- de importação por fonte×ano×mês e o conteúdo do relatório diário.
--
-- Causa raiz (confirmada via pg_default_acl): neste projeto existem
-- DOIS caminhos independentes que concedem EXECUTE a anon em toda
-- function nova do schema public —
--   (1) o grant implícito padrão do Postgres a PUBLIC (= todo mundo)
--       ao criar qualquer function, a menos que revogado;
--   (2) um default privilege próprio do Supabase (dono postgres,
--       schema public) que concede EXECUTE direto a anon/authenticated/
--       service_role no exato momento da criação — independente do (1).
-- Revogar só um dos dois caminhos NÃO fecha o acesso: é preciso
-- `revoke ... from public` E `revoke ... from anon` juntos (confirmado
-- experimentalmente: revogar só de anon deixou 3 das funções abaixo
-- ainda executáveis por anon via o caminho (1); só depois de também
-- revogar de public é que fecharam).
--
-- bolsa_admin_matriz nunca teve nenhum revoke — o único caso real de
-- vazamento de dado (as demais já tinham check interno de
-- saas_is_admin(), então a chamada anon só falhava com exceção, sem
-- vazar nada, mas ficava desnecessariamente exposta): saas_admin_memoria,
-- saas_metricas_admin, saas_admin_monitor_stats.
--
-- bolsa_admin_fontes (criada na própria migração 213000) já tinha
-- `revoke all from public` no arquivo original, mas sem `from anon` —
-- por isso o caminho (2) continuava aberto. Fechado aqui.
--
-- NÃO investigado nesta correção (fora do escopo desta migração,
-- fica registrado para uma revisão de segurança dedicada): outras
-- ~10 SECURITY DEFINER também executáveis por anon sem guard de
-- admin — bolsa_buscar/bolsa_precos_estatisticas (parecem ser busca
-- pública da landing, por design) e saas_consumir/saas_meu_acesso/
-- saas_meus_monitores/saas_monitor_criar/saas_monitor_duplicar/
-- saas_monitor_sugerir_expansoes/saas_registrar_evento (precisam de
-- leitura linha a linha para confirmar que todas escopam
-- corretamente por auth.uid() e não confiam em parâmetro de cliente).
-- ============================================================

create or replace function public.bolsa_admin_matriz() returns jsonb
language plpgsql stable security definer set search_path to 'public', 'bolsa' as $function$
begin
  if not public.saas_is_admin() then
    raise exception 'somente administradores';
  end if;
  return jsonb_build_object(
 'gerado_em', now(),
 'db', jsonb_build_object('bytes', pg_database_size(current_database()),
        'limite_bytes', (select limite_bytes from bolsa.capacidade_config where id=1),
        'pct', round(100.0*pg_database_size(current_database())/(select limite_bytes from bolsa.capacidade_config where id=1),1)),
 'transparencia', (select jsonb_agg(to_jsonb(a) order by a.ano desc) from (
    select ano,
      jsonb_object_agg(lpad(mes::text,2,'0'),
        jsonb_build_object('s', import_status, 'linhas', linhas_processadas, 'erros', erros,
                           'mismatch', coalesce((detalhe->>'coverage_mismatch')::bool, false)) order by mes) meses,
      count(*) filter (where import_status='COMPLETE') completos,
      count(*) filter (where import_status in ('PARTIAL','IMPORTING','VALIDATING','DOWNLOADING')) parciais,
      count(*) filter (where import_status='PENDING') pendentes,
      count(*) filter (where import_status='SOURCE_NOT_AVAILABLE') fonte_indisponivel,
      count(*) filter (where import_status='FAILED') falhas,
      (count(*) filter (where import_status in ('COMPLETE','SOURCE_NOT_AVAILABLE')) = count(*)) ano_fechado
    from bolsa.arquivos_historicos
    where fonte='transparencia' and (detalhe->>'hold') is null
    group by ano) a),
 'compras_gov', (select jsonb_agg(to_jsonb(a) order by a.dataset, a.ano desc) from (
    select dataset, ano, import_status s, cursor_bytes, tamanho_bytes,
      case when coalesce(tamanho_bytes,0)>0 then round(100.0*cursor_bytes/tamanho_bytes,1) end pct,
      inseridos, erros
    from bolsa.arquivos_historicos
    where fonte='compras_gov' and dataset like 'comprasgov_anual%' and (detalhe->>'hold') is null) a),
 'contratos_gov', (select jsonb_agg(to_jsonb(a) order by a.dataset, a.ano desc) from (
    select dataset, ano, import_status s, cursor_bytes, tamanho_bytes,
      case when coalesce(tamanho_bytes,0)>0 then round(100.0*cursor_bytes/tamanho_bytes,1) end pct,
      inseridos, coalesce(detalhe->>'hold','') hold
    from bolsa.arquivos_historicos where fonte='contratos_gov' and url not like '%-latest.csv') a),
 'pncp', jsonb_build_object(
    'por_mes', (select jsonb_agg(to_jsonb(a) order by a.ym) from (
       select to_char(date_trunc('month', data_publicacao_pncp),'YYYY-MM') ym, count(*) n
       from bolsa.licitacoes where data_publicacao_pncp is not null group by 1) a)),
 'totais_ano', (select jsonb_agg(to_jsonb(t) order by t.ano desc) from (
    select ano,
      sum(n_lics)::bigint licitacoes, sum(vl)::numeric valor_estimado,
      sum(n_itens)::bigint itens, sum(n_parts)::bigint participantes,
      sum(n_venc)::bigint vencedores, max(n_forn)::bigint fornecedores,
      sum(n_emps)::bigint empenhos, sum(n_contr)::bigint contratos,
      sum(v_emp)::numeric valor_empenhado, sum(v_pago)::numeric valor_pago
    from (
      select ano, count(*)::bigint n_lics, sum(valor)::numeric vl, 0::bigint n_itens, 0::bigint n_parts, 0::bigint n_venc, 0::bigint n_forn, 0::bigint n_emps, 0::bigint n_contr, 0::numeric v_emp, 0::numeric v_pago
        from bolsa.licitacoes_legado group by ano
      union all
      select ano, 0, 0, count(*)::bigint, 0, 0, 0, 0, 0, 0, 0 from bolsa.itens_legado group by ano
      union all
      select ano, 0, 0, 0, count(*)::bigint, (count(*) filter (where situacao='vencedor'))::bigint,
             (count(distinct fornecedor_ni))::bigint, 0, 0, 0, 0 from bolsa.participacoes group by ano
      union all
      select ano, 0, 0, 0, 0, 0, 0, count(*)::bigint, 0, 0, 0 from bolsa.empenhos_licitacao group by ano
      union all
      select ano, 0, 0, 0, 0, 0, 0, 0, count(*)::bigint, 0, 0 from bolsa.contratos_legado group by ano
      union all
      select ano, 0, 0, 0, 0, 0, 0, 0, 0, sum(valor_empenhado)::numeric, sum(valor_pago)::numeric
        from bolsa.contrato_empenhos_legado group by ano
    ) u where ano is not null group by ano) t),
 'canonicas', jsonb_build_object(
    'registros_fonte', (select count(*) from bolsa.licitacoes_legado) + (select count(*) from bolsa.licitacoes),
    'duplicatas_pncp_marcadas', (select count(*) from bolsa.licitacoes_legado where possivel_duplicado_pncp is not null),
    'entidades_canonicas_estimadas', (select count(*) from bolsa.licitacoes_legado where possivel_duplicado_pncp is null)
                                     + (select count(*) from bolsa.licitacoes)),
 'gaps', (select jsonb_agg(to_jsonb(g) order by g.ano) from (
    select 'transparencia' fonte, ano,
           count(*) filter (where import_status not in ('COMPLETE','SOURCE_NOT_AVAILABLE')) meses_abertos
    from bolsa.arquivos_historicos where fonte='transparencia' and (detalhe->>'hold') is null
    group by ano
    having count(*) filter (where import_status not in ('COMPLETE','SOURCE_NOT_AVAILABLE')) > 0) g),
 'alertas_capacidade', (select jsonb_agg(to_jsonb(x) order by x.id desc) from (
    select id, em, nivel, db_bytes from bolsa.capacidade_alertas order by id desc limit 5) x),
 'relatorio_diario', (select dados from bolsa.relatorios_diarios order by dia desc limit 1)
  );
end $function$;

revoke all on function public.bolsa_admin_matriz() from public;
revoke all on function public.bolsa_admin_matriz() from anon;
grant execute on function public.bolsa_admin_matriz() to authenticated;

revoke all on function public.bolsa_admin_fontes() from public;
revoke all on function public.bolsa_admin_fontes() from anon;
grant execute on function public.bolsa_admin_fontes() to authenticated;

revoke all on function public.saas_admin_memoria() from public;
revoke all on function public.saas_metricas_admin() from public;
revoke all on function public.saas_admin_monitor_stats() from public;
grant execute on function public.saas_admin_memoria() to authenticated;
grant execute on function public.saas_metricas_admin() to authenticated;
grant execute on function public.saas_admin_monitor_stats() to authenticated;
