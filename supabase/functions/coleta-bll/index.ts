// ============================================================
// BOLSA — conector BLL Compras (Bolsa de Licitações do Brasil) v1
// bllcompras.com — Wave 1 P0.
//
// MESMA FAMÍLIA DE TECNOLOGIA da BNC (bnccompras.com): confirmado por
// discovery em 2026-09-04 — mesmíssima estrutura de HTML/rotas
// (/Process/ProcessSearchPublic, /Process/ProcessView, /Process/
// ProcessFiles, /Process/ProcessDocuments, /BatchList/
// GetProcessMessageView), mesmos títulos de modal ("Arquivos do
// Processo", "Documentos exigidos no processo", "Mensagens do
// Processo" — texto idêntico, não só parecido), mesmo servidor
// Microsoft-IIS/10.0 + jQuery + reCAPTCHA. Este arquivo é o adapter
// dessa família aplicado a um segundo cliente/marca — mesma lógica de
// parsing da BNC, só troca BASE/FONTE. Reuso pleno da entidade genérica
// (processo_disputa / processo_disputa_detalhe / documento_processo,
// as mesmas usadas pela BNC — fonte_id já distingue a origem).
//
// Motor genérico usado DIRETO via SQL (bolsa.registrar_estado) — regra 5
// da autorização da Wave 1: _shared/motor.ts não é usado ainda porque seu
// bundling entre arquivos nunca foi comprovado no deploy. Toda gravação
// jsonb usa sql.json(obj), nunca JSON.stringify(obj)::jsonb (regra 6).
//
// Capacidades confirmadas (herdadas da mesma plataforma, reverificadas
// nesta fonte especificamente antes de deployar):
//  - Listagem pública (/Process/ProcessSearchPublic?param1=0): sem
//    login/captcha, confirmado com dado real (MUNICIPIO DE PEROLA,
//    MUNICIPIO DE TEIXEIRA DE FREITAS etc.).
//  - Detalhe/Arquivos/Documentos/Mensagens: confirmados 200 OK, sem
//    captcha, mesma estrutura da BNC.
//  - Lotes/Itens (/Process/ProcessBatches via GetBatchesInfo): mesma
//    plataforma da BNC, mesmo ExecuteCaptcha('processView') — reCAPTCHA
//    v2 invisible. Herdado como INDISPONÍVEL sem re-testar em cada
//    processo (mesma engine, mesmo botão, mesmo JS) — nunca contornado.
//
// Chave estável: órgão + número do edital + modalidade (não o token
// opaco da URL, que muda a cada carga de página).
// ============================================================
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });

const BASE = "https://bllcompras.com";
const FONTE = "bll";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function decodeEntities(s: string): string {
  return s
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
    .replace(/&amp;/g, "&").replace(/&aacute;/gi, "á").replace(/&eacute;/gi, "é")
    .replace(/&iacute;/gi, "í").replace(/&oacute;/gi, "ó").replace(/&uacute;/gi, "ú")
    .replace(/&atilde;/gi, "ã").replace(/&otilde;/gi, "õ").replace(/&ccedil;/gi, "ç")
    .replace(/&aring;|&#194;/gi, "").replace(/&nbsp;/g, " ").trim();
}

function slug(s: string): string {
  return s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

interface Stats {
  processos_vistos: number; processos_novos: number; processos_atualizados: number; processos_sem_mudanca: number;
  enriquecidos: number; arquivos_encontrados: number; erros: number; detalhes: string[];
}
const novoStats = (): Stats => ({ processos_vistos: 0, processos_novos: 0, processos_atualizados: 0, processos_sem_mudanca: 0, enriquecidos: 0, arquivos_encontrados: 0, erros: 0, detalhes: [] });
const nota = (s: Stats, m: string) => { if (s.detalhes.length < 12) s.detalhes.push(m); };

async function capturarRaw(url: string, contexto: string, httpStatus: number, texto: string) {
  const hash = await sha256(texto || "null");
  try {
    await sql`insert into bolsa.raw_payloads (fonte_id, url, contexto, http_status, content_hash, payload)
              values (${FONTE}, ${url}, ${contexto}, ${httpStatus}, ${hash}, ${sql.json({ texto: texto.slice(0, 200000) })}::jsonb)
              on conflict (url, content_hash) do nothing`;
  } catch { /* RAW é auditoria, não bloqueia o fluxo principal */ }
}

async function fetchTexto(url: string, contexto: string, stats: Stats, tentativas = 2): Promise<{ ok: boolean; status: number; texto: string }> {
  for (let t = 0; t < tentativas; t++) {
    try {
      const res = await fetch(url, {
        headers: { accept: "text/html,application/json;q=0.9,*/*;q=0.8", "user-agent": UA },
        signal: AbortSignal.timeout(15000),
      });
      const texto = await res.text();
      if (res.ok) {
        await capturarRaw(url, contexto, res.status, texto);
        return { ok: true, status: res.status, texto };
      }
      if (res.status === 429 || res.status >= 500) { await sleep(500 * 2 ** t); continue; }
      return { ok: false, status: res.status, texto: "" };
    } catch (e) {
      nota(stats, `fetch ${contexto}: ${String((e as Error)?.message ?? e)}`);
      await sleep(500 * 2 ** t);
    }
  }
  return { ok: false, status: 0, texto: "" };
}

interface ProcessoBll {
  token: string; orgao: string; numero: string; modalidade: string;
  cidade_uf: string; situacao: string; data_publicacao: string; data_sessao: string;
}

function extrairProcessos(html: string): ProcessoBll[] {
  const out: ProcessoBll[] = [];
  const linhaRe = /<tr>\s*<td class="tablebutton"><a[^>]+href="\/Process\/ProcessView\?param1=([^"]+)"[^>]*>.*?<\/a><\/td>\s*<td class="orgnamewidth">([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<\/tr>/g;
  let m: RegExpExecArray | null;
  while ((m = linhaRe.exec(html))) {
    out.push({
      token: m[1],
      orgao: decodeEntities(m[2]),
      numero: decodeEntities(m[3]),
      modalidade: decodeEntities(m[4]),
      cidade_uf: decodeEntities(m[5]),
      situacao: decodeEntities(m[6]),
      data_publicacao: decodeEntities(m[7]),
      data_sessao: decodeEntities(m[8]),
    });
  }
  return out;
}

function campoInput(html: string, id: string): string | null {
  const re = new RegExp(`id="${id}"[^>]*value="([^"]*)"`);
  const m = re.exec(html);
  return m ? decodeEntities(m[1]) : null;
}

function extrairDetalhe(html: string): Record<string, string | null> {
  return {
    numero_processo_administrativo: campoInput(html, "AdmNumber"),
    condutor: campoInput(html, "Conductor"),
    autoridade: campoInput(html, "Authority"),
    tipo_contrato: campoInput(html, "ContractKind"),
    publicacao: campoInput(html, "PublicationTime"),
    inicio_recebimento_proposta: campoInput(html, "ProposalReceivingStart"),
    fim_recebimento_proposta: campoInput(html, "ProposalAnalysisStart"),
    inicio_disputa: campoInput(html, "DisputeStart"),
    fim_impugnacao: campoInput(html, "ImpeachmentEndTime"),
    fim_esclarecimentos: campoInput(html, "ClarifyEndTime"),
    prazo_recursos: campoInput(html, "AppealReceivingText"),
  };
}

interface ArquivoBll { titulo: string; criado_em: string; url: string }

function extrairArquivos(jsonTexto: string): ArquivoBll[] {
  const out: ArquivoBll[] = [];
  let htmlDecodificado = "";
  try {
    const j = JSON.parse(jsonTexto);
    htmlDecodificado = String(j?.html ?? "");
  } catch { return out; }
  const linhaRe = /<td>([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<td\s*class="tablebutton">\s*<a href="([^"]+)"/g;
  let m: RegExpExecArray | null;
  while ((m = linhaRe.exec(htmlDecodificado))) {
    out.push({ titulo: decodeEntities(m[1]), criado_em: decodeEntities(m[2]), url: m[3] });
  }
  return out;
}

Deno.serve(async (_req: Request) => {
  const stats = novoStats();
  let logId: number | null = null;
  try {
    const rLog = await sql`insert into bolsa.coleta_log (fonte_id, job) values (${FONTE}, 'listagem') returning id`;
    logId = rLog[0].id;
  } catch { /* log não fatal */ }
  try {
    await sql`select bolsa.garantir_fonte(${FONTE}, 'BLL Compras (Bolsa de Licitações do Brasil)', ${BASE}, ${sql.json({
      listagem_publica: true, detalhe_processo: true, arquivos: true,
      documentos_exigidos: "acessivel_nao_validado", mensagens: "acessivel_nao_coletado",
      impugnacoes: "acessivel_nao_coletado", esclarecimentos: "acessivel_nao_coletado",
      lotes_itens_lances_resultados: false,
      motivo_indisponivel: "ProcessBatches exige token de reCAPTCHA v2 invisible (ExecuteCaptcha) — não contornado",
      tecnologia_familia: "mesma plataforma da BNC (bnccompras.com) — confirmado por discovery 2026-09-04",
    })}::jsonb)`;

    const listagem = await fetchTexto(`${BASE}/Process/ProcessSearchPublic?param1=0`, "listagem_publica", stats);
    if (!listagem.ok) {
      stats.erros++; nota(stats, `listagem: HTTP ${listagem.status}`);
      return new Response(JSON.stringify(stats), { headers: { "content-type": "application/json" } });
    }
    const processos = extrairProcessos(listagem.texto);
    stats.processos_vistos = processos.length;

    const ckRows = await sql`select valor from bolsa.checkpoints where chave = 'bll:listagem'`;
    const enriquecidos = new Set<string>(((ckRows[0]?.valor as any)?.enriquecidos as string[]) ?? []);
    const LIMITE_ENRIQUECIMENTO = 10;
    let enriquecidosNestaExecucao = 0;

    for (const p of processos) {
      const chave = `${slug(p.orgao)}:${slug(p.numero)}:${slug(p.modalidade)}`;
      try {
        const rows = await sql`select bolsa.registrar_estado('processo_disputa', ${chave}, ${FONTE}, ${sql.json({
          orgao: p.orgao, numero: p.numero, modalidade: p.modalidade, cidade_uf: p.cidade_uf,
          situacao: p.situacao, data_publicacao: p.data_publicacao, data_sessao: p.data_sessao,
        })}::jsonb) as r`;
        const r = (rows[0] as any).r;
        if (r.novo) stats.processos_novos++;
        else if (r.mudancas.length > 0) stats.processos_atualizados++;
        else stats.processos_sem_mudanca++;

        if (!enriquecidos.has(chave) && enriquecidosNestaExecucao < LIMITE_ENRIQUECIMENTO) {
          enriquecidosNestaExecucao++;
          const qs = `param1=${p.token}`;
          await sleep(150);
          const det = await fetchTexto(`${BASE}/Process/ProcessView?${qs}`, "detalhe_processo", stats);
          if (det.ok) {
            const campos = extrairDetalhe(det.texto);
            await sql`select bolsa.registrar_estado('processo_disputa_detalhe', ${chave}, ${FONTE}, ${sql.json(campos)}::jsonb)`;
          }
          await sleep(150);
          const arq = await fetchTexto(`${BASE}/Process/ProcessFiles?${qs}`, "arquivos", stats);
          if (arq.ok) {
            const arquivos = extrairArquivos(arq.texto);
            stats.arquivos_encontrados += arquivos.length;
            for (const a of arquivos) {
              const chaveArquivo = `${chave}:${slug(a.titulo)}`;
              await sql`select bolsa.registrar_estado('documento_processo', ${chaveArquivo}, ${FONTE}, ${sql.json({
                processo_chave: chave, titulo: a.titulo, criado_em: a.criado_em, url_download: a.url,
              })}::jsonb)`;
            }
          }
          enriquecidos.add(chave);
          stats.enriquecidos++;
        }
      } catch (e) {
        stats.erros++; nota(stats, `processo ${p.numero}: ${String((e as Error).message)}`);
      }
    }

    const listaFinal = [...enriquecidos].slice(-500);
    await sql`insert into bolsa.checkpoints (chave, valor, atualizado_em)
              values ('bll:listagem', ${sql.json({ enriquecidos: listaFinal, ultima_execucao: new Date().toISOString() })}::jsonb, now())
              on conflict (chave) do update set valor = excluded.valor, atualizado_em = now()`;

    await sql`update bolsa.fontes set status = 'ATIVA', ultimo_sucesso_em = now() where id = ${FONTE}`;
  } catch (e) {
    stats.erros++; nota(stats, String((e as Error)?.message ?? e));
  }

  if (logId != null) {
    try {
      await sql`update bolsa.coleta_log set finalizado_em = now(), registros = ${stats.processos_vistos},
                inseridos = ${stats.processos_novos}, atualizados = ${stats.processos_atualizados}, ignorados = ${stats.processos_sem_mudanca},
                documentos = ${stats.arquivos_encontrados}, erros = ${stats.erros}, detalhe = ${sql.json(stats)}::jsonb
                where id = ${logId}`;
    } catch { /* log não fatal */ }
  }

  return new Response(JSON.stringify(stats), { headers: { "content-type": "application/json" } });
});
