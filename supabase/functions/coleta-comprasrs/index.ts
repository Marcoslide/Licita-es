// ============================================================
// BOLSA — conector Compras RS (Compras Eletrônicas do Rio Grande do Sul) v2
// Wave 2 #3. www.compras.rs.gov.br — portal estadual próprio (Apache).
//
// Discovery de 2ª camada (2026-09-04): busca real roda via
// POST /editais/pesquisa.json (achado no bundle procurement/search.js),
// exige publicationStartDate/publicationEndDate (nomes reais dos <input>
// do form, período máximo de 12 meses — validação de domínio, não
// bloqueio). Resposta é JSON limpo (iTotalDisplayRecords + data[]), sem
// captcha/WAF/auth em nenhuma camada testada.
//
// Motor genérico direto via SQL, sql.json(). Usa a MESMA entidade
// 'processo_disputa' e o MESMO formato de campos (orgao/numero/modalidade/
// situacao/data_publicacao/data_sessao) da família BNC/BLL — não por
// coincidência de nome, mas porque bolsa.resolver_canonico_processo_disputa()
// já sabe processar esse formato sem nenhuma modificação (reuso real).
// ============================================================
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });
const BASE = "https://www.compras.rs.gov.br";
const FONTE = "comprasrs";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";

function slug(s: string): string {
  return (s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

function epochParaData(ms: number | null): string {
  if (!ms) return "";
  const d = new Date(ms);
  return `${String(d.getUTCDate()).padStart(2, "0")}/${String(d.getUTCMonth() + 1).padStart(2, "0")}/${d.getUTCFullYear()}`;
}

interface Edital {
  id: number; biddingType: string; issuanceNumber: string; processNumber: string;
  tradeOffice: string; description: string; startDate: number | null;
  legalNormType: string; biddingTypeName: string; publishDate: number | null;
}

async function buscarPagina(dataInicio: string, dataFim: string, start: number, length: number): Promise<{ total: number; itens: Edital[] }> {
  const params = new URLSearchParams({
    draw: "1", start: String(start), length: String(length),
    iDisplayStart: String(start), iDisplayLength: String(length), sEcho: "1",
    publicationStartDate: dataInicio, publicationEndDate: dataFim,
  });
  const res = await fetch(`${BASE}/editais/pesquisa.json`, {
    method: "POST",
    headers: {
      "user-agent": UA, "content-type": "application/x-www-form-urlencoded; charset=UTF-8",
      "x-requested-with": "XMLHttpRequest", accept: "application/json, text/javascript, */*; q=0.01",
      referer: `${BASE}/editais/pesquisar`,
    },
    body: params.toString(),
    signal: AbortSignal.timeout(20000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const j = await res.json();
  return { total: j.iTotalDisplayRecords ?? 0, itens: j.data ?? [] };
}

Deno.serve(async (req: Request) => {
  const body = await req.json().catch(() => ({} as Record<string, unknown>));
  const stats = { registros_vistos: 0, novos: 0, atualizados: 0, sem_mudanca: 0, erros: 0, total_periodo: 0, detalhes: [] as string[] };
  let logId: number | null = null;

  const hoje = new Date();
  const fmt = (d: Date) => `${String(d.getUTCDate()).padStart(2, "0")}/${String(d.getUTCMonth() + 1).padStart(2, "0")}/${d.getUTCFullYear()}`;
  const inicioJanela = new Date(hoje); inicioJanela.setUTCDate(inicioJanela.getUTCDate() - 364);
  const dataInicio = fmt(inicioJanela);
  const dataFim = fmt(hoje);
  const chaveCk = "comprasrs:cursor";
  const LOTE = 100;
  const LIMITE_POR_EXECUCAO = 300;

  try {
    const rLog = await sql`insert into bolsa.coleta_log (fonte_id, job) values (${FONTE}, 'listagem') returning id`;
    logId = rLog[0].id;
  } catch { /* log não fatal */ }

  try {
    await sql`select bolsa.garantir_fonte(${FONTE}, 'Compras Eletrônicas RS', ${BASE}, ${sql.json({
      listagem_publica: true, busca_por_periodo: true, periodo_maximo_meses: 12,
    })}::jsonb)`;

    const ckRows = await sql`select valor from bolsa.checkpoints where chave = ${chaveCk}`;
    const ckAnterior = ckRows[0]?.valor as { janela?: string; start?: number } | undefined;
    const janelaAtual = `${dataInicio}-${dataFim}`;
    let start = ckAnterior?.janela === janelaAtual ? (ckAnterior.start ?? 0) : 0;

    let processadosNestaExecucao = 0;
    let totalPeriodo = 0;
    let terminouJanela = false;

    while (processadosNestaExecucao < LIMITE_POR_EXECUCAO) {
      const { total, itens } = await buscarPagina(dataInicio, dataFim, start, LOTE);
      totalPeriodo = total;
      if (itens.length === 0) { terminouJanela = true; break; }

      for (const it of itens) {
        stats.registros_vistos++;
        processadosNestaExecucao++;
        try {
          const chave = `${slug(it.tradeOffice)}:${slug(it.issuanceNumber)}:${slug(it.biddingTypeName)}`;
          const rows = await sql`select bolsa.registrar_estado('processo_disputa', ${chave}, ${FONTE}, ${sql.json({
            orgao: it.tradeOffice, numero: it.issuanceNumber, modalidade: it.biddingTypeName,
            cidade_uf: "", situacao: it.legalNormType, data_publicacao: epochParaData(it.publishDate),
            data_sessao: epochParaData(it.startDate), processo_numero: it.processNumber,
            descricao: it.description, id_comprasrs: it.id,
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

      start += itens.length;
      if (start >= total) { terminouJanela = true; break; }
    }

    stats.total_periodo = totalPeriodo;
    await sql`insert into bolsa.checkpoints (chave, valor, atualizado_em)
              values (${chaveCk}, ${sql.json({ janela: janelaAtual, start, total_periodo: totalPeriodo, terminou: terminouJanela, ultima_execucao: new Date().toISOString() })}::jsonb, now())
              on conflict (chave) do update set valor = excluded.valor, atualizado_em = now()`;
    (stats as any).cursor_final = start;
    (stats as any).terminou_janela = terminouJanela;

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
