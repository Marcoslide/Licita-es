// BOLSA — PortalTransparenciaCollector: execução financeira (empenho/liquidação/pagamento).
// A chave é lida de bolsa.segredos e nunca é exposta no código ou nos logs.
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
  prepare: false,
  max: 1,
  idle_timeout: 15,
  connect_timeout: 10,
});
const BASE = "https://api.portaldatransparencia.gov.br/api-de-dados";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

interface Stats {
  paginas: number;
  registros: number;
  inseridos: number;
  ignorados: number;
  erros: number;
  detalhes: string[];
}

const nota = (stats: Stats, message: string) => {
  if (stats.detalhes.length < 10) stats.detalhes.push(message);
};

function mapFase(value: unknown): "EMPENHO" | "LIQUIDACAO" | "PAGAMENTO" | null {
  const text = String(value ?? "").toUpperCase();
  if (text.includes("EMPENHO")) return "EMPENHO";
  if (text.includes("LIQUIDA")) return "LIQUIDACAO";
  if (text.includes("PAGAMENTO")) return "PAGAMENTO";
  return null;
}

const fasePorCodigo = {
  1: "EMPENHO",
  2: "LIQUIDACAO",
  3: "PAGAMENTO",
} as const;

const numBr = (value: unknown) => {
  if (value == null) return null;
  const number = typeof value === "string"
    ? Number(value.replace(/\./g, "").replace(",", "."))
    : Number(value);
  return Number.isFinite(number) ? number : null;
};

const dataBr = (value: unknown) => {
  if (typeof value !== "string" || !value) return null;
  const match = value.match(/^(\d{2})\/(\d{2})\/(\d{4})/);
  return match ? `${match[3]}-${match[2]}-${match[1]}` : value.slice(0, 10);
};

const textoOuCampo = (value: unknown, campo: "codigo" | "nome") => {
  if (value == null) return null;
  if (typeof value === "object") {
    const object = value as Record<string, unknown>;
    const nested = object[campo] ?? object[campo === "codigo" ? "codigoSIAFI" : "descricao"];
    return nested == null ? null : String(nested);
  }
  return String(value);
};

async function jobDespesas(params: any, stats: Stats, deadline: number, chave: string) {
  const dataEmissao = params.dataEmissao ?? (() => {
    const date = new Date(Date.now() - 2 * 864e5);
    return `${String(date.getUTCDate()).padStart(2, "0")}/${String(date.getUTCMonth() + 1).padStart(2, "0")}/${date.getUTCFullYear()}`;
  })();
  const maxPaginas = Math.max(1, Math.min(Number(params.maxPaginas ?? 2), 20));
  const faseSolicitada = params.fase == null ? null : Number(params.fase);
  const fases = faseSolicitada == null ? [1, 2, 3] : [faseSolicitada];
  const gestao = params.gestao == null ? null : String(params.gestao).replace(/\D/g, "");
  const codigoPessoa = params.codigoPessoa == null
    ? null
    : String(params.codigoPessoa).replace(/\D/g, "");
  const ano = Math.trunc(Number(params.ano ?? new Date().getUTCFullYear()));
  let unidadesGestoras: string[] = [];

  if (Array.isArray(params.unidadesGestoras)) {
    unidadesGestoras = params.unidadesGestoras
      .map((value: unknown) => String(value).replace(/\D/g, ""))
      .filter(Boolean);
  } else if (params.unidadeGestora != null) {
    unidadesGestoras = [String(params.unidadeGestora).replace(/\D/g, "")].filter(Boolean);
  } else if (!gestao && !codigoPessoa) {
    const unidades = await sql`select distinct uasg_codigo
                               from bolsa.contratos_gov
                               where uasg_codigo is not null and uasg_codigo <> ''
                               order by uasg_codigo
                               limit 25`;
    unidadesGestoras = unidades
      .map((row) => String(row.uasg_codigo).replace(/\D/g, ""))
      .filter(Boolean);
  }

  if (fases.some((fase) => ![1, 2, 3].includes(fase))) {
    stats.erros++;
    nota(stats, "fase inválida: use 1 (empenho), 2 (liquidação) ou 3 (pagamento)");
    return;
  }

  if (!codigoPessoa && !gestao && !unidadesGestoras.length) {
    stats.erros++;
    nota(stats, "a API exige unidadeGestora ou gestao; nenhuma unidade válida foi encontrada");
    return;
  }

  const alvos = unidadesGestoras.length
    ? unidadesGestoras.map((unidadeGestora) => ({ unidadeGestora, gestao }))
    : [{ unidadeGestora: null, gestao }];

  for (const alvo of alvos) {
    for (const faseCodigo of fases) {
      for (let pagina = 1; pagina <= maxPaginas; pagina++) {
      if (Date.now() > deadline) {
        nota(stats, "tempo esgotado");
        return;
      }

      const query = new URLSearchParams({ fase: String(faseCodigo), pagina: String(pagina) });
      const endpoint = codigoPessoa
        ? "/despesas/documentos-por-favorecido"
        : "/despesas/documentos";
      if (codigoPessoa) {
        query.set("codigoPessoa", codigoPessoa);
        query.set("ano", String(ano));
        query.set("ordenacaoResultado", "4");
      } else {
        query.set("dataEmissao", dataEmissao);
      }
      if (alvo.unidadeGestora) {
        query.set(codigoPessoa ? "ug" : "unidadeGestora", alvo.unidadeGestora);
      }
      if (alvo.gestao) query.set("gestao", alvo.gestao);
      const url = `${BASE}${endpoint}?${query.toString()}`;
      let body: any = null;
      try {
        const response = await fetch(url, {
          headers: {
            accept: "application/json",
            "user-agent": UA,
            "chave-api-dados": chave,
          },
          signal: AbortSignal.timeout(25000),
        });
        const text = await response.text();
        if (!response.ok) {
          nota(stats, `fase ${faseCodigo}, HTTP ${response.status}: ${text.slice(0, 120)}`);
          stats.erros++;
          if (response.status === 401) return;
          break;
        }

        const hash = await sha256(text || "null");
        await sql`insert into bolsa.raw_payloads (fonte_id, url, contexto, http_status, content_hash, payload)
                  values ('portal_transparencia', ${url}, ${codigoPessoa ? `documentos_favorecido_fase_${faseCodigo}` : `despesas_documentos_fase_${faseCodigo}`}, ${response.status}, ${hash}, ${text || "null"}::jsonb)
                  on conflict (url, content_hash) do nothing`;
        body = text ? JSON.parse(text) : null;
      } catch (error) {
        stats.erros++;
        nota(stats, `fase ${faseCodigo}, fetch: ${String((error as Error).message)}`);
        break;
      }

      const linhas: any[] = Array.isArray(body) ? body : [];
      if (!linhas.length) break;
      stats.paginas++;

      for (const item of linhas) {
        try {
          const fase = mapFase(item.fase ?? item.faseDespesa) ?? fasePorCodigo[faseCodigo as 1 | 2 | 3];
          const documento = item.codigoDocumento ?? item.documento ?? null;
          const chaveDedup = documento
            ? `${fase}:${documento}`
            : (await sha256(JSON.stringify(item))).slice(0, 32);
          const favorecidoNi = (item.codigoFavorecido ?? item.favorecido?.codigo ?? "")
            .toString()
            .replace(/\D/g, "") || null;
          const existente = await sql`select 1 from bolsa.pagamentos_transparencia where chave_dedup = ${chaveDedup}`;

          await sql`insert into bolsa.pagamentos_transparencia (
                      fase, chave_dedup, documento, data, valor, orgao_codigo, orgao_nome,
                      unidade_gestora, favorecido_ni, favorecido_nome, elemento_despesa,
                      source_payload, last_seen_at
                    ) values (
                      ${fase}, ${chaveDedup}, ${documento}, ${dataBr(item.data ?? item.dataEmissao)},
                      ${numBr(item.valor ?? item.valorDocumento)},
                      ${item.codigoOrgao ?? textoOuCampo(item.orgao, "codigo")},
                      ${item.nomeOrgao ?? textoOuCampo(item.orgao, "nome")},
                      ${textoOuCampo(item.unidadeGestora ?? item.ug, "codigo") ?? alvo.unidadeGestora},
                      ${favorecidoNi}, ${item.nomeFavorecido ?? textoOuCampo(item.favorecido, "nome")},
                      ${textoOuCampo(item.elementoDespesa, "codigo") ?? textoOuCampo(item.elementoDespesa, "nome")},
                      ${JSON.stringify(item)}::jsonb, now()
                    )
                    on conflict (chave_dedup) do update set
                      valor = excluded.valor,
                      source_payload = excluded.source_payload,
                      last_seen_at = now()`;
          if (existente.length) stats.ignorados++;
          else stats.inseridos++;
          stats.registros++;
        } catch (error) {
          stats.erros++;
          nota(stats, `documento: ${String((error as Error).message)}`);
        }
      }

      await sleep(700);
      }
    }
  }
}

Deno.serve(async (request: Request) => {
  let params: any = {};
  try {
    params = await request.json();
  } catch (_) {
    // Corpo vazio usa os parâmetros padrão.
  }

  const stats: Stats = {
    paginas: 0,
    registros: 0,
    inseridos: 0,
    ignorados: 0,
    erros: 0,
    detalhes: [],
  };
  const deadline = Date.now() + Number(params.orcamentoMs ?? 35000);
  let logId: number | null = null;

  try {
    const rows = await sql`insert into bolsa.coleta_log (fonte_id, job)
                           values ('portal_transparencia', 'despesas') returning id`;
    logId = rows[0].id;
  } catch (error) {
    nota(stats, String((error as Error).message));
  }

  try {
    const segredo = await sql`select valor from bolsa.segredos where chave = 'transparencia_api_key'`;
    if (!segredo.length) {
      nota(stats, "aguardando chave da API — nada coletado");
      await sql`update bolsa.fontes set status = 'AGUARDANDO_CHAVE' where id = 'portal_transparencia'`;
    } else {
      await jobDespesas(params, stats, deadline, segredo[0].valor as string);
      const statusFonte = stats.erros > 0 && stats.registros === 0
        ? "TEMPORARILY_UNAVAILABLE"
        : "ATIVA";
      await sql`update bolsa.fontes
                set status = ${statusFonte},
                    ultimo_sucesso_em = case when ${statusFonte === "ATIVA"} then now() else ultimo_sucesso_em end
                where id = 'portal_transparencia'`;
    }
  } catch (error) {
    stats.erros++;
    nota(stats, `exceção: ${String((error as Error).message)}`);
  }

  if (logId != null) {
    try {
      await sql`update bolsa.coleta_log
                set finalizado_em = now(), paginas = ${stats.paginas}, registros = ${stats.registros},
                    inseridos = ${stats.inseridos}, ignorados = ${stats.ignorados}, erros = ${stats.erros},
                    detalhe = ${JSON.stringify({ params, notas: stats.detalhes })}::jsonb
                where id = ${logId}`;
    } catch (_) {
      // Falha de telemetria não invalida os dados já persistidos.
    }
  }

  return new Response(JSON.stringify({ ok: stats.erros === 0, ...stats }), {
    headers: { "content-type": "application/json" },
  });
});
