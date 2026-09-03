-- ============================================================
-- PROMPT 01 — Fundação do motor de conectores (estrutura)
-- Source Registry (§1), identidade canônica (§6), proveniência (§7),
-- matriz de capacidades comprovadas (§3) e RPC do painel admin (§24).
--
-- ESTA MIGRAÇÃO AINDA NÃO FOI APLICADA EM PRODUÇÃO: no momento da
-- criação (03/09/2026 ~21:05 UTC) a plataforma colocou o banco em
-- SOMENTE-LEITURA porque a organização do projeto segue no plano FREE
-- (500 MB) com 1,6 GB usados — o upgrade de 8 GB assinado pelo usuário
-- não chegou à organização nnafqgjemezmeklbwopu. Aplicar assim que o
-- plano Pro estiver ativo. Os crons de coleta foram pausados
-- (cron.alter_job active=false) para não esmagar o banco read-only;
-- o bloco de reativação está no fim deste arquivo.
--
-- Reaproveita a arquitetura existente (§36): raw_payloads/
-- arquivos_historicos + bucket memoria-bruta (RAW §4), licitacoes/
-- *_legado (normalização §5), pg_cron + coleta_config + disparar_fonte
-- (scheduler §12), funções coleta-* (conectores §2), eventos (timeline
-- §8), import_erros (DLQ §14), leases/cursores (checkpoints §10).
-- ============================================================

-- 1) SOURCE REGISTRY ------------------------------------------------
create table if not exists bolsa.fontes_registro (
  source_id            text primary key,
  nome                 text not null,
  nome_curto           text,
  camada               text,
  tipo_entidade        text,
  esfera               text,
  uf                   text,
  municipio            text,
  url                  text,
  url_api              text,
  url_docs             text,
  url_descoberta       text,
  entrega_declarada    text,
  metodo_preferencial  text,
  metodo               text check (metodo is null or metodo in
                         ('api','csv','json','xml','rss','html','documentos','navegador','misto')),
  prioridade           text not null default 'P2' check (prioridade in ('P0','P1','P2')),
  status               text not null default 'descoberta' check (status in
                         ('descoberta','em_analise','pronta_para_dev','desenvolvimento',
                          'homologacao','ativa','instavel','manutencao','bloqueada','descontinuada')),
  capacidades          jsonb not null default '{}'::jsonb,  -- declaradas (chave ausente = desconhecido)
  tem_historico        boolean,
  historico_desde      text,
  freq_recomendada     text,
  rate_limit           text,
  autenticacao         text,
  conector             text,          -- slug da edge function quando REALMENTE integrado
  conector_versao      text,
  ultima_coleta        timestamptz,
  ultima_coleta_ok     timestamptz,
  proxima_coleta       timestamptz,
  tempo_resposta_ms    integer,
  erros_total          bigint not null default 0,
  registros_total      bigint not null default 0,
  discovery            jsonb not null default '{}'::jsonb,  -- §23: a investigação técnica fica salva
  origem_levantamento  text,
  status_levantamento  text,
  obs                  text,
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now()
);
create index if not exists fontes_registro_pri_idx on bolsa.fontes_registro (prioridade, status);
create index if not exists fontes_registro_uf_idx  on bolsa.fontes_registro (uf) where uf is not null;
alter table bolsa.fontes_registro enable row level security;  -- sem policies: acesso só via RPC admin

create or replace function bolsa.fontes_registro_touch() returns trigger
language plpgsql as $$ begin new.atualizado_em := now(); return new; end $$;
drop trigger if exists trg_fontes_registro_touch on bolsa.fontes_registro;
create trigger trg_fontes_registro_touch before update on bolsa.fontes_registro
  for each row execute function bolsa.fontes_registro_touch();

-- 2) IDENTIDADE CANÔNICA (§6) --------------------------------------
create table if not exists bolsa.proc_canonico (
  id             bigserial primary key,
  chave_canonica text not null unique,       -- ex.: 'pncp:00394445000101-1-000107/2025'
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
create table if not exists bolsa.proc_fontes (
  canonico_id    bigint not null references bolsa.proc_canonico(id) on delete cascade,
  fonte          text not null,
  tabela         text not null,
  registro_chave text not null,
  url_original   text,
  visto_em       timestamptz not null default now(),
  primary key (fonte, tabela, registro_chave)
);
create index if not exists proc_fontes_canonico_idx on bolsa.proc_fontes (canonico_id);
alter table bolsa.proc_canonico enable row level security;
alter table bolsa.proc_fontes  enable row level security;

-- 3) PROVENIÊNCIA / CONFLITO ENTRE FONTES (§7) ---------------------
create table if not exists bolsa.proveniencia (
  id             bigserial primary key,
  canonico_id    bigint references bolsa.proc_canonico(id) on delete cascade,
  campo          text not null,
  valor_anterior text,
  valor_novo     text,
  fonte          text not null,
  confianca      numeric,
  observado_em   timestamptz not null default now(),
  vigente_em     timestamptz
);
create index if not exists proveniencia_canonico_idx on bolsa.proveniencia (canonico_id, campo);
alter table bolsa.proveniencia enable row level security;

-- 4) RESOLVER CANÔNICO REAL: PNCP × Compras.gov --------------------
-- casa bolsa.licitacoes.numero_controle_pncp com
-- bolsa.licitacoes_legado.possivel_duplicado_pncp (mesmo formato
-- oficial CNPJ-1-SEQ/ANO). Idempotente; divergência de valor vira
-- proveniência em vez de sobrescrita silenciosa (§7).
create or replace function bolsa.resolver_canonico_pncp() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_canon int; v_pncp int; v_cg int; v_conf int;
begin
  insert into bolsa.proc_canonico (chave_canonica)
  select 'pncp:' || l.numero_controle_pncp from bolsa.licitacoes l
  on conflict (chave_canonica) do nothing;
  get diagnostics v_canon = row_count;

  insert into bolsa.proc_fontes (canonico_id, fonte, tabela, registro_chave, url_original)
  select c.id, 'pncp', 'bolsa.licitacoes', l.numero_controle_pncp, l.link_sistema_origem
  from bolsa.licitacoes l
  join bolsa.proc_canonico c on c.chave_canonica = 'pncp:' || l.numero_controle_pncp
  on conflict (fonte, tabela, registro_chave) do nothing;
  get diagnostics v_pncp = row_count;

  insert into bolsa.proc_fontes (canonico_id, fonte, tabela, registro_chave, url_original)
  select c.id, 'compras_gov', 'bolsa.licitacoes_legado', g.chave_fonte, null
  from bolsa.licitacoes_legado g
  join bolsa.proc_canonico c on c.chave_canonica = 'pncp:' || g.possivel_duplicado_pncp
  where g.fonte = 'compras_gov' and g.possivel_duplicado_pncp is not null
  on conflict (fonte, tabela, registro_chave) do nothing;
  get diagnostics v_cg = row_count;

  insert into bolsa.proveniencia (canonico_id, campo, valor_anterior, valor_novo, fonte, confianca)
  select c.id, 'valor_estimado', l.valor_total_estimado::text, g.valor::text, 'compras_gov', 0.6
  from bolsa.licitacoes l
  join bolsa.proc_canonico c on c.chave_canonica = 'pncp:' || l.numero_controle_pncp
  join bolsa.licitacoes_legado g on g.possivel_duplicado_pncp = l.numero_controle_pncp and g.fonte = 'compras_gov'
  where l.valor_total_estimado is not null and g.valor is not null
    and l.valor_total_estimado <> g.valor
    and not exists (select 1 from bolsa.proveniencia p
                    where p.canonico_id = c.id and p.campo = 'valor_estimado' and p.fonte = 'compras_gov'
                      and p.valor_novo = g.valor::text);
  get diagnostics v_conf = row_count;

  return jsonb_build_object('canonicos_novos', v_canon, 'fontes_pncp', v_pncp,
    'fontes_compras_gov', v_cg, 'conflitos_valor', v_conf,
    'total_canonicos', (select count(*) from bolsa.proc_canonico),
    'cross_source', (select count(*) from (
       select canonico_id from bolsa.proc_fontes group by canonico_id having count(distinct fonte) > 1) m));
end $$;

-- 5) MATRIZ DE CAPACIDADES COMPROVADAS (§3): contagens REAIS -------
create or replace view bolsa.v_capacidades_comprovadas as
select * from (values
  ('coleta-pncp', 'pncp', 'editais',       (select count(*) from bolsa.licitacoes)),
  ('coleta-pncp', 'pncp', 'itens',         (select count(*) from bolsa.itens)),
  ('coleta-pncp', 'pncp', 'documentos',    (select count(*) from bolsa.documentos)),
  ('coleta-pncp', 'pncp', 'resultados',    (select count(*) from bolsa.resultados_itens)),
  ('coleta-pncp', 'pncp', 'atas',          (select count(*) from bolsa.atas)),
  ('coleta-pncp', 'pncp', 'contratos',     (select count(*) from bolsa.contratos)),
  ('coleta-pncp', 'pncp', 'pca',           (select count(*) from bolsa.pca_itens)),
  ('coleta-pncp', 'pncp', 'orgaos',        (select count(*) from bolsa.orgaos)),
  ('coleta-pncp', 'pncp', 'fornecedores',  (select count(*) from bolsa.fornecedores)),
  ('coleta-pncp', 'pncp', 'eventos_timeline', (select count(*) from bolsa.eventos)),
  ('coleta-historico-transp', 'transparencia', 'editais',       (select count(*) from bolsa.licitacoes_legado where fonte='transparencia')),
  ('coleta-historico-transp', 'transparencia', 'itens',         (select count(*) from bolsa.itens_legado where fonte='transparencia')),
  ('coleta-historico-transp', 'transparencia', 'participantes', (select count(*) from bolsa.participacoes)),
  ('coleta-historico-transp', 'transparencia', 'empenhos',      (select count(*) from bolsa.empenhos_licitacao)),
  ('coleta-historico-bulk', 'compras_gov', 'editais', (select count(*) from bolsa.licitacoes_legado where fonte='compras_gov')),
  ('coleta-historico-bulk', 'compras_gov', 'itens',   (select count(*) from bolsa.itens_legado where fonte='compras_gov')),
  ('coleta-historico-contratos', 'contratos_gov', 'contratos', (select count(*) from bolsa.contratos_legado)),
  ('coleta-historico-contratos', 'contratos_gov', 'empenhos',  (select count(*) from bolsa.contrato_empenhos_legado)),
  ('coleta-comprasgov', 'compras_gov_api', 'catalogo',        (select count(*) from bolsa.catalogo)),
  ('coleta-comprasgov', 'compras_gov_api', 'precos',          (select count(*) from bolsa.precos_praticados)),
  ('coleta-comprasgov', 'compras_gov_api', 'atas_saldo',      (select count(*) from bolsa.arp_saldos)),
  ('coleta-contratosgov', 'contratos_gov_api', 'contratos',   (select count(*) from bolsa.contratos_gov)),
  ('coleta-transparencia', 'transparencia_api', 'empenhos',   (select count(*) from bolsa.empenhos)),
  ('coleta-transparencia', 'transparencia_api', 'pagamentos', (select count(*) from bolsa.pagamentos_transparencia))
) as t(conector, fonte, capacidade, registros);

-- 6) RPC DO PAINEL ADMIN (§24) -------------------------------------
create or replace function public.bolsa_admin_fontes() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  if not public.saas_is_admin() then
    raise exception 'somente administradores';
  end if;
  select jsonb_build_object(
    'gerado_em', now(),
    'cards', (select jsonb_build_object(
        'total', count(*),
        'p0', count(*) filter (where prioridade='P0'),
        'p1', count(*) filter (where prioridade='P1'),
        'p2', count(*) filter (where prioridade='P2'),
        'ativa', count(*) filter (where status='ativa'),
        'desenvolvimento', count(*) filter (where status in ('desenvolvimento','homologacao','pronta_para_dev')),
        'em_analise', count(*) filter (where status='em_analise'),
        'descoberta', count(*) filter (where status='descoberta'),
        'instavel', count(*) filter (where status in ('instavel','manutencao','bloqueada')))
      from bolsa.fontes_registro),
    'matriz', (select jsonb_agg(jsonb_build_object('conector', conector, 'fonte', fonte,
                 'capacidade', capacidade, 'registros', registros) order by conector, capacidade)
               from bolsa.v_capacidades_comprovadas),
    'canonico', (select jsonb_build_object(
        'total', (select count(*) from bolsa.proc_canonico),
        'cross_source', (select count(*) from (select canonico_id from bolsa.proc_fontes
                          group by canonico_id having count(distinct fonte) > 1) m),
        'conflitos_registrados', (select count(*) from bolsa.proveniencia))),
    'fontes', (select jsonb_agg(jsonb_build_object(
        'sid', source_id, 'nome', nome, 'pri', prioridade, 'camada', camada,
        'uf', uf, 'esfera', esfera, 'status', status, 'conector', conector,
        'url', url, 'entrega', left(coalesce(entrega_declarada,''), 160),
        'metodo', coalesce(metodo, left(metodo_preferencial, 60)),
        'ultima_ok', ultima_coleta_ok, 'registros', registros_total, 'obs', left(coalesce(obs,''), 200))
        order by prioridade, (status <> 'ativa'), source_id)
      from bolsa.fontes_registro)
  ) into r;
  return r;
end $$;
revoke all on function public.bolsa_admin_fontes() from public;
grant execute on function public.bolsa_admin_fontes() to authenticated;

-- ============================================================
-- REATIVAÇÃO DOS CRONS (rodar depois que o plano Pro ativar e o
-- banco sair de somente-leitura; os importadores retomam sozinhos
-- dos cursores/checkpoints):
--   select cron.alter_job(jobid, active := true) from cron.job
--    where jobname like 'bolsa_%' or jobname = 'saas_monitores_tick';
-- ============================================================
