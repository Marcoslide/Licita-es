-- Wave 1 P0 — discovery real do Portal de Compras Públicas (2026-09-04).
-- ACHADO POSITIVO: API REST pública, oficial, versionada e documentada
-- (apidoc.js) em apipcp.portaldecompraspublicas.com.br/publico/apidoc/,
-- grupo "Busca_Automatizada" — feita explicitamente para "automatização
-- de consultas... para serem consumidos por outros sistemas". Cobre:
-- listagem (listarProcessos, processosAbertos com paginação/UF/data),
-- detalhe (obterProcesso), documentos (obteranexoslicitacao), atas/
-- resultados (obterAtas), ITENS (obterItensEmDisputa), CHAT
-- (obterChat, paginado), status (obterStatusProcesso), fornecedores/
-- participantes (processosFornecedor por idFornecedor). Módulo
-- "Comprador" tem inclusive rota dedicada "Obter dados do PNCP" —
-- overlap com PNCP é rastreado pela própria plataforma.
-- Todas as rotas exigem parâmetro publicKey (testado sem key:
-- HTTP 400 {"success":false,"mensagem":"Erro autenticação"} — rota
-- existe e responde, só falta a chave). A documentação orienta contato
-- via e-mail (comprador@portaldecompraspublicas.com.br), WhatsApp ou
-- telefone para dúvidas/acesso a ambiente de testes — sugere que obter
-- a publicKey é um passo de relacionamento comercial/onboarding, não
-- uma falha técnica nem uma proteção a ser contornada. NÃO contatamos
-- a empresa nem tentamos obter a chave sem autorização explícita do
-- usuário — decisão de negócio, não técnica.
update bolsa.fontes_registro
set status = 'pronta_para_dev',
    metodo = 'api',
    autenticacao = 'publicKey_query_param_requer_solicitacao',
    url_api = 'https://apipcp.portaldecompraspublicas.com.br/publico/',
    url_docs = 'https://apipcp.portaldecompraspublicas.com.br/publico/apidoc/',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-04',
      'resultado', 'api_publica_documentada_aguardando_publickey',
      'plataforma', 'Angular SPA (não SSR) em www.portaldecompraspublicas.com.br; API real em apipcp.portaldecompraspublicas.com.br',
      'documentacao_completa', 'https://apipcp.portaldecompraspublicas.com.br/publico/apidoc/api_data.json (apidoc.js, 636KB, dezenas de rotas)',
      'endpoints_modulo_publico', jsonb_build_array(
        'GET /publico/listarProcessos (cdSituacao, dataInicio, dataFim, pagina)',
        'GET /publico/processosAbertos (dataInicio, dataFim, uf, pagina)',
        'GET /publico/obterProcesso (idLicitacao) — informações públicas completas',
        'GET /publico/obterStatusProcesso (idLicitacao)',
        'GET /publico/obteranexoslicitacao (idLicitacao) — DOCUMENTOS',
        'GET /publico/obterAtas (idLicitacao, tipoAta) — ATAS/RESULTADOS',
        'GET /publico/obterItensEmDisputa (idLicitacao) — ITENS',
        'GET /publico/obterChat (idLicitacao, idUltimaFrase, pagina) — CHAT paginado',
        'GET /publico/processosFornecedor (idFornecedor, tipoFornecedor, pagina) — PARTICIPANTES/FORNECEDORES',
        'GET /publico/obterProcessosPoucaParticipacao — inteligência de mercado (baixa concorrência)'
      ),
      'overlap_pncp', 'módulo Comprador tem rota dedicada "Obter dados do PNCP" — a própria plataforma rastreia o vínculo PNCP por processo',
      'bloqueio', 'todas as rotas /publico/* exigem query param publicKey; testado sem key: HTTP 400 {"success":false,"mensagem":"Erro autenticação"} (rota existe, responde — não é 404)',
      'como_obter_key', 'documentação orienta contato: comprador@portaldecompraspublicas.com.br, WhatsApp 3003-5455, ou telefone — parece ser onboarding comercial padrão para consumidores de API, não uma barreira de segurança',
      'decisao', 'discovery completo e positivo; obtenção da publicKey NÃO iniciada — é decisão de negócio/contato externo, aguardando autorização explícita do usuário'
    ),
    obs = 'MELHOR achado da Wave 1 até agora: API pública oficial, documentada, cobrindo listagem+detalhe+documentos+atas+itens+CHAT+fornecedores, com rota própria de vínculo PNCP. Único bloqueio é a publicKey (requer contato comercial, não é uma proteção técnica a driblar). Aguardando decisão do usuário sobre como obter a chave antes de construir o conector.',
    atualizado_em = now()
where source_id = 'SRC0007';
