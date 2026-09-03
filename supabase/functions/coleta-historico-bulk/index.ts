// ============================================================
// BOLSA DE LICITAÇÕES — Memória Histórica: importador BULK v2
// 1) job "descobrir": sonda programaticamente a cobertura real
//    (earliest/latest) das fontes de arquivos oficiais (§3, §70)
//    — Portal da Transparência (ZIPs mensais) e repositórios de
//    listagem (Compras.gov / Contratos.gov) — e registra tudo em
//    bolsa.fontes_cobertura / bolsa.arquivos_historicos.
// 2) job "transparencia_mes": baixa o ZIP mensal de licitações do
//    Portal da Transparência (público, sem chave), importa
//    Licitação + ItemLicitação + Participantes + EmpenhosRelacionados
//    em lote (unnest) para bolsa.licitacoes_legado / itens_legado /
//    participacoes / empenhos_licitacao. Linha ruim vai para
//    bolsa.import_erros — nunca derruba o arquivo (§74).
// 3) job "auto": pega o próximo arquivo AGENDADO e importa.
// Idempotente (§72): reimportar um mês não duplica.
// ============================================================
import postgres from "npm:postgres@3.4.5";
import { unzipSync } from "npm:fflate@0.8.2";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 20, connect_timeout: 10 });
const UA = "BolsaLicitacoes/0.1 (memoria historica de dados publicos; +https://github.com/Marcoslide/Licita-es)";
const TRANSP = "https://portaldatransparencia.gov.br/download-de-dados/licitacoes";
const PARSER_VERSION = 1;

const norm = (s: string) => s.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().trim();
const brNum = (s: string | undefined): number | null => {
  if (!s) return null;
  const t = s.trim().replace(/\./g, "").replace(",", ".").replace(/[^0-9.\-]/g, "");
  const n = Number(t);
  return Number.isFinite(n) && t !== "" ? n : null;
};
const brData = (s: string | undefined): string | null => {
  if (!s) return null;
  const m = s.trim().match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  return m ? `${m[3]}-${m[2]}-${m[1]}` : null;
};
async function sha256hex(buf: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", buf as BufferSource);
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// CSV ';' com aspas (sem quebras de linha dentro de campos — desvios vão para import_erros)
function parseCsvLinha(l: string): string[] {
  const out: string[] = [];
  let cur = "", dentro = false;
  for (let i = 0; i < l.length; i++) {
    const ch = l[i];
    if (dentro) {
      if (ch === '"') { if (l[i + 1] === '"') { cur += '"'; i++; } else dentro = false; }
      else cur += ch;
    } else {
      if (ch === '"') dentro = true;
      else if (ch === ";") { out.push(cur); cur = ""; }
      else cur += ch;
    }
  }
  out.push(cur);
  return out;
}

function acharCol(headers: string[], ...pedacos: string[][]): number {
  for (const alt of pedacos) {
    const idx = headers.findIndex((h) => alt.every((p) => h.includes(p)));
    if (idx >= 0) return idx;
  }
  return -1;
}

async function sondar(url: string): Promise<{ ok: boolean; status: number; tamanho: number | null; range: boolean }> {
  try {
    const r = await fetch(url, { method: "GET", headers: { "user-agent": UA, range: "bytes=0-0" }, signal: AbortSignal.timeout(20000) });
    const cr = r.headers.get("content-range"); // "bytes 0-0/12345"
    const tamanho = cr ? Number(cr.split("/")[1]) : (r.headers.get("content-length") ? Number(r.headers.get("content-length")) : null);
    await r.body?.cancel();
    return { ok: r.ok, status: r.status, tamanho: Number.isFinite(tamanho as number) ? tamanho : null, range: r.status === 206 };
  } catch { return { ok: false, status: 0, tamanho: null, range: false }; }
}

// ---------- DESCOBRIR (§3): cobertura real por sondagem ----------
async function jobDescobrir(deadline: number): Promise<Record<string, unknown>> {
  const out: Record<string, unknown> = {};

  // 1) Transparência: sonda meses de referência para achar earliest/latest reais
  const agora = new Date();
  const pontos: string[] = [];
  for (let a = agora.getUTCFullYear(); a >= 2010 && pontos.length < 20; a--) pontos.push(`${a}01`);
  const ultimoFechado = (() => { const d = new Date(Date.UTC(agora.getUTCFullYear(), agora.getUTCMonth(), 1)); d.setUTCMonth(d.getUTCMonth() - 1); return `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, "0")}`; })();
  const okMeses: string[] = []; const falhaMeses: string[] = [];
  const rUlt = await sondar(`${TRANSP}/${ultimoFechado}`);
  if (rUlt.ok) okMeses.push(ultimoFechado); else falhaMeses.push(ultimoFechado);
  for (const p of pontos) {
    if (Date.now() > deadline) break;
    const r = await sondar(`${TRANSP}/${p}`);
    (r.ok ? okMeses : falhaMeses).push(p);
    if (r.ok && r.tamanho) {
      await sql`insert into bolsa.arquivos_historicos (fonte, dataset, ano, mes, url, tamanho_bytes, aceita_range)
                values ('transparencia', 'licitacoes_zip', ${Number(p.slice(0, 4))}, ${Number(p.slice(4, 6))}, ${`${TRANSP}/${p}`}, ${r.tamanho}, ${r.range})
                on conflict (url) do update set tamanho_bytes = excluded.tamanho_bytes, aceita_range = excluded.aceita_range`;
    }
    await new Promise((res) => setTimeout(res, 150));
  }
  const earliestT = okMeses.sort()[0] ?? null;
  const latestT = okMeses.sort().at(-1) ?? null;
  await sql`insert into bolsa.fontes_cobertura (fonte, dataset, earliest_available, latest_available, metodo, detalhe)
            values ('transparencia', 'licitacoes_zip', ${earliestT}, ${latestT},
                    'sondagem GET Range bytes=0-0 em janeiro de cada ano + último mês fechado',
                    ${JSON.stringify({ meses_ok: okMeses, meses_falha: falhaMeses })}::jsonb)
            on conflict (fonte, dataset) do update set earliest_available = excluded.earliest_available,
              latest_available = excluded.latest_available, metodo = excluded.metodo,
              detalhe = excluded.detalhe, verificado_em = now()`;
  out.transparencia = { earliest: earliestT, latest: latestT, ok: okMeses.length, falhas: falhaMeses.length };

  // 2) Repositórios de listagem (Compras.gov / Contratos.gov): coleta os links reais
  // caminhos confirmados pela listagem real da raiz /seges/ (descoberta anterior)
  const listagens = [
    { fonte: "compras_gov", dataset: "repositorio_seges", url: "https://repositorio.dados.gov.br/seges/" },
    { fonte: "compras_gov", dataset: "comprasgov_arquivos", url: "https://repositorio.dados.gov.br/seges/comprasgov/" },
    { fonte: "compras_gov", dataset: "lances_pregao", url: "https://repositorio.dados.gov.br/seges/lances_pregao/" },
    { fonte: "contratos_gov", dataset: "comprasnet_contratos", url: "https://repositorio.dados.gov.br/seges/comprasnet_contratos/" },
  ];
  for (const L of listagens) {
    if (Date.now() > deadline) break;
    try {
      const r = await fetch(L.url, { headers: { "user-agent": UA }, signal: AbortSignal.timeout(20000) });
      const html = r.ok ? await r.text() : "";
      const hrefs = [...html.matchAll(/href="([^"?][^"]*)"/g)].map((m) => m[1])
        .filter((h) => !h.startsWith("/") && h !== "../");
      const dirs = hrefs.filter((h) => h.endsWith("/")).slice(0, 40);
      const arquivos = hrefs.filter((h) => /\.(csv|zip|xlsx|json)$/i.test(h)).slice(0, 60);
      const anos = [...new Set([...hrefs.join(" ").matchAll(/(20[0-2]\d)/g)].map((m) => m[1]))].sort();
      await sql`insert into bolsa.fontes_cobertura (fonte, dataset, earliest_available, latest_available, metodo, detalhe)
                values (${L.fonte}, ${L.dataset}, ${anos[0] ?? null}, ${anos.at(-1) ?? null},
                        ${"listagem HTML de " + L.url + " (HTTP " + r.status + ")"},
                        ${JSON.stringify({ http: r.status, diretorios: dirs, arquivos: arquivos.slice(0, 30) })}::jsonb)
                on conflict (fonte, dataset) do update set earliest_available = excluded.earliest_available,
                  latest_available = excluded.latest_available, metodo = excluded.metodo,
                  detalhe = excluded.detalhe, verificado_em = now()`;
      for (const a of arquivos.slice(0, 25)) {
        const urlAbs = L.url + a;
        const anoM = a.match(/(20[0-2]\d)/);
        await sql`insert into bolsa.arquivos_historicos (fonte, dataset, ano, url)
                  values (${L.fonte}, ${L.dataset}, ${anoM ? Number(anoM[1]) : null}, ${urlAbs})
                  on conflict (url) do nothing`;
      }
      (out as any)[L.dataset] = { http: r.status, dirs: dirs.length, arquivos: arquivos.length };
    } catch (e) {
      (out as any)[L.dataset] = { erro: String((e as Error).message) };
      await sql`insert into bolsa.fontes_cobertura (fonte, dataset, metodo, detalhe)
                values (${L.fonte}, ${L.dataset}, ${"listagem falhou: " + L.url},
                        ${JSON.stringify({ erro: String((e as Error).message) })}::jsonb)
                on conflict (fonte, dataset) do update set metodo = excluded.metodo,
                  detalhe = excluded.detalhe, verificado_em = now()`;
    }
  }
  return out;
}

// ---------- IMPORTAÇÃO TRANSPARÊNCIA (mês) ----------
interface Cnt { lics: number; itens: number; parts: number; emps: number; erros: number }

async function importarTransparenciaMes(ano: number, mes: number, deadline: number): Promise<Record<string, unknown>> {
  const ym = `${ano}${String(mes).padStart(2, "0")}`;
  const url = `${TRANSP}/${ym}`;
  const arqRows = await sql`insert into bolsa.arquivos_historicos (fonte, dataset, ano, mes, url, import_status)
    values ('transparencia', 'licitacoes_zip', ${ano}, ${mes}, ${url}, 'IMPORTANDO')
    on conflict (url) do update set import_status = 'IMPORTANDO', parser_version = ${PARSER_VERSION}
    returning id, linhas_processadas`;
  const arqId = arqRows[0].id;

  const resp = await fetch(url, { headers: { "user-agent": UA }, signal: AbortSignal.timeout(60000) });
  if (!resp.ok) {
    await resp.body?.cancel();
    await sql`update bolsa.arquivos_historicos set import_status = 'ERRO',
              detalhe = detalhe || ${JSON.stringify({ http: resp.status })}::jsonb where id = ${arqId}`;
    return { ym, erro: `HTTP ${resp.status}` };
  }
  const buf = new Uint8Array(await resp.arrayBuffer());
  const hash = await sha256hex(buf);
  await sql`update bolsa.arquivos_historicos set tamanho_bytes = ${buf.length}, sha256 = ${hash}, baixado_em = now() where id = ${arqId}`;

  const zip = unzipSync(buf);
  const dec = new TextDecoder("iso-8859-1");
  const nomes = Object.keys(zip);
  const cnt: Cnt = { lics: 0, itens: 0, parts: 0, emps: 0, erros: 0 };
  const detArquivos: Record<string, number> = {};

  const fLic = nomes.find((n) => { const nn = norm(n); return nn.includes("licitac") && !nn.includes("item") && !nn.includes("particip") && !nn.includes("empenho"); });
  const fItem = nomes.find((n) => norm(n).includes("item"));
  const fPart = nomes.find((n) => norm(n).includes("particip"));
  const fEmp = nomes.find((n) => norm(n).includes("empenho"));

  // chave comum entre os 4 arquivos do mês
  const chaveDe = (cols: string[], iNum: number, iUg: number, iMod: number) =>
    `${(cols[iUg] ?? "").trim()}:${norm(cols[iMod] ?? "").slice(0, 12)}:${(cols[iNum] ?? "").trim()}`;

  // ---- Licitação ----
  if (fLic) {
    const linhas = dec.decode(zip[fLic]).split(/\r?\n/).filter((l) => l.length > 0);
    const H = parseCsvLinha(linhas[0]).map(norm);
    const iNum = acharCol(H, ["numero", "licitac"]);
    const iUg = acharCol(H, ["codigo", "ug"]);
    const iNomeUg = acharCol(H, ["nome", "ug"]);
    const iOrgC = acharCol(H, ["codigo", "orgao"]);
    const iOrgN = H.findIndex((h) => h.includes("nome") && h.includes("orgao") && !h.includes("superior"));
    const iMod = acharCol(H, ["modalidade"]);
    const iProc = acharCol(H, ["processo"]);
    const iObj = acharCol(H, ["objeto"]);
    const iSit = acharCol(H, ["situacao"]);
    const iVal = acharCol(H, ["valor"]);
    const iDtRes = acharCol(H, ["data", "resultado"]);
    const iDtAb = acharCol(H, ["data", "abertura"]);
    const iMun = acharCol(H, ["municipio"]);
    detArquivos[fLic] = linhas.length - 1;
    for (let ini = 1; ini < linhas.length; ini += 400) {
      if (Date.now() > deadline) break;
      const lote = linhas.slice(ini, ini + 400);
      const a = { ch: [] as string[], mod: [] as (string | null)[], num: [] as (string | null)[], proc: [] as (string | null)[],
        orgC: [] as (string | null)[], orgN: [] as (string | null)[], ug: [] as (string | null)[], ugN: [] as (string | null)[],
        mun: [] as (string | null)[], obj: [] as (string | null)[], sit: [] as (string | null)[],
        val: [] as (number | null)[], dtR: [] as (string | null)[], dtA: [] as (string | null)[] };
      for (let k = 0; k < lote.length; k++) {
        try {
          const c = parseCsvLinha(lote[k]);
          if (c.length < 4 || iNum < 0 || iUg < 0) throw new Error("colunas insuficientes");
          a.ch.push(chaveDe(c, iNum, iUg, iMod));
          a.mod.push(c[iMod] ?? null); a.num.push(c[iNum] ?? null); a.proc.push(iProc >= 0 ? c[iProc] : null);
          a.orgC.push(iOrgC >= 0 ? c[iOrgC] : null); a.orgN.push(iOrgN >= 0 ? c[iOrgN] : null);
          a.ug.push(c[iUg] ?? null); a.ugN.push(iNomeUg >= 0 ? c[iNomeUg] : null);
          a.mun.push(iMun >= 0 ? c[iMun] : null); a.obj.push(iObj >= 0 ? c[iObj] : null);
          a.sit.push(iSit >= 0 ? c[iSit] : null); a.val.push(iVal >= 0 ? brNum(c[iVal]) : null);
          a.dtR.push(iDtRes >= 0 ? brData(c[iDtRes]) : null); a.dtA.push(iDtAb >= 0 ? brData(c[iDtAb]) : null);
        } catch (e) {
          cnt.erros++;
          await sql`insert into bolsa.import_erros (arquivo_id, linha_num, erro, conteudo)
                    values (${arqId}, ${ini + k}, ${String((e as Error).message)}, ${lote[k].slice(0, 400)})`;
        }
      }
      if (a.ch.length) {
        await sql`insert into bolsa.licitacoes_legado (fonte, chave_fonte, ano, modalidade, numero, processo,
                    orgao_codigo, orgao_nome, ug_codigo, ug_nome, municipio, objeto, situacao, valor, data_resultado, data_abertura)
                  select distinct on (ch) 'transparencia', ch, ${ano}, mo, nu, pr, oc, onm, ug, ugn, mu, ob, si, va, dr::date, da::date
                  from unnest(${a.ch}::text[], ${a.mod}::text[], ${a.num}::text[], ${a.proc}::text[],
                              ${a.orgC}::text[], ${a.orgN}::text[], ${a.ug}::text[], ${a.ugN}::text[],
                              ${a.mun}::text[], ${a.obj}::text[], ${a.sit}::text[], ${a.val}::numeric[],
                              ${a.dtR}::text[], ${a.dtA}::text[])
                    as t(ch, mo, nu, pr, oc, onm, ug, ugn, mu, ob, si, va, dr, da)
                  on conflict (fonte, chave_fonte) do update set
                    situacao = excluded.situacao, valor = excluded.valor,
                    data_resultado = excluded.data_resultado, last_seen_at = now()`;
        cnt.lics += a.ch.length;
      }
    }
  }

  // ---- ItemLicitação ----
  if (fItem && Date.now() < deadline) {
    const linhas = dec.decode(zip[fItem]).split(/\r?\n/).filter((l) => l.length > 0);
    const H = parseCsvLinha(linhas[0]).map(norm);
    const iNum = acharCol(H, ["numero", "licitac"]);
    const iUg = acharCol(H, ["codigo", "ug"]);
    const iMod = acharCol(H, ["modalidade"]);
    const iCod = acharCol(H, ["codigo", "item"]);
    const iDesc = acharCol(H, ["descric"]);
    const iQtd = acharCol(H, ["quantidade"]);
    const iVal = acharCol(H, ["valor", "item"], ["valor"]);
    const iVenc = acharCol(H, ["vencedor"], ["cnpj"]);
    const iVencN = H.findIndex((h) => h.includes("nome") && (h.includes("vencedor") || h.includes("fornecedor")));
    detArquivos[fItem] = linhas.length - 1;
    for (let ini = 1; ini < linhas.length; ini += 400) {
      if (Date.now() > deadline) break;
      const lote = linhas.slice(ini, ini + 400);
      const a = { ch: [] as string[], ni: [] as (string | null)[], de: [] as (string | null)[],
        qt: [] as (number | null)[], vu: [] as (number | null)[], ve: [] as (string | null)[], vn: [] as (string | null)[] };
      for (let k = 0; k < lote.length; k++) {
        try {
          const c = parseCsvLinha(lote[k]);
          if (c.length < 4 || iNum < 0 || iUg < 0) throw new Error("colunas insuficientes");
          a.ch.push(chaveDe(c, iNum, iUg, iMod));
          a.ni.push(iCod >= 0 ? c[iCod] : null);
          a.de.push(iDesc >= 0 ? c[iDesc] : null);
          a.qt.push(iQtd >= 0 ? brNum(c[iQtd]) : null);
          a.vu.push(iVal >= 0 ? brNum(c[iVal]) : null);
          a.ve.push(iVenc >= 0 ? (c[iVenc] ?? "").replace(/\D/g, "") || null : null);
          a.vn.push(iVencN >= 0 ? c[iVencN] : null);
        } catch (e) {
          cnt.erros++;
          await sql`insert into bolsa.import_erros (arquivo_id, linha_num, erro, conteudo)
                    values (${arqId}, ${ini + k}, ${"item: " + String((e as Error).message)}, ${lote[k].slice(0, 400)})`;
        }
      }
      if (a.ch.length) {
        await sql`insert into bolsa.itens_legado (fonte, licitacao_chave, numero_item, descricao, quantidade, valor_unitario, vencedor_ni, vencedor_nome, ano)
                  select distinct on (ch, ni, ve) 'transparencia', ch, ni, de, qt, vu, ve, vn, ${ano}
                  from unnest(${a.ch}::text[], ${a.ni}::text[], ${a.de}::text[], ${a.qt}::numeric[],
                              ${a.vu}::numeric[], ${a.ve}::text[], ${a.vn}::text[])
                    as t(ch, ni, de, qt, vu, ve, vn)
                  on conflict (fonte, licitacao_chave, item_key, vend_key) do update set
                    descricao = excluded.descricao, quantidade = excluded.quantidade,
                    valor_unitario = excluded.valor_unitario`;
        cnt.itens += a.ch.length;
      }
    }
  }

  // ---- ParticipantesLicitação (§13-14: participar ≠ vencer) ----
  if (fPart && Date.now() < deadline) {
    const linhas = dec.decode(zip[fPart]).split(/\r?\n/).filter((l) => l.length > 0);
    const H = parseCsvLinha(linhas[0]).map(norm);
    const iNum = acharCol(H, ["numero", "licitac"]);
    const iUg = acharCol(H, ["codigo", "ug"]);
    const iMod = acharCol(H, ["modalidade"]);
    const iCnpj = acharCol(H, ["cnpj"], ["participante", "codigo"]);
    const iNome = H.findIndex((h) => h.includes("nome") && h.includes("participante"));
    const iItem = acharCol(H, ["codigo", "item"]);
    const iVencFlag = H.findIndex((h) => h.includes("vencedor"));
    detArquivos[fPart] = linhas.length - 1;
    for (let ini = 1; ini < linhas.length; ini += 500) {
      if (Date.now() > deadline) break;
      const lote = linhas.slice(ini, ini + 500);
      const a = { ch: [] as string[], it: [] as (string | null)[], ni: [] as (string | null)[],
        nm: [] as (string | null)[], si: [] as string[] };
      for (let k = 0; k < lote.length; k++) {
        try {
          const c = parseCsvLinha(lote[k]);
          if (c.length < 3 || iNum < 0 || iUg < 0 || iCnpj < 0) throw new Error("colunas insuficientes");
          a.ch.push(chaveDe(c, iNum, iUg, iMod));
          a.it.push(iItem >= 0 ? c[iItem] : null);
          a.ni.push((c[iCnpj] ?? "").replace(/\D/g, "") || null);
          a.nm.push(iNome >= 0 ? c[iNome] : null);
          a.si.push(iVencFlag >= 0 && /^s(im)?$/i.test((c[iVencFlag] ?? "").trim()) ? "vencedor" : "participou");
        } catch (e) {
          cnt.erros++;
          await sql`insert into bolsa.import_erros (arquivo_id, linha_num, erro, conteudo)
                    values (${arqId}, ${ini + k}, ${"part: " + String((e as Error).message)}, ${lote[k].slice(0, 400)})`;
        }
      }
      if (a.ch.length) {
        await sql`insert into bolsa.participacoes (fonte, licitacao_chave, item_numero, fornecedor_ni, fornecedor_nome, situacao, ano)
                  select 'transparencia', ch, it, ni, nm, si, ${ano}
                  from unnest(${a.ch}::text[], ${a.it}::text[], ${a.ni}::text[], ${a.nm}::text[], ${a.si}::text[])
                    as t(ch, it, ni, nm, si)
                  on conflict (fonte, licitacao_chave, item_key, forn_key, situacao) do nothing`;
        cnt.parts += a.ch.length;
      }
    }
  }

  // ---- EmpenhosRelacionados ----
  if (fEmp && Date.now() < deadline) {
    const linhas = dec.decode(zip[fEmp]).split(/\r?\n/).filter((l) => l.length > 0);
    const H = parseCsvLinha(linhas[0]).map(norm);
    const iNum = acharCol(H, ["numero", "licitac"]);
    const iUg = acharCol(H, ["codigo", "ug"]);
    const iMod = acharCol(H, ["modalidade"]);
    const iEmp = acharCol(H, ["empenho"]);
    const iDt = acharCol(H, ["data", "emissao"], ["data"]);
    const iVal = acharCol(H, ["valor"]);
    const iFavN = H.findIndex((h) => h.includes("favorecido") && h.includes("nome"));
    const iFavC = H.findIndex((h) => h.includes("favorecido") && (h.includes("codigo") || h.includes("cnpj")));
    detArquivos[fEmp] = linhas.length - 1;
    for (let ini = 1; ini < linhas.length; ini += 500) {
      if (Date.now() > deadline) break;
      const lote = linhas.slice(ini, ini + 500);
      const a = { ch: [] as string[], em: [] as string[], dt: [] as (string | null)[],
        va: [] as (number | null)[], fc: [] as (string | null)[], fn: [] as (string | null)[] };
      for (let k = 0; k < lote.length; k++) {
        try {
          const c = parseCsvLinha(lote[k]);
          if (c.length < 3 || iNum < 0 || iUg < 0 || iEmp < 0) throw new Error("colunas insuficientes");
          const emp = (c[iEmp] ?? "").trim();
          if (!emp) throw new Error("empenho vazio");
          a.ch.push(chaveDe(c, iNum, iUg, iMod));
          a.em.push(emp);
          a.dt.push(iDt >= 0 ? brData(c[iDt]) : null);
          a.va.push(iVal >= 0 ? brNum(c[iVal]) : null);
          a.fc.push(iFavC >= 0 ? (c[iFavC] ?? "").replace(/\D/g, "") || null : null);
          a.fn.push(iFavN >= 0 ? c[iFavN] : null);
        } catch (e) {
          cnt.erros++;
          await sql`insert into bolsa.import_erros (arquivo_id, linha_num, erro, conteudo)
                    values (${arqId}, ${ini + k}, ${"emp: " + String((e as Error).message)}, ${lote[k].slice(0, 400)})`;
        }
      }
      if (a.ch.length) {
        await sql`insert into bolsa.empenhos_licitacao (fonte, licitacao_chave, empenho_codigo, data_emissao, valor, favorecido_ni, favorecido_nome, ano)
                  select distinct on (ch, em) 'transparencia', ch, em, dt::date, va, fc, fn, ${ano}
                  from unnest(${a.ch}::text[], ${a.em}::text[], ${a.dt}::text[], ${a.va}::numeric[],
                              ${a.fc}::text[], ${a.fn}::text[])
                    as t(ch, em, dt, va, fc, fn)
                  on conflict (fonte, licitacao_chave, empenho_codigo) do update set
                    valor = excluded.valor, data_emissao = excluded.data_emissao`;
        cnt.emps += a.ch.length;
      }
    }
  }

  const completo = Date.now() < deadline;
  await sql`update bolsa.arquivos_historicos set
      import_status = ${completo ? "IMPORTADO" : "AGENDADO"},
      linhas_processadas = ${cnt.lics + cnt.itens + cnt.parts + cnt.emps},
      inseridos = ${cnt.lics + cnt.itens + cnt.parts + cnt.emps},
      erros = erros + ${cnt.erros},
      finalizado_em = case when ${completo} then now() else null end,
      detalhe = detalhe || ${JSON.stringify({ arquivos_no_zip: nomes, contagem_por_arquivo: detArquivos, parcial: !completo })}::jsonb
    where id = ${arqId}`;

  await sql`insert into bolsa.memoria_anos (ano, fonte, status, relatorio)
            values (${ano}, 'transparencia', 'PARCIAL', ${JSON.stringify({ ultimo_mes_importado: ym })}::jsonb)
            on conflict (ano, fonte) do update set relatorio = memoria_anos.relatorio || excluded.relatorio, atualizado_em = now()`;

  return { ym, zip_bytes: buf.length, sha256: hash.slice(0, 16), ...cnt, completo };
}

// ---------- AUTO: próximo arquivo agendado ----------
async function jobAuto(deadline: number): Promise<Record<string, unknown>> {
  const r = await sql`select id, fonte, dataset, ano, mes from bolsa.arquivos_historicos
                      where import_status = 'AGENDADO' and fonte = 'transparencia'
                      order by ano desc, mes desc limit 1`;
  if (!r.length) return { fila: "vazia" };
  return await importarTransparenciaMes(r[0].ano, r[0].mes, deadline);
}

Deno.serve(async (req: Request) => {
  let p: any = {};
  try { p = await req.json(); } catch { /* corpo vazio */ }
  const deadline = Date.now() + (p.orcamentoMs ?? 50000);
  const job = p.job ?? "auto";
  let out: Record<string, unknown> = {};
  try {
    if (job === "descobrir") out = await jobDescobrir(deadline);
    else if (job === "listar") {
      // exploração genérica de um diretório de repositório, sem redeploy
      const alvo = String(p.url ?? "");
      if (!/^https:\/\/repositorio\.dados\.gov\.br\//.test(alvo)) out = { erro: "url fora do repositório oficial" };
      else {
        const r = await fetch(alvo, { headers: { "user-agent": UA }, signal: AbortSignal.timeout(25000) });
        const html = r.ok ? await r.text() : "";
        const hrefs = [...html.matchAll(/href="([^"?][^"]*)"/g)].map((m) => m[1]).filter((h) => !h.startsWith("/") && h !== "../");
        out = { http: r.status, diretorios: hrefs.filter((h) => h.endsWith("/")).slice(0, 60),
                arquivos: hrefs.filter((h) => !h.endsWith("/")).slice(0, 80) };
      }
    }
    else if (job === "transparencia_mes") out = await importarTransparenciaMes(Number(p.ano), Number(p.mes), deadline);
    else if (job === "auto") out = await jobAuto(deadline);
    else out = { erro: "job desconhecido" };
  } catch (e) {
    out = { erro: String((e as Error).message) };
  }
  return new Response(JSON.stringify({ ok: true, job, ...out }), { headers: { "content-type": "application/json" } });
});
