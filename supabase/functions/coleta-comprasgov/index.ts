// BOLSA — ComprasGovCollector (dadosabertos.compras.gov.br):
// catálogo CATMAT/CATSER direcionado aos códigos vistos nos nossos itens,
// pesquisa de preços praticados e saldo de empenho de itens de ARP.
import postgres from "npm:postgres@3.4.5";
const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });
const BASE = "https://dadosabertos.compras.gov.br";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
interface Stats { paginas: number; registros: number; inseridos: number; atualizados: number; ignorados: number; erros: number; catalogo: number; precos: number; saldos: number; detalhes: string[]; }
const nota = (s: Stats, m: string) => { if (s.detalhes.length < 10) s.detalhes.push(m); };

async function fetchJson(url: string, stats: Stats, ctx: string, tmo = 25000): Promise<{ ok: boolean; status: number; body: any }> {
  let ultimo = "";
  for (let t = 0; t < 3; t++) {
    try {
      const res = await fetch(url, { headers: { accept: "application/json", "user-agent": UA }, signal: AbortSignal.timeout(tmo) });
      const txt = await res.text();
      if (res.ok) {
        try {
          const hash = await sha256(txt || "null");
          await sql`insert into bolsa.raw_payloads (fonte_id, url, contexto, http_status, content_hash, payload)
                    values ('compras_gov', ${url}, ${ctx}, ${res.status}, ${hash}, ${txt || "null"}::jsonb)
                    on conflict (url, content_hash) do nothing`;
        } catch (e) { nota(stats, "raw: " + String((e as Error).message)); }
        return { ok: true, status: res.status, body: txt ? JSON.parse(txt) : null };
      }
      if (res.status === 404) { nota(stats, `404 ${url.slice(38, 120)}: ${txt.slice(0, 90)}`); return { ok: false, status: 404, body: null }; }
      if (res.status === 429 || res.status >= 500) { await sleep(500 * 2 ** t + Math.random() * 300); continue; }
      nota(stats, `HTTP ${res.status}: ${txt.slice(0, 120)}`);
      return { ok: false, status: res.status, body: null };
    } catch (e) { ultimo = String((e as Error)?.message ?? e); await sleep(500 * 2 ** t + Math.random() * 300); }
  }
  stats.erros++; if (ultimo) nota(stats, `fetch: ${ultimo}`);
  return { ok: false, status: 0, body: null };
}

// códigos de catálogo vistos nos nossos itens e ainda não resolvidos
async function codigosPendentes(limite: number, soComCatalogo = false) {
  return await sql`
    select distinct i.catalogo_codigo as codigo
    from bolsa.itens i
    where i.catalogo_codigo is not null and i.catalogo_codigo ~ '^[0-9]+$'
      and ${soComCatalogo
        ? sql`exists (select 1 from bolsa.catalogo c where c.codigo = i.catalogo_codigo)
              and not exists (select 1 from bolsa.precos_praticados p where p.catalogo_codigo = i.catalogo_codigo)`
        : sql`not exists (select 1 from bolsa.catalogo c where c.codigo = i.catalogo_codigo)`}
    limit ${limite}`;
}

async function jobCatalogo(p: any, stats: Stats, deadline: number) {
  const alvos = await codigosPendentes(p.maxCodigos ?? 15);
  for (const { codigo } of alvos) {
    if (Date.now() > deadline) { nota(stats, "tempo esgotado (catalogo)"); break; }
    let tipo = "MATERIAL";
    let r = await fetchJson(`${BASE}/modulo-material/4_consultarItemMaterial?pagina=1&tamanhoPagina=10&codigoItem=${codigo}`, stats, "catmat");
    let reg = r.ok ? (r.body?.resultado ?? []).find((x: any) => String(x.codigoItem) === String(codigo)) : null;
    if (!reg) {
      tipo = "SERVICO";
      r = await fetchJson(`${BASE}/modulo-servico/6_consultarItemServico?pagina=1&tamanhoPagina=10&codigoServico=${codigo}`, stats, "catser");
      reg = r.ok ? (r.body?.resultado ?? []).find((x: any) => String(x.codigoServico ?? x.codigoItem) === String(codigo)) : null;
    }
    if (!reg) {
      // marca como não encontrado para não insistir (§58: registrar, não descartar)
      await sql`insert into bolsa.catalogo (tipo, codigo, situacao, source_payload, last_seen_at)
                values ('MATERIAL', ${codigo}, 'NAO_ENCONTRADO_NA_FONTE', ${JSON.stringify({ consulta: codigo, encontrado: false })}::jsonb, now())
                on conflict (tipo, codigo) do update set last_seen_at = now()`;
      stats.ignorados++;
      continue;
    }
    try {
      await sql`insert into bolsa.catalogo (tipo, codigo, descricao, grupo_codigo, grupo_nome, classe_codigo, classe_nome,
                  pdm_codigo, pdm_nome, situacao, source_updated_at, source_payload, last_seen_at)
                values (${tipo}, ${codigo}, ${reg.descricaoItem ?? reg.descricaoServico ?? reg.descricao ?? null},
                  ${reg.codigoGrupo != null ? String(reg.codigoGrupo) : null}, ${reg.nomeGrupo ?? null},
                  ${reg.codigoClasse != null ? String(reg.codigoClasse) : null}, ${reg.nomeClasse ?? null},
                  ${reg.codigoPdm != null ? String(reg.codigoPdm) : null}, ${reg.nomePdm ?? null},
                  ${reg.statusItem === true || reg.statusServico === true ? 'ATIVO' : (reg.statusItem === false || reg.statusServico === false ? 'INATIVO' : null)},
                  ${reg.dataHoraAtualizacao ?? null}, ${JSON.stringify(reg)}::jsonb, now())
                on conflict (tipo, codigo) do update set descricao = excluded.descricao, situacao = excluded.situacao,
                  source_payload = excluded.source_payload, last_seen_at = now()`;
      stats.catalogo++; stats.inseridos++; stats.registros++;
    } catch (e) { stats.erros++; nota(stats, "catalogo: " + String((e as Error).message)); }
    await sleep(150);
  }
}

async function jobPrecos(p: any, stats: Stats, deadline: number) {
  const alvos = await codigosPendentes(p.maxCodigos ?? 6, true);
  for (const { codigo } of alvos) {
    if (Date.now() > deadline) { nota(stats, "tempo esgotado (precos)"); break; }
    const cat = await sql`select tipo from bolsa.catalogo where codigo = ${codigo} and situacao is distinct from 'NAO_ENCONTRADO_NA_FONTE' limit 1`;
    if (!cat.length) continue;
    const tipo = cat[0].tipo as string;
    const url = tipo === "SERVICO"
      ? `${BASE}/modulo-pesquisa-preco/3_consultarServico?pagina=1&tamanhoPagina=50&codigoItemCatalogo=${codigo}`
      : `${BASE}/modulo-pesquisa-preco/1_consultarMaterial?pagina=1&tamanhoPagina=50&tipo=material&codigo=${codigo}`;
    const r = await fetchJson(url, stats, "pesquisa_preco");
    if (!r.ok || !Array.isArray(r.body?.resultado)) continue;
    stats.paginas++;
    for (const e of r.body.resultado as any[]) {
      try {
        const chave = (await sha256(JSON.stringify([codigo, e.idCompra ?? e.id_compra, e.numeroItemCompra ?? e.numero_item_compra, e.valorUnitario ?? e.precoUnitario, e.dataResultado ?? e.dataCompra]))).slice(0, 32);
        const ni = (e.niFornecedor ?? e.cnpjFornecedor ?? e.cpfCnpjFornecedor ?? "").toString().replace(/\D/g, "") || null;
        await sql`insert into bolsa.precos_praticados (tipo, catalogo_codigo, chave_dedup, descricao_item, valor_unitario, quantidade,
                    unidade, data_compra, data_resultado, orgao_nome, uasg_codigo, uasg_nome, uf, municipio_nome,
                    fornecedor_ni, fornecedor_nome, modalidade_nome, numero_processo, source_payload, last_seen_at)
                  values (${tipo}, ${codigo}, ${chave}, ${e.descricaoItem ?? e.descricao ?? null},
                    ${e.valorUnitario ?? e.precoUnitario ?? null}, ${e.quantidade ?? null}, ${e.siglaUnidadeFornecimento ?? e.unidadeMedida ?? null},
                    ${e.dataCompra ?? null}, ${e.dataResultado ?? null}, ${e.nomeOrgao ?? e.orgao ?? null},
                    ${e.codigoUasg != null ? String(e.codigoUasg) : null}, ${e.nomeUasg ?? null},
                    ${e.estado ?? e.siglaUf ?? null}, ${e.municipio ?? e.nomeMunicipio ?? null},
                    ${ni}, ${e.nomeFornecedor ?? e.fornecedor ?? null}, ${e.nomeModalidade ?? e.modalidade ?? null},
                    ${e.idCompra != null ? String(e.idCompra) : null}, ${JSON.stringify(e)}::jsonb, now())
                  on conflict (fonte_id, chave_dedup) do update set last_seen_at = now()`;
        stats.precos++; stats.registros++;
      } catch (er) { stats.erros++; nota(stats, "preco: " + String((er as Error).message)); }
    }
    await sleep(150);
  }
}

async function jobArpSaldo(p: any, stats: Stats, deadline: number) {
  const alvos = await sql`
    select a.numero_ata, a.unidade_codigo from bolsa.atas a
    where a.numero_ata is not null and a.unidade_codigo is not null and a.cancelado is not true
      and not exists (select 1 from bolsa.arp_saldos s where s.numero_ata = a.numero_ata and s.unidade_gerenciadora = a.unidade_codigo)
    order by a.vigencia_fim desc nulls last limit ${p.maxAtas ?? 4}`;
  for (const alvo of alvos) {
    if (Date.now() > deadline) { nota(stats, "tempo esgotado (arp)"); break; }
    const url = `${BASE}/modulo-arp/4_consultarEmpenhosSaldoItem?pagina=1&tamanhoPagina=50&numeroAta=${encodeURIComponent(alvo.numero_ata)}&unidadeGerenciadora=${encodeURIComponent(alvo.unidade_codigo)}`;
    const r = await fetchJson(url, stats, "arp_saldo");
    if (!r.ok) continue;
    const linhas: any[] = Array.isArray(r.body?.resultado) ? r.body.resultado : [];
    if (!linhas.length) {
      await sql`insert into bolsa.arp_saldos (numero_ata, unidade_gerenciadora, chave_dedup, source_payload, last_seen_at)
                values (${alvo.numero_ata}, ${alvo.unidade_codigo}, 'sem-registros', ${JSON.stringify({ resultado: [] })}::jsonb, now())
                on conflict (numero_ata, unidade_gerenciadora, chave_dedup) do update set last_seen_at = now()`;
      continue;
    }
    stats.paginas++;
    for (const e of linhas) {
      try {
        const chave = (await sha256(JSON.stringify(e))).slice(0, 32);
        await sql`insert into bolsa.arp_saldos (numero_ata, unidade_gerenciadora, chave_dedup, numero_item, catalogo_codigo,
                    quantidade_registrada, quantidade_empenhada, saldo, valor_unitario, source_payload, last_seen_at)
                  values (${alvo.numero_ata}, ${alvo.unidade_codigo}, ${chave},
                    ${e.numeroItem ?? e.numero_item ?? null}, ${e.codigoItem != null ? String(e.codigoItem) : null},
                    ${e.quantidadeRegistrada ?? e.quantidade ?? null}, ${e.quantidadeEmpenhada ?? null},
                    ${e.saldo ?? e.saldoItem ?? null}, ${e.valorUnitario ?? null}, ${JSON.stringify(e)}::jsonb, now())
                  on conflict (numero_ata, unidade_gerenciadora, chave_dedup) do update set
                    saldo = excluded.saldo, source_payload = excluded.source_payload, last_seen_at = now()`;
        stats.saldos++; stats.registros++;
      } catch (er) { stats.erros++; nota(stats, "saldo: " + String((er as Error).message)); }
    }
    await sleep(150);
  }
}

Deno.serve(async (req: Request) => {
  let p: any = {};
  try { p = await req.json(); } catch (_) { /* vazio */ }
  const job: string = p.job ?? "catalogo";
  const stats: Stats = { paginas: 0, registros: 0, inseridos: 0, atualizados: 0, ignorados: 0, erros: 0, catalogo: 0, precos: 0, saldos: 0, detalhes: [] };
  const deadline = Date.now() + (p.orcamentoMs ?? 35000);
  let logId: number | null = null;
  try { const r = await sql`insert into bolsa.coleta_log (fonte_id, job) values ('compras_gov', ${job}) returning id`; logId = r[0].id; } catch (e) { nota(stats, String((e as Error).message)); }
  try {
    if (job === "catalogo") { await jobCatalogo(p, stats, deadline); await jobPrecos(p, stats, deadline); }
    else if (job === "precos") await jobPrecos(p, stats, deadline);
    else if (job === "arp_saldo") await jobArpSaldo(p, stats, deadline);
    else return new Response(JSON.stringify({ erro: "job desconhecido" }), { status: 400 });
    const statusFonte = stats.erros > 0 && stats.registros === 0 ? "TEMPORARILY_UNAVAILABLE" : "ATIVA";
    await sql`update bolsa.fontes set status = ${statusFonte}, ultimo_sucesso_em = case when ${statusFonte === "ATIVA"} then now() else ultimo_sucesso_em end where id = 'compras_gov'`;
  } catch (e) { stats.erros++; nota(stats, "excecao: " + String((e as Error).message)); }
  if (logId != null) {
    try {
      await sql`update bolsa.coleta_log set finalizado_em = now(), paginas = ${stats.paginas}, registros = ${stats.registros},
                inseridos = ${stats.inseridos}, atualizados = ${stats.atualizados}, ignorados = ${stats.ignorados}, erros = ${stats.erros},
                detalhe = ${JSON.stringify({ job, params: p, catalogo: stats.catalogo, precos: stats.precos, saldos: stats.saldos, notas: stats.detalhes })}::jsonb
                where id = ${logId}`;
    } catch { /* não fatal */ }
  }
  return new Response(JSON.stringify({ ok: true, job, ...stats }), { headers: { "content-type": "application/json" } });
});
