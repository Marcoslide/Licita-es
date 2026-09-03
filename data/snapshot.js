// ============================================================
// INSTANTÂNEO REAL DA BASE NACIONAL — gerado da nossa base
// (Supabase/Postgres, schema bolsa) em 2026-09-03T01:34:39Z.
// Fonte primária: PNCP (pncp.gov.br) — coleta própria da Bolsa.
// NENHUM número aqui é inventado; tudo é consultável via SQL
// nas views public.bolsa_vw_* do projeto.
// ============================================================
window.BOLSA_SNAPSHOT = {
  gerado_em: "2026-09-03T02:28:00Z",
  fonte_primaria: "PNCP — Portal Nacional de Contratações Públicas",
  resumo: {
    licitacoes: 596, recebendo_propostas: 288,
    valor_estimado_total: 2423540684.07,
    itens: 1462, documentos: 201, resultados: 31,
    valor_homologado_total: 3597703.80,
    fornecedores: 282, orgaos: 485,
    contratos: 250, valor_contratado_total: 85113966.67,
    contratos_vencendo_180d: 169,
    eventos: 840, eventos_alteracao: 0, raw_payloads: 265,
    ultima_coleta_em: "2026-09-03T02:28:00Z"
  },
  multifonte: {
    atas: 150, atas_vencendo_180d: 102,
    pca_itens: 100,
    catalogo_itens: 1,
    precos_praticados: 0,
    contratos_gov: 94, valor_contratos_gov: 165853091,
    empenhos: 26, valor_empenhado: 161346.31, valor_pago: 89037.52,
    faturas: 0, garantias: 0, arp_saldos: 0, pagamentos_transparencia: 0
  },
  fontes: [
    { id: "pncp", nome: "PNCP", status: "ATIVA", ok: "2026-09-03T02:28:07Z",
      cobre: "licitações · itens · documentos · resultados · contratos · atas · PCA" },
    { id: "compras_gov", nome: "Compras.gov.br (Dados Abertos)", status: "TEMPORARILY_UNAVAILABLE", ok: "2026-09-03T02:24:43Z",
      cobre: "CATMAT/CATSER · pesquisa de preços · saldo de ARP (retomada automática pelo cron)" },
    { id: "contratos_gov", nome: "Contratos.gov.br", status: "ATIVA", ok: "2026-09-03T02:24:50Z",
      cobre: "contratos federais por UG · empenhos · faturas · garantias · ocorrências" },
    { id: "portal_transparencia", nome: "Portal da Transparência", status: "AGUARDANDO_CHAVE", ok: null,
      cobre: "empenho/liquidação/pagamento — exige chave gratuita (conector pronto)" }
  ],
  amostras_novas: {
    ata: { numero: "RP 16", objeto: "Registro de preço para aquisição de medicamentos", cnpj_orgao: "01621539000120" },
    contrato_gov: { numero: "00065/2025", fornecedor: "VIVACOM COMERCIO E SERVICOS LTDA", objeto: "Serviços contínuos de manutenção", valor: 12679132.18, fim: "2027-11-13" },
    empenho: { numero: "2025NE003378", empenhado: 12572.98, pago: 0, emissao: "2025-09-04" },
    pca: [
      { descricao: "MANUTENÇÃO DE VEÍCULOS LEVES E PESADOS", valor: 7125322.05, desejada: "2026-12-14" },
      { descricao: "SOFTWARE", valor: 4735200.68, desejada: "2026-11-20" }
    ]
  },
  por_uf: [
    { uf: "AC", processos: 3, valor: 1410366.25, abertas: 3 },
    { uf: "AL", processos: 3, valor: 4618434.95, abertas: 2 },
    { uf: "AM", processos: 6, valor: 9841931.13, abertas: 2 },
    { uf: "AP", processos: 1, valor: 1605324.28, abertas: 1 },
    { uf: "BA", processos: 24, valor: 34979338.34, abertas: 18 },
    { uf: "CE", processos: 27, valor: 45708165.31, abertas: 8 },
    { uf: "DF", processos: 36, valor: 142553387.03, abertas: 24 },
    { uf: "ES", processos: 14, valor: 7434322.61, abertas: 5 },
    { uf: "GO", processos: 36, valor: 88157027.63, abertas: 11 },
    { uf: "MA", processos: 4, valor: 2254353.08, abertas: 4 },
    { uf: "MG", processos: 49, valor: 321808572.72, abertas: 34 },
    { uf: "MS", processos: 9, valor: 38979408.02, abertas: 7 },
    { uf: "MT", processos: 1, valor: 7539626.12, abertas: 1 },
    { uf: "PA", processos: 6, valor: 61684694.23, abertas: 3 },
    { uf: "PB", processos: 12, valor: 41196049.67, abertas: 4 },
    { uf: "PE", processos: 22, valor: 43989659.96, abertas: 19 },
    { uf: "PI", processos: 4, valor: 2721344.41, abertas: 3 },
    { uf: "PR", processos: 39, valor: 98204501.66, abertas: 18 },
    { uf: "RJ", processos: 30, valor: 122620900.26, abertas: 12 },
    { uf: "RN", processos: 21, valor: 14056480.25, abertas: 15 },
    { uf: "RO", processos: 2, valor: 81114732.36, abertas: 2 },
    { uf: "RR", processos: 3, valor: 9674259.78, abertas: 1 },
    { uf: "RS", processos: 90, valor: 346649872.65, abertas: 42 },
    { uf: "SC", processos: 39, valor: 115945522.62, abertas: 18 },
    { uf: "SE", processos: 1, valor: 0, abertas: 1 },
    { uf: "SP", processos: 109, valor: 777511148.77, abertas: 27 },
    { uf: "TO", processos: 5, valor: 1281259.98, abertas: 3 }
  ],
  top_orgaos: [
    { nome: "INSTITUTO DE ASSISTENCIA MEDICA AO SERVIDOR PUBLICO ESTADUAL", esfera: "E", processos: 4, valor: 648290595.20 },
    { nome: "SUBSECRETARIA DA ADMINISTRACAO CENTRAL DE LICITACOES", esfera: "E", processos: 1, valor: 199165611.60 },
    { nome: "CONSORCIO INTERFEDERATIVO MINAS GERAIS - CIMINAS", esfera: "N", processos: 1, valor: 150000000.57 },
    { nome: "DNIT - DEPARTAMENTO NACIONAL DE INFRAEST DE TRANSPORTES", esfera: "F", processos: 1, valor: 114573990.07 },
    { nome: "MUNICIPIO DE MACAE", esfera: "M", processos: 1, valor: 103540937.43 },
    { nome: "CONSORCIO INTERMUNICIPAL DA REGIAO DA AMFRI - CIM-AMFRI", esfera: "N", processos: 1, valor: 95213261.53 }
  ],
  top_fornecedores: [
    { nome: "CONSTRUCOST LTDA", ni: "01814959000123", porte: "ME", itens: 1, valor_homologado: 1490000 },
    { nome: "ALLGED SOLUCOES DE TI LTDA", ni: "23226948000165", porte: "EPP", itens: 1, valor_homologado: 240000 },
    { nome: "PRO - SAUDE DIST LTDA", ni: "47968031000102", porte: "ME", itens: 2, valor_homologado: 78860 },
    { nome: "M CARREGA COMERCIO DE PRODUTOS HOSPITALARES LTDA", ni: "32593430000150", porte: "ME", itens: 5, valor_homologado: 39000 },
    { nome: "64.994.027 ADRIANO DE ARAUJO PACHECO", ni: "64994027000120", porte: "ME", itens: 10, valor_homologado: 9841.80 }
  ],
  modalidades: [
    { nome: "Pregão - Eletrônico", processos: 200, valor: 714413751.06 },
    { nome: "Inexigibilidade", processos: 100, valor: 745509114.54 },
    { nome: "Concorrência - Eletrônica", processos: 100, valor: 585382313.92 },
    { nome: "Dispensa", processos: 100, valor: 3341459.26 },
    { nome: "Credenciamento", processos: 96, valor: 374894045.29 }
  ],
  contratos_vencendo: [
    { objeto: "Óleo lubrificante e correlatos", fornecedor: "LS BATERIAS LTDA", uf: "SC", valor: 1316.40, fim: "2026-09-03", dias: 0 },
    { objeto: "Materiais ambulatoriais e insumos hospitalares", fornecedor: "ALTERMED MATERIAL MEDICO HOSPITALAR LTDA", uf: "SC", valor: 100, fim: "2026-09-03", dias: 0 },
    { objeto: "Materiais odontológicos e correlatos", fornecedor: "MARINOX COM. DE PECAS ODONTOLOGICAS LTDA", uf: "SC", valor: 185, fim: "2026-09-04", dias: 1 },
    { objeto: "Óleos e correlatos", fornecedor: "MM PRODUTOS AUTOMOTIVOS LTDA", uf: "RS", valor: 9405, fim: "2026-09-08", dias: 5 },
    { objeto: "Materiais de higiene, limpeza, copa e cozinha", fornecedor: "Impar Indústria de Papéis LTDA", uf: "SC", valor: 3756, fim: "2026-09-08", dias: 5 }
  ],
  ultimas: [
    { ncp: "19493732000199-1-000089/2026", objeto: "Credenciamento — serviços de sinalização viária urbana (CIMINAS)", uf: "MG", cidade: "Araxá", valor: 150000000.57, pub: "2026-09-02 19:08" },
    { ncp: "29979036000140-1-000133/2026", objeto: "Locação de Imóvel APS Cambuí (INSS)", uf: "MG", cidade: "Belo Horizonte", valor: 76694.79, pub: "2026-09-02 17:56" },
    { ncp: "13908702000110-1-000147/2026", objeto: "Credenciamento de médicos peritos — Campo Formoso", uf: "BA", cidade: "Campo Formoso", valor: 174000, pub: "2026-09-02 17:55" },
    { ncp: "05505334000130-1-000016/2026", objeto: "Gêneros alimentícios da agricultura familiar — alimentação escolar", uf: "MA", cidade: "Guimarães", valor: 557048, pub: "2026-09-02 17:22" },
    { ncp: "46634358000177-1-000146/2024", objeto: "Credenciamento de médicos — urgência e emergência", uf: "SP", cidade: "Itapeva", valor: 27530820, pub: "2026-09-02 17:04" }
  ],
  cadeia_exemplo: {
    ncp: "07615750000117-1-000063/2026",
    objeto: "Aquisição de equipamentos para o Hospital Municipal de Jaguaruana (emenda parlamentar)",
    orgao: "MUNICIPIO DE JAGUARUANA", uf: "CE", cidade: "Jaguaruana",
    modalidade: "Pregão - Eletrônico", valor_estimado: 267566,
    url_pncp: "https://pncp.gov.br/app/editais/07615750000117/2026/63",
    itens: 11, documentos: [{ titulo: "Edital_e_anexos_082026PE", tipo: "Edital" }],
    resultados: [
      { item: 1, fornecedor: "M CARREGA COM. DE PRODUTOS HOSPITALARES LTDA", ni: "32593430000150", vu: 1900, vt: 3800 },
      { item: 2, fornecedor: "M CARREGA COM. DE PRODUTOS HOSPITALARES LTDA", ni: "32593430000150", vu: 2300, vt: 11500 },
      { item: 10, fornecedor: "PRO - SAUDE DIST LTDA", ni: "47968031000102", vu: 2900, vt: 34800 },
      { item: 11, fornecedor: "PRO - SAUDE DIST LTDA", ni: "47968031000102", vu: 44060, vt: 44060 }
    ]
  },
  mg_universo: {
    processos: 49, valor: 321808572.72,
    cidades: [
      { nome: "Araxá", n: 1, v: 150000000.57 }, { nome: "Montes Claros", n: 1, v: 61419600 },
      { nome: "Caratinga", n: 1, v: 32088798.97 }, { nome: "Botumirim", n: 1, v: 19244099.80 },
      { nome: "Borda da Mata", n: 1, v: 18142403 }, { nome: "Belo Horizonte", n: 8, v: 12640831.15 }
    ],
    orgaos: [
      { nome: "MUNICIPIO DE AIMORES", n: 4 }, { nome: "MUNICIPIO DE GRAO MOGOL", n: 3 },
      { nome: "MUNICIPIO DE BELO HORIZONTE", n: 2 }, { nome: "MUNICIPIO DE BELMIRO BRAGA", n: 2 }
    ]
  },
  saude: {
    fonte: "PNCP", status: "ATIVA", ultimo_sucesso: "2026-09-03T01:31:33Z", execucoes: 11,
    capabilities: { licitacoes: true, itens: true, documentos: true, resultados: true, contratos: true, atas: "previsto", pca: "previsto", pagamentos: false, lances: false },
    cron: [
      { job: "delta", freq: "*/20 min" }, { job: "detalhes", freq: "3×/hora" }, { job: "contratos", freq: "1×/hora" }
    ],
    ultimas_execucoes: [
      { job: "contratos", em: "01:30", registros: 50, inseridos: 0, erros: 1 },
      { job: "detalhes", em: "01:30", docs: 25, itens: 47, resultados: 12, erros: 0 },
      { job: "detalhes", em: "01:28 (cron autônomo)", docs: 21, erros: 0 },
      { job: "delta", em: "01:23", registros: 350, inseridos: 0, ignorados: 350, nota: "idempotência: revisita sem duplicar", erros: 2 },
      { job: "delta", em: "01:20 (cron autônomo)", registros: 400, inseridos: 0, ignorados: 400, erros: 1 },
      { job: "backfill jun/2026", em: "01:16", registros: 100, inseridos: 100, erros: 0 }
    ]
  },
  supabase: {
    url: "https://rxcfbbzosbfiwyloqtdk.supabase.co",
    anon: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ4Y2ZiYnpvc2JmaXd5bG9xdGRrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc5MzE4MTEsImV4cCI6MjEwMzUwNzgxMX0.g1hXBzu2dYjyggOPWKVadxgHQRlwQ7ebQqRk4i-Z3F4"
  }
};
