# Dicionário inicial dos campos observados

Os nomes de origem abaixo foram observados em respostas reais em 02/09/2026. O payload integral permanece em `source_raw_records.payload_original`; esta tabela descreve apenas a projeção normalizada inicial.

| Entidade | Campo normalizado | PNCP | Compras.gov | Observação |
|---|---|---|---|---|
| Contratação | `pncp_control_number` | `numeroControlePNCP` | `numeroControlePNCP` | Chave de consolidação entre fontes |
| Contratação | `year` / `sequence` | `anoCompra` / `sequencialCompra` | `anoCompraPncp` / `sequencialCompraPncp` | Não confundir sequência com número da compra |
| Contratação | `object` | `objetoCompra` | `objetoCompra` | Texto original preservado no bruto |
| Contratação | `estimated_value` | `valorTotalEstimado` | `valorTotalEstimado` | Pode ser zero quando orçamento é sigiloso |
| Contratação | `homologated_value` | `valorTotalHomologado` | `valorTotalHomologado` | Pode ser nulo antes do resultado |
| Órgão | `tax_id` | `orgaoEntidade.cnpj` | `orgaoEntidadeCnpj` | CNPJ do comprador, não do fornecedor/cliente |
| Unidade | `code` | `unidadeOrgao.codigoUnidade` | `unidadeOrgaoCodigoUnidade` | UASG ou código da unidade da fonte |
| Localidade | UF/IBGE | `unidadeOrgao.ufSigla` / `codigoIbge` | `unidadeOrgaoUfSigla` / `unidadeOrgaoCodigoIbge` | Dimensões normalizadas |
| Item | `item_number` | `numeroItem` | `numeroItem`/`numeroItemCompra` | Único dentro da contratação |
| Item | valores | `valorUnitarioEstimado`, `valorTotal`, `quantidade` | campos equivalentes | Precisão original permanece no JSON bruto |
| Resultado | sequência | `sequencialResultado` | `sequencialResultado` | Único dentro do item |
| Resultado | fornecedor | `niFornecedor`, `nomeRazaoSocialFornecedor` | `niFornecedor` e razão social | `niFornecedor` pode exigir tratamento por tipo de pessoa |
| Resultado | valores | `valorUnitarioHomologado`, `valorTotalHomologado`, `quantidadeHomologada` | campos equivalentes | Alimenta preços praticados |
| Ata | controle | `numeroControlePNCP` | `numeroControlePncpAta` em módulos ARP | Sufixo da ata vincula ao controle da compra |
| Contrato | controle | `numeroControlePNCP` (resposta real) | identificador do módulo contrato | O exemplo genérico sugeria variante; migration 002 reparou o mapeamento |
| Documento | identidade | CNPJ + ano + compra + `sequencialDocumento` | DADO NÃO DISPONÍVEL NA FONTE CONSULTADA | URL pode responder MIME genérico; hash do binário é autoritativo |
| PCA | controle | derivado de CNPJ, `sequencialPca`, `anoPca` | PGC usa identificação própria | Formato oficial `CNPJ-0-NNNNNN/AAAA` |

## Paginação

- PNCP: `data`, `totalRegistros`, `totalPaginas`, `numeroPagina`, `paginasRestantes`, `empty`.
- Compras.gov: `resultado`, `totalRegistros`, `totalPaginas`, `paginasRestantes`; `pagina` é enviada na requisição.
- PNCP publicação/proposta: `tamanhoPagina` 10–50; demais agregados PNCP em geral 10–500; instrumento de cobrança 10–100.
- Compras.gov: máximo documentado de 500 por página nos módulos principais.
