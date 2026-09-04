// ============================================================
// MOTOR GENÉRICO DE COLETA — módulo compartilhado (Wave 1 em diante)
// Fecha o gap reportado no relatório final do PROMPT 01: RAW ->
// versão -> diff -> proveniência -> evento sem reimplementação por
// portal. Qualquer conector novo importa este arquivo em vez de
// copiar/colar a lógica de captura+diff do coleta-pncp.
//
// Uso típico dentro de um conector:
//   import { criarSql, garantirFonte, fetchComRetry, registrarEstado } from "../_shared/motor.ts";
//   const sql = criarSql();
//   await garantirFonte(sql, "bnc", "Bolsa Nacional de Compras", "https://bnccompras.com/");
//   const r = await fetchComRetry(sql, "bnc", url, "sessao");
//   const resultado = await registrarEstado(sql, "sessao_disputa", chave, "bnc", campos);
//   // resultado.novo / resultado.versao / resultado.mudancas já vêm prontos.
// ============================================================
import postgres from "npm:postgres@3.4.5";

export type Sql = ReturnType<typeof postgres>;

export function criarSql(): Sql {
  return postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });
}

export async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Garante a linha em bolsa.fontes (FK exigida por bolsa.raw_payloads.fonte_id).
// Idempotente — chamar no início de cada invocação não tem custo real.
export async function garantirFonte(sql: Sql, id: string, nome: string, baseUrl: string, capabilities: Record<string, unknown> = {}) {
  // sql.json() (nunca JSON.stringify + ::jsonb manual) — ver nota em
  // registrarEstado abaixo sobre a dupla-serialização que corrompeu
  // bolsa.estado_atual.dados em 2026-09-04.
  await sql`select bolsa.garantir_fonte(${id}, ${nome}, ${baseUrl}, ${sql.json(capabilities)}::jsonb)`;
}

// Grava a resposta bruta em bolsa.raw_payloads (RAW imutável, deduplicada por
// url+hash). Não fatal: falha aqui nunca deve derrubar a coleta principal.
export async function capturarRaw(sql: Sql, fonteId: string, url: string, contexto: string, httpStatus: number, texto: string): Promise<string> {
  const hash = await sha256(texto || "null");
  try {
    await sql`insert into bolsa.raw_payloads (fonte_id, url, contexto, http_status, content_hash, payload)
              values (${fonteId}, ${url}, ${contexto}, ${httpStatus}, ${hash}, ${texto || "null"}::jsonb)
              on conflict (url, content_hash) do nothing`;
  } catch { /* RAW é auditoria, não bloqueia o fluxo principal */ }
  return hash;
}

export interface RespostaFetch { ok: boolean; status: number; texto: string; body: unknown | null }

// Fetch com retry/backoff + captura RAW automática. Só usa endpoints
// públicos — não contorna CAPTCHA/anti-bot (isso é decisão do conector,
// que deve marcar a capacidade como indisponível se a fonte exigir).
export async function fetchComRetry(
  sql: Sql, fonteId: string, url: string, contexto: string,
  opts?: { tentativas?: number; headers?: Record<string, string>; timeoutMs?: number },
): Promise<RespostaFetch> {
  const tentativas = opts?.tentativas ?? 3;
  const headers = { accept: "application/json, text/html;q=0.8", "user-agent": "BolsaLicitacoes/0.1 (coleta de dados publicos)", ...opts?.headers };
  for (let t = 0; t < tentativas; t++) {
    try {
      const res = await fetch(url, { headers, signal: AbortSignal.timeout(opts?.timeoutMs ?? 15000) });
      const texto = await res.text();
      if (res.ok) {
        await capturarRaw(sql, fonteId, url, contexto, res.status, texto);
        let body: unknown = null;
        try { body = texto ? JSON.parse(texto) : null; } catch { body = null; }
        return { ok: true, status: res.status, texto, body };
      }
      if (res.status === 429 || res.status >= 500) { await sleep(400 * 2 ** t + Math.random() * 300); continue; }
      return { ok: false, status: res.status, texto, body: null };
    } catch {
      await sleep(400 * 2 ** t + Math.random() * 300);
    }
  }
  return { ok: false, status: 0, texto: "", body: null };
}

export interface ResultadoEstado { estado_id: number; versao: number; novo: boolean; mudancas: { campo: string; de: unknown; para: unknown }[] }

// Núcleo do motor: RAW já foi gravado por fetchComRetry/capturarRaw; aqui
// entra o payload NORMALIZADO (campos já extraídos pelo conector) e o
// banco faz o diff genérico contra o estado salvo da última vez, grava
// eventos por campo alterado (sem lista hardcoded), preserva a versão
// anterior e, se canonicoId for informado, vincula em bolsa.proc_fontes
// para permitir cruzamento cross-source.
export async function registrarEstado(
  sql: Sql, entidade: string, chave: string, fonteId: string,
  campos: Record<string, unknown>, canonicoId: number | null = null, confianca = 1.0,
): Promise<ResultadoEstado> {
  // IMPORTANTE: sql.json(campos), nunca JSON.stringify(campos) + ::jsonb —
  // o driver postgres.js já serializa objeto JS -> jsonb; stringificar
  // manualmente antes faz dupla-serialização e grava `dados` como STRING
  // em vez de objeto (bug real encontrado e corrigido em 2026-09-04,
  // migration fix_registrar_estado_guarda_tipo_jsonb, que também blindou
  // a função contra esse tipo de entrada malformada).
  const rows = await sql`select bolsa.registrar_estado(${entidade}, ${chave}, ${fonteId}, ${sql.json(campos)}::jsonb, ${canonicoId}, ${confianca}) as r`;
  const r = (rows[0] as any).r;
  return { estado_id: r.estado_id, versao: r.versao, novo: r.novo, mudancas: r.mudancas ?? [] };
}
