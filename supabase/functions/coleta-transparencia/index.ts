// BOLSA — PortalTransparenciaCollector: execução financeira (empenho/liquidação/pagamento).
// A API exige chave GRATUITA (cadastro em portaldatransparencia.gov.br/api-de-dados/cadastrar-email).
// Sem chave: NADA é coletado — a fonte fica AGUARDANDO_CHAVE (§5: informação que exige
// credencial não é coletada; nunca contornamos autenticação). A chave é lida de
// bolsa.segredos (chave = 'transparencia_api_key'), acessível só ao service role.
import postgres from "npm:postgres@3.4.5";
const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });
const BASE = "https://api.portaldatransparencia.gov.br/api-de-dados";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
interface Stats { paginas: number; registros: number; inseridos: number; ignorados: number; erros: number; detalhes: string[]; }
const nota = (s: Stats, m: string) => { if (s.detalhes.length < 10) s.detalhes.push(m); };

function mapFase(v: unknown): "EMPENHO" | "LIQUIDACAO" | "PAGAMENTO" | null {
  const t = String(v ?? "").toUpperCase();
  if (t.includes("EMPENHO")) return "EMPENHO";
  if (t.includes("LIQUIDA")) return "LIQUIDACAO";
  if (t.includes("PAGAMENTO")) return "PAGAMENTO";
  return null;
}
const numBr = (v: unknown) => { if (v == null) return null; const n = typeof v === "string" ? Number(v.replace(/\./g, "").replace(",", ".")) : Number(v); return Number.isFinite(n) ? n : null; };
const dataBr = (v: unknown) => { if (typeof v !== "string" || !v) return null; const m = v.match(/^(\d{2})\/(\d{2})\/(\d{4})/); return m ? `${m[3]}-${m[2]}-${m[1]}` : v.slice(0, 10); };

async function jobDespesas(p: any, stats: Stats, deadline: number, chave: string) {
  const d = p.dataEmissao ?? (() => { const x = new Date(Date.now() - 2 * 864e5); return `${String(x.getUTCDate()).padStart(2, "0")}/${String(x.getUTCMonth() + 1).padStart(2, "0")}/${x.getUTCFullYear()}`; })();
  const maxPaginas = p.maxPaginas ?? 2;
  for (let pag = 1; pag <= maxPaginas; pag++) {
    if (Date.now() > deadline) { nota(stats, "tempo esgotado"); return; }
    const url = `${BASE}/despesas/documentos?dataEmissao=${encodeURIComponent(d)}&pagina=${pag}`;
    let body: any = null;
    try {
      const res = await fetch(url, { headers: { accept: "application/json", "user-agent": UA, "chave-api-dados": chave }, signal: AbortSignal.timeout(25000) });
      const txt = await res.text();
      if (!res.ok) { nota(stats, `HTTP ${res.status}: ${txt.slice(0, 120)}`); if (res.status === 401) return; stats.erros++; return; }
      const hash = await sha256(txt || "null");
      await sql`insert into bolsa.raw_payloads (fonte_id, url, contexto, http_status, content_hash, payload)
                values ('portal_transparencia', ${url}, 'despesas_documentos', ${res.status}, ${hash}, ${txt || "null"}::jsonb)
                on conflict (url, content_hash) do nothing`;
      body = txt ? JSON.parse(txt) : null;
    } catch (e) { stats.erros++; nota(stats, "fetch: " + String((e as Error).message)); return; }
    const linhas: any[] = Array.isArray(body) ? body : [];
    if (!linhas.length) return;
    stats.paginas++;
    for (const e of linhas) {
      try {
        const fase = mapFase(e.fase ?? e.faseDespesa);
        if (!fase) { stats.ignorados++; continue; }
        const doc = e.codigoDocumento ?? e.documento ?? null;
        const chaveDedup = doc ? `${fase}:${doc}` : (await sha256(JSON.stringify(e))).slice(0, 32);
        const ni = (e.codigoFavorecido ?? e.favorecido?.codigo ?? "").toString().replace(/\D/g, "") || null;
        const antes = await sql`select 1 from bolsa.pagamentos_transparencia where chave_dedup = ${chaveDedup}`;
        await sql`insert into bolsa.pagamentos_transparencia (fase, chave_dedup, documento, data, valor, orgao_codigo, orgao_nome,
                    unidade_gestora, favorecido_ni, favorecido_nome, elemento_despesa, source_payload, last_seen_at)
                  values (${fase}, ${chaveDedup}, ${doc}, ${dataBr(e.data ?? e.dataEmissao)}, ${numBr(e.valor ?? e.valorDocumento)},
                    ${e.codigoOrgao ?? e.orgao?.codigo ?? null}, ${e.orgao ?? e.nomeOrgao ?? null},
                    ${e.unidadeGestora ?? e.ug ?? null}, ${ni}, ${e.favorecido ?? e.nomeFavorecido ?? null},
                    ${e.elementoDespesa ?? null}, ${JSON.stringify(e)}::jsonb, now())
                  on conflict (chave_dedup) do update set valor = excluded.valor, source_payload = excluded.source_payload, last_seen_at = now()`;
        if (antes.length) stats.ignorados++; else stats.inseridos++;
        stats.registros++;
      } catch (er) { stats.erros++; nota(stats, "doc: " + String((er as Error).message)); }
    }
    await sleep(400); // limite da API: respeitar ritmo
  }
}

Deno.serve(async (req: Request) => {
  let p: any = {};
  try { p = await req.json(); } catch (_) { /* vazio */ }
  const stats: Stats = { paginas: 0, registros: 0, inseridos: 0, ignorados: 0, erros: 0, detalhes: [] };
  const deadline = Date.now() + (p.orcamentoMs ?? 35000);
  let logId: number | null = null;
  try { const r = await sql`insert into bolsa.coleta_log (fonte_id, job) values ('portal_transparencia', 'despesas') returning id`; logId = r[0].id; } catch (e) { nota(stats, String((e as Error).message)); }
  try {
    const seg = await sql`select valor from bolsa.segredos where chave = 'transparencia_api_key'`;
    if (!seg.length) {
      nota(stats, "aguardando chave gratuita da API (bolsa.segredos: transparencia_api_key) — nada coletado, conforme §5");
      await sql`update bolsa.fontes set status = 'AGUARDANDO_CHAVE' where id = 'portal_transparencia'`;
    } else {
      await jobDespesas(p, stats, deadline, seg[0].valor as string);
      const statusFonte = stats.erros > 0 && stats.registros === 0 ? "TEMPORARILY_UNAVAILABLE" : "ATIVA";
      await sql`update bolsa.fontes set status = ${statusFonte}, ultimo_sucesso_em = case when ${statusFonte === "ATIVA"} then now() else ultimo_sucesso_em end where id = 'portal_transparencia'`;
    }
  } catch (e) { stats.erros++; nota(stats, "excecao: " + String((e as Error).message)); }
  if (logId != null) {
    try {
      await sql`update bolsa.coleta_log set finalizado_em = now(), paginas = ${stats.paginas}, registros = ${stats.registros},
                inseridos = ${stats.inseridos}, ignorados = ${stats.ignorados}, erros = ${stats.erros},
                detalhe = ${JSON.stringify({ params: p, notas: stats.detalhes })}::jsonb where id = ${logId}`;
    } catch { /* não fatal */ }
  }
  return new Response(JSON.stringify({ ok: true, ...stats }), { headers: { "content-type": "application/json" } });
});
