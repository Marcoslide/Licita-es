// BOLSA — ContratosGovCollector: contratos por UG (federal) + execução
// (empenhos, faturas, garantias, ocorrências) via API pública do Comprasnet Contratos.
import postgres from "npm:postgres@3.4.5";
const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });
const BASE = "https://contratos.comprasnet.gov.br";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
interface Stats { paginas: number; registros: number; inseridos: number; atualizados: number; ignorados: number; erros: number; empenhos: number; faturas: number; garantias: number; ocorrencias: number; detalhes: string[]; }
const nota = (s: Stats, m: string) => { if (s.detalhes.length < 10) s.detalhes.push(m); };
function cnpjValido(c: string): boolean {
  const n = c.replace(/\D/g, "");
  if (n.length !== 14 || /^(\d)\1+$/.test(n)) return false;
  const calc = (len: number) => {
    const w = len === 12 ? [5,4,3,2,9,8,7,6,5,4,3,2] : [6,5,4,3,2,9,8,7,6,5,4,3,2];
    const s2 = w.reduce((a, p, i) => a + p * +n[i], 0);
    const r = s2 % 11; return r < 2 ? 0 : 11 - r;
  };
  return calc(12) === +n[12] && calc(13) === +n[13];
}

async function fetchJson(url: string, stats: Stats, ctx: string, tmo = 30000): Promise<{ ok: boolean; status: number; body: any }> {
  let ultimo = "";
  for (let t = 0; t < 3; t++) {
    try {
      const res = await fetch(url, { headers: { accept: "application/json", "user-agent": UA }, signal: AbortSignal.timeout(tmo) });
      const txt = await res.text();
      if (res.ok) {
        try {
          const hash = await sha256(txt || "null");
          await sql`insert into bolsa.raw_payloads (fonte_id, url, contexto, http_status, content_hash, payload)
                    values ('contratos_gov', ${url}, ${ctx}, ${res.status}, ${hash}, ${txt || "null"}::jsonb)
                    on conflict (url, content_hash) do nothing`;
        } catch (e) { nota(stats, "raw: " + String((e as Error).message)); }
        return { ok: true, status: res.status, body: txt ? JSON.parse(txt) : null };
      }
      if (res.status === 404) return { ok: false, status: 404, body: null };
      if (res.status === 429 || res.status >= 500) { await sleep(500 * 2 ** t + Math.random() * 300); continue; }
      nota(stats, `HTTP ${res.status} ${url.slice(-60)}`);
      return { ok: false, status: res.status, body: null };
    } catch (e) { ultimo = String((e as Error)?.message ?? e); await sleep(500 * 2 ** t + Math.random() * 300); }
  }
  stats.erros++; if (ultimo) nota(stats, `fetch: ${ultimo}`);
  return { ok: false, status: 0, body: null };
}

function extrairFornecedor(f: unknown): { ni: string | null; nome: string | null } {
  if (f && typeof f === "object") {
    const o = f as any;
    const bruto = o.cnpj_cpf_idgener ?? o.cnpj ?? o.ni ?? null;
    return { ni: bruto ? String(bruto).replace(/\D/g, "") || null : null, nome: o.nome ?? null };
  }
  if (typeof f === "string") {
    const m = f.match(/(\d{2}\.?\d{3}\.?\d{3}\/?\d{4}-?\d{2})/);
    return { ni: m ? m[1].replace(/\D/g, "") : null, nome: f.replace(/^[\d./-]+\s*-?\s*/, "") || f };
  }
  return { ni: null, nome: null };
}
const numOuNull = (v: unknown) => { const n = typeof v === "string" ? Number(v.replace(/\./g, "").replace(",", ".")) : Number(v); return Number.isFinite(n) ? n : null; };
const dataBr = (v: unknown) => { if (typeof v !== "string" || !v) return null; const m = v.match(/^(\d{2})\/(\d{2})\/(\d{4})/); return m ? `${m[3]}-${m[2]}-${m[1]}` : v.slice(0, 10); };

async function jobContratos(p: any, stats: Stats, deadline: number) {
  const budget = p.maxUgs ?? 2;
  const ck = await sql`select valor from bolsa.checkpoints where chave = 'contratosgov:ugs'`;
  const feitas: Record<string, string> = (ck[0]?.valor as any)?.feitas ?? {};
  const alvos = p.ugs ?? (await sql`
    select u.codigo from bolsa.unidades u
    join bolsa.orgaos o on o.cnpj = u.orgao_cnpj and o.esfera_id = 'F'
    where length(u.codigo) = 6 and u.codigo ~ '^[0-9]+$'
    group by u.codigo order by count(*) desc limit 40`).map((r: any) => r.codigo);
  const pendentes = alvos.filter((ug: string) => !feitas[ug]).slice(0, budget);
  for (const ug of pendentes) {
    if (Date.now() > deadline) { nota(stats, "tempo esgotado (contratos)"); break; }
    const r = await fetchJson(`${BASE}/api/contrato/ug/${ug}`, stats, "contratos_ug");
    if (!r.ok || !Array.isArray(r.body)) { feitas[ug] = "erro:" + r.status; continue; }
    stats.paginas++;
    for (const c of r.body as any[]) {
      if (c?.id == null) { stats.ignorados++; continue; }
      try {
        const forn = extrairFornecedor(c.fornecedor);
        if (forn.ni && forn.ni.length === 14) {
          if (!cnpjValido(forn.ni)) await sql`insert into bolsa.data_quality_issues (entidade, chave, campo, problema, valor) values ('fornecedor', ${forn.ni}, 'ni', 'cnpj_invalido', ${forn.ni})`;
          await sql`insert into bolsa.fornecedores (ni, tipo_pessoa, nome, last_seen_at) values (${forn.ni}, 'PJ', ${forn.nome}, now())
                    on conflict (ni) do update set last_seen_at = now()`;
        }
        const antes = await sql`select 1 from bolsa.contratos_gov where id_fonte = ${c.id}`;
        await sql`insert into bolsa.contratos_gov (id_fonte, receita_despesa, numero, orgao_codigo, orgao_nome, uasg_codigo, uasg_nome,
                    fornecedor_ni, fornecedor_nome, objeto, tipo, categoria, processo, modalidade, licitacao_numero,
                    vigencia_inicio, vigencia_fim, valor_global, valor_inicial, num_parcelas, valor_parcela, valor_acumulado,
                    situacao, source_payload, last_seen_at)
                  values (${c.id}, ${c.receita_despesa ?? null}, ${c.numero ?? null},
                    ${c.codigo_orgao ?? null}, ${typeof c.contratante === "object" ? (c.contratante?.orgao?.nome ?? null) : (c.contratante ?? null)},
                    ${ug}, ${typeof c.contratante === "object" ? (c.contratante?.orgao?.unidade_gestora_origem?.nome ?? null) : null},
                    ${forn.ni}, ${forn.nome}, ${c.objeto ?? null}, ${c.tipo ?? null}, ${c.categoria ?? null}, ${c.processo ?? null},
                    ${c.modalidade ?? null}, ${c.licitacao_numero ?? null},
                    ${dataBr(c.vigencia_inicio)}, ${dataBr(c.vigencia_fim)},
                    ${numOuNull(c.valor_global)}, ${numOuNull(c.valor_inicial)}, ${c.num_parcelas ?? null},
                    ${numOuNull(c.valor_parcela)}, ${numOuNull(c.valor_acumulado)}, ${c.situacao ?? null},
                    ${JSON.stringify(c)}::jsonb, now())
                  on conflict (id_fonte) do update set
                    vigencia_fim = excluded.vigencia_fim, valor_global = excluded.valor_global,
                    valor_acumulado = excluded.valor_acumulado, situacao = excluded.situacao,
                    source_payload = excluded.source_payload, last_seen_at = now()`;
        if (antes.length) stats.ignorados++; else { stats.inseridos++; await sql`insert into bolsa.eventos (entidade, chave, tipo, fonte_id) values ('contrato_gov', ${String(c.id)}, 'NOVO_REGISTRO', 'contratos_gov')`; }
        stats.registros++;
      } catch (e) { stats.erros++; nota(stats, "contrato: " + String((e as Error).message)); }
    }
    feitas[ug] = new Date().toISOString();
    await sql`insert into bolsa.checkpoints (chave, valor, atualizado_em) values ('contratosgov:ugs', ${JSON.stringify({ feitas })}::jsonb, now())
              on conflict (chave) do update set valor = excluded.valor, atualizado_em = now()`;
    await sleep(200);
  }
}

async function jobExecucao(p: any, stats: Stats, deadline: number) {
  const budget = p.maxContratos ?? 5;
  const pend = await sql`select id_fonte from bolsa.contratos_gov where execucao_coletada_em is null
                         order by vigencia_fim desc nulls last limit ${budget}`;
  for (const row of pend) {
    if (Date.now() > deadline) { nota(stats, "tempo esgotado (execucao)"); break; }
    const id = row.id_fonte;
    const recursos: [string, string][] = [["empenhos", "empenhos"], ["faturas", "faturas"], ["garantias", "garantias"], ["ocorrencias", "ocorrencias"]];
    for (const [rec, tabela] of recursos) {
      let r = await fetchJson(`${BASE}/api/contrato/${id}/${rec}`, stats, "cg_" + rec, 20000);
      if (!r.ok && r.status === 404) r = await fetchJson(`${BASE}/api/contrato/id/${id}/${rec}`, stats, "cg_" + rec, 20000);
      if (!r.ok || !Array.isArray(r.body)) continue;
      for (const e of r.body as any[]) {
        try {
          const chave = String(e.numero ?? e.id ?? (await sha256(JSON.stringify(e))).slice(0, 24));
          if (tabela === "empenhos") {
            await sql`insert into bolsa.empenhos (id_contratos_gov, chave_dedup, numero, credor_ni, credor_nome, plano_interno, natureza_despesa,
                        valor_empenhado, valor_aliquidar, valor_liquidado, valor_pago, data_emissao, source_payload, last_seen_at)
                      values (${id}, ${chave}, ${e.numero ?? null}, ${extrairFornecedor(e.credor).ni}, ${extrairFornecedor(e.credor).nome},
                        ${e.planointerno ?? e.plano_interno ?? null}, ${e.naturezadespesa ?? e.natureza_despesa ?? null},
                        ${numOuNull(e.empenhado)}, ${numOuNull(e.aliquidar)}, ${numOuNull(e.liquidado)}, ${numOuNull(e.pago)},
                        ${dataBr(e.data_emissao)}, ${JSON.stringify(e)}::jsonb, now())
                      on conflict (id_contratos_gov, chave_dedup) do update set valor_liquidado = excluded.valor_liquidado,
                        valor_pago = excluded.valor_pago, source_payload = excluded.source_payload, last_seen_at = now()`;
            stats.empenhos++;
          } else if (tabela === "faturas") {
            await sql`insert into bolsa.faturas (id_contratos_gov, chave_dedup, numero, valor, valor_liquido, emissao, vencimento, situacao, source_payload, last_seen_at)
                      values (${id}, ${chave}, ${e.numero ?? null}, ${numOuNull(e.valor)}, ${numOuNull(e.valorliquido ?? e.valor_liquido)},
                        ${dataBr(e.emissao)}, ${dataBr(e.vencimento)}, ${e.situacao ?? null}, ${JSON.stringify(e)}::jsonb, now())
                      on conflict (id_contratos_gov, chave_dedup) do update set situacao = excluded.situacao, source_payload = excluded.source_payload, last_seen_at = now()`;
            stats.faturas++;
          } else if (tabela === "garantias") {
            await sql`insert into bolsa.garantias (id_contratos_gov, chave_dedup, tipo, valor, vencimento, source_payload, last_seen_at)
                      values (${id}, ${chave}, ${e.tipo ?? null}, ${numOuNull(e.valor)}, ${dataBr(e.vencimento)}, ${JSON.stringify(e)}::jsonb, now())
                      on conflict (id_contratos_gov, chave_dedup) do update set valor = excluded.valor, source_payload = excluded.source_payload, last_seen_at = now()`;
            stats.garantias++;
          } else {
            await sql`insert into bolsa.ocorrencias_contrato (id_contratos_gov, chave_dedup, numero, tipo, situacao, data, descricao, source_payload, last_seen_at)
                      values (${id}, ${chave}, ${e.numero ?? null}, ${e.tipo ?? null}, ${e.situacao ?? null}, ${dataBr(e.data)}, ${e.descricao ?? null}, ${JSON.stringify(e)}::jsonb, now())
                      on conflict (id_contratos_gov, chave_dedup) do update set situacao = excluded.situacao, source_payload = excluded.source_payload, last_seen_at = now()`;
            stats.ocorrencias++;
          }
        } catch (er) { stats.erros++; nota(stats, tabela + ": " + String((er as Error).message)); }
      }
      await sleep(120);
    }
    await sql`update bolsa.contratos_gov set execucao_coletada_em = now() where id_fonte = ${id}`;
  }
}

Deno.serve(async (req: Request) => {
  let p: any = {};
  try { p = await req.json(); } catch (_) { /* vazio */ }
  const job: string = p.job ?? "contratos";
  const stats: Stats = { paginas: 0, registros: 0, inseridos: 0, atualizados: 0, ignorados: 0, erros: 0, empenhos: 0, faturas: 0, garantias: 0, ocorrencias: 0, detalhes: [] };
  const deadline = Date.now() + (p.orcamentoMs ?? 35000);
  let logId: number | null = null;
  try { const r = await sql`insert into bolsa.coleta_log (fonte_id, job) values ('contratos_gov', ${job}) returning id`; logId = r[0].id; } catch (e) { nota(stats, String((e as Error).message)); }
  try {
    if (job === "contratos") { await jobContratos(p, stats, deadline); await jobExecucao(p, stats, deadline); }
    else if (job === "execucao") await jobExecucao(p, stats, deadline);
    else return new Response(JSON.stringify({ erro: "job desconhecido" }), { status: 400 });
    const statusFonte = stats.erros > 0 && stats.registros === 0 && stats.empenhos === 0 ? "TEMPORARILY_UNAVAILABLE" : "ATIVA";
    await sql`update bolsa.fontes set status = ${statusFonte}, ultimo_sucesso_em = case when ${statusFonte === "ATIVA"} then now() else ultimo_sucesso_em end where id = 'contratos_gov'`;
  } catch (e) { stats.erros++; nota(stats, "excecao: " + String((e as Error).message)); }
  if (logId != null) {
    try {
      await sql`update bolsa.coleta_log set finalizado_em = now(), paginas = ${stats.paginas}, registros = ${stats.registros},
                inseridos = ${stats.inseridos}, atualizados = ${stats.atualizados}, ignorados = ${stats.ignorados}, erros = ${stats.erros},
                detalhe = ${JSON.stringify({ job, params: p, empenhos: stats.empenhos, faturas: stats.faturas, garantias: stats.garantias, ocorrencias: stats.ocorrencias, notas: stats.detalhes })}::jsonb
                where id = ${logId}`;
    } catch { /* não fatal */ }
  }
  return new Response(JSON.stringify({ ok: true, job, ...stats }), { headers: { "content-type": "application/json" } });
});
