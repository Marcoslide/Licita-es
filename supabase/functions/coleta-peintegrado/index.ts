// ============================================================
// BOLSA — conector PE Integrado (Pernambuco) v1
// Wave 3 #3. www.peintegrado.pe.gov.br — ASP.NET WebForms clássico.
//
// Discovery de 2ª camada (2026-09-05): a listagem real
// (tbody#trListaMuralProcesso, vazio no HTML) é populada via
// ASP.NET AJAX PageMethods (ScriptManager), NÃO via .asmx (esse padrão
// existe na mesma app para outras telas, mas não para esta) — achado no
// arquivo específico da página (Portal/Scripts/NovaPagina/
// licitacoes-em-andamento.js, referenciado só nesta página, não nos 3
// bundles compartilhados portaljs1/2/3 já mapeados):
// POST /Portal/Pages/LicitacoesEmAndamento.aspx/PesquisarLicitacoesEmAndamento
// Content-Type: application/json — retorna {d:{Dados:[...],TotalRegistros}}.
// 655 processos totais confirmados. reCAPTCHA v3 presente na página é
// invisível/automático e ligado à ação "homepage" (login) — confirmado
// que o endpoint de listagem funciona sem nenhum token de captcha
// (erros reais do .NET foram só de parâmetro/tipo, nunca de auth/captcha).
// Nenhuma proteção contornada.
//
// Mesma entidade 'processo_disputa' e mesmo formato de campos da família
// BNC/BLL/Compras RS/M2A/SIADES — reaproveita
// bolsa.resolver_canonico_processo_disputa() sem modificação.
// ============================================================
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });
const BASE = "https://www.peintegrado.pe.gov.br";
const FONTE = "peintegrado";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";

interface Item {
  nCdProcesso: number; sNrProcessoDisplay: string; sNrEdital: string; sDsObjeto: string;
  sNmEmpresa: string; sNmApelido: string; tDtInicial: string | null; tDtFinal: string | null;
  nCdSituacao: number; sDsSituacao: string; nCdModulo: number; sNmModalidade: string;
  dVlEstimado: number; dVlNegociado: number; dVlEconomia: number; dPcEconomia: number;
}

function dataDotNetParaIso(s: string | null): string | null {
  if (!s) return null;
  const m = /\/Date\((-?\d+)\)\//.exec(s);
  if (!m) return null;
  const ms = Number(m[1]);
  if (!Number.isFinite(ms) || ms < 0) return null;
  return new Date(ms).toISOString();
}

async function buscarPagina(offset: number, tamanho: number): Promise<{ itens: Item[]; total: number }> {
  const corpo = {
    dtoProcesso: {
      nAnoFinalizacao: 0, tmpTipoMuralProcesso: 0, nCdModulo: 0, tmpTipoMuralVisao: 999,
      nCdSituacao: 0, tDtInicial: "2015-01-01", tDtFinal: "2027-12-31", nCdTipoProcesso: 0,
      sNmUnidadeCompradora: "", sNmUnidadeGestora: "", nCdProcesso: 0,
      sOrdenarPor: "TDTFINAL", sOrdenarPorDirecao: "DESC",
      dtoPaginacao: { nPaginaDe: offset, nPaginaAte: tamanho },
      dtoIdioma: { nCdIdioma: 1 },
      SituacaoLicitacao: "Em_Andamento", sNmUnidadesGestoras: "", sNmUnidadesCompradoras: "",
    },
    quantidadePorPagina: tamanho,
  };
  const res = await fetch(`${BASE}/Portal/Pages/LicitacoesEmAndamento.aspx/PesquisarLicitacoesEmAndamento`, {
    method: "POST",
    headers: { "user-agent": UA, "content-type": "application/json; charset=utf-8", "x-requested-with": "XMLHttpRequest", accept: "application/json" },
    body: JSON.stringify(corpo),
    signal: AbortSignal.timeout(20000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const j = await res.json();
  return { itens: j.d?.Dados ?? [], total: j.d?.TotalRegistros ?? 0 };
}

Deno.serve(async (_req: Request) => {
  const stats = { registros_vistos: 0, novos: 0, atualizados: 0, sem_mudanca: 0, erros: 0, total_registros: 0, detalhes: [] as string[] };
  let logId: number | null = null;
  const chaveCk = "peintegrado:cursor";
  const TAMANHO_PAGINA = 50;
  const LIMITE_POR_EXECUCAO = 300;

  try {
    const rLog = await sql`insert into bolsa.coleta_log (fonte_id, job) values (${FONTE}, 'listagem') returning id`;
    logId = rLog[0].id;
  } catch { /* log não fatal */ }

  try {
    await sql`select bolsa.garantir_fonte(${FONTE}, 'PE Integrado', ${BASE}, ${sql.json({
      listagem_publica: true, endpoint_real: "/Portal/Pages/LicitacoesEmAndamento.aspx/PesquisarLicitacoesEmAndamento",
      tecnologia: "ASP.NET WebForms PageMethods", paginacao: "offset/tamanho (dtoPaginacao)",
    })}::jsonb)`;

    const ckRows = await sql`select valor from bolsa.checkpoints where chave = ${chaveCk}`;
    const ckAnterior = ckRows[0]?.valor as { offset?: number; terminou?: boolean } | undefined;
    let offset = ckAnterior?.terminou ? 0 : (ckAnterior?.offset ?? 0);

    let processadosNestaExecucao = 0;
    let terminouVarredura = false;
    let totalRegistros = 0;

    while (processadosNestaExecucao < LIMITE_POR_EXECUCAO) {
      const { itens, total } = await buscarPagina(offset, TAMANHO_PAGINA);
      totalRegistros = total;
      if (itens.length === 0) { terminouVarredura = true; break; }

      for (const it of itens) {
        stats.registros_vistos++;
        processadosNestaExecucao++;
        try {
          const chave = `peintegrado:${it.nCdProcesso}`;
          const rows = await sql`select bolsa.registrar_estado('processo_disputa', ${chave}, ${FONTE}, ${sql.json({
            orgao: it.sNmEmpresa ?? "", numero: it.sNrProcessoDisplay ?? it.sNrEdital ?? "", modalidade: it.sNmModalidade,
            cidade_uf: "-PE", situacao: it.sDsSituacao,
            data_publicacao: null, data_sessao: dataDotNetParaIso(it.tDtInicial),
            data_final_sessao: dataDotNetParaIso(it.tDtFinal), descricao: it.sDsObjeto,
            apelido_orgao: it.sNmApelido, valor_estimado: it.dVlEstimado, valor_negociado: it.dVlNegociado,
            valor_economia: it.dVlEconomia, percentual_economia: it.dPcEconomia,
            id_pe_integrado: it.nCdProcesso, codigo_modulo: it.nCdModulo,
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

      offset += itens.length;
      if (offset >= total) { terminouVarredura = true; break; }
      if (processadosNestaExecucao >= LIMITE_POR_EXECUCAO) break;
    }

    stats.total_registros = totalRegistros;
    await sql`insert into bolsa.checkpoints (chave, valor, atualizado_em)
              values (${chaveCk}, ${sql.json({ offset, total_registros: totalRegistros, terminou: terminouVarredura, ultima_execucao: new Date().toISOString() })}::jsonb, now())
              on conflict (chave) do update set valor = excluded.valor, atualizado_em = now()`;
    (stats as any).offset_final = offset;
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
