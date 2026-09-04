-- PARTE H — resolução real de URLs oficiais das 63 fontes P0 sem URL
-- (9 nomeadas + 54 placeholders estado/capital), via pesquisa paralela
-- (4 agentes regionais, WebSearch cruzado, nenhuma URL inventada — cada
-- linha abaixo tem fonte de confirmação registrada no discovery jsonb
-- resumido em 'confianca'/'obs'). Nenhuma tentativa de acesso privilegiado.
--
-- Achados estruturais importantes:
--  - Vários municípios/estados NÃO têm sistema técnico distinto: rodam a
--    sessão de pregão no Compras.gov.br federal (SRC0001) e/ou publicam só
--    no PNCP. Marcados 'descontinuada' com obs explicando — não é uma
--    fonte técnica que deixou de existir, é uma que nunca existiu separada.
--  - Porto Alegre (RS) e Palmas (TO) confirmaram usar o Portal de Compras
--    Públicas — a MESMA fonte SRC0007 já mapeada na Wave 1, aguardando a
--    publicKey. Eleva a prioridade dela.
--  - Cuiabá (MT) confirma sessões via BLL Compras — fonte JÁ ATIVA
--    (SRC0003/SRC0049) no nosso sistema.
--  - ES: SIGA foi descontinuado e substituído por SIADES em jan/2025
--    (SRC0017 vira duplicata de SRC0044, que é atualizado).
update bolsa.fontes_registro t set
  status = v.status,
  url = coalesce(v.url, t.url),
  obs = v.obs,
  atualizado_em = now()
from (values
  -- nomeadas
  ('SRC0011','descoberta','https://compras.m2atecnologia.com.br/','M2A Compras confirmado (M2A Tecnologia), citado em editais municipais do CE. Confiança alta.'),
  ('SRC0012','descoberta','https://ammlicita.org.br/','AMM Licita confirmado — plataforma da Associação Mineira de Municípios (MG, 853 municípios). Confiança alta.'),
  ('SRC0013','descoberta','https://licitamaisbrasil.com.br/','LicitaMais Brasil confirmado (Licita Mais Brasil Ltda, SP), citado em edital municipal SC. ATENÇÃO: existe empresa de nome parecido "Licit Mais Brasil" (licitmaisbrasil.com.br, Goiânia) — NÃO confundir, são entidades diferentes.'),
  ('SRC0016','descontinuada','https://e-lic.sc.gov.br/','DUPLICATA: mesmo sistema de SRC0650 (Governo de SC), que fica com o registro principal.'),
  ('SRC0017','descontinuada','https://compras.es.gov.br/','DUPLICATA/SUCESSÃO: SIADES é o nome atual do sistema já cadastrado em SRC0044 — substituiu o antigo SIGA-ES em jan/2025 (comunicado oficial). SRC0044 foi atualizado para refletir o nome atual.'),
  ('SRC0018','descontinuada','https://www.compras.rj.gov.br/','DUPLICATA: mesmo sistema de SRC0550 (Governo do RJ), que fica com o registro principal.'),
  ('SRC0019','descontinuada','https://aquisicoes.seplag.mt.gov.br/','DUPLICATA: mesmo sistema de SRC0390 (Governo de MT), que fica com o registro principal.'),
  ('SRC0021','descontinuada','https://www.e-compras.am.gov.br/publico/','DUPLICATA: mesmo sistema de SRC0250 (Governo do AM), que fica com o registro principal.'),
  ('SRC0022','descontinuada','https://sislog.go.gov.br/','DUPLICATA: mesmo sistema de SRC0350 (Governo de GO), que fica com o registro principal.'),
  -- Norte
  ('SRC0190','descoberta','https://licitacao.ac.gov.br/','Portal de Licitações do Acre confirmado. Confiança alta (decretos/notícias oficiais).'),
  ('SRC0200','descontinuada',null,'Rio Branco: sem sistema técnico distinto confirmado. Iniciativa própria "Compra Mais Rio Branco" anunciada mas NÃO disponível publicamente ainda (declaração oficial da própria prefeitura). Usa ComprasNet federal (UASG 980139) — coberto por SRC0001.'),
  ('SRC0230','descoberta','https://compras.portal.ap.gov.br/','CLC — Central de Licitações e Contratos do Amapá confirmada. Confiança alta.'),
  ('SRC0240','descontinuada',null,'Macapá: sem sistema técnico distinto identificado. Publica via Portal da Transparência municipal, PNCP como referência central.'),
  ('SRC0250','descoberta','https://www.e-compras.am.gov.br/publico/','e-Compras Amazonas confirmado (Decreto 47.133/2023). Confiança alta.'),
  ('SRC0260','descoberta','https://compras.manaus.am.gov.br/','Compras Manaus confirmado (notícia oficial da prefeitura). Confiança alta.'),
  ('SRC0450','descoberta','https://www.compraspara.pa.gov.br/','ComprasPará confirmado (Decreto Estadual 2.313/2018). Confiança alta.'),
  ('SRC0460','descoberta','https://pgm.belem.pa.gov.br/portal-de-licitacoes/','Portal de Licitações de Belém (PGM) confirmado, mas não está claro se tem motor de disputa transacional ou é só repositório de editais. Confiança média.'),
  ('SRC0610','descontinuada',null,'Rondônia: sem sistema técnico distinto — SUPEL usa Compras Governamentais/ComprasNet federal (Decreto Estadual 28.874/2024). Coberto por SRC0001.'),
  ('SRC0620','descontinuada',null,'Porto Velho: não confirmado sistema próprio distinto. compras.portovelho.ro.gov.br funciona como Portal de Transparência, não motor de pregão.'),
  ('SRC0630','descontinuada',null,'Roraima: sem sistema técnico distinto — SELC é secretaria institucional, pregões via ComprasNet federal, fornecedores no SICAF. Coberto por SRC0001.'),
  ('SRC0640','descontinuada',null,'Boa Vista: não confirmado sistema próprio distinto. Editais no Diário Oficial do Município; pregões via ComprasNet federal.'),
  ('SRC0710','descoberta','https://portaldecompras.to.gov.br/','Portal de Compras do Tocantins confirmado (parte do sistema SIGA-TO, Decreto 6.084/2020). Confiança alta.'),
  ('SRC0720','descoberta','https://www.portaldecompraspublicas.com.br/','Palmas confirma uso do Portal de Compras Públicas — MESMA fonte de SRC0007 (aguardando publicKey). Historicamente também usou CidadeCompras (uso mais antigo, 2013-2015). Confiança média sobre qual está vigente hoje.'),
  -- Nordeste
  ('SRC0210','descontinuada',null,'Alagoas: sem sistema técnico distinto — AMGESP realiza pregões mas sessão pública roda no Compras.gov.br federal. AlCompras (alcompras.itec.al.gov.br) é só cadastro de fornecedores. Coberto por SRC0001.'),
  ('SRC0220','descoberta','https://licitacao.maceio.al.gov.br/','Portal de Licitações da ALICC (Maceió) confirmado. Confiança alta.'),
  ('SRC0270','descoberta','https://comprasnet.ba.gov.br/','Comprasnet.BA confirmado (notícia oficial SAEB). Confiança alta.'),
  ('SRC0280','descoberta','https://compras.salvador.ba.gov.br/','Compras Salvador confirmado (subdomínio oficial da prefeitura). Confiança alta.'),
  ('SRC0290','descoberta','https://portalcompras.ce.gov.br/','Portal Compras CE confirmado (plataforma S2GPR/SEPLAG-CE). Confiança alta.'),
  ('SRC0300','descoberta','https://compras.sepog.fortaleza.ce.gov.br/','Portal Compras Fortaleza confirmado (Decreto Municipal 15.595/2023). Confiança alta.'),
  ('SRC0370','descoberta','https://compras.ma.gov.br/','Portal de Compras Governamentais do Maranhão confirmado (Decreto 36.160/2020, sistema SIGA-MA — nome genérico reutilizado por vários estados, não confundir com SIGA-RJ/antigo SIGA-ES). Confiança alta.'),
  ('SRC0380','descontinuada',null,'São Luís: sem sistema técnico distinto confirmado. Usa ComprasNet federal (UASG 980921); saoluis.ma.gov.br/portal/editais é só avisos institucionais.'),
  ('SRC0470','descoberta','https://centraldecompras.pb.gov.br/','Central de Compras da Paraíba confirmada (notícia oficial do governo). Confiança alta.'),
  ('SRC0480','descontinuada',null,'João Pessoa: sem sistema técnico distinto confirmado com alta confiança. Usa ComprasNet federal (UASG 982051); seadlicitacao.joaopessoa.pb.gov.br existe mas evidência mais forte aponta para o federal.'),
  ('SRC0520','descoberta','https://portaldecompras.recife.pe.gov.br/','Portal de Compras do Recife confirmado (site oficial da prefeitura). Confiança alta.'),
  ('SRC0530','descoberta','https://centraldecompras.sead.pi.gov.br/','Central de Compras do Piauí confirmada (Decretos Estaduais 23.865/2025 e 23.910/2025). Confiança alta.'),
  ('SRC0540','descontinuada',null,'Teresina: sem sistema técnico distinto confirmado. Usa ComprasNet federal (UASG 981219); pmt.pi.gov.br/licitacoes é só avisos institucionais.'),
  ('SRC0570','descoberta','https://compras.rn.gov.br/','Central de Compras SEAD-RN — confiança média (uma variante do domínio respondeu genérico nginx, recomendo validar antes de configurar coleta em produção).'),
  ('SRC0580','descoberta','https://compras.natal.rn.gov.br/','Natal: dois domínios oficiais coexistem (compras.natal.rn.gov.br geral + centraldecompras.natal.rn.gov.br corporativo) — confiança média-alta, relação entre os dois não totalmente clara.'),
  ('SRC0690','descoberta','https://comprasnet.se.gov.br/','ComprasNet.SE confirmado (institucional comprasnet.se.gov.br, sistema transacional em sistema.comprasnet.se.gov.br). Confiança alta.'),
  ('SRC0700','descoberta','https://aracajucompras.se.gov.br/','Aracaju Compras confirmado (notícias oficiais da prefeitura). Confiança alta.'),
  -- Centro-Oeste + Sul
  ('SRC0310','descoberta','https://portal.compras.df.gov.br/','ComprasDF confirmado (Decreto 37.729/2016). Confiança alta.'),
  ('SRC0320','descontinuada','https://portal.compras.df.gov.br/','DUPLICATA: Distrito Federal não tem prefeitura de capital separada — mesma entidade de SRC0310.'),
  ('SRC0340','descoberta','https://portaldecompras.vitoria.es.gov.br/','Portal de Compras de Vitória confirmado (página oficial da prefeitura). Confiança alta.'),
  ('SRC0350','descoberta','https://sislog.go.gov.br/','SISLOG (Goiás) confirmado — substituiu o antigo ComprasNet.GO (notícia oficial SEINFRA/Seplag-GO). Confiança alta.'),
  ('SRC0360','descontinuada',null,'Goiânia: sem sistema técnico distinto — usa Compras.gov.br federal desde 2022 (nota oficial: primeira cidade do país a fazer pregão pela nova Lei via Compras.gov.br). Coberto por SRC0001. Confiança média (reconfirmar periodicamente).'),
  ('SRC0390','descoberta','https://aquisicoes.seplag.mt.gov.br/','SIAG/SEPLAG-MT confirmado (domínio oficial da secretaria). Confiança alta.'),
  ('SRC0400','descoberta','http://licitacao.cuiaba.mt.gov.br/licitacao/','Cuiabá: híbrido — portal próprio só publica editais em PDF; sessões de pregão eletrônico rodam na BLL Compras (bll.org.br) — fonte JÁ ATIVA no nosso sistema (SRC0003/SRC0049). Confirmado em editais oficiais 2025/2026 da PMC.'),
  ('SRC0410','descoberta','https://www.compras.ms.gov.br/','Compras MS confirmado (domínios oficiais SAD-MS). Confiança alta.'),
  ('SRC0420','descoberta','http://compras.campogrande.ms.gov.br/sgc/','SIGA/SGC de Campo Grande confirmado (notícias oficiais da prefeitura). Confiança alta.'),
  ('SRC0440','descontinuada',null,'Belo Horizonte: NÃO existe "BH Compras" ou sistema técnico distinto próprio. Usa Compras.gov.br federal + PNCP + listagem institucional própria (prefeitura.pbh.gov.br/licitacoes). Coberto por SRC0001.'),
  ('SRC0490','descoberta','https://www.comprasparana.pr.gov.br/','Compras Paraná confirmado (portal público sobre sistema GMS, gms.pr.gov.br). Confiança alta.'),
  ('SRC0600','descoberta','https://www.portaldecompraspublicas.com.br/','Porto Alegre confirma uso do Portal de Compras Públicas desde 2016 — MESMA fonte de SRC0007 (aguardando publicKey). Documento oficial hospedado em prefeitura.poa.br. Confiança alta.'),
  ('SRC0650','descoberta','https://e-lic.sc.gov.br/','e-LIC Santa Catarina confirmado ATIVO, com sessões de pregão real indexadas (CIASC/Secretaria de Administração). Confiança alta — candidata forte para Wave 2.'),
  ('SRC0680','descoberta','https://compras.prefeitura.sp.gov.br/','São Paulo: sistema múltiplo — portal geral (compras.prefeitura.sp.gov.br) + Painel de Negócios Públicos (epubli.prefeitura.sp.gov.br, substituiu e-negocioscidadesp em 2023) + uso do Licitações-e/BB para sessões de alguns órgãos. Confiança alta na existência, média sobre qual URL é "a" oficial única.')
) as v(source_id, status, url, obs)
where t.source_id = v.source_id;

-- ES (SRC0044): atualiza nome/obs para refletir a sucessão SIGA→SIADES
update bolsa.fontes_registro
set obs = obs || ' ATUALIZAÇÃO: o sistema foi renomeado de SIGA para SIADES em jan/2025 (comunicado oficial). SRC0017 (SIADES) é duplicata desta linha.',
    atualizado_em = now()
where source_id = 'SRC0044';
