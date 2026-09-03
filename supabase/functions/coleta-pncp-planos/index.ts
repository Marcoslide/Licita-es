// BOLSA — PNCP: atas de registro de preço + PCA (função modular do PncpCollector).
// Endpoints públicos: /api/consulta/v1/atas (período de vigência) e /api/consulta/v1/pca/atualizacao.
import postgres from "npm:postgres@3.4.5";
const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });
const PNCP = "https://pncp.gov.br";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
interface Stats { paginas: number; registros: number; inseridos: number; atualizados: number; ignorados: number; erros: number; detalhes: string[]; }
const nota = (s: Stats, m: string) => { if (s.detalhes.length < 10) s.detalhes.push(m); };

async function fetchJson(url: string, stats: Stats, tmo = 25000): Promise<{ ok: boolean; status: number; body: any }> {
  let ultimo = "";
  for (let t = 0; t < 3; t++) {
    try {
      const res = await fetch(url, { headers: { accept: "application/json", "user-agent": UA }, signal: AbortSignal.timeout(tmo) });
      if (res.status === 204) return { ok: true, status: 204, body: null };
      const txt = await res.text();
      if (res.ok) {
        try {
          const hash = await sha256(txt || "null");
          await sql`insert into bolsa.raw_payloads (fonte_id, url, contexto, http_status, content_hash, payload)
                    values ('pncp', ${url}, ${url.includes("/atas") ? "atas" : "pca"}, ${res.status}, ${hash}, ${txt || "null"}::jsonb)
                    on conflict (url, content_hash) do nothing`;
        } catch (e) { nota(stats, "raw: " + String((e as Error).message)); }
        return { ok: true, status: res.status, body: txt ? JSON.parse(txt) : null };
      }
      if (res.status === 404) return { ok: false, status: 404, body: null };
      if (res.status === 429 || res.status >= 500) { await sleep(400 * 2 ** t + Math.random() * 300); continue; }
      nota(stats, `HTTP ${res.status}: ${txt.slice(0, 140)}`);
      return { ok: false, status: res.status, body: null };
    } catch (e) { ultimo = String((e as Error)?.message ?? e); await sleep(400 * 2 ** t + Math.random() * 300); }
  }
  stats.erros++; if (ultimo) nota(stats, `fetch: ${ultimo}`);
  return { ok: false, status: 0, body: null };
}

const ymd = (d: Date) => d.toISOString().slice(0, 10).replace(/-/g, "");

async function jobAtas(p: any, stats: Stats, deadline: number) {
  const dataInicial = p.dataInicial ?? ymd(new Date());
  const dataFinal = p.dataFinal ?? ymd(new Date(Date.now() + 864e5));
  const maxPaginas = p.maxPaginas ?? 3;
  const ckChave = `pncp:atas:${dataInicial}-${dataFinal}`;
  const ck = await sql`select valor from bolsa.checkpoints where chave = ${ckChave}`;
  let pag = ((ck[0]?.valor as any)?.pagina ?? 0) + 1;
  for (let n = 0; n < maxPaginas; n++, pag++) {
    if (Date.now() > deadline) { nota(stats, "tempo esgotado (atas)"); return; }
    const url = `${PNCP}/api/consulta/v1/atas?dataInicial=${dataInicial}&dataFinal=${dataFinal}&pagina=${pag}&tamanhoPagina=50`;
    const r = await fetchJson(url, stats);
    if (!r.ok || !r.body) return;
    stats.paginas++;
    for (const a of (r.body.data ?? [])) {
      const ncp = a.numeroControlePNCPAta ?? null;
      if (!ncp) { stats.ignorados++; continue; }
      try {
        if (a.cnpjOrgao) {
          await sql`insert into bolsa.orgaos (cnpj, razao_social, last_seen_at, source_payload)
                    values (${a.cnpjOrgao}, ${a.nomeOrgao ?? null}, now(), ${JSON.stringify({ cnpj: a.cnpjOrgao, razaoSocial: a.nomeOrgao })}::jsonb)
                    on conflict (cnpj) do update set last_seen_at = now()`;
        }
        const antes = await sql`select 1 from bolsa.atas where numero_controle_pncp_ata = ${ncp}`;
        await sql`insert into bolsa.atas (numero_controle_pncp_ata, numero_ata, ano, numero_controle_pncp_compra,
                    orgao_cnpj, unidade_codigo, objeto, data_assinatura, vigencia_inicio, vigencia_fim,
                    cancelado, source_updated_at, source_payload, last_seen_at)
                  values (${ncp}, ${a.numeroAtaRegistroPreco ?? null}, ${a.anoAta ?? null}, ${a.numeroControlePNCPCompra ?? null},
                    ${a.cnpjOrgao ?? null}, ${a.codigoUnidadeOrgao != null ? String(a.codigoUnidadeOrgao) : null}, ${a.objetoContratacao ?? null},
                    ${a.dataAssinatura ?? null}, ${a.vigenciaInicio ?? null}, ${a.vigenciaFim ?? null},
                    ${typeof a.cancelado === "boolean" ? a.cancelado : null}, ${a.dataAtualizacao ?? null}, ${JSON.stringify(a)}::jsonb, now())
                  on conflict (numero_controle_pncp_ata) do update set
                    vigencia_fim = excluded.vigencia_fim, cancelado = excluded.cancelado,
                    source_updated_at = excluded.source_updated_at, source_payload = excluded.source_payload,
                    last_seen_at = now()`;
        if (antes.length) stats.ignorados++; else { stats.inseridos++; await sql`insert into bolsa.eventos (entidade, chave, tipo, fonte_id) values ('ata', ${ncp}, 'NOVO_REGISTRO', 'pncp')`; }
        stats.registros++;
      } catch (e) { stats.erros++; nota(stats, "ata: " + String((e as Error).message)); }
    }
    await sql`insert into bolsa.checkpoints (chave, valor, atualizado_em) values (${ckChave}, ${JSON.stringify({ pagina: pag, dataInicial, dataFinal })}::jsonb, now())
              on conflict (chave) do update set valor = excluded.valor, atualizado_em = now()`;
    if (!r.body.paginasRestantes || r.body.paginasRestantes <= 0) return;
    await sleep(120);
  }
}

async function jobPca(p: any, stats: Stats, deadline: number) {
  const dataInicio = p.dataInicio ?? ymd(new Date(Date.now() - 2 * 864e5));
  const dataFim = p.dataFim ?? ymd(new Date());
  const maxPaginas = p.maxPaginas ?? 2;
  const ckChave = `pncp:pca:${dataInicio}-${dataFim}`;
  const ck = await sql`select valor from bolsa.checkpoints where chave = ${ckChave}`;
  let pag = ((ck[0]?.valor as any)?.pagina ?? 0) + 1;
  for (let n = 0; n < maxPaginas; n++, pag++) {
    if (Date.now() > deadline) { nota(stats, "tempo esgotado (pca)"); return; }
    const url = `${PNCP}/api/consulta/v1/pca/atualizacao?dataInicio=${dataInicio}&dataFim=${dataFim}&pagina=${pag}&tamanhoPagina=50`;
    const r = await fetchJson(url, stats);
    if (!r.ok || !r.body) return;
    stats.paginas++;
    // cada registro é um ENVELOPE por órgão/plano contendo itens[] (forma real da fonte)
    for (const env of (r.body.data ?? [])) {
      const orgao = env.orgaoEntidadeCnpj ?? env.orgaoCnpj ?? env.cnpj ?? null;
      const ano = env.anoPca ?? env.anoPlano ?? null;
      const itensArr = Array.isArray(env.itens) ? env.itens : [env];
      for (const it of itensArr) {
        try {
          const chave = (await sha256(JSON.stringify(it))).slice(0, 32);
          const antes = orgao != null && ano != null
            ? await sql`select 1 from bolsa.pca_itens where orgao_cnpj = ${orgao} and ano_pca = ${ano} and chave_dedup = ${chave}`
            : [];
          await sql`insert into bolsa.pca_itens (orgao_cnpj, ano_pca, chave_dedup, numero_item, categoria_nome, descricao,
                      quantidade, valor_unitario, valor_total, valor_orcamento_exercicio, data_desejada,
                      unidade_requisitante, classificacao_superior_codigo, classificacao_superior_nome, catalogo_codigo,
                      source_updated_at, source_payload, last_seen_at)
                    values (${orgao}, ${ano ?? 0}, ${chave}, ${it.numeroItem ?? null},
                      ${it.categoriaItemPcaNome ?? it.nomeClassificacaoCatalogo ?? null},
                      ${it.descricaoItem ?? it.pdmDescricao ?? null},
                      ${it.quantidadeEstimada ?? it.quantidade ?? null},
                      ${it.valorUnitario ?? null}, ${it.valorTotal ?? null}, ${it.valorOrcamentoExercicio ?? null},
                      ${it.dataDesejada ?? null}, ${it.unidadeRequisitante ?? null},
                      ${it.classificacaoSuperiorCodigo ?? null}, ${it.classificacaoSuperiorNome ?? null},
                      ${it.codigoItem != null ? String(it.codigoItem) : null},
                      ${it.dataAtualizacao ?? null}, ${JSON.stringify(it)}::jsonb, now())
                    on conflict (orgao_cnpj, ano_pca, chave_dedup) do update set
                      quantidade = excluded.quantidade, valor_total = excluded.valor_total,
                      source_updated_at = excluded.source_updated_at, source_payload = excluded.source_payload, last_seen_at = now()`;
          if (antes.length) stats.ignorados++; else stats.inseridos++;
          stats.registros++;
        } catch (e) { stats.erros++; nota(stats, "pca: " + String((e as Error).message)); }
      }
    }
    await sql`insert into bolsa.checkpoints (chave, valor, atualizado_em) values (${ckChave}, ${JSON.stringify({ pagina: pag })}::jsonb, now())
              on conflict (chave) do update set valor = excluded.valor, atualizado_em = now()`;
    if (!r.body.paginasRestantes || r.body.paginasRestantes <= 0) return;
    await sleep(120);
  }
}

Deno.serve(async (req: Request) => {
  let p: any = {};
  try { p = await req.json(); } catch (_) { /* vazio */ }
  const job: string = p.job ?? "atas";
  const stats: Stats = { paginas: 0, registros: 0, inseridos: 0, atualizados: 0, ignorados: 0, erros: 0, detalhes: [] };
  const deadline = Date.now() + (p.orcamentoMs ?? 35000);
  let logId: number | null = null;
  try { const r = await sql`insert into bolsa.coleta_log (fonte_id, job) values ('pncp', ${"planos:" + job}) returning id`; logId = r[0].id; } catch (e) { nota(stats, String((e as Error).message)); }
  try {
    if (job === "atas") await jobAtas(p, stats, deadline);
    else if (job === "pca") await jobPca(p, stats, deadline);
    else return new Response(JSON.stringify({ erro: "job desconhecido" }), { status: 400 });
    if (stats.paginas > 0) await sql`update bolsa.fontes set status = 'ATIVA', ultimo_sucesso_em = now() where id = 'pncp'`;
  } catch (e) { stats.erros++; nota(stats, "excecao: " + String((e as Error).message)); }
  if (logId != null) {
    try {
      await sql`update bolsa.coleta_log set finalizado_em = now(), paginas = ${stats.paginas}, registros = ${stats.registros},
                inseridos = ${stats.inseridos}, atualizados = ${stats.atualizados}, ignorados = ${stats.ignorados}, erros = ${stats.erros},
                detalhe = ${JSON.stringify({ job, params: p, notas: stats.detalhes })}::jsonb where id = ${logId}`;
    } catch { /* não fatal */ }
  }
  return new Response(JSON.stringify({ ok: true, job, ...stats }), { headers: { "content-type": "application/json" } });
});
