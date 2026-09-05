// ============================================================
// BOLSA — conector M2A Compras (M2A Tecnologia) v3
// Wave 2 #7 aprofundado. compras.m2atecnologia.com.br — portal real
// (não institucional), citado em editais municipais do Ceará.
//
// Discovery (2026-09-05): listagem em /processos/index/ é renderizada por
// Django server-side; o filtro/busca dispara via AJAX real:
// GET /processos/tabela/?search=&regiao=&uf=&municipio=&modalidade=&page=N
// (achado no <script> inline da própria página, função
// datatableReloadProcessos()). Resposta JSON limpa ({html_table: "..."}),
// sem captcha/WAF/auth. 20 processos por página, paginação real (page=500
// ainda retorna dados reais distintos; page muito além do fim devolve uma
// página de erro HTML, não JSON — usado como sinal de fim).
//
// Cada card tem um UUID hex estável na própria URL
// (/processos/publicacao/{uuid}/{slug}/) — usado como chave, mais robusto
// que índice de página. Mesma entidade 'processo_disputa' e mesmo formato
// de campos (orgao/numero/modalidade/situacao/cidade_uf/data_sessao) da
// família BNC/BLL/Compras RS — reaproveita
// bolsa.resolver_canonico_processo_disputa() sem nenhuma modificação.
// ============================================================
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });
const BASE = "https://compras.m2atecnologia.com.br";
const FONTE = "m2a";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";

interface Item {
  uuid: string; slug: string; titulo: string;
  modalidade: string | null; modoDisputa: string | null;
  abertura: string | null; situacao: string | null;
  numeroRaw: string | null; orgao: string | null; cidadeUf: string | null;
}

function campoApos(chunk: string, label: string): string | null {
  const re = new RegExp(`${label}\\s*<\\/h6>[\\s\\S]{0,200}?<b>([^<]+)<\\/b>`);
  const m = re.exec(chunk);
  return m ? m[1].trim() : null;
}

function aberturaParaIso(txt: string | null): string | null {
  if (!txt) return null;
  const m = /(\d{2})\/(\d{2})\/(\d{4})\s*às\s*(\d{2}):(\d{2})/.exec(txt);
  if (!m) return null;
  const [, d, mo, y, h, mi] = m;
  return `${y}-${mo}-${d}T${h}:${mi}:00`;
}

function extrairItens(html: string): Item[] {
  const blocos = html.split('<section class="mb-2"').slice(1);
  const itens: Item[] = [];
  for (const b of blocos) {
    const mTitulo = /<span href="\/processos\/publicacao\/([a-f0-9]+)\/([^"]+)\/">([^<]+)<\/span>/.exec(b);
    if (!mTitulo) continue;
    const mNumero = /<h5[^>]*>([^<]+)<\/h5>/.exec(b);
    const mOrgao = /<h6 class="text-primary[^"]*"[^>]*>([^<]+)<\/h6>/.exec(b);
    let orgao: string | null = null;
    let cidadeUf: string | null = null;
    if (mOrgao) {
      const raw = mOrgao[1].trim();
      const idx = raw.lastIndexOf(" - ");
      if (idx >= 0) {
        orgao = raw.slice(0, idx).trim();
        const resto = raw.slice(idx + 3).trim();
        const partes = resto.split(" / ").map((s) => s.trim());
        cidadeUf = partes.length === 2 ? `${partes[0]}-${partes[1]}` : resto;
      } else {
        orgao = raw;
      }
    }
    itens.push({
      uuid: mTitulo[1], slug: mTitulo[2], titulo: mTitulo[3].trim(),
      modalidade: campoApos(b, "Modalidade"),
      modoDisputa: campoApos(b, "Modo de disputa"),
      abertura: campoApos(b, "Abertura do certame"),
      situacao: campoApos(b, "Situação"),
      numeroRaw: mNumero ? mNumero[1].trim() : null,
      orgao, cidadeUf,
    });
  }
  return itens;
}

Deno.serve(async (req: Request) => {
  const stats = { registros_vistos: 0, novos: 0, atualizados: 0, sem_mudanca: 0, erros: 0, detalhes: [] as string[] };
  let logId: number | null = null;
  const chaveCk = "m2a:cursor";
  const LIMITE_POR_EXECUCAO = 300;

  try {
    const rLog = await sql`insert into bolsa.coleta_log (fonte_id, job) values (${FONTE}, 'listagem') returning id`;
    logId = rLog[0].id;
  } catch { /* log não fatal */ }

  try {
    await sql`select bolsa.garantir_fonte(${FONTE}, 'M2A Compras', ${BASE}, ${sql.json({
      listagem_publica: true, endpoint_real: "/processos/tabela/", paginacao: "page=N, 20 por pagina",
    })}::jsonb)`;

    const ckRows = await sql`select valor from bolsa.checkpoints where chave = ${chaveCk}`;
    const ckAnterior = ckRows[0]?.valor as { pagina?: number; terminou?: boolean } | undefined;
    let pagina = ckAnterior?.terminou ? 1 : (ckAnterior?.pagina ?? 1);

    let processadosNestaExecucao = 0;
    let terminouVarredura = false;

    while (processadosNestaExecucao < LIMITE_POR_EXECUCAO) {
      const url = `${BASE}/processos/tabela/?search=&regiao=&uf=&municipio=&modalidade=&page=${pagina}`;
      const res = await fetch(url, { headers: { "user-agent": UA, accept: "application/json" }, signal: AbortSignal.timeout(20000) });
      const texto = await res.text();
      let j: { html_table?: string };
      try {
        j = JSON.parse(texto);
      } catch {
        terminouVarredura = true; // page além do fim devolve HTML de erro, não JSON
        break;
      }
      const itens = extrairItens(String(j.html_table ?? ""));
      if (itens.length === 0) { terminouVarredura = true; break; }

      for (const it of itens) {
        stats.registros_vistos++;
        processadosNestaExecucao++;
        try {
          const chave = `m2a:${it.uuid}`;
          const rows = await sql`select bolsa.registrar_estado('processo_disputa', ${chave}, ${FONTE}, ${sql.json({
            orgao: it.orgao ?? "", numero: it.numeroRaw ?? "", modalidade: it.modalidade,
            cidade_uf: it.cidadeUf ?? "", situacao: it.situacao,
            data_publicacao: null, data_sessao: aberturaParaIso(it.abertura),
            modo_disputa: it.modoDisputa, descricao: it.titulo,
            uuid_m2a: it.uuid, slug_m2a: it.slug,
            url_processo: `${BASE}/processos/publicacao/${it.uuid}/${it.slug}/`,
          })}::jsonb) as r`;
          const r = (rows[0] as any).r;
          if (r.novo) stats.novos++;
          else if (r.mudancas.length > 0) stats.atualizados++;
          else stats.sem_mudanca++;
        } catch (e) {
          stats.erros++;
          if (stats.detalhes.length < 10) stats.detalhes.push(String((e as Error)?.message ?? e));
        }
      }

      pagina++;
      if (processadosNestaExecucao >= LIMITE_POR_EXECUCAO) break;
    }

    await sql`insert into bolsa.checkpoints (chave, valor, atualizado_em)
              values (${chaveCk}, ${sql.json({ pagina, terminou: terminouVarredura, ultima_execucao: new Date().toISOString() })}::jsonb, now())
              on conflict (chave) do update set valor = excluded.valor, atualizado_em = now()`;
    (stats as any).pagina_final = pagina;
    (stats as any).terminou_varredura = terminouVarredura;

    await sql`update bolsa.fontes set status = 'ATIVA', ultimo_sucesso_em = now() where id = ${FONTE}`;
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
