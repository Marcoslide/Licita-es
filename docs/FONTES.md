# Inventário inicial de fontes

Data da verificação: 2026-09-02. A ordem de integração é API oficial, arquivo oficial aberto, integração autorizada, exportação pública e, apenas em último caso, página pública permitida.

| Fonte | Oferta oficial encontrada | Acesso | Prioridade | Estado nesta entrega |
|---|---|---|---|---|
| PNCP | API REST pública, Swagger e manuais de consulta/integração | Sem autenticação para GETs consultados | P0 | Conector operante; detalhe, itens, resultados, documentos e histórico implementados |
| Compras.gov.br | API REST pública, Swagger, manual 2.0, CSV e OCDS | Sem autenticação nos módulos públicos | P0 | Conector de contratações implementado; catálogo completo gerado |
| Portal da Transparência | API REST para licitações, contratos, despesas, NF-e, CEIS, CNEP e CEPIM; planilhas para volume | Token por e-mail; 90 req/min 06:00–23:59 e 300 req/min 00:00–05:59 informados no portal | P1 | Fonte cadastrada como `CREDENCIAL_PENDENTE`; variável preparada |
| Banco de Preços em Saúde | Bases anuais compiladas em CSV desde 1997 e painel de preços | Arquivo público; cadastro apenas para registrar compras | P1 saúde | Fonte cadastrada; coletor CSV pendente do mapeamento de arquivos/colunas |
| CMED/Anvisa | Listas de preços de medicamentos em XLS/PDF, histórico e bases abertas da Anvisa | Arquivos públicos | P1 saúde | Inventário inicial; priorizar XLS oficial, não o painel |
| Dados abertos Anvisa | Arquivos abertos de medicamentos e dispositivos, conforme catálogo de dados | Arquivos públicos; API oficial não confirmada para todas as bases | P2 | DADO NÃO DISPONÍVEL NA FONTE CONSULTADA quanto a uma API única |
| Diário Oficial da União | Pesquisa e arquivos oficiais da Imprensa Nacional | Consulta pública; condições e formatos variam | P2 | Mapear API/arquivos antes de qualquer automação de página |
| Tribunais de Contas | Portais e dados abertos heterogêneos por tribunal | Variável | P2 | Inventário por tribunal pendente |
| Portais estaduais e municipais | APIs/arquivos heterogêneos e integrações já refletidas parcialmente no PNCP | Variável | P2/P3 | Priorizar lacunas comprovadas após medir cobertura PNCP |
| Plataformas privadas de licitação | Exportações públicas e integrações contratuais variam | Pode exigir contrato/login | P3 | Não acessar endpoints privados ou sessões autenticadas sem autorização |

## Portal da Transparência

Variável criada: `PORTAL_TRANSPARENCIA_API_TOKEN`. O conector autenticado não foi testado porque nenhuma credencial foi fornecida, e nenhuma foi inventada. A documentação pública informa consultas a CEIS, CNEP, CEPIM, contratos, licitações, despesas e notas fiscais, entre outras. Para cargas integrais, o próprio portal recomenda planilhas de dados abertos.

## Banco de Preços em Saúde

A fonte oficial confirma bases anuais compiladas em CSV para compras registradas por estados e municípios, dados desde 1997 e consulta pelo Painel de Preços em Saúde. A próxima implementação deve descobrir os links estáveis dos CSVs e validar o dicionário do painel antes de modelar CATMAT, quantidade, órgão, fornecedor, preço praticado e preço regulado.

## Separação de identificadores

- CNPJ do órgão comprador: identidade de `organizations` e filtro `cnpj`/`orgaoEntidadeCnpj`.
- Identificação do fornecedor: `niFornecedor`/CNPJ-CPF de `suppliers`.
- CNPJ do cliente da Bolsa: fora do escopo desta coleta pública e não usado pelos conectores.
