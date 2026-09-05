// ============================================================
// BOLSA — conector CEIS (Cadastro de Empresas Inidôneas e Suspensas) v1
// Wave 2 #1. Portal da Transparência (CGU), mesma família de host já
// ativa (coleta-historico-transp usa download-de-dados/licitacoes/YYYYMM
// com sucesso). Descoberta real desta sessão: download-de-dados/{ceis|
// cnep|cepim}/YYYYMMDD redireciona para um bucket S3 público
// (dadosabertos-download.cgu.gov.br) SEM WAF/captcha — só a página
// informativa (sem sufixo de data) tem o desafio AWS WAF. Não contornado
// (nunca precisou: o endpoint de arquivo real não tem desafio).
//
// Motor genérico usado direto via SQL (regra Wave 1/2: sql.json(), nunca
// JSON.stringify()::jsonb). Entidade nova 'sancao_ceis' — dados vêm
// passthrough do cabeçalho real do CSV (normalizado), sem supor nomes de
// coluna: evita quebrar se a CGU mudar o layout, e evita fabricar mapeamento
// de campo sem ter visto o dado real.
//
// Canonicalização: CEIS não tem contrapartida no PNCP (é lista de sanção a
// fornecedor, não processo de disputa) — não usa
// bolsa.resolver_canonico_processo_disputa(). Cada CNPJ/CPF sancionado vira
// seu próprio canônico direto (chave_canonica = 'ceis:'||documento),
// nunca órfão, sem ambiguidade possível (chave já é o identificador único).
import postgres from "npm:postgres@3.4.5";
import { unzipSync } from "npm:fflate@0.8.2";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });
const FONTE = "transparencia";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";

async function sha256(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes as unknown as BufferSource);
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function normalizaChave(s: string): string {
  return s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
}

// parser CSV linha a linha (sem montar array 2D inteiro em memória — CSVs
// da CGU passam de 100k linhas e a versão anterior estourava o worker).
function parseLinhaCsv(l: string): string[] {
  const out: string[] = [];
  let atual = "";
  let dentroAspas = false;
  for (let i = 0; i < l.length; i++) {
    const c = l[i];
    if (c === '"') dentroAspas = !dentroAspas;
    else if (c === ";" && !dentroAspas) { out.push(atual); atual = ""; }
    else atual += c;
  }
  out.push(atual);
  return out;
}

// gerador: produz uma linha (array de campos) por vez, sem nunca reter o
// texto inteiro dividido em memória além do necessário.
function* linhasCsv(texto: string): Generator<string[]> {
  let inicio = 0;
  while (inicio < texto.length) {
    let fim = texto.indexOf("\n", inicio);
    if (fim === -1) fim = texto.length;
    let linha = texto.slice(inicio, fim);
    if (linha.endsWith("\r")) linha = linha.slice(0, -1);
    inicio = fim + 1;
    if (linha.length === 0) continue;
    yield parseLinhaCsv(linha);
  }
}

interface Config { dataset: "ceis" | "cnep" | "cepim"; entidade: string; campoChave: string[]; campoDesambiguador: string[] }
const CONFIGS: Config[] = [
  { dataset: "ceis", entidade: "sancao_ceis", campoChave: ["cpf_ou_cnpj_do_sancionado", "cnpj_ou_cpf_do_sancionado", "cpf_cnpj_sancionado"], campoDesambiguador: ["numero_do_processo", "data_inicio_sancao"] },
  { dataset: "cnep", entidade: "sancao_cnep", campoChave: ["cnpj_ou_cpf_do_sancionado", "cpf_ou_cnpj_do_sancionado", "cpf_cnpj_sancionado"], campoDesambiguador: ["numero_do_processo", "data_inicio_sancao"] },
  { dataset: "cepim", entidade: "entidade_impedida_cepim", campoChave: ["cnpj", "cnpj_entidade", "cpf_cnpj"], campoDesambiguador: ["data_da_situacao"] },
];

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  // bolsa.disparar_fonte() manda os params como body JSON (cron); chamadas
  // manuais de diagnóstico usam query string — aceita os dois caminhos.
  const body = await req.json().catch(() => ({} as Record<string, string>));
  const modo = url.searchParams.get("modo") ?? body.modo ?? "coletar";
  const datasetParam = (url.searchParams.get("dataset") ?? body.dataset ?? "ceis") as Config["dataset"];
  const cfg = CONFIGS.find((c) => c.dataset === datasetParam) ?? CONFIGS[0];

  // Arquivos do dia publicam com atraso variável por dataset (CEIS/CNEP
  // costumam sair no mesmo dia ou D+1; CEPIM demora mais — confirmado
  // 2026-09-05: hoje e D-1 devolvem 403 AccessDenied real do S3, D-2 devolve
  // 200 com zip real). Tenta hoje e recua até 4 dias, usa o primeiro que
  // responder OK — evita fixar um atraso específico por dataset.
  function formatarYmd(d: Date): string {
    return `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, "0")}${String(d.getUTCDate()).padStart(2, "0")}`;
  }
  let ymd = "";
  let fileUrl = "";
  let res: Response | null = null;
  const tentativas: { ymd: string; status: number }[] = [];
  for (let dias = 0; dias <= 4; dias++) {
    const d = new Date();
    d.setUTCDate(d.getUTCDate() - dias);
    const ymdTentativa = formatarYmd(d);
    const urlTentativa = `https://portaldatransparencia.gov.br/download-de-dados/${cfg.dataset}/${ymdTentativa}`;
    const r = await fetch(urlTentativa, { headers: { "user-agent": UA, accept: "*/*" }, signal: AbortSignal.timeout(30000) });
    tentativas.push({ ymd: ymdTentativa, status: r.status });
    if (r.ok) { ymd = ymdTentativa; fileUrl = urlTentativa; res = r; break; }
  }

  const stats = { dataset: cfg.dataset, ymd_usado: ymd || null, tentativas_data: tentativas, registros_vistos: 0, novos: 0, atualizados: 0, sem_mudanca: 0, erros: 0, campo_chave_usado: "", headers_amostra: [] as string[], detalhes: [] as string[] };
  let logId: number | null = null;
  try {
    const rLog = await sql`insert into bolsa.coleta_log (fonte_id, job) values (${FONTE}, ${"sancoes_" + cfg.dataset}) returning id`;
    logId = rLog[0].id;
  } catch { /* log não fatal */ }

  try {
    await sql`select bolsa.garantir_fonte(${FONTE}, 'Portal da Transparência (CGU)', 'https://portaldatransparencia.gov.br', ${sql.json({
      licitacoes_bulk: true, ceis: true, cnep: true, cepim: true,
    })}::jsonb)`;
    if (!res || !res.ok) {
      stats.erros++; stats.detalhes.push(`nenhum arquivo disponivel nas ultimas ${tentativas.length} datas testadas (ainda nao publicado)`);
      return new Response(JSON.stringify(stats), { headers: { "content-type": "application/json" } });
    }
    const buf = new Uint8Array(await res.arrayBuffer());
    const hash = await sha256(buf);

    const arquivos = unzipSync(buf);
    const nomeCsv = Object.keys(arquivos).find((n) => n.toLowerCase().endsWith(".csv"));
    if (!nomeCsv) { stats.erros++; stats.detalhes.push("CSV não encontrado dentro do zip"); throw new Error("sem csv"); }

    const dec = new TextDecoder("iso-8859-1");
    const texto = dec.decode(arquivos[nomeCsv]);
    const gerador = linhasCsv(texto);
    const primeira = gerador.next();
    if (primeira.done) { stats.erros++; stats.detalhes.push("csv vazio"); throw new Error("csv vazio"); }
    const headers = primeira.value.map(normalizaChave);
    stats.headers_amostra = headers.slice(0, 20);

    await sql`insert into bolsa.raw_payloads (fonte_id, url, contexto, http_status, content_hash, payload)
              values (${FONTE}, ${fileUrl}, ${"sancoes_" + cfg.dataset}, ${res.status}, ${hash}, ${sql.json({ headers, tamanho_bytes: buf.length })}::jsonb)
              on conflict (url, content_hash) do nothing`;

    if (modo === "inspecionar") {
      const amostra: string[][] = [];
      for (const linha of gerador) { amostra.push(linha); if (amostra.length >= 3) break; }
      return new Response(JSON.stringify({ ...stats, headers_completos: headers, amostra_linhas: amostra }), { headers: { "content-type": "application/json" } });
    }

    const idxChave = cfg.campoChave.map((c) => headers.indexOf(c)).find((i) => i >= 0) ?? -1;
    const idxDesamb = cfg.campoDesambiguador.map((c) => headers.indexOf(c)).find((i) => i >= 0) ?? -1;
    stats.campo_chave_usado = idxChave >= 0 ? headers[idxChave] : "NENHUM_ENCONTRADO";
    const LIMITE_REGISTROS = 300;
    const chaveCk = "sancoes_" + cfg.dataset + ":cursor";

    const ckRows = await sql`select valor from bolsa.checkpoints where chave = ${chaveCk}`;
    const ckAnterior = ckRows[0]?.valor as { ymd?: string; proximo_indice?: number } | undefined;
    const cursorInicial = ckAnterior?.ymd === ymd ? (ckAnterior.proximo_indice ?? 0) : 0;

    let indice = 0;
    let processados = 0;
    let terminou = true;
    for (const linha of gerador) {
      if (indice < cursorInicial) { indice++; continue; }
      if (processados >= LIMITE_REGISTROS) { terminou = false; break; }
      indice++;
      processados++;
      stats.registros_vistos++;
      try {
        const dados: Record<string, string> = {};
        headers.forEach((h, i) => { dados[h] = linha[i] ?? ""; });
        const chaveDoc = idxChave >= 0 ? (linha[idxChave] ?? "").replace(/\D/g, "") : "";
        if (!chaveDoc) { stats.erros++; continue; }
        const desamb = idxDesamb >= 0 ? normalizaChave(linha[idxDesamb] ?? "") : "";
        const chave = `${cfg.dataset}:${chaveDoc}:${desamb || indice}`;

        const rows = await sql`select bolsa.registrar_estado(${cfg.entidade}, ${chave}, ${FONTE}, ${sql.json(dados)}::jsonb) as r`;
        const r = (rows[0] as any).r;
        if (r.novo) stats.novos++;
        else if (r.mudancas.length > 0) stats.atualizados++;
        else stats.sem_mudanca++;

        // sem contrapartida no PNCP: canônico direto por documento, nunca órfão
        const chaveCanonica = `${cfg.dataset}:${chaveDoc}`;
        await sql`insert into bolsa.proc_canonico (chave_canonica) values (${chaveCanonica}) on conflict (chave_canonica) do nothing`;
        const canRows = await sql`select id from bolsa.proc_canonico where chave_canonica = ${chaveCanonica}`;
        const canonicoId = canRows[0]?.id;
        if (canonicoId) {
          await sql`insert into bolsa.proc_fontes (canonico_id, fonte, tabela, registro_chave, url_original)
                    values (${canonicoId}, ${FONTE}, 'bolsa.estado_atual', ${chave}, ${fileUrl})
                    on conflict (fonte, tabela, registro_chave) do nothing`;
          await sql`update bolsa.estado_atual set canonico_id = ${canonicoId}
                    where fonte_id = ${FONTE} and entidade = ${cfg.entidade} and chave = ${chave}`;
        }
      } catch (e) {
        stats.erros++;
        if (stats.detalhes.length < 10) stats.detalhes.push(String((e as Error)?.message ?? e));
      }
    }

    await sql`insert into bolsa.checkpoints (chave, valor, atualizado_em)
              values (${chaveCk}, ${sql.json({ ymd, sha256: hash, proximo_indice: indice, terminou, ultima_execucao: new Date().toISOString() })}::jsonb, now())
              on conflict (chave) do update set valor = excluded.valor, atualizado_em = now()`;
    (stats as any).cursor_final = indice;
    (stats as any).terminou_arquivo_do_dia = terminou;
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
