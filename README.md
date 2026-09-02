# Bolsa de Licitações — protótipo do terminal

Protótipo navegável (HTML único, sem backend) da visão de produto **Bolsa de Licitações**:
uma plataforma de inteligência do mercado público brasileiro com experiência de terminal
financeiro — *a tecnologia trabalha, a pessoa decide*.

## Como testar

Abra `index.html` em qualquer navegador moderno. Não há build nem dependências
(as fontes vêm do Google Fonts; sem internet, caem no fallback do sistema).

**Todos os dados são simulados para demonstração** — empresas, órgãos, valores e
processos são fictícios e servem apenas para exercitar a experiência.

## O que o protótipo cobre (telas priorizadas na especificação)

| Tela | Conteúdo |
|---|---|
| **F1 Terminal** | Briefing "Seu dia na Bolsa" (funil 3.842 → 3 prioritárias), "Pergunte à Bolsa", ticker de índices setoriais, 12 indicadores, mapa de calor do Brasil (cartograma 27 UFs, 6 métricas, drill-down por estado), índice de aquecimento por segmento, blocos Quentes / Maiores Margens / Maior Chance / Escondidas / Urgentes / Próximas Compras / Aquecendo / Esfriando, watchlist, alertas críticos, agenda de sessões, contratos vencendo e resumo da carteira |
| **F2 Ficha da Licitação** | Decisão primeiro (PARTICIPAR + por quê), 6 scores explicáveis, Opportunity Score, Price to Win com faixa/piso/break-even, simulador de lucratividade interativo (cenários conservador/competitivo/agressivo + "não desça de"), DNA histórico, concorrentes prováveis, checklist de habilitação (edital × cofre documental, com bloqueadores), edital em blocos com rastreabilidade (página · cláusula · confiança) e chat "Pergunte ao Edital" |
| **F3 Raio-X do Mercado** | Seringa 10 mL: tamanho do mercado, preços, tendência, sazonalidade, market share (com disclaimer), compradores, oportunidades abertas, contratos vencendo, PCA, exigências frequentes e prontidão |
| **F4 Raio-X do Concorrente** | MedFarma: valores por classificação (adjudicado/homologado/contratado/pago), evolução, regiões, padrões de disputa observados (rotulados como inferência), confronto direto e sinal estatístico sem acusação |
| **F5 Central de Documentação** | Saúde documental, certidões com vencimento e **impacto operacional**, atestados, faltantes, régua de alertas, histórico de versões |
| **F6 Carteira** | Kanban do pipeline + insights executivos da IA |

Conceitos transversais demonstrados: níveis de confiança (CONFIRMADO / CALCULADO /
INFERIDO / PREVISTO), separação fato × inferência × previsão, "não localizado" em vez de
inventar cláusula, exigências do edital separadas de padrões históricos, e navegação
cruzada entre oportunidade → mercado → concorrente → documentos → carteira.

## Próximos passos sugeridos

Fase 1 do roadmap da especificação: modelagem das entidades centrais (licitação, órgão,
item, fornecedor, documento…), conectores de coleta (PNCP, Compras.gov), normalização/
deduplicação e busca — mantendo esta experiência como norte da interface.
