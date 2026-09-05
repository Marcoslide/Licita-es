-- Wave 3 #4 — LicitaMais Brasil: progresso real, endpoint exato de
-- listagem ainda não localizado — pausado por custo/benefício (mesmo
-- critério de e-LIC SC/PE Integrado/Compras ES na Wave 2).
--
-- Extraído do bundle JS (mesma técnica de BBMNET/Compras BR/Compras
-- RS/SIADES): API real em https://api.licitamaisbrasil.com.br (backend
-- "licita-mais-backend-master", confirmado via /  -> healthcheck real,
-- isDbConnected:true) + WebSocket de chat em
-- wss://chat.licitamaisbrasil.com.br/ (dado de alto valor se um dia for
-- coletado). API exige header Origin (CORS ativo, não é bloqueio de
-- autenticação — testado: sem Origin = 403 "Not allowed by CORS", com
-- Origin correto = passa a checagem CORS normalmente). GET /processes
-- (chute) devolveu 404 real do Express ("Cannot GET /processes"), ou
-- seja o servidor responde normalmente, só não é essa a rota.
--
-- Buscas no bundle app.js por padrões de chamada (.get("/, nomes de rota
-- como "auction"/"detail"/"tradingRoom" vistos nos nomes de chunk CSS/JS
-- publicamente listados) não acharam a string literal do endpoint — o
-- app.js principal não contém as chamadas HTTP dos módulos lazy-loaded
-- (por página), que teriam de ser baixados e vasculhados um a um.
-- Sem bloqueio confirmado em nenhuma camada — pausado por custo/benefício.
update bolsa.fontes_registro
set discovery = jsonb_build_object(
      'testado_em', '2026-09-05',
      'api_real', 'https://api.licitamaisbrasil.com.br (backend licita-mais-backend-master, healthcheck real confirmado)',
      'websocket_chat', 'wss://chat.licitamaisbrasil.com.br/ (nao testado, dado de alto valor potencial)',
      'cors', 'API exige header Origin correto (nao e bloqueio de autenticacao/captcha) — confirmado sem Origin=403, com Origin=passa',
      'endpoint_listagem', 'nao localizado ainda — chutes diretos (/processes) devolveram 404 real do Express, servidor responde normalmente',
      'resultado', 'progresso_parcial_pausado_custo_beneficio'
    ),
    obs = obs || ' Wave 3 (2026-09-05): API real extraida do bundle (api.licitamaisbrasil.com.br, healthcheck confirmado) + websocket de chat (wss://chat.licitamaisbrasil.com.br/). CORS exige header Origin (nao autenticacao). Endpoint exato de listagem publica ainda nao localizado — modulos lazy-loaded (por pagina) nao vasculhados individualmente. Sem bloqueio confirmado. Pausado por custo/beneficio, mesmo criterio de e-LIC SC/Compras ES/PE Integrado na Wave 2 — pode ser retomado com mais tempo (vasculhar chunks lazy-loaded chamados "auction"/"detail"/"tradingRoom").',
    atualizado_em = now()
where source_id = 'SRC0013';
