# Relatório de entrega — Motor de Busca Híbrido

Data: 03/09/2026  
Branch: `codex/modern-dashboard-ui`

## Resultado executivo

A Bolsa deixou de executar apenas uma busca literal sobre a lista de processos. O sistema publicado agora possui um motor central de consulta que compila a intenção do usuário, aplica filtros estruturados, procura no objeto e nos itens, calcula relevância de 0 a 100, explica o motivo de cada correspondência e entrega o mesmo conjunto filtrado para KPIs, mapa, rankings, listas, preços, contratos e PCA.

O ambiente produtivo continua usando o Supabase como base canônica e a API da VPS como gateway somente de leitura. O scheduler de coleta permaneceu ativo durante toda a publicação.

## Antes × depois

| Tema | Antes | Depois |
| --- | --- | --- |
| Consulta | `ilike` literal e agrupamentos pequenos | Compilador único de consulta com termos, frases, inclusões, exclusões e filtros |
| Campos | Predominância do objeto da licitação | Objeto, itens, órgão, unidade, cidade, UF, modalidade, status, fornecedor e catálogo |
| Português | Correspondência textual simples | Acentos, caixa, pontuação, abreviações, plural, variações morfológicas e erros de digitação controlados |
| Sinônimos | Listas fixas na interface | Taxonomia aprovada com origem, confiança e versão |
| Relevância | Ordenação sem explicação | Score 0–100, pesos por campo, cobertura de conceitos, penalidade de ruído e motivo visível |
| Especificação | Sem tratamento sistemático | Extração de massa, volume, potência e tensão; aviso e penalidade para especificação divergente |
| Modos | Uma busca | Precisa, inteligente, ampla e frase exata |
| Escopo analítico | Componentes podiam divergir | Um `ActiveMarketScope` compartilhado por todos os componentes |
| Navegação | Resultado isolado | Facetas, drill-down geográfico, chips removíveis, breadcrumb, URL compartilhável e visões salvas |
| Desempenho | Reconsultava e recalculava cada ordenação | Cache do corpus, índice de órgãos, contagens e ranking por escopo |
| Qualidade | Sem métricas formais | `precision@k`, `NDCG@k`, golden set, eventos anônimos e endpoint administrativo protegido |

## Capacidades entregues

- Busca híbrida determinística com sinais lexicais, fuzzy, taxonomia, catálogo e filtros estruturados.
- Busca consolidada no nível do processo: um processo aparece uma vez, acompanhado dos itens que justificaram a correspondência.
- Operadores visuais para deve conter, pode conter, excluir, frase exata e inclusão de documentos.
- Interpretação de linguagem natural para produto/serviço, UF, cidades conhecidas, período, modalidade, status, valor mínimo, abertura nos próximos dias, frase entre aspas e exclusão explícita.
- Conversa contextual: perguntas subsequentes preservam o escopo existente.
- Autocomplete com debounce e cancelamento de requisições antigas.
- Correção sugerida sem trocar silenciosamente a intenção do usuário.
- Facetas e totais calculados sobre o conjunto efetivamente encontrado.
- Estado vazio correto: os indicadores anteriores não permanecem na tela quando a consulta retorna zero.
- Feedback de relevância armazenado por dispositivo, sem alterar o ranking global de outros usuários.
- APIs administrativas de diagnóstico e qualidade protegidas por token.
- Migrações para logs, feedback, golden set, sinônimos e documentos de busca.

## Evidências na base real

Consultas feitas diretamente na API publicada em 03/09/2026:

| Consulta | Resultado observado |
| --- | --- |
| `material hospitalar`, modo inteligente | 48 processos, R$ 101.110.261,98 no escopo; soma das facetas estaduais igual a 48; três primeiros scores iguais a 100; os dois primeiros foram justificados por 23 e 9 itens correspondentes |
| `medicamentos` + UF `MG`, modo preciso | 1 processo; todos os resultados e a única faceta pertencem a MG |
| `caderia escolar`, modo inteligente | 0 processos reais; sugestão `cadeira escolar` com confiança de 85,7%; nenhum processo escolar genérico foi apresentado como cadeira |
| `ceftriaxona 1g`, modo inteligente | 0 processos na coleta atualmente disponível; a interface limpa os indicadores e informa ausência de resultado, sem fabricar dado |

A primeira consulta fria por `material hospitalar`, incluindo todas as facetas, levou 3,36 s no teste de publicação. As ordenações subsequentes do mesmo escopo levaram 3 ms e 5 ms. O cache expira rapidamente para manter os dados atuais.

## Validação técnica

- 37 testes automatizados aprovados; 1 teste de integração externa permanece opt-in.
- Sintaxe JavaScript do HTML validada pelo Node.js.
- API respondeu `status: ok` e `public_data: supabase-live` após a publicação.
- Contêiner web saudável, contêiner API saudável e scheduler preservado.
- O trabalho paralelo do Claude não foi mesclado nem alterado.

## Arquivos principais

- `src/bolsa_licitacoes/market_search.py`: compilador, normalização, taxonomia, scoring, explicação e métricas.
- `src/bolsa_licitacoes/supabase_public_api.py`: integração do motor com a base real, facetas e cache.
- `index.html`: `ActiveMarketScope`, modos de busca, construtor visual, autocomplete, feedback e atualização integral da experiência.
- `migrations/007_search_quality.sql`: qualidade e feedback na instalação SQLite.
- `supabase/migrations/0009_market_search_engine.sql`: estrutura preparada para FTS/trigramas e qualidade no Supabase.

## Limites honestos e próximas fases

O que está em produção corresponde ao V1/V2 do roadmap: busca textual híbrida, taxonomia controlada, fuzzy, reranking por regras, explicação e escopo global. Os itens abaixo foram preparados ou delimitados, mas não devem ser anunciados como ativos:

1. A migração de FTS/trigramas do Supabase está versionada, mas ainda precisa de credencial de implantação e benchmark antes de ser aplicada na base canônica.
2. Embeddings/pgvector e reranking por modelo semântico são a fase V3/V4; o modo amplo atual usa taxonomia aprovada, não vetores.
3. Busca no conteúdo integral de PDF depende de extração/OCR e chunks. Hoje só são usados os dados de documento efetivamente disponíveis.
4. O feedback persistente multiusuário deve ser conectado ao login/consentimento quando a central administrativa do Claude for integrada. Até lá, fica local ao dispositivo.
5. Filtros de baixa concorrência não são aplicados sem histórico confiável de participantes e lances; a interface informa essa indisponibilidade em vez de exibir uma estimativa global.

Esses limites protegem a confiabilidade: uma funcionalidade somente é considerada pronta quando respeita o escopo ativo e possui dados suficientes para sustentá-la.
