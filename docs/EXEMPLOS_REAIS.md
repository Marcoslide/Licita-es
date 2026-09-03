# Exemplos reais preservados

Os exemplos abaixo foram obtidos das APIs públicas oficiais em 2026-09-02. Eles servem para reproduzir o mapeamento de campos sem confundir dados reais com os dados simulados do protótipo visual.

## Publicação PNCP

Consulta: `GET /api/consulta/v1/contratacoes/publicacao?dataInicial=20260901&dataFinal=20260901&codigoModalidadeContratacao=6&pagina=1&tamanhoPagina=10`.

```json
{
  "totalRegistros": 1568,
  "totalPaginas": 157,
  "numeroControlePNCP": "01612441000107-1-000131/2026",
  "modalidadeNome": "Pregão - Eletrônico",
  "valorTotalEstimado": 46150.0
}
```

O processo é do Município de Bela Vista da Caroba/PR e trata de licença de software de gestão para a Secretaria de Assistência Social.

## Contratação presente em PNCP e Compras.gov.br

```json
{
  "numeroControlePNCP": "01010446000160-1-000022/2025",
  "idCompra": "92682905900032025",
  "valorTotalEstimado": 189540.0,
  "valorTotalHomologado": 146000.0
}
```

O normalizador consolidou as duas origens pelo número de controle PNCP. O item 1 possui resultado homologado de R$ 146.000,00 para o fornecedor de CNPJ `29.580.650/0001-35`, CONEXAO SOLUCOES CORPORATIVAS LTDA.

## Contrato PNCP

```json
{
  "numeroControlePNCP": "13880257000127-2-000239/2026",
  "numeroContratoEmpenho": "219",
  "valorInicial": 28608.0,
  "valorGlobal": 28608.0
}
```

O payload real demonstrou que o campo vigente é `numeroControlePNCP`; o conector aceita também variantes antigas documentadas.

## Ata de registro de preços

```json
{
  "numeroControlePNCP": "95591764000105-1-000026/2025-000001",
  "numeroAtaRegistroPreco": "00024",
  "dataVigenciaInicio": "2025-03-11",
  "dataVigenciaFim": "2026-03-11"
}
```

## Plano de Contratações Anual

```json
{
  "cnpj": "00394460000141",
  "anoPca": 2022,
  "sequencialPca": 1,
  "numeroItem": 1,
  "descricao": "CESSÃO TEMPORÁRIA DE DIREITOS SOBRE PROGRAMAS DE COMPUTADOR LOCAÇÃO DE SOFTWARE",
  "valorTotal": 198000.0
}
```

Foram importados três itens desse PCA. Como a resposta de itens não traz o controle pronto, o normalizador deriva a chave estável `00394460000141-0-000001/2022:1` de CNPJ, ano, sequencial e item.

## Metadados de arquivo

```json
[
  {
    "titulo": "Edital Pregão 053/2026",
    "mime_detectado": "application/pdf",
    "tamanho": 2858586,
    "sha256": "b2d51f3668350adb771b73b9aa8ebfa20cab54aff47dc48b446b7e4f0103cd29"
  },
  {
    "titulo": "Parecer Juridico",
    "mime_detectado": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "tamanho": 8297,
    "sha256": "03e3d77bf6c7d488d415741459b8504f293fd37c7c53981c8b420462db708aa9"
  }
]
```

Os payloads completos continuam em `source_raw_records.payload_original`, com URL, parâmetros, status HTTP, timestamps, hash, versão e encadeamento da versão anterior.
