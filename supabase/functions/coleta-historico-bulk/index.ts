// ============================================================
// BOLSA DE LICITAÇÕES — Memória Histórica: importador BULK v12
// (estados PENDING/DOWNLOADING/IMPORTING/VALIDATING/COMPLETE/PARTIAL/
//  SOURCE_NOT_AVAILABLE/FAILED; retomada intra-mês por fase/linha;
//  CSV anual por Range com registros multiline; filas independentes por
//  fonte (p.fonte) com lease anti-colisão; brutos no bucket memoria-bruta;
//  parsers Contratos.gov (contratos + empenhos de contrato))
// v12: todo merge em detalhe usa guard jsonb_typeof='object' — um detalhe
//  corrompido (array/string) se auto-corrige em vez de quebrar lease/mapa
//  para sempre; mapa nunca é gravado como null; tamanho_bytes vem do
//  Content-Range; falha de upload do bruto fica registrada em detalhe.
//  Cada fila roda no seu próprio slug (bulk=compras, -transp, -contratos)
//  para não dividir o orçamento de CPU do isolate entre filas.
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
function parseCsvLinha(l: string, sep = ";"): string[] {
  if (!l.includes('"')) return l.split(sep); // fast-path: split nativo poupa CPU do worker
  const out: string[] = [];
  let cur = "", dentro = false;
  for (let i = 0; i < l.length; i++) {
    const ch = l[i];
    if (dentro) {
      if (ch === '"') { if (l[i + 1] === '"') { cur += '"'; i++; } else dentro = false; }
      else cur += ch;
    } else {
      if (ch === '"') dentro = true;
      else if (ch === sep) { out.push(cur); cur = ""; }
      else cur += ch;
    }
  }
  out.push(cur);
  return out;
}

// CSVs oficiais têm campos com quebra de linha dentro de aspas: junta as
// linhas físicas em registros lógicos (aspas balanceadas). `pendente` é um
// registro ainda aberto no fim do bloco (vai para resto_linha no modo Range).
function normalizarRegistros(linhas: string[]): { completos: string[]; pendente: string | null } {
  const out: string[] = [];
  let buf: string | null = null;
  let impar = false;
  for (const l of linhas) {
    // fast-path (CPU do worker): linha sem aspas nem registro aberto passa direto
    if (buf === null && l.indexOf('"') === -1) { out.push(l); continue; }
    let q = 0;
    for (let i = l.indexOf('"'); i >= 0; i = l.indexOf('"', i + 1)) q++;
    if (buf === null) {
      if (q % 2 === 0) out.push(l);
      else { buf = l; impar = true; }
    } else {
      buf += "\n" + l;
      if (q % 2 === 1) impar = !impar;
      if (!impar) { out.push(buf); buf = null; }
    }
  }
  return { completos: out, pendente: buf };
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
                    ${{ meses_ok: okMeses, meses_falha: falhaMeses }}::jsonb)
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
                        ${{ http: r.status, diretorios: dirs, arquivos: arquivos.slice(0, 30) }}::jsonb)
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
                        ${{ erro: String((e as Error).message) }}::jsonb)
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
    values ('transparencia', 'licitacoes_zip', ${ano}, ${mes}, ${url}, 'DOWNLOADING')
    on conflict (url) do update set import_status = 'DOWNLOADING', parser_version = ${PARSER_VERSION}
    returning id, detalhe`;
  const arqId = arqRows[0].id;
  // retomada intra-mês (§59): {fase: lic|item|part|emp, linha: N}
  const curIni = (arqRows[0].detalhe?.cursor as { fase?: string; linha?: number }) ?? {};
  const ordemFases = ["lic", "item", "part", "emp"];
  const faseIni = ordemFases.includes(curIni.fase ?? "") ? curIni.fase! : "lic";
  const linhaIni = Number(curIni.linha ?? 1) || 1;
  let cortouEm: { fase: string; linha: number } | null = null;
  const pulaFase = (f: string) => ordemFases.indexOf(f) < ordemFases.indexOf(faseIni);
  const inicioDa = (f: string) => (f === faseIni ? linhaIni : 1);
  const salvaCursor = async (f: string, linha: number) => {
    cortouEm = { fase: f, linha };
    await sql`update bolsa.arquivos_historicos set detalhe = (case when jsonb_typeof(detalhe) = 'object' then detalhe else '{}'::jsonb end) || ${{ cursor: cortouEm }}::jsonb where id = ${arqId}`;
  };
  // checkpoint leve: se o worker morrer (limite de CPU/memória), a retomada
  // parte daqui em vez de refazer a fase inteira
  let lotesCk = 0;
  const anotaCursor = async (f: string, linha: number) => {
    await sql`update bolsa.arquivos_historicos set detalhe = (case when jsonb_typeof(detalhe) = 'object' then detalhe else '{}'::jsonb end) || ${{ cursor: { fase: f, linha } }}::jsonb where id = ${arqId}`;
  };

  const resp = await fetch(url, { headers: { "user-agent": UA }, signal: AbortSignal.timeout(60000) });
  if (!resp.ok) {
    await resp.body?.cancel();
    // mês nunca publicado (403/404) não é falha da Bolsa
    const st = (resp.status === 403 || resp.status === 404) ? "SOURCE_NOT_AVAILABLE" : "FAILED";
    await sql`update bolsa.arquivos_historicos set import_status = ${st},
              detalhe = (case when jsonb_typeof(detalhe) = 'object' then detalhe else '{}'::jsonb end) || ${{ http: resp.status }}::jsonb where id = ${arqId}`;
    return { ym, status: st, http: resp.status };
  }
  let buf: Uint8Array | null = new Uint8Array(await resp.arrayBuffer());
  const zipBytes = buf.length;
  const hash = await sha256hex(buf);
  await sql`update bolsa.arquivos_historicos set tamanho_bytes = ${zipBytes}, sha256 = ${hash}, baixado_em = now(), import_status = 'IMPORTING' where id = ${arqId}`;

  // §5: bruto imutável vai para o object storage (uma única vez por arquivo)
  if (!arqRows[0].detalhe?.storage_path) {
    try {
      const sp = `transparencia/${ym}.zip`;
      // env pode trazer JWT legacy (eyJ...) ou chave nova (sb_secret_...):
      // manda nos dois headers que o Storage aceita; o prefixo (público) vai
      // para o diagnóstico quando falha — nunca a chave inteira
      const chave = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
      const up = await fetch(`${Deno.env.get("SUPABASE_URL")}/storage/v1/object/memoria-bruta/${sp}`, {
        method: "POST",
        headers: { authorization: `Bearer ${chave}`, apikey: chave,
                   "content-type": "application/zip", "x-upsert": "true" },
        body: buf as unknown as BodyInit,
      });
      if (up.ok) await sql`update bolsa.arquivos_historicos set storage_path = ${sp},
          detalhe = (case when jsonb_typeof(detalhe) = 'object' then detalhe else '{}'::jsonb end) || ${{ storage_path: sp, storage_upload_http: null, storage_upload_err: null }}::jsonb where id = ${arqId}`;
      else {
        // falha visível no detalhe (§19: sem verdade silenciosa) — nunca derruba a importação
        const corpo = (await up.text().catch(() => "")).slice(0, 300);
        const tipoChave = chave ? chave.slice(0, 10) + "… (" + chave.length + " chars)" : "AUSENTE";
        console.log(`upload memoria-bruta falhou HTTP ${up.status} (chave ${tipoChave}): ${corpo}`);
        await sql`update bolsa.arquivos_historicos set
            detalhe = (case when jsonb_typeof(detalhe) = 'object' then detalhe else '{}'::jsonb end) || ${{ storage_upload_http: up.status, storage_upload_err: corpo, storage_upload_key_tipo: tipoChave }}::jsonb where id = ${arqId}`;
      }
    } catch (e) {
      console.log(`upload memoria-bruta lançou: ${String((e as Error).message)}`);
      await sql`update bolsa.arquivos_historicos set
          detalhe = (case when jsonb_typeof(detalhe) = 'object' then detalhe else '{}'::jsonb end) || ${{ storage_upload_err: String((e as Error).message).slice(0, 300) }}::jsonb where id = ${arqId}`.catch(() => {});
    }
  }

  // NÃO inflar o ZIP inteiro (os 4 CSVs juntos estouram a memória do worker):
  // primeiro só listamos os nomes, depois inflamos um arquivo por fase.
  const nomes: string[] = [];
  unzipSync(buf, { filter: (f) => { nomes.push(f.name); return false; } });
  const abrir = (nome: string): Uint8Array => unzipSync(buf!, { filter: (f) => f.name === nome })[nome];
  const dec = new TextDecoder("iso-8859-1");
  const cnt: Cnt = { lics: 0, itens: 0, parts: 0, emps: 0, erros: 0 };
  const detArquivos: Record<string, number> = {};

  const fLic = nomes.find((n) => { const nn = norm(n); return nn.includes("licitac") && !nn.includes("item") && !nn.includes("particip") && !nn.includes("empenho"); });
  const fItem = nomes.find((n) => norm(n).includes("item"));
  const fPart = nomes.find((n) => norm(n).includes("particip"));
  const fEmp = nomes.find((n) => norm(n).includes("empenho"));

  // chave comum entre os 4 arquivos do mês
  const chaveDe = (cols: string[], iNum: number, iUg: number, iMod: number) =>
    `${(cols[iUg] ?? "").trim()}:${norm(cols[iMod] ?? "").slice(0, 12)}:${(cols[iNum] ?? "").trim()}`;
  // registros lógicos (campos multiline) — arquivo inteiro está em memória,
  // então um pendente no fim é registro malformado e entra como está
  const registrosDe = (bytes: Uint8Array): string[] => {
    const nr = normalizarRegistros(dec.decode(bytes).split(/\r?\n/));
    const rs = nr.pendente ? [...nr.completos, nr.pendente] : nr.completos;
    return rs.filter((l) => l.length > 0);
  };

  // ---- Licitação ----
  if (fLic && !pulaFase("lic") && !cortouEm) {
    const linhas = registrosDe(abrir(fLic));
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
    for (let ini = inicioDa("lic"); ini < linhas.length; ini += 400) {
      if (Date.now() > deadline) { await salvaCursor("lic", ini); break; }
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
      if (++lotesCk >= 10) { lotesCk = 0; await anotaCursor("lic", Math.min(ini + 400, linhas.length)); }
    }
  }

  // ---- ItemLicitação ----
  if (fItem && !pulaFase("item") && !cortouEm) {
    const linhas = registrosDe(abrir(fItem));
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
    for (let ini = inicioDa("item"); ini < linhas.length; ini += 400) {
      if (Date.now() > deadline) { await salvaCursor("item", ini); break; }
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
      if (++lotesCk >= 10) { lotesCk = 0; await anotaCursor("item", Math.min(ini + 400, linhas.length)); }
    }
  }

  // ---- ParticipantesLicitação (§13-14: participar ≠ vencer) ----
  if (fPart && !pulaFase("part") && !cortouEm) {
    const linhas = registrosDe(abrir(fPart));
    const H = parseCsvLinha(linhas[0]).map(norm);
    const iNum = acharCol(H, ["numero", "licitac"]);
    const iUg = acharCol(H, ["codigo", "ug"]);
    const iMod = acharCol(H, ["modalidade"]);
    const iCnpj = acharCol(H, ["cnpj"], ["participante", "codigo"]);
    const iNome = H.findIndex((h) => h.includes("nome") && h.includes("participante"));
    const iItem = acharCol(H, ["codigo", "item"]);
    const iVencFlag = H.findIndex((h) => h.includes("vencedor"));
    detArquivos[fPart] = linhas.length - 1;
    for (let ini = inicioDa("part"); ini < linhas.length; ini += 500) {
      if (Date.now() > deadline) { await salvaCursor("part", ini); break; }
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
      if (++lotesCk >= 10) { lotesCk = 0; await anotaCursor("part", Math.min(ini + 500, linhas.length)); }
    }
  }

  // ---- EmpenhosRelacionados ----
  if (fEmp && !pulaFase("emp") && !cortouEm) {
    const linhas = registrosDe(abrir(fEmp));
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
    for (let ini = inicioDa("emp"); ini < linhas.length; ini += 500) {
      if (Date.now() > deadline) { await salvaCursor("emp", ini); break; }
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
      if (++lotesCk >= 10) { lotesCk = 0; await anotaCursor("emp", Math.min(ini + 500, linhas.length)); }
    }
  }

  const completo = !cortouEm;
  await sql`update bolsa.arquivos_historicos set
      import_status = ${completo ? "VALIDATING" : "PARTIAL"},
      linhas_processadas = linhas_processadas + ${cnt.lics + cnt.itens + cnt.parts + cnt.emps},
      inseridos = inseridos + ${cnt.lics + cnt.itens + cnt.parts + cnt.emps},
      erros = erros + ${cnt.erros},
      finalizado_em = case when ${completo} then now() else null end,
      detalhe = (case when jsonb_typeof(detalhe) = 'object' then detalhe else '{}'::jsonb end)
                || ${Object.assign({ arquivos_no_zip: nomes, parcial: !completo }, completo ? { cursor: null } : {})}::jsonb
                || jsonb_build_object('contagem_por_arquivo',
                     (case when jsonb_typeof(detalhe->'contagem_por_arquivo') = 'object' then detalhe->'contagem_por_arquivo' else '{}'::jsonb end)
                     || ${detArquivos}::jsonb)
    where id = ${arqId}`;

  // validação de cobertura (§8/§76): linhas processadas × linhas dos arquivos do ZIP.
  // processadas pode EXCEDER o esperado (retomadas relêem trechos); mismatch é só quando falta.
  if (completo) {
    await sql`update bolsa.arquivos_historicos a set
        import_status = 'COMPLETE',
        detalhe = (case when jsonb_typeof(a.detalhe) = 'object' then a.detalhe else '{}'::jsonb end) || jsonb_build_object(
          'validacao', jsonb_build_object(
             'esperado_linhas', (select coalesce(sum((v.value)::bigint),0) from jsonb_each_text(coalesce(a.detalhe->'contagem_por_arquivo','{}'::jsonb)) v),
             'processado_linhas', a.linhas_processadas, 'erros', a.erros, 'em', now()),
          'coverage_mismatch',
             (a.linhas_processadas + a.erros) < 0.98 * (select coalesce(sum((v.value)::bigint),0) from jsonb_each_text(coalesce(a.detalhe->'contagem_por_arquivo','{}'::jsonb)) v))
      where a.id = ${arqId}`;
  }

  await sql`insert into bolsa.memoria_anos (ano, fonte, status, relatorio)
            values (${ano}, 'transparencia', 'PARCIAL', ${{ ultimo_mes_importado: ym }}::jsonb)
            on conflict (ano, fonte) do update set relatorio = memoria_anos.relatorio || excluded.relatorio, atualizado_em = now()`;

  return { ym, zip_bytes: zipBytes, sha256: hash.slice(0, 16), ...cnt, completo, status: completo ? "COMPLETE" : "PARTIAL" };
}

// ---------- AUTO: próximo arquivo agendado ----------

// ---------- COMPRAS.GOV: CSV anual por Range (§5-7, retomada por byte §59) ----------
const CHUNK = 1536 * 1024;

async function importarCsvRange(arq: any, deadline: number): Promise<Record<string, unknown>> {
  const st = { lidas: 0, inseridos: 0, erros: 0 };
  let cursor: number = Number(arq.cursor_bytes ?? 0);
  let resto: string = arq.resto_linha ?? "";
  let mapa: any = arq.detalhe?.mapa ?? null;
  let sep: string = arq.detalhe?.sep ?? ";";
  await sql`update bolsa.arquivos_historicos set import_status = 'IMPORTING' where id = ${arq.id}`;

  const salvar = async (status: string | null, extra: Record<string, unknown> = {}) => {
    await sql`update bolsa.arquivos_historicos set
        cursor_bytes = ${cursor}, resto_linha = ${resto.slice(0, 24000)},
        linhas_processadas = linhas_processadas + ${st.lidas},
        inseridos = inseridos + ${st.inseridos}, erros = erros + ${st.erros},
        import_status = coalesce(${status}, import_status),
        finalizado_em = case when ${status === "COMPLETE"} then now() else finalizado_em end,
        detalhe = (case when jsonb_typeof(detalhe) = 'object' then detalhe else '{}'::jsonb end)
                  || ${Object.assign({ sep }, mapa ? { mapa } : {}, extra)}::jsonb
      where id = ${arq.id}`;
    st.lidas = 0; st.inseridos = 0; st.erros = 0;
    if (status === "COMPLETE") {
      // validação: cursor final × tamanho sondado; e memória por ano da fonte
      await sql`update bolsa.arquivos_historicos set
          detalhe = (case when jsonb_typeof(detalhe) = 'object' then detalhe else '{}'::jsonb end) || jsonb_build_object(
            'validacao', jsonb_build_object('fim_bytes', cursor_bytes, 'tamanho_sondado', tamanho_bytes, 'em', now()),
            'coverage_mismatch', (tamanho_bytes is not null and cursor_bytes < tamanho_bytes))
        where id = ${arq.id}`;
      if (arq.ano) {
        await sql`insert into bolsa.memoria_anos (ano, fonte, status, relatorio)
            values (${arq.ano}, ${arq.fonte}, 'PARCIAL', ${{ arquivo_concluido: arq.dataset, em: new Date().toISOString() }}::jsonb)
            on conflict (ano, fonte) do update set relatorio = memoria_anos.relatorio || excluded.relatorio, atualizado_em = now()`;
      }
    }
  };

  // guarda: cursor avançado sem mapa persistido (bug antigo do detalhe NULL) —
  // reimportar do zero é idempotente e não perde nada
  if (cursor > 0 && !mapa) {
    cursor = 0; resto = "";
    await salvar(null, { reinicio: "mapa ausente com cursor avançado; reimport preventivo" });
  }

  const dec = new TextDecoder("utf-8");
  while (Date.now() < deadline - 8000) {
    const fim = cursor + CHUNK - 1;
    let r: Response;
    try {
      r = await fetch(arq.url, { headers: { "user-agent": UA, range: `bytes=${cursor}-${fim}` }, signal: AbortSignal.timeout(30000) });
    } catch (e) {
      await salvar(cursor > 0 ? "PARTIAL" : "PENDING", { ultima_falha: String((e as Error).message) });
      return { arquivo: arq.id, parcial: true, motivo: "rede" };
    }
    if (r.status === 416) { // pedimos além do fim: arquivo terminou exatamente no chunk anterior
      await r.body?.cancel();
      await salvar("COMPLETE", { fim_bytes: cursor, via: "416" });
      return { arquivo: arq.id, dataset: arq.dataset, concluido: true, bytes: cursor };
    }
    if (!r.ok && r.status !== 206) {
      await r.body?.cancel();
      await salvar("FAILED", { http: r.status });
      return { arquivo: arq.id, erro: `HTTP ${r.status}` };
    }
    if (r.status !== 206) { // servidor ignorou o Range: só aceitável para arquivo pequeno no início
      const cl = Number(r.headers.get("content-length") ?? 0);
      if (cursor > 0 || cl > 32 * 1024 * 1024) {
        await r.body?.cancel();
        await salvar("FAILED", { motivo: "servidor ignorou Range (HTTP 200) em arquivo grande", content_length: cl || null });
        return { arquivo: arq.id, erro: "range ignorado" };
      }
    }
    if (r.status === 206 && arq.tamanho_bytes == null) {
      // total real vem do Content-Range (bytes ini-fim/total) — necessário
      // para o coverage_mismatch (§8) validar cursor final × tamanho
      const total = Number((r.headers.get("content-range") ?? "").split("/")[1]);
      if (Number.isFinite(total) && total > 0) {
        arq.tamanho_bytes = total;
        await sql`update bolsa.arquivos_historicos set tamanho_bytes = ${total} where id = ${arq.id}`;
      }
    }
    const bytes = new Uint8Array(await r.arrayBuffer());
    const texto = resto + dec.decode(bytes, { stream: false });
    const fisicas = texto.split(/\r?\n/);
    resto = fisicas.pop() ?? "";
    const acabou = bytes.length < CHUNK; // resposta curta = fim do arquivo
    if (acabou && resto.trim().length) { fisicas.push(resto); resto = ""; }
    // registros lógicos: campo multiline aberto no fim do bloco volta pro resto
    const nr = normalizarRegistros(fisicas);
    if (nr.pendente !== null) {
      if (acabou) nr.completos.push(nr.pendente); // fim do arquivo: registro malformado entra como está
      else resto = nr.pendente + "\n" + resto;
    }
    const linhas = nr.completos;

    let idx = 0;
    if (cursor === 0 && !mapa) {
      const hLinha = (linhas[0] ?? "").replace(/^\ufeff/, "");
      sep = (hLinha.split(";").length >= hLinha.split(",").length) ? ";" : ",";
      const H = parseCsvLinha(hLinha, sep).map(norm);
      const col = (...alts: string[][]) => acharCol(H, ...alts);
      mapa = {
        chave: col(["numero","controle","pncp"], ["id","compra"], ["identificador"]),
        objeto: col(["objeto"], ["descricao","compra"]),
        descricao: col(["descricao","item"], ["descricao"]),
        valor: col(["valor","total"], ["valor","estimado"], ["valor"]),
        vunit: col(["valor","unitario"], ["preco","unitario"]),
        qtd: col(["quantidade"]),
        forn: col(["cnpj","fornecedor"], ["ni","fornecedor"], ["fornecedor","codigo"]),
        fornNome: col(["nome","fornecedor"], ["razao","fornecedor"]),
        item: col(["numero","item"], ["codigo","item"]),
        uasg: col(["uasg"], ["unidade","codigo"], ["codigo","ug"]),
        orgaoNome: col(["nome","orgao"], ["orgao"]),
        municipio: col(["municipio"]),
        uf: col(["uf"], ["sigla","uf"]),
        modalidade: col(["modalidade"]),
        situacao: col(["situacao"]),
        ano: col(["ano","compra"], ["ano"]),
        data: col(["data","publicacao"], ["data","resultado"], ["data"]),
        // extras p/ Contratos.gov (headers reais do comprasnet-contratos)
        idExato: H.findIndex((h) => h === "id"),
        processo: col(["processo"]),
        tipo: col(["tipo"]),
        categoria: col(["categoria"]),
        vigIni: col(["vigencia","inicio"], ["inicio","vigencia"], ["data","assinatura"]),
        vigFim: col(["vigencia","fim"], ["fim","vigencia"]),
        valorGlobal: col(["valor","global"], ["valor","inicial"]),
        contratoId: col(["contrato","id"], ["id","contrato"]),
        empenho: col(["empenho"], ["numero","empenho"]),
        vEmpenhado: col(["empenhado"]),
        vLiquidado: col(["liquidado"]),
        vPago: col(["pago"]),
        credor: col(["credor"], ["cnpj","cpf"]),
        header: H.slice(0, 40),
      };
      if (arq.dataset === "contratos_anual" && mapa.idExato >= 0) mapa.chave = mapa.idExato;
      if (arq.dataset === "contratos_anual_empenhos" && mapa.idExato >= 0 && mapa.chave < 0) mapa.chave = mapa.idExato;
      if (mapa.chave < 0) {
        await salvar("FAILED", { motivo: "cabecalho sem coluna-chave reconhecida", header: mapa.header });
        return { arquivo: arq.id, erro: "cabecalho sem chave", header: mapa.header };
      }
      idx = 1;
    }

    // chunk baixado é processado por inteiro (o cursor avança bytes completos;
    // cortar no meio perderia linhas em silêncio — nunca §64)
    const destino = (arq.dataset === "comprasgov_anual_resultados" || arq.dataset === "comprasgov_anual_itens") ? "itens"
      : arq.dataset === "contratos_anual" ? "contratos"
      : arq.dataset === "contratos_anual_empenhos" ? "contrato_empenhos"
      : "licitacoes";
    for (let b = idx; b < linhas.length; b += 500) {
      const lote = linhas.slice(b, b + 500).filter((l) => l.length > 0);
      if (!lote.length) continue;
      if (destino === "contratos") {
        const a = { ch: [] as string[], nu: [] as (string|null)[], pr: [] as (string|null)[], tp: [] as (string|null)[],
          ct: [] as (string|null)[], si: [] as (string|null)[], onm: [] as (string|null)[], ug: [] as (string|null)[],
          fn2: [] as (string|null)[], fnm: [] as (string|null)[], ob: [] as (string|null)[], vg: [] as (number|null)[],
          vi: [] as (string|null)[], vf: [] as (string|null)[], an: [] as (number|null)[] };
        for (const l of lote) {
          try {
            const c = parseCsvLinha(l, sep);
            const ch = (c[mapa.chave] ?? "").trim();
            if (!ch) throw new Error("chave vazia");
            const dataBr = (i: number) => i >= 0 ? (brData(c[i]) ?? ((c[i] ?? "").match(/^\d{4}-\d{2}-\d{2}/)?.[0] ?? null)) : null;
            a.ch.push(ch);
            a.nu.push(mapa.item >= 0 ? c[mapa.item] : (mapa.chave >= 0 ? c[mapa.chave] : null));
            a.pr.push(mapa.processo >= 0 ? c[mapa.processo] : null);
            a.tp.push(mapa.tipo >= 0 ? c[mapa.tipo] : null);
            a.ct.push(mapa.categoria >= 0 ? c[mapa.categoria] : null);
            a.si.push(mapa.situacao >= 0 ? c[mapa.situacao] : null);
            a.onm.push(mapa.orgaoNome >= 0 ? c[mapa.orgaoNome] : null);
            a.ug.push(mapa.uasg >= 0 ? c[mapa.uasg] : null);
            a.fn2.push(mapa.forn >= 0 ? (c[mapa.forn] ?? "").replace(/\D/g, "") || null : null);
            a.fnm.push(mapa.fornNome >= 0 ? c[mapa.fornNome] : null);
            a.ob.push(mapa.objeto >= 0 ? (c[mapa.objeto] ?? "").slice(0, 800) : null);
            a.vg.push(mapa.valorGlobal >= 0 ? brNum(c[mapa.valorGlobal]) : (mapa.valor >= 0 ? brNum(c[mapa.valor]) : null));
            a.vi.push(dataBr(mapa.vigIni));
            a.vf.push(dataBr(mapa.vigFim));
            a.an.push(arq.ano ?? null);
            st.lidas++;
          } catch (e) {
            st.erros++;
            await sql`insert into bolsa.import_erros (arquivo_id, erro, conteudo) values (${arq.id}, ${String((e as Error).message)}, ${l.slice(0, 300)})`;
          }
        }
        if (a.ch.length) {
          await sql`insert into bolsa.contratos_legado (fonte, chave_fonte, numero, processo, tipo, categoria, situacao,
                      orgao_nome, unidade_codigo, fornecedor_ni, fornecedor_nome, objeto, valor_global, vigencia_inicio, vigencia_fim, ano)
                    select distinct on (ch) 'contratos_gov', ch, nu, pr, tp, ct, si, onm, ug, fn2, fnm, ob, vg, vi::date, vf::date, an
                    from unnest(${a.ch}::text[], ${a.nu}::text[], ${a.pr}::text[], ${a.tp}::text[], ${a.ct}::text[],
                                ${a.si}::text[], ${a.onm}::text[], ${a.ug}::text[], ${a.fn2}::text[], ${a.fnm}::text[],
                                ${a.ob}::text[], ${a.vg}::numeric[], ${a.vi}::text[], ${a.vf}::text[], ${a.an}::int[])
                      as t(ch, nu, pr, tp, ct, si, onm, ug, fn2, fnm, ob, vg, vi, vf, an)
                    on conflict (fonte, chave_fonte) do update set
                      situacao = excluded.situacao, valor_global = excluded.valor_global,
                      vigencia_fim = excluded.vigencia_fim, last_seen_at = now()`;
          st.inseridos += a.ch.length;
        }
      } else if (destino === "contrato_empenhos") {
        const a = { co: [] as string[], em: [] as string[], dt: [] as (string|null)[], cr: [] as (string|null)[],
          crn: [] as (string|null)[], ve: [] as (number|null)[], vl: [] as (number|null)[], vp: [] as (number|null)[],
          an: [] as (number|null)[] };
        for (const l of lote) {
          try {
            const c = parseCsvLinha(l, sep);
            const co = (mapa.contratoId >= 0 ? c[mapa.contratoId] ?? "" : "").trim();
            const em = (mapa.empenho >= 0 ? c[mapa.empenho] ?? "" : (c[mapa.chave] ?? "")).trim();
            if (!co || !em) throw new Error("contrato/empenho vazio");
            a.co.push(co); a.em.push(em);
            a.dt.push(mapa.data >= 0 ? (brData(c[mapa.data]) ?? ((c[mapa.data] ?? "").match(/^\d{4}-\d{2}-\d{2}/)?.[0] ?? null)) : null);
            a.cr.push(mapa.credor >= 0 ? (c[mapa.credor] ?? "").replace(/\D/g, "") || null : null);
            a.crn.push(mapa.fornNome >= 0 ? c[mapa.fornNome] : null);
            a.ve.push(mapa.vEmpenhado >= 0 ? brNum(c[mapa.vEmpenhado]) : (mapa.valor >= 0 ? brNum(c[mapa.valor]) : null));
            a.vl.push(mapa.vLiquidado >= 0 ? brNum(c[mapa.vLiquidado]) : null);
            a.vp.push(mapa.vPago >= 0 ? brNum(c[mapa.vPago]) : null);
            a.an.push(arq.ano ?? null);
            st.lidas++;
          } catch (e) {
            st.erros++;
            await sql`insert into bolsa.import_erros (arquivo_id, erro, conteudo) values (${arq.id}, ${String((e as Error).message)}, ${l.slice(0, 300)})`;
          }
        }
        if (a.co.length) {
          await sql`insert into bolsa.contrato_empenhos_legado (fonte, contrato_chave, empenho_codigo, data_emissao,
                      credor_ni, credor_nome, valor_empenhado, valor_liquidado, valor_pago, ano)
                    select distinct on (co, em) 'contratos_gov', co, em, dt::date, cr, crn, ve, vl, vp, an
                    from unnest(${a.co}::text[], ${a.em}::text[], ${a.dt}::text[], ${a.cr}::text[], ${a.crn}::text[],
                                ${a.ve}::numeric[], ${a.vl}::numeric[], ${a.vp}::numeric[], ${a.an}::int[])
                      as t(co, em, dt, cr, crn, ve, vl, vp, an)
                    on conflict (fonte, contrato_chave, empenho_codigo) do update set
                      valor_empenhado = excluded.valor_empenhado, valor_liquidado = excluded.valor_liquidado,
                      valor_pago = excluded.valor_pago`;
          st.inseridos += a.co.length;
        }
      } else if (destino === "itens") {
        const a = { ch: [] as string[], it: [] as (string|null)[], de: [] as (string|null)[],
          qt: [] as (number|null)[], vu: [] as (number|null)[], ve: [] as (string|null)[],
          vn: [] as (string|null)[], an: [] as (number|null)[] };
        for (const l of lote) {
          try {
            const c = parseCsvLinha(l, sep);
            const ch = (c[mapa.chave] ?? "").trim();
            if (!ch) throw new Error("chave vazia");
            a.ch.push(ch);
            a.it.push(mapa.item >= 0 ? c[mapa.item] : null);
            a.de.push(mapa.descricao >= 0 ? (c[mapa.descricao] ?? "").slice(0, 500) : null);
            a.qt.push(mapa.qtd >= 0 ? brNum(c[mapa.qtd]) : null);
            a.vu.push(mapa.vunit >= 0 ? brNum(c[mapa.vunit]) : (mapa.valor >= 0 ? brNum(c[mapa.valor]) : null));
            a.ve.push(mapa.forn >= 0 ? (c[mapa.forn] ?? "").replace(/\D/g, "") || null : null);
            a.vn.push(mapa.fornNome >= 0 ? c[mapa.fornNome] : null);
            a.an.push(mapa.ano >= 0 ? (Number(c[mapa.ano]) || null) : arq.ano);
            st.lidas++;
          } catch (e) {
            st.erros++;
            await sql`insert into bolsa.import_erros (arquivo_id, erro, conteudo) values (${arq.id}, ${String((e as Error).message)}, ${l.slice(0, 300)})`;
          }
        }
        if (a.ch.length) {
          await sql`insert into bolsa.itens_legado (fonte, licitacao_chave, numero_item, descricao, quantidade, valor_unitario, vencedor_ni, vencedor_nome, ano)
                    select distinct on (ch, it2, ve) 'compras_gov', ch, it2, de, qt, vu, ve, vn, an
                    from unnest(${a.ch}::text[], ${a.it}::text[], ${a.de}::text[], ${a.qt}::numeric[],
                                ${a.vu}::numeric[], ${a.ve}::text[], ${a.vn}::text[], ${a.an}::int[])
                      as t(ch, it2, de, qt, vu, ve, vn, an)
                    on conflict (fonte, licitacao_chave, item_key, vend_key) do update set
                      valor_unitario = excluded.valor_unitario, descricao = excluded.descricao`;
          st.inseridos += a.ch.length;
        }
      } else {
        const a = { ch: [] as string[], ob: [] as (string|null)[], va: [] as (number|null)[],
          ug: [] as (string|null)[], onm: [] as (string|null)[], mu: [] as (string|null)[],
          uf2: [] as (string|null)[], mo: [] as (string|null)[], si: [] as (string|null)[],
          an: [] as (number|null)[], dt: [] as (string|null)[] };
        for (const l of lote) {
          try {
            const c = parseCsvLinha(l, sep);
            const ch = (c[mapa.chave] ?? "").trim();
            if (!ch) throw new Error("chave vazia");
            a.ch.push(ch);
            a.ob.push(mapa.objeto >= 0 ? (c[mapa.objeto] ?? "").slice(0, 800) : null);
            a.va.push(mapa.valor >= 0 ? brNum(c[mapa.valor]) : null);
            a.ug.push(mapa.uasg >= 0 ? c[mapa.uasg] : null);
            a.onm.push(mapa.orgaoNome >= 0 ? c[mapa.orgaoNome] : null);
            a.mu.push(mapa.municipio >= 0 ? c[mapa.municipio] : null);
            a.uf2.push(mapa.uf >= 0 ? (c[mapa.uf] ?? "").slice(0, 2) || null : null);
            a.mo.push(mapa.modalidade >= 0 ? c[mapa.modalidade] : null);
            a.si.push(mapa.situacao >= 0 ? c[mapa.situacao] : null);
            a.an.push(mapa.ano >= 0 ? (Number(c[mapa.ano]) || null) : arq.ano);
            a.dt.push(mapa.data >= 0 ? (brData(c[mapa.data]) ?? ((c[mapa.data] ?? "").match(/^\d{4}-\d{2}-\d{2}/)?.[0] ?? null)) : null);
            st.lidas++;
          } catch (e) {
            st.erros++;
            await sql`insert into bolsa.import_erros (arquivo_id, erro, conteudo) values (${arq.id}, ${String((e as Error).message)}, ${l.slice(0, 300)})`;
          }
        }
        if (a.ch.length) {
          await sql`insert into bolsa.licitacoes_legado (fonte, chave_fonte, ano, modalidade, orgao_nome, ug_codigo, municipio, uf, objeto, situacao, valor, data_resultado, possivel_duplicado_pncp)
                    select distinct on (ch) 'compras_gov', ch, an, mo, onm, ug, mu, uf2, ob, si, va, dt::date,
                           case when ch ~ '^\\d{14}-\\d-\\d+/\\d{4}$' then ch end
                    from unnest(${a.ch}::text[], ${a.ob}::text[], ${a.va}::numeric[], ${a.ug}::text[],
                                ${a.onm}::text[], ${a.mu}::text[], ${a.uf2}::text[], ${a.mo}::text[],
                                ${a.si}::text[], ${a.an}::int[], ${a.dt}::text[])
                      as t(ch, ob, va, ug, onm, mu, uf2, mo, si, an, dt)
                    on conflict (fonte, chave_fonte) do update set
                      situacao = excluded.situacao, valor = excluded.valor, last_seen_at = now()`;
          st.inseridos += a.ch.length;
        }
      }
    }

    cursor += bytes.length;
    await salvar(null);
    if (acabou) { await salvar("COMPLETE", { fim_bytes: cursor }); return { arquivo: arq.id, dataset: arq.dataset, concluido: true, bytes: cursor }; }
  }
  await salvar(cursor > 0 ? "PARTIAL" : "PENDING");
  return { arquivo: arq.id, dataset: arq.dataset, parcial: true, cursor_bytes: cursor };
}

async function jobAuto(deadline: number, fonte?: string): Promise<Record<string, unknown>> {
  const out: Record<string, unknown> = {};
  // Filas INDEPENDENTES por fonte (§22): cada cron dispara com p.fonte e as
  // fontes progridem em paralelo (workers separados, sem estourar CPU).
  // Sem fonte forçada, alterna por minuto. Lease de 90-120s evita dois
  // workers no mesmo arquivo quando os ticks se sobrepõem.
  const vezCompras = fonte ? fonte !== "transparencia" : new Date().getUTCMinutes() % 2 === 0;
  // fila por fonte: 'compras' = anuais do Compras.gov; 'contratos' = Contratos.gov;
  // sem fonte, os cinco datasets numa fila só
  const dsFila = fonte === "contratos"
    ? ["contratos_anual", "contratos_anual_empenhos"]
    : fonte === "compras"
      ? ["comprasgov_anual_compras", "comprasgov_anual_resultados", "comprasgov_anual_itens"]
      : ["comprasgov_anual_compras", "comprasgov_anual_resultados", "comprasgov_anual_itens",
         "contratos_anual", "contratos_anual_empenhos"];
  // prioridade: compras (licitações) -> resultados -> itens -> contratos -> empenhos de contrato
  const claimCompras = () => sql`
    update bolsa.arquivos_historicos a
       set detalhe = (case when jsonb_typeof(a.detalhe) = 'object' then a.detalhe else '{}'::jsonb end) || jsonb_build_object('lease_ate', (now() + interval '90 seconds')::text)
     where a.id = (
       select id from bolsa.arquivos_historicos
       where import_status in ('PENDING','PARTIAL','IMPORTING')
         and dataset = any(${dsFila}::text[])
         and (jsonb_typeof(detalhe) <> 'object' or ((detalhe->>'hold') is null
              and coalesce(nullif(detalhe->>'lease_ate','')::timestamptz, '-infinity') < now()))
       order by import_status in ('IMPORTING','PARTIAL') desc,
                case dataset when 'comprasgov_anual_compras' then 1
                             when 'comprasgov_anual_resultados' then 2
                             when 'comprasgov_anual_itens' then 3
                             when 'contratos_anual' then 4 else 5 end,
                ano desc limit 1)
     returning a.id, a.fonte, a.dataset, a.ano, a.url, a.cursor_bytes, a.tamanho_bytes, a.resto_linha, a.detalhe`;
  // lease 100s < tick de 120s: o mesmo mês é retomado a cada tick até
  // COMPLETE, em vez de abrir um segundo mês em paralelo (CPU do isolate)
  const claimTransp = () => sql`
    update bolsa.arquivos_historicos a
       set detalhe = (case when jsonb_typeof(a.detalhe) = 'object' then a.detalhe else '{}'::jsonb end) || jsonb_build_object('lease_ate', (now() + interval '100 seconds')::text)
     where a.id = (
       select id from bolsa.arquivos_historicos
       where import_status in ('PENDING','PARTIAL','IMPORTING','DOWNLOADING') and fonte = 'transparencia'
         and (jsonb_typeof(detalhe) <> 'object'
              or coalesce(nullif(detalhe->>'lease_ate','')::timestamptz, '-infinity') < now())
       order by import_status in ('IMPORTING','PARTIAL','DOWNLOADING') desc, ano desc, mes desc limit 1)
     returning a.id, a.ano, a.mes`;
  if (vezCompras) {
    const cg = await claimCompras();
    if (cg.length) { out.compras_gov = await importarCsvRange(cg[0], deadline); return out; }
    if (fonte) { out.fila = "compras vazia"; return out; }
  }
  const r = await claimTransp();
  if (r.length) { out.transparencia = await importarTransparenciaMes(r[0].ano, r[0].mes, deadline); return out; }
  if (fonte === "transparencia") { out.fila = "transparencia vazia"; return out; }
  const cg2 = await claimCompras();
  if (cg2.length) out.compras_gov = await importarCsvRange(cg2[0], deadline);
  else out.fila = "vazia";
  return out;
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
    else if (job === "auto") out = await jobAuto(deadline, typeof p.fonte === "string" ? p.fonte : undefined);
    else out = { erro: "job desconhecido" };
  } catch (e) {
    out = { erro: String((e as Error).message) };
  }
  return new Response(JSON.stringify({ ok: true, job, ...out }), { headers: { "content-type": "application/json" } });
});
