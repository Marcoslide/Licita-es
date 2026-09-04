-- PARTE H — dedupe dos placeholders genéricos de estado/capital contra
-- fontes já conhecidas com URL própria (7 casos identificados por nome/UF
-- sem precisar de busca nova). Não são fontes técnicas distintas — o
-- placeholder do seed de 765 e a fonte já cadastrada são o mesmo sistema
-- real. Copia a URL para transparência e marca como duplicata.
update bolsa.fontes_registro set
  url = (select url from bolsa.fontes_registro where source_id = 'SRC0015'),
  status = 'descontinuada',
  obs = 'DUPLICATA: mesmo sistema de SRC0015 (Compras RS / Compras Eletrônicas RS). Placeholder do seed de 765 fontes, não é uma fonte técnica distinta.',
  atualizado_em = now()
where source_id = 'SRC0590';

update bolsa.fontes_registro set
  url = (select url from bolsa.fontes_registro where source_id = 'SRC0020'),
  status = 'descontinuada',
  obs = 'DUPLICATA: mesmo sistema de SRC0020 (Compras MG). Placeholder do seed de 765 fontes, não é uma fonte técnica distinta.',
  atualizado_em = now()
where source_id = 'SRC0430';

update bolsa.fontes_registro set
  url = (select url from bolsa.fontes_registro where source_id = 'SRC0044'),
  status = 'descontinuada',
  obs = 'DUPLICATA: mesmo sistema de SRC0044 (Compras ES / SIGA). Placeholder do seed de 765 fontes, não é uma fonte técnica distinta.',
  atualizado_em = now()
where source_id = 'SRC0330';

update bolsa.fontes_registro set
  url = (select url from bolsa.fontes_registro where source_id = 'SRC0010'),
  status = 'descontinuada',
  obs = 'DUPLICATA: mesmo sistema de SRC0010 (PE Integrado). Placeholder do seed de 765 fontes, não é uma fonte técnica distinta.',
  atualizado_em = now()
where source_id = 'SRC0510';

update bolsa.fontes_registro set
  url = (select url from bolsa.fontes_registro where source_id = 'SRC0035'),
  status = 'descontinuada',
  obs = 'DUPLICATA: mesmo sistema de SRC0035 (BEC-SP, trilha histórica paralela deferida). Placeholder do seed de 765 fontes, não é uma fonte técnica distinta.',
  atualizado_em = now()
where source_id = 'SRC0670';

update bolsa.fontes_registro set
  url = (select url from bolsa.fontes_registro where source_id = 'SRC0037'),
  status = 'descontinuada',
  obs = 'DUPLICATA: mesmo sistema de SRC0037 (Prefeitura de Florianópolis - Licitações). Placeholder do seed de 765 fontes, não é uma fonte técnica distinta.',
  atualizado_em = now()
where source_id = 'SRC0660';

update bolsa.fontes_registro set
  url = (select url from bolsa.fontes_registro where source_id = 'SRC0043'),
  status = 'descontinuada',
  obs = 'DUPLICATA: mesmo sistema de SRC0043 (e-Compras Curitiba). Placeholder do seed de 765 fontes, não é uma fonte técnica distinta.',
  atualizado_em = now()
where source_id = 'SRC0500';
