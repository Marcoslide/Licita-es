# Catálogo de endpoints — API PNCP CONSULTA

Gerado do contrato OpenAPI oficial (`3.0.1`, versão `1.0`).

Todos os endpoints abaixo são apenas catalogados. O coletor usa somente operações GET públicas; rotas de autenticação, usuários e módulos restritos não são chamadas.

| Método | Endpoint | Finalidade | Parâmetros | HTTP |
|---|---|---|---|---|
| GET | `/v1/atas` | Consultar Ata de Registro de Preço por Período de Vigência | `dataInicial`*:string; `dataFinal`*:string; `idUsuario`:integer; `cnpj`:string; `codigoUnidadeAdministrativa`:string; `pagina`*:integer [1..]; `tamanhoPagina`:integer [10..500] | `400`, `422`, `204`, `500`, `401`, `200` |
| GET | `/v1/atas/atualizacao` | Consultar Atas de Registro de Preço por Data de Atualização Global | `dataInicial`*:string; `dataFinal`*:string; `idUsuario`:integer; `cnpj`:string; `codigoUnidadeAdministrativa`:string; `pagina`*:integer [1..]; `tamanhoPagina`:integer [10..500] | `400`, `422`, `204`, `500`, `401`, `200` |
| GET | `/v1/contratacoes/atualizacao` | Consultar Contratações por Data de Atualização Global | `dataInicial`*:string; `dataFinal`*:string; `codigoModalidadeContratacao`*:integer; `codigoModoDisputa`:integer; `uf`:string; `codigoMunicipioIbge`:string; `cnpj`:string; `codigoUnidadeAdministrativa`:string; `idUsuario`:integer; `pagina`*:integer [1..]; `tamanhoPagina`:integer [10..50] | `400`, `422`, `204`, `500`, `401`, `200` |
| GET | `/v1/contratacoes/proposta` | Consultar Contratações com Recebimento de Propostas Aberto | `dataFinal`*:string; `codigoModalidadeContratacao`:integer; `uf`:string; `codigoMunicipioIbge`:string; `cnpj`:string; `codigoUnidadeAdministrativa`:string; `idUsuario`:integer; `pagina`*:integer [1..]; `tamanhoPagina`:integer [10..50] | `400`, `422`, `204`, `500`, `401`, `200` |
| GET | `/v1/contratacoes/publicacao` | Consultar Contratações por Data de Publicação | `dataInicial`*:string; `dataFinal`*:string; `codigoModalidadeContratacao`*:integer; `codigoModoDisputa`:integer; `uf`:string; `codigoMunicipioIbge`:string; `cnpj`:string; `codigoUnidadeAdministrativa`:string; `idUsuario`:integer; `pagina`*:integer [1..]; `tamanhoPagina`:integer [10..50] | `400`, `422`, `204`, `500`, `401`, `200` |
| GET | `/v1/contratos` | Consultar Contratos por Data de Publicação | `dataInicial`*:string; `dataFinal`*:string; `cnpjOrgao`:string; `codigoUnidadeAdministrativa`:string; `usuarioId`:integer; `pagina`*:integer [1..]; `tamanhoPagina`:integer [10..500] | `400`, `422`, `204`, `500`, `401`, `200` |
| GET | `/v1/contratos/atualizacao` | Consultar Contratos/Empenhos por Data de Atualização Global | `dataInicial`*:string; `dataFinal`*:string; `cnpjOrgao`:string; `codigoUnidadeAdministrativa`:string; `usuarioId`:integer; `pagina`*:integer [1..]; `tamanhoPagina`:integer [10..500] | `400`, `422`, `204`, `500`, `401`, `200` |
| GET | `/v1/instrumentoscobranca/inclusao` | Consultar Instrumentos de Cobrança por Data de Inclusão | `dataInicial`*:string; `dataFinal`*:string; `tipoInstrumentoCobranca`:integer; `cnpjOrgao`:string; `pagina`*:integer [1..]; `tamanhoPagina`:integer [10..100] | `400`, `422`, `204`, `500`, `401`, `200` |
| GET | `/v1/orgaos/{cnpj}/compras/{ano}/{sequencial}` | Consultar Contratação | `cnpj`*:string; `ano`*:integer; `sequencial`*:integer [1..] | `400`, `422`, `204`, `500`, `401`, `200` |
| GET | `/v1/pca/` | Consultar Itens de PCA por Ano do PCA e Código de Classificação Superior | `anoPca`*:integer; `codigoClassificacaoSuperior`*:string; `pagina`*:integer [1..]; `tamanhoPagina`:integer [10..500] | `400`, `422`, `204`, `500`, `401`, `200` |
| GET | `/v1/pca/atualizacao` | Consultar PCA por Data de Atualização Global | `dataInicio`*:string; `dataFim`*:string; `cnpj`:string; `codigoUnidade`:string; `pagina`*:integer [1..]; `tamanhoPagina`:integer [10..500] | `400`, `422`, `204`, `500`, `401`, `200` |
| GET | `/v1/pca/usuario` | Consultar Itens de PCA por Ano do PCA, IdUsuario e Código de Classificação Superior | `anoPca`*:integer; `idUsuario`*:integer; `codigoClassificacaoSuperior`:string; `cnpj`:string; `pagina`*:integer [1..]; `tamanhoPagina`:integer [10..500] | `400`, `422`, `204`, `500`, `401`, `200` |

`*` = obrigatório. Os limites exibidos vêm do schema OpenAPI, quando publicados.

## Consultas detalhadas do Manual de Integração 2.6

Estas operações GET não aparecem no Swagger da API agregada de consulta, mas estão publicadas no manual oficial de integração e foram consideradas no desenho do coletor. A base histórica é `https://pncp.gov.br/api/pncp`; em 02/09/2026, o detalhe de contratação nessa base respondeu `301` informando migração para `https://pncp.gov.br/api/consulta`, enquanto itens, arquivos e histórico continuaram respondendo somente na base histórica.

| Entidade | Endpoint GET | Parâmetros/paginação | Implementado/testado |
|---|---|---|---|
| Contratação | `/v1/orgaos/{cnpj}/compras/{ano}/{sequencial}` | path obrigatório | Sim / 200 na base `api/consulta` |
| Documentos da contratação | `/v1/orgaos/{cnpj}/compras/{ano}/{sequencial}/arquivos` | path obrigatório | Sim / 200 |
| Download de documento | `/v1/orgaos/{cnpj}/compras/{ano}/{sequencial}/arquivos/{sequencialDocumento}` | path obrigatório | Sim no serviço de objetos |
| Itens | `/v1/orgaos/{cnpj}/compras/{ano}/{sequencial}/itens` | `pagina`, `tamanhoPagina` | Sim / 200 |
| Item | `/v1/orgaos/{cnpj}/compras/{ano}/{sequencial}/itens/{numeroItem}` | path obrigatório | Catalogado |
| Resultados do item | `/v1/orgaos/{cnpj}/compras/{ano}/{sequencial}/itens/{numeroItem}/resultados` | path obrigatório | Sim, quando `temResultado=true` |
| Resultado específico | `/v1/orgaos/{cnpj}/compras/{ano}/{sequencial}/itens/{numeroItem}/resultados/{sequencialResultado}` | path obrigatório | Catalogado |
| Histórico | `/v1/orgaos/{cnpj}/compras/{ano}/{sequencial}/historico` | `pagina`, `tamanhoPagina` | Sim / 200 |
| Imagem de item | `/v1/orgaos/{cnpj}/compras/{ano}/{sequencial}/itens/{numeroItem}/imagem/{sequencialImagem}` | path obrigatório | Catalogado; amostra pendente |
| Atas da contratação | `/v1/orgaos/{cnpj}/compras/{anoCompra}/{sequencialCompra}/atas` | path obrigatório | Catalogado |
| Detalhe da ata | `/v1/orgaos/{cnpj}/compras/{anoCompra}/{sequencialCompra}/atas/{sequencialAta}` | path obrigatório | Catalogado |
| Documentos da ata | `/v1/orgaos/{cnpj}/compras/{anoCompra}/{sequencialCompra}/atas/{sequencialAta}/arquivos` | path obrigatório | Catalogado |
| Histórico da ata | `/v1/orgaos/{cnpj}/compras/{ano}/{sequencial}/atas/{sequencialAta}/historico` | path obrigatório | Catalogado |
| Contratos vinculados à ata | `/v1/orgaos/{cnpj}/compras/{ano}/{sequencial}/atas/{sequencialAta}/contratos` | `pagina`, `tamanhoPagina` | Catalogado |
| Contrato/empenho | `/v1/orgaos/{cnpj}/contratos/{ano}/{sequencial}` | path obrigatório | Catalogado |
| Contratos de uma contratação | `/v1/orgaos/{cnpj}/contratos/contratacao/{anoContratacao}/{sequencialContratacao}` | path obrigatório | Catalogado |
| Documentos do contrato | `/v1/orgaos/{cnpj}/contratos/{ano}/{sequencial}/arquivos` | path obrigatório | Catalogado |
| Histórico do contrato | `/v1/orgaos/{cnpj}/contratos/{ano}/{sequencial}/historico` | path obrigatório | Catalogado |
| Instrumento de cobrança | `/v1/orgaos/{cnpj}/contratos/{ano}/{sequencialContrato}/instrumentocobranca/{sequencialInstrumentoCobranca}` | path obrigatório | Catalogado |

Todas são consultas públicas GET. As operações de inclusão, retificação, exclusão, proposta, lance ou participação são deliberadamente excluídas.
