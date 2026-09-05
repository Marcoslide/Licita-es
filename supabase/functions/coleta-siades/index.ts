// ============================================================
// BOLSA — conector SIADES / Compras ES (Espírito Santo) v1
// Wave 3 #2. compras.es.gov.br é só portal institucional (OrchardCore) —
// a app real está em siades.es.gov.br (achada via link "Manual do SIADES
// para fornecedores" no menu de compras.es.gov.br). UI é SPA Vue
// (licitacao-pub), mas a API pública real está em
// GET /licitacao/api/public/v1/licitacoes/?page=N&size=M — achada
// extraindo o bundle JS da SPA (mesma técnica de BBMNET/Compras BR/
// Compras RS). Confirmada via /licitacao/api/public/v1/parametros-publicos:
// recaptchaDownloadPubAtivo=false (downloads/leitura não exigem captcha —
// reCAPTCHA nesta plataforma só protege o formulário de impugnação/
// esclarecimento, uma ação de escrita, não a leitura pública).
// 1.359 licitações totais confirmadas (totalElements da paginação).
//
// Achado de alto valor: exibirRelatorioHistoricoLancesAreaPublica=true e
// exibirRelatorioParticipantesAreaPublica=true — histórico de lances e
// participantes são públicos nesta instância (não coletados nesta v1,
// documentado como próximo passo).
//
// Mesma entidade 'processo_disputa' e mesmo formato de campos da família
// BNC/BLL/Compras RS/M2A — reaproveita
// bolsa.resolver_canonico_processo_disputa() sem modificação. Campo
// cnpjOrgaoSuperiorPncp (CNPJ exato do órgão, ligado ao PNCP) é real e
// mais preciso que o matching por nome que o resolver usa hoje — guardado
// como metadado extra (nao usado no matching ainda, resolver não aceita
// CNPJ como entrada; melhoria futura, não implementada nesta v1).
// ============================================================
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });
const BASE = "https://siades.es.gov.br";
const FONTE = "siades";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";

interface Item {
  id: number; orgao: { nome: string } | null; numeroEdital: string; numProcesso: string;
  objeto: string; situacao: string; status: string; modalidade: string; modoDisputa: string;
  dataAbertura: string | null; dataPublicacao: string | null; ano: number;
  cnpjOrgaoSuperiorPncp: string | null; responsavel: string | null;
  edital: { arquivoNome?: string; arquivoUri?: string; tipo?: string } | null;
  amparoLegal: { lei?: string } | null;
}

async function buscarPagina(page: number, size: number): Promise<{ items: Item[]; totalElements: number }> {
  const res = await fetch(`${BASE}/licitacao/api/public/v1/licitacoes/?page=${page}&size=${size}`, {
    headers: { "user-agent": UA, accept: "application/json" },
    signal: AbortSignal.timeout(20000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const j = await res.json();
  return { items: j.items ?? [], totalElements: j.totalElements ?? 0 };
}

Deno.serve(async (_req: Request) => {
  const stats = { registros_vistos: 0, novos: 0, atualizados: 0, sem_mudanca: 0, erros: 0, total_elementos: 0, detalhes: [] as string[] };
  let logId: number | null = null;
  const chaveCk = "siades:cursor";
  const TAMANHO_PAGINA = 50;
  const LIMITE_POR_EXECUCAO = 300;

  try {
    const rLog = await sql`insert into bolsa.coleta_log (fonte_id, job) values (${FONTE}, 'listagem') returning id`;
    logId = rLog[0].id;
  } catch { /* log não fatal */ }

  try {
    await sql`select bolsa.garantir_fonte(${FONTE}, 'SIADES - Compras ES', ${BASE}, ${sql.json({
      listagem_publica: true, endpoint_real: "/licitacao/api/public/v1/licitacoes/", paginacao: "Spring Data (page,size,totalElements,totalPages)",
      anexos: true, ata_publica: true, acompanhamento: true, historico_lances_publico: true, participantes_publico: true,
    })}::jsonb)`;

    const ckRows = await sql`select valor from bolsa.checkpoints where chave = ${chaveCk}`;
    const ckAnterior = ckRows[0]?.valor as { pagina?: number; terminou?: boolean } | undefined;
    let pagina = ckAnterior?.terminou ? 0 : (ckAnterior?.pagina ?? 0);

    let processadosNestaExecucao = 0;
    let terminouVarredura = false;
    let totalElementos = 0;

    while (processadosNestaExecucao < LIMITE_POR_EXECUCAO) {
      const { items, totalElements } = await buscarPagina(pagina, TAMANHO_PAGINA);
      totalElementos = totalElements;
      if (items.length === 0) { terminouVarredura = true; break; }

      for (const it of items) {
        stats.registros_vistos++;
        processadosNestaExecucao++;
        try {
          const chave = `siades:${it.id}`;
          const rows = await sql`select bolsa.registrar_estado('processo_disputa', ${chave}, ${FONTE}, ${sql.json({
            orgao: it.orgao?.nome ?? "", numero: it.numeroEdital ?? "", modalidade: it.modalidade,
            cidade_uf: "-ES", situacao: it.situacao ?? it.status,
            data_publicacao: it.dataPublicacao, data_sessao: it.dataAbertura,
            modo_disputa: it.modoDisputa, descricao: it.objeto, ano: it.ano,
            num_processo: it.numProcesso, cnpj_orgao_superior_pncp: it.cnpjOrgaoSuperiorPncp,
            responsavel: it.responsavel, amparo_legal: it.amparoLegal?.lei ?? null,
            edital_arquivo: it.edital?.arquivoNome ?? null, id_siades: it.id,
          })}::jsonb) as r`;
          const r = (rows[0] as any).r;
          if (r.novo) stats.novos++;
          else if (r.mudancas.length > 0) stats.atualizados++;
          else stats.sem_mudanca++;
        } catch (e) {
          stats.erros++;
          if (stats.detalhes.length < 10) stats.detalhes.push(String((e as Error)?.message ?? e));
        }
      }

      pagina++;
      if ((pagina) * TAMANHO_PAGINA >= totalElements) { terminouVarredura = true; break; }
      if (processadosNestaExecucao >= LIMITE_POR_EXECUCAO) break;
    }

    stats.total_elementos = totalElementos;
    await sql`insert into bolsa.checkpoints (chave, valor, atualizado_em)
              values (${chaveCk}, ${sql.json({ pagina, total_elementos: totalElementos, terminou: terminouVarredura, ultima_execucao: new Date().toISOString() })}::jsonb, now())
              on conflict (chave) do update set valor = excluded.valor, atualizado_em = now()`;
    (stats as any).pagina_final = pagina;
    (stats as any).terminou_varredura = terminouVarredura;

    await sql`update bolsa.fontes set status = 'ATIVA', ultimo_sucesso_em = now() where id = ${FONTE}`;
  } catch (e) {
    stats.erros++; stats.detalhes.push(String((e as Error)?.message ?? e));
  }

  if (logId != null) {
    try {
      await sql`update bolsa.coleta_log set finalizado_em = now(), registros = ${stats.registros_vistos},
                inseridos = ${stats.novos}, atualizados = ${stats.atualizados}, ignorados = ${stats.sem_mudanca},
                erros = ${stats.erros}, detalhe = ${sql.json(stats)}::jsonb where id = ${logId}`;
    } catch { /* log não fatal */ }
  }

  return new Response(JSON.stringify(stats), { headers: { "content-type": "application/json" } });
});
