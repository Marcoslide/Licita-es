// BOLSA — conector BNC (Bolsa Nacional de Compras) v1
// Capacidade REAL e comprovada via discovery (2026-09-04): a listagem
// pública inicial (`/Process/ProcessSearchPublic?param1=0`) retorna até
// ~100 processos mais recentes já renderizados em HTML, SEM exigir
// login nem captcha. A busca filtrada por parâmetros
// (`/Process/GetProcessByParams`) EXIGE token de reCAPTCHA v2 invisible
// gerado client-side — essa capacidade fica marcada como indisponível,
// não contornada (instrução explícita: nunca burlar CAPTCHA/anti-bot).
//
// Capacidade coberta aqui: listagem contínua tipo "delta" (mesmo padrão
// do bolsa_delta do PNCP) — cada tick relê os processos mais recentes,
// registra via o motor genérico (RAW->versão->diff->evento) e detecta
// mudança de situação/datas sem lista de campos hardcoded por portal.
// Chave é construída a partir de dados de negócio estáveis (órgão +
// número + modalidade), não do token de sessão da URL (que muda a cada
// carga da página e não serve como identificador persistente).
import { criarSql, garantirFonte, fetchComRetry, registrarEstado } from "../_shared/motor.ts";

const BASE = "https://bnccompras.com";
const FONTE = "bnc";

function decodeEntities(s: string): string {
  return s
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
    .replace(/&amp;/g, "&").replace(/&aacute;/gi, "á").replace(/&eacute;/gi, "é")
    .replace(/&iacute;/gi, "í").replace(/&oacute;/gi, "ó").replace(/&uacute;/gi, "ú")
    .replace(/&atilde;/gi, "ã").replace(/&otilde;/gi, "õ").replace(/&ccedil;/gi, "ç")
    .replace(/&nbsp;/g, " ").trim();
}

function slug(s: string): string {
  return s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

interface ProcessoBnc {
  url_detalhe: string; orgao: string; numero: string; modalidade: string;
  cidade_uf: string; situacao: string; data_publicacao: string; data_sessao: string;
}

function extrairProcessos(html: string): ProcessoBnc[] {
  const out: ProcessoBnc[] = [];
  const linhaRe = /<tr>\s*<td class="tablebutton"><a[^>]+href="([^"]+)"[^>]*>.*?<\/a><\/td>\s*<td class="orgnamewidth">([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<td>([^<]*)<\/td>\s*<\/tr>/g;
  let m: RegExpExecArray | null;
  while ((m = linhaRe.exec(html))) {
    out.push({
      url_detalhe: BASE + decodeEntities(m[1]).replace(/&amp;/g, "&"),
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

Deno.serve(async (_req: Request) => {
  const sql = criarSql();
  const stats = { encontrados: 0, novos: 0, atualizados: 0, sem_mudanca: 0, erros: 0, detalhes: [] as string[] };
  try {
    await garantirFonte(sql, FONTE, "Bolsa Nacional de Compras (BNC)", BASE, {
      listagem_publica: true, busca_filtrada: false, motivo_busca_filtrada: "reCAPTCHA v2 invisible exigido em GetProcessByParams — não contornado",
    });

    const r = await fetchComRetry(sql, FONTE, `${BASE}/Process/ProcessSearchPublic?param1=0`, "listagem_publica", { timeoutMs: 20000 });
    if (!r.ok) {
      stats.erros++; stats.detalhes.push(`listagem: HTTP ${r.status}`);
      return new Response(JSON.stringify(stats), { headers: { "content-type": "application/json" } });
    }

    const processos = extrairProcessos(r.texto);
    stats.encontrados = processos.length;

    for (const p of processos) {
      try {
        const chave = `${slug(p.orgao)}:${slug(p.numero)}:${slug(p.modalidade)}`;
        const resultado = await registrarEstado(sql, "processo_disputa", chave, FONTE, {
          orgao: p.orgao, numero: p.numero, modalidade: p.modalidade, cidade_uf: p.cidade_uf,
          situacao: p.situacao, data_publicacao: p.data_publicacao, data_sessao: p.data_sessao,
          url_detalhe: p.url_detalhe,
        });
        if (resultado.novo) stats.novos++;
        else if (resultado.mudancas.length > 0) stats.atualizados++;
        else stats.sem_mudanca++;
      } catch (e) {
        stats.erros++;
        if (stats.detalhes.length < 10) stats.detalhes.push(`processo ${p.numero}: ${String((e as Error).message)}`);
      }
    }
  } catch (e) {
    stats.erros++; stats.detalhes.push(String((e as Error)?.message ?? e));
  }
  return new Response(JSON.stringify(stats), { headers: { "content-type": "application/json" } });
});
