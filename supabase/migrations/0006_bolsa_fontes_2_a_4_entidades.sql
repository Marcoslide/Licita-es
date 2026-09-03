-- ============================================================
-- Etapas 2–4: entidades para Compras.gov, Contratos.gov e
-- Portal da Transparência + atas/PCA do PNCP.
-- Campos incertos da fonte vivem no source_payload (§27).
-- ============================================================

insert into bolsa.fontes (id, nome, base_url, capabilities, status) values
 ('compras_gov','Compras.gov.br — Dados Abertos','https://dadosabertos.compras.gov.br',
  '{"catalogo_catmat":true,"catalogo_catser":true,"pesquisa_precos":true,"arp":"sondagem","legado":"sondagem","licitacoes":"via PNCP","pagamentos":false,"lances":false}'::jsonb,'EM_IMPLANTACAO'),
 ('contratos_gov','Contratos.gov.br (Comprasnet Contratos)','https://contratos.comprasnet.gov.br',
  '{"contratos":true,"itens":"sondagem","empenhos":true,"faturas":true,"garantias":true,"ocorrencias":true,"pagamentos":"parcial via empenhos","lances":false}'::jsonb,'EM_IMPLANTACAO'),
 ('portal_transparencia','Portal da Transparência','https://api.portaldatransparencia.gov.br',
  '{"despesas":true,"empenhos":true,"pagamentos":true,"observacao":"exige chave de API gratuita","lances":false}'::jsonb,'EM_IMPLANTACAO')
on conflict (id) do nothing;

create table bolsa.atas (
  numero_controle_pncp_ata text primary key,
  numero_ata text,
  ano int,
  numero_controle_pncp_compra text,
  orgao_cnpj text,
  unidade_codigo text,
  uf text,
  municipio_nome text,
  objeto text,
  data_assinatura date,
  vigencia_inicio date,
  vigencia_fim date,
  cancelado boolean,
  source_updated_at timestamptz,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index atas_fim_idx on bolsa.atas (vigencia_fim);
create index atas_compra_idx on bolsa.atas (numero_controle_pncp_compra);

create table bolsa.pca_itens (
  id bigint generated always as identity primary key,
  fonte_id text not null default 'pncp',
  orgao_cnpj text,
  ano_pca int not null,
  chave_dedup text not null,
  numero_item int,
  categoria_nome text,
  descricao text,
  quantidade numeric,
  valor_unitario numeric,
  valor_total numeric,
  valor_orcamento_exercicio numeric,
  data_desejada date,
  unidade_requisitante text,
  classificacao_superior_codigo text,
  classificacao_superior_nome text,
  catalogo_codigo text,
  source_updated_at timestamptz,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (orgao_cnpj, ano_pca, chave_dedup)
);
create index pca_ano_idx on bolsa.pca_itens (ano_pca);

create table bolsa.catalogo (
  tipo text not null check (tipo in ('MATERIAL','SERVICO')),
  codigo text not null,
  descricao text,
  unidade text,
  grupo_codigo text, grupo_nome text,
  classe_codigo text, classe_nome text,
  pdm_codigo text, pdm_nome text,
  situacao text,
  source_updated_at timestamptz,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (tipo, codigo)
);

create table bolsa.precos_praticados (
  id bigint generated always as identity primary key,
  fonte_id text not null default 'compras_gov',
  tipo text check (tipo in ('MATERIAL','SERVICO')),
  catalogo_codigo text,
  chave_dedup text not null,
  descricao_item text,
  valor_unitario numeric,
  quantidade numeric,
  unidade text,
  data_compra date,
  data_resultado date,
  orgao_nome text,
  uasg_codigo text,
  uasg_nome text,
  uf text, municipio_nome text,
  fornecedor_ni text, fornecedor_nome text,
  modalidade_nome text,
  numero_processo text,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (fonte_id, chave_dedup)
);
create index precos_catalogo_idx on bolsa.precos_praticados (catalogo_codigo);

create table bolsa.contratos_gov (
  id_fonte bigint primary key,
  receita_despesa text,
  numero text,
  orgao_codigo text, orgao_nome text,
  uasg_codigo text, uasg_nome text,
  fornecedor_ni text, fornecedor_nome text,
  objeto text,
  tipo text, categoria text, processo text,
  modalidade text, licitacao_numero text,
  vigencia_inicio date, vigencia_fim date,
  valor_global numeric, valor_inicial numeric,
  num_parcelas int, valor_parcela numeric, valor_acumulado numeric,
  situacao text,
  source_updated_at timestamptz,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index cg_uasg_idx on bolsa.contratos_gov (uasg_codigo);
create index cg_fim_idx on bolsa.contratos_gov (vigencia_fim);
create index cg_forn_idx on bolsa.contratos_gov (fornecedor_ni);

create table bolsa.empenhos (
  id bigint generated always as identity primary key,
  id_contratos_gov bigint references bolsa.contratos_gov(id_fonte),
  chave_dedup text not null,
  numero text,
  credor_ni text, credor_nome text,
  plano_interno text, natureza_despesa text,
  valor_empenhado numeric,
  valor_aliquidar numeric,
  valor_liquidado numeric,
  valor_pago numeric,
  data_emissao date,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (id_contratos_gov, chave_dedup)
);

create table bolsa.faturas (
  id bigint generated always as identity primary key,
  id_contratos_gov bigint references bolsa.contratos_gov(id_fonte),
  chave_dedup text not null,
  numero text,
  valor numeric, valor_liquido numeric,
  emissao date, vencimento date,
  situacao text,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (id_contratos_gov, chave_dedup)
);

create table bolsa.garantias (
  id bigint generated always as identity primary key,
  id_contratos_gov bigint references bolsa.contratos_gov(id_fonte),
  chave_dedup text not null,
  tipo text,
  valor numeric,
  vencimento date,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (id_contratos_gov, chave_dedup)
);

create table bolsa.ocorrencias_contrato (
  id bigint generated always as identity primary key,
  id_contratos_gov bigint references bolsa.contratos_gov(id_fonte),
  chave_dedup text not null,
  numero text, tipo text, situacao text,
  data date, descricao text,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (id_contratos_gov, chave_dedup)
);

create table bolsa.pagamentos_transparencia (
  id bigint generated always as identity primary key,
  fase text not null check (fase in ('EMPENHO','LIQUIDACAO','PAGAMENTO')),
  chave_dedup text not null unique,
  documento text,
  data date,
  valor numeric,
  orgao_codigo text, orgao_nome text,
  unidade_gestora text,
  favorecido_ni text, favorecido_nome text,
  elemento_despesa text,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index pt_fase_data_idx on bolsa.pagamentos_transparencia (fase, data desc);

create table bolsa.segredos (
  chave text primary key,
  valor text not null,
  atualizado_em timestamptz not null default now()
);

do $$ declare t text;
begin
  foreach t in array array['atas','pca_itens','catalogo','precos_praticados','contratos_gov',
    'empenhos','faturas','garantias','ocorrencias_contrato','pagamentos_transparencia'] loop
    execute format('create trigger fix_payload_trg before insert or update on bolsa.%I for each row execute function bolsa.fix_payload()', t);
  end loop;
end $$;

do $$ declare t text;
begin
  foreach t in array array['atas','pca_itens','catalogo','precos_praticados','contratos_gov',
    'empenhos','faturas','garantias','ocorrencias_contrato','pagamentos_transparencia','segredos'] loop
    execute format('alter table bolsa.%I enable row level security', t);
  end loop;
  foreach t in array array['atas','pca_itens','catalogo','precos_praticados','contratos_gov',
    'empenhos','faturas','garantias','ocorrencias_contrato','pagamentos_transparencia'] loop
    execute format('create policy leitura_publica on bolsa.%I for select to anon, authenticated using (true)', t);
  end loop;
end $$;

insert into bolsa.coleta_config (job, cron, params) values
 ('pncp_atas','37 */2 * * *','{"job":"atas","orcamentoMs":35000}'),
 ('pncp_pca','52 6 * * *','{"job":"pca","orcamentoMs":35000}'),
 ('comprasgov_catalogo','18 * * * *','{"job":"catalogo","orcamentoMs":35000}'),
 ('comprasgov_precos','33 */2 * * *','{"job":"precos","orcamentoMs":35000}'),
 ('contratosgov','7 */3 * * *','{"job":"contratos","orcamentoMs":35000}'),
 ('transparencia','47 */6 * * *','{"job":"despesas","orcamentoMs":35000}')
on conflict (job) do nothing;
