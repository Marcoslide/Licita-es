-- Wave 3 #3 — PE Integrado: conector real construído e provado.
--
-- Discovery de 2ª camada (2026-09-05): a listagem real
-- (tbody#trListaMuralProcesso, vazio no HTML servidor) é populada via
-- ASP.NET AJAX PageMethods (ScriptManager), não .asmx (esse padrão existe
-- na mesma app para outras telas, mas não para esta) — achado no arquivo
-- específico da página (Portal/Scripts/NovaPagina/
-- licitacoes-em-andamento.js, não referenciado nos 3 bundles
-- compartilhados portaljs1/2/3 já mapeados na Wave 2):
-- POST /Portal/Pages/LicitacoesEmAndamento.aspx/PesquisarLicitacoesEmAndamento
-- Content-Type: application/json — retorna {d:{Dados:[...],TotalRegistros}}.
-- 655 processos totais confirmados.
--
-- reCAPTCHA v3 presente na página é invisível/automático e ligado à ação
-- "homepage" (login) — confirmado que o endpoint de listagem funciona sem
-- nenhum token de captcha (os erros reais encontrados durante o discovery
-- foram só de parâmetro/tipo do .NET — nome errado de parâmetro, DateTime
-- não-nulável recebendo null — nunca de autenticação ou captcha). Nenhuma
-- proteção contornada.
--
-- Provado com 2 execuções reais sequenciais (600 registros, 600 chaves
-- distintas, 0 erros), idempotência confirmada (reenvio -> novo:false,
-- mudancas:[]). Canonicalização real via
-- bolsa.resolver_canonico_processo_disputa() (reaproveitada sem
-- modificação): 600/600 com canonico_id, 0 review_required, rerun
-- idempotente (0/0/0/0).
insert into bolsa.coleta_config (job, cron, params, ativo)
values ('peintegrado', '15,45 * * * *', '{}'::jsonb, true)
on conflict (job) do update set cron = excluded.cron, params = excluded.params, ativo = true;

update bolsa.fontes_registro
set status = 'ativa',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-05',
      'endpoint_real', '/Portal/Pages/LicitacoesEmAndamento.aspx/PesquisarLicitacoesEmAndamento',
      'tecnologia', 'ASP.NET WebForms PageMethods (nao .asmx)',
      'formato', 'JSON limpo ({d:{Dados,TotalRegistros}}), paginacao offset/tamanho',
      'volume_real', '655 processos totais',
      'resultado', 'conector_ativo_provado',
      'execucoes_reais', 2, 'registros_distintos', 600, 'erros', 0,
      'canonicalizacao', '600/600 com canonico_id, 0 review_required, rerun idempotente (0/0/0/0)',
      'recaptcha', 'presente na pagina (v3 invisivel, ligado a acao homepage/login) mas confirmado que NAO protege o endpoint de listagem — nao contornado'
    ),
    obs = obs || ' Wave 3 (2026-09-05): endpoint real achado em Portal/Scripts/NovaPagina/licitacoes-em-andamento.js (arquivo especifico da pagina, nao nos bundles compartilhados ja mapeados) — PageMethods.PesquisarLicitacoesEmAndamento via POST JSON, nao .asmx. 655 processos totais. Conector ativo, provado com 2 execucoes reais (600 registros, 0 erros) e canonicalizacao (600/600, idempotente). Cron bolsa_peintegrado ativado (15,45 * * * *). reCAPTCHA v3 da pagina confirmado que nao protege este endpoint.',
    atualizado_em = now()
where source_id = 'SRC0010';
