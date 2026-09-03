-- BOLSA DE LICITAÇÕES — schema canônico (dialeto SQLite, espelho da migração Postgres em supabase/migrations)
-- Camadas: raw (imutável) -> normalizada -> analítica. NULL = não disponível; 0 = zero de fato (§35).

CREATE TABLE IF NOT EXISTS fontes (
  id TEXT PRIMARY KEY, nome TEXT NOT NULL, base_url TEXT NOT NULL,
  capabilities TEXT NOT NULL DEFAULT '{}', status TEXT NOT NULL DEFAULT 'ATIVA',
  ultimo_sucesso_em TEXT, criado_em TEXT NOT NULL DEFAULT (datetime('now'))
);
INSERT OR IGNORE INTO fontes (id, nome, base_url, capabilities) VALUES
 ('pncp','Portal Nacional de Contratações Públicas','https://pncp.gov.br',
  '{"licitacoes":true,"itens":true,"documentos":true,"resultados":true,"contratos":true,"atas":true,"pca":true,"pagamentos":false,"lances":false}');

CREATE TABLE IF NOT EXISTS raw_payloads (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fonte_id TEXT NOT NULL REFERENCES fontes(id),
  url TEXT NOT NULL, contexto TEXT, http_status INTEGER,
  content_hash TEXT NOT NULL, payload TEXT NOT NULL,
  colhido_em TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (url, content_hash)
);

CREATE TABLE IF NOT EXISTS orgaos (
  cnpj TEXT PRIMARY KEY, razao_social TEXT, poder_id TEXT, esfera_id TEXT,
  first_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
  source_payload TEXT
);

CREATE TABLE IF NOT EXISTS unidades (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  orgao_cnpj TEXT NOT NULL REFERENCES orgaos(cnpj),
  codigo TEXT NOT NULL, nome TEXT, uf TEXT, municipio_nome TEXT, codigo_ibge TEXT,
  UNIQUE (orgao_cnpj, codigo)
);

CREATE TABLE IF NOT EXISTS licitacoes (
  numero_controle_pncp TEXT PRIMARY KEY,
  fonte_id TEXT NOT NULL REFERENCES fontes(id),
  orgao_cnpj TEXT, unidade_codigo TEXT,
  ano_compra INTEGER, sequencial_compra INTEGER, numero_compra TEXT, processo TEXT,
  modalidade_id INTEGER, modalidade_nome TEXT, modo_disputa TEXT,
  situacao_id INTEGER, situacao_nome TEXT, situacao_fonte TEXT,
  srp INTEGER, instrumento TEXT, objeto TEXT,
  valor_total_estimado REAL, valor_total_homologado REAL,
  data_publicacao_pncp TEXT, data_abertura_proposta TEXT, data_encerramento_proposta TEXT,
  uf TEXT, municipio_nome TEXT, codigo_ibge TEXT,
  amparo_legal TEXT, informacao_complementar TEXT, link_sistema_origem TEXT, usuario_nome TEXT,
  itens_coletados_em TEXT, arquivos_coletados_em TEXT, resultados_coletados_em TEXT,
  first_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
  source_updated_at TEXT, source_payload TEXT NOT NULL, raw_hash TEXT
);
CREATE INDEX IF NOT EXISTS licitacoes_uf_idx ON licitacoes (uf);
CREATE INDEX IF NOT EXISTS licitacoes_pub_idx ON licitacoes (data_publicacao_pncp);
CREATE INDEX IF NOT EXISTS licitacoes_situacao_idx ON licitacoes (situacao_nome);

CREATE TABLE IF NOT EXISTS itens (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  numero_controle_pncp TEXT NOT NULL REFERENCES licitacoes(numero_controle_pncp),
  numero_item INTEGER NOT NULL, descricao TEXT, material_ou_servico TEXT,
  quantidade REAL, unidade TEXT, valor_unitario_estimado REAL, valor_total_estimado REAL,
  categoria_id INTEGER, categoria_nome TEXT, criterio_julgamento TEXT,
  situacao_fonte TEXT, beneficio TEXT, ncm_nbs TEXT, catalogo_codigo TEXT,
  tem_resultado INTEGER, orcamento_sigiloso INTEGER,
  source_updated_at TEXT, source_payload TEXT NOT NULL,
  first_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (numero_controle_pncp, numero_item)
);

CREATE TABLE IF NOT EXISTS fornecedores (
  ni TEXT PRIMARY KEY, tipo_pessoa TEXT, nome TEXT, porte TEXT,
  first_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_seen_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS resultados_itens (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  numero_controle_pncp TEXT NOT NULL REFERENCES licitacoes(numero_controle_pncp),
  numero_item INTEGER NOT NULL, sequencial_resultado INTEGER,
  fornecedor_ni TEXT, fornecedor_nome TEXT, tipo_pessoa TEXT, porte TEXT,
  quantidade_homologada REAL, valor_unitario_homologado REAL, valor_total_homologado REAL,
  percentual_desconto REAL, situacao_fonte TEXT, data_resultado TEXT,
  source_payload TEXT NOT NULL,
  first_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_seen_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS resultados_uq ON resultados_itens
  (numero_controle_pncp, numero_item, ifnull(fornecedor_ni,'-'), ifnull(sequencial_resultado,0));

CREATE TABLE IF NOT EXISTS documentos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  numero_controle_pncp TEXT NOT NULL REFERENCES licitacoes(numero_controle_pncp),
  sequencial_documento INTEGER, titulo TEXT, tipo_documento TEXT, url TEXT,
  status_ativo INTEGER, data_publicacao TEXT, source_payload TEXT NOT NULL,
  first_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_seen_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS documentos_uq ON documentos
  (numero_controle_pncp, ifnull(sequencial_documento,0), ifnull(url,'-'));

CREATE TABLE IF NOT EXISTS contratos (
  numero_controle_pncp TEXT PRIMARY KEY,
  numero_controle_pncp_compra TEXT, numero_contrato TEXT, ano_contrato INTEGER,
  processo TEXT, categoria TEXT, tipo TEXT, objeto TEXT,
  orgao_cnpj TEXT, unidade_codigo TEXT, uf TEXT, municipio_nome TEXT,
  fornecedor_ni TEXT, fornecedor_nome TEXT,
  valor_inicial REAL, valor_global REAL,
  data_assinatura TEXT, vigencia_inicio TEXT, vigencia_fim TEXT,
  data_publicacao_pncp TEXT, source_updated_at TEXT, source_payload TEXT NOT NULL,
  first_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_seen_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS eventos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entidade TEXT NOT NULL, chave TEXT NOT NULL, tipo TEXT NOT NULL,
  campo TEXT, valor_anterior TEXT, valor_novo TEXT, fonte_id TEXT,
  detectado_em TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS eventos_chave_idx ON eventos (chave);

CREATE TABLE IF NOT EXISTS checkpoints (
  chave TEXT PRIMARY KEY, valor TEXT NOT NULL,
  atualizado_em TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS coleta_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fonte_id TEXT NOT NULL, job TEXT NOT NULL,
  iniciado_em TEXT NOT NULL DEFAULT (datetime('now')), finalizado_em TEXT,
  paginas INTEGER DEFAULT 0, registros INTEGER DEFAULT 0, inseridos INTEGER DEFAULT 0,
  atualizados INTEGER DEFAULT 0, ignorados INTEGER DEFAULT 0, documentos INTEGER DEFAULT 0,
  erros INTEGER DEFAULT 0, detalhe TEXT
);

CREATE TABLE IF NOT EXISTS data_quality_issues (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entidade TEXT, chave TEXT, campo TEXT, problema TEXT, valor TEXT,
  detectado_em TEXT NOT NULL DEFAULT (datetime('now'))
);
