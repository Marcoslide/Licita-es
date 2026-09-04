-- Atualiza o source registry para refletir a realidade: BNC e BLL
-- Compras têm conectores reais implantados, testados (idempotência +
-- checkpoint em múltiplas execuções reais) e crons ativos. Faltou
-- atualizar isso quando a BNC foi implantada — corrigido aqui junto
-- com a BLL (mesma família de tecnologia).
update bolsa.fontes_registro
set status = 'ativa',
    metodo = 'html',
    conector = 'coleta-bnc',
    conector_versao = 'v3',
    autenticacao = 'nenhuma_para_capacidades_publicas',
    freq_recomendada = '30min',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-04',
      'resultado', 'ativo_producao',
      'capacidades_coletadas', jsonb_build_array('listagem_publica', 'detalhe_processo', 'arquivos_com_download_direto'),
      'capacidades_confirmadas_nao_coletadas', jsonb_build_array('documentos_exigidos', 'mensagens_chat', 'impugnacoes', 'esclarecimentos'),
      'capacidade_indisponivel', 'lotes/itens/lances/resultados atrás de reCAPTCHA v2 invisible — não contornado',
      'familia_tecnologia', 'mesma plataforma da BLL Compras (bllcompras.com)'
    ),
    obs = 'Conector real ativo desde 2026-09-04. Idempotência e persistência de checkpoint provadas com dado real em múltiplas execuções (ver relatório da sessão). Zero corrupção jsonb em centenas de linhas.',
    ultima_coleta_ok = now(),
    atualizado_em = now()
where source_id in ('SRC0005', 'SRC0051');

update bolsa.fontes_registro
set status = 'ativa',
    metodo = 'html',
    conector = 'coleta-bll',
    conector_versao = 'v1',
    autenticacao = 'nenhuma_para_capacidades_publicas',
    url = 'https://bllcompras.com/',
    freq_recomendada = '30min',
    discovery = jsonb_build_object(
      'testado_em', '2026-09-04',
      'resultado', 'ativo_producao',
      'plataforma_real', 'bllcompras.com (bll.org.br é o site institucional WordPress)',
      'familia_tecnologia', 'mesma plataforma da BNC (bnccompras.com) — HTML/rotas/modais idênticos, confirmado por discovery',
      'capacidades_coletadas', jsonb_build_array('listagem_publica', 'detalhe_processo', 'arquivos_com_download_direto'),
      'capacidades_confirmadas_nao_coletadas', jsonb_build_array('documentos_exigidos', 'mensagens_chat'),
      'capacidade_indisponivel', 'lotes/itens/lances/resultados atrás de reCAPTCHA v2 invisible — não contornado (herdado da mesma plataforma da BNC)'
    ),
    obs = 'Conector real ativo desde 2026-09-04, adaptado do conector BNC (mesma família de tecnologia). Idempotência e persistência de checkpoint provadas com dado real (100 processos reais, 2 execuções). Zero corrupção jsonb.',
    ultima_coleta_ok = now(),
    atualizado_em = now()
where source_id in ('SRC0003', 'SRC0049');
