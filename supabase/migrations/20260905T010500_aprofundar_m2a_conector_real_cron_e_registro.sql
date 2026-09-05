-- Aprofundamento M2A Compras (SRC0011) — conector real construído e provado.
--
-- Discovery de 2ª camada (2026-09-05): listagem /processos/index/ é Django
-- server-side; busca real dispara via AJAX GET /processos/tabela/
-- (achado no <script> inline da própria página, função
-- datatableReloadProcessos()). Resposta JSON limpa ({html_table}), sem
-- captcha/WAF/auth em nenhuma camada. 20 processos por página; UUID hex
-- estável por processo na própria URL, usado como chave.
--
-- Provado com 3 execuções reais sequenciais (900 registros, 900 chaves
-- distintas, 0 erros), idempotência confirmada (reenvio do mesmo registro
-- -> novo:false, mudancas:[]), canonicalização real via
-- bolsa.resolver_canonico_processo_disputa() (reaproveitada sem nenhuma
-- modificação — mesma entidade/formato de campos de BNC/BLL/Compras RS):
-- 900/900 com canonico_id, 0 review_required, 0 erros; rerun da
-- canonicalização = 0/0/0/0 (idempotente).
select cron.schedule('bolsa_m2a', '25,55 * * * *', $$select bolsa.disparar_fonte('coleta-m2a','m2a')$$);

update bolsa.fontes_registro
set status = 'ativa',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-05',
      'endpoint_real', '/processos/tabela/?search=&regiao=&uf=&municipio=&modalidade=&page=N',
      'formato', 'JSON limpo ({html_table}), 20 processos/pagina, chave = UUID hex estavel na URL',
      'resultado', 'conector_ativo_provado',
      'execucoes_reais', 3, 'registros_reais', 900, 'chaves_distintas', 900, 'erros', 0,
      'canonicalizacao', '900/900 com canonico_id, 0 review_required, rerun idempotente (0/0/0/0)',
      'campos_extraidos', 'titulo/objeto, modalidade, modo de disputa, abertura do certame, situacao, numero do certame, orgao, cidade/UF',
      'limitacao_conhecida', 'pagina exata de fim da listagem nao determinada ainda (page=500 real, page=2000 alem do fim) — conector detecta o fim via resposta nao-JSON e reinicia varredura do zero na proxima execucao apos terminou=true'
    ),
    obs = obs || ' Aprofundamento (2026-09-05): conector real construido e ativado. Endpoint AJAX /processos/tabela/ descoberto no JS inline da pagina. 3 execucoes reais provadas (900 registros, 0 erros), idempotencia e canonicalizacao confirmadas (reaproveita resolver_canonico_processo_disputa sem modificacao). Cron bolsa_m2a a cada 30min (25,55 * * * *). Volume total ainda desconhecido (paginacao real vai alem de page=500) — varredura continua incrementalmente a cada execucao de cron, reiniciando do zero ao completar uma volta.',
    atualizado_em = now()
where source_id = 'SRC0011';
