-- PARTE J — pesquisa de alternativa oficial/legítima para as 4 fontes
-- bloqueadas da Wave 1. Só pesquisa pública (WebSearch), nenhuma tentativa
-- de contato comercial nem preenchimento de formulário — mesma régua da
-- Portal de Compras Públicas (achar a porta, não abrir).
update bolsa.fontes_registro
set status = 'pronta_para_dev',
    obs = obs || ' ATUALIZAÇÃO PARTE J: encontrado formulário oficial de solicitação de "Manual de Integração" (bbmnet.com.br/cadastro-formulario-de-acesso-manual-de-integracao/), citando integração oficial com PNCP/TransfereGov. Caminho legítimo análogo ao da Portal de Compras Públicas (SRC0007) — não preenchido, não contatado. Se obtido acesso, permite reavaliar sem contornar o Keycloak.',
    atualizado_em = now()
where source_id in ('SRC0009','SRC0050','SRC0089');

update bolsa.fontes_registro
set obs = obs || ' ATUALIZAÇÃO PARTE J: nenhuma API pública/dados abertos oficiais encontrados para a Licitanet especificamente. Processos de entidades sob Lei 14.133 já devem estar no PNCP (overlap parcial via conector PNCP existente); processos de entidades sob regime próprio (RLC) não têm alternativa legítima identificada.',
    atualizado_em = now()
where source_id in ('SRC0002','SRC0054');

update bolsa.fontes_registro
set obs = obs || ' ATUALIZAÇÃO PARTE J: Licitar Digital divulga publicamente ter "APIs RESTful" para integração com sistemas de gestão pública, mas sem documentação técnica pública (endpoints/auth) localizada — só manual do fornecedor (uso da interface, não API). Precisaria contato comercial direto para confirmar; não contatado.',
    atualizado_em = now()
where source_id in ('SRC0004','SRC0055');

update bolsa.fontes_registro
set obs = obs || ' ATUALIZAÇÃO PARTE J: nenhuma API pública/dados abertos oficiais encontrados para comprasbr.com.br (plataforma HAL) especificamente. ATENÇÃO a uma armadilha de nome: existe também "Compras BR" como um dos 7 sistemas integrados à Plataforma +Brasil federal (transferegov) — é uma coisa DIFERENTE (não é o comprasbr.com.br testado na Wave 1). Não confundir os dois em fontes futuras.',
    atualizado_em = now()
where source_id = 'SRC0008';
