// ============================================================
// BOLSA DE LICITAÇÕES — Backfill histórico PNCP (Edge Function) v3
// Consome bolsa.backfill_jobs (fonte→dataset→ano→mês) com cursor
// de retomada exata (§59). RAW imutável + normalização idempotente.
// Não gera eventos por registro (carga histórica não é "mudança");
// os eventos continuam por conta da coleta delta.
// ============================================================
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });

const PNCP = "https://pncp.gov.br";
const UA = "BolsaLicitacoes/0.1 (memoria historica de dados publicos; +https://github.com/Marcoslide/Licita-es)";
const MODALIDADES = [6, 8, 4, 9, 12, 7, 5, 1, 3, 13];
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

interface St { paginas: number; registros: number; inseridos: number; atualizados: number; erros: number; notas: string[] }
const nota = (s: St, m: string) => { if (s.notas.length < 8) s.notas.push(m); };

async function fetchJson(url: string, st: St, contexto: string, tentativas = 3): Promise<{ ok: boolean; status: number; body: any }> {
  for (let t = 0; t < tentativas; t++) {
    try {
      const res = await fetch(url, { headers: { accept: "application/json", "user-agent": UA }, signal: AbortSignal.timeout(15000) });
      if (res.status === 204) return { ok: true, status: 204, body: null };
      if (res.ok) {
        const txt = await res.text();
        const body = txt ? JSON.parse(txt) : null;
        try {
          const hash = await sha256(txt || "null");
          await sql`insert into bolsa.raw_payloads (fonte_id, url, contexto, http_status, content_hash, payload)
                    values ('pncp', ${url}, ${contexto}, ${res.status}, ${hash}, ${txt || "null"}::jsonb)
                    on conflict (url, content_hash) do nothing`;
        } catch (e) { nota(st, "raw: " + String((e as Error).message)); }
        return { ok: true, status: res.status, body };
      }
      await res.body?.cancel();
      if (res.status === 404) return { ok: false, status: 404, body: null };
      if (res.status === 429 || res.status >= 500) { await sleep(400 * 2 ** t + Math.random() * 300); continue; }
      return { ok: false, status: res.status, body: null };
    } catch { await sleep(400 * 2 ** t + Math.random() * 300); }
  }
  st.erros++;
  return { ok: false, status: 0, body: null };
}

// upsert enxuto para carga histórica: sem select-antes e sem eventos;
// (xmax = 0) distingue inserido de atualizado
async function upsertLicitacaoHist(c: any, st: St) {
  const ncp = c.numeroControlePNCP ?? null;
  if (!ncp) return;
  const org = c.orgaoEntidade ?? {}; const un = c.unidadeOrgao ?? {};
  try {
    if (org.cnpj) {
      await sql`insert into bolsa.orgaos (cnpj, razao_social, poder_id, esfera_id, last_seen_at, source_payload)
                values (${org.cnpj}, ${org.razaoSocial ?? null}, ${org.poderId ?? null}, ${org.esferaId ?? null}, now(), ${JSON.stringify(org)}::jsonb)
                on conflict (cnpj) do update set razao_social = coalesce(excluded.razao_social, bolsa.orgaos.razao_social), last_seen_at = now()`;
      if (un.codigoUnidade != null) {
        await sql`insert into bolsa.unidades (orgao_cnpj, codigo, nome, uf, municipio_nome, codigo_ibge)
                  values (${org.cnpj}, ${String(un.codigoUnidade)}, ${un.nomeUnidade ?? null}, ${un.ufSigla ?? null}, ${un.municipioNome ?? null}, ${un.codigoIbge != null ? String(un.codigoIbge) : null})
                  on conflict (orgao_cnpj, codigo) do nothing`;
      }
    }
    const r = await sql`insert into bolsa.licitacoes (
        numero_controle_pncp, fonte_id, orgao_cnpj, unidade_codigo, ano_compra, sequencial_compra,
        numero_compra, processo, modalidade_id, modalidade_nome, modo_disputa, situacao_id, situacao_nome,
        situacao_fonte, srp, instrumento, objeto, valor_total_estimado, valor_total_homologado,
        data_publicacao_pncp, data_abertura_proposta, data_encerramento_proposta, uf, municipio_nome,
        codigo_ibge, amparo_legal, informacao_complementar, link_sistema_origem, usuario_nome,
        source_updated_at, source_payload, last_seen_at)
      values (${ncp}, 'pncp', ${org.cnpj ?? null}, ${un.codigoUnidade != null ? String(un.codigoUnidade) : null},
        ${c.anoCompra ?? null}, ${c.sequencialCompra ?? null}, ${c.numeroCompra ?? null}, ${c.processo ?? null},
        ${c.modalidadeId ?? null}, ${c.modalidadeNome ?? null}, ${c.modoDisputaNome ?? null},
        ${c.situacaoCompraId ?? null}, ${c.situacaoCompraNome ?? null}, ${c.situacaoCompraNome ?? null},
        ${typeof c.srp === "boolean" ? c.srp : null}, ${c.tipoInstrumentoConvocatorioNome ?? null},
        ${c.objetoCompra ?? null}, ${c.valorTotalEstimado ?? null}, ${c.valorTotalHomologado ?? null},
        ${c.dataPublicacaoPncp ?? null}, ${c.dataAberturaProposta ?? null}, ${c.dataEncerramentoProposta ?? null},
        ${un.ufSigla ?? null}, ${un.municipioNome ?? null}, ${un.codigoIbge != null ? String(un.codigoIbge) : null},
        ${c.amparoLegal?.nome ?? null}, ${c.informacaoComplementar ?? null}, ${c.linkSistemaOrigem ?? null},
        ${c.usuarioNome ?? null}, ${c.dataAtualizacao ?? null}, ${JSON.stringify(c)}::jsonb, now())
      on conflict (numero_controle_pncp) do update set
        situacao_nome = excluded.situacao_nome, situacao_fonte = excluded.situacao_fonte,
        valor_total_estimado = excluded.valor_total_estimado, valor_total_homologado = excluded.valor_total_homologado,
        source_updated_at = excluded.source_updated_at, source_payload = excluded.source_payload,
        last_seen_at = now()
      returning (xmax = 0) as inserido`;
    if (r[0]?.inserido) st.inseridos++; else st.atualizados++;
    st.registros++;
  } catch (e) { st.erros++; nota(st, `lic ${ncp}: ` + String((e as Error).message)); }
}

async function upsertContratoHist(c: any, st: St) {
  const ncp = c.numeroControlePNCP ?? null;
  if (!ncp) return;
  const o = c.orgaoEntidade ?? {}; const u = c.unidadeOrgao ?? {};
  try {
    if (c.niFornecedor) {
      await sql`insert into bolsa.fornecedores (ni, tipo_pessoa, nome, last_seen_at)
                values (${c.niFornecedor}, ${c.tipoPessoa ?? null}, ${c.nomeRazaoSocialFornecedor ?? null}, now())
                on conflict (ni) do update set nome = coalesce(excluded.nome, bolsa.fornecedores.nome), last_seen_at = now()`;
    }
    const r = await sql`insert into bolsa.contratos (numero_controle_pncp, numero_controle_pncp_compra, numero_contrato, ano_contrato, processo, categoria, tipo, objeto, orgao_cnpj, unidade_codigo, uf, municipio_nome, fornecedor_ni, fornecedor_nome, valor_inicial, valor_global, data_assinatura, vigencia_inicio, vigencia_fim, data_publicacao_pncp, source_updated_at, source_payload, last_seen_at)
      values (${ncp}, ${c.numeroControlePncpCompra ?? c.numeroControlePNCPCompra ?? null}, ${c.numeroContratoEmpenho ?? null}, ${c.anoContrato ?? null}, ${c.processo ?? null}, ${c.categoriaProcessoNome ?? null}, ${c.tipoContratoNome ?? null}, ${c.objetoContrato ?? null}, ${o.cnpj ?? null}, ${u.codigoUnidade != null ? String(u.codigoUnidade) : null}, ${u.ufSigla ?? null}, ${u.municipioNome ?? null}, ${c.niFornecedor ?? null}, ${c.nomeRazaoSocialFornecedor ?? null}, ${c.valorInicial ?? null}, ${c.valorGlobal ?? null}, ${c.dataAssinatura ?? null}, ${c.dataVigenciaInicio ?? null}, ${c.dataVigenciaFim ?? null}, ${c.dataPublicacaoPncp ?? null}, ${c.dataAtualizacao ?? null}, ${JSON.stringify(c)}::jsonb, now())
      on conflict (numero_controle_pncp) do update set
        valor_global = excluded.valor_global, vigencia_fim = excluded.vigencia_fim,
        source_updated_at = excluded.source_updated_at, source_payload = excluded.source_payload, last_seen_at = now()
      returning (xmax = 0) as inserido`;
    if (r[0]?.inserido) st.inseridos++; else st.atualizados++;
    st.registros++;
  } catch (e) { st.erros++; nota(st, `ctr ${ncp}: ` + String((e as Error).message)); }
}

function janelaMes(ano: number, mes: number): { ini: string; fim: string } {
  const ult = new Date(Date.UTC(ano, mes, 0)).getUTCDate();
  const mm = String(mes).padStart(2, "0");
  return { ini: `${ano}${mm}01`, fim: `${ano}${mm}${String(ult).padStart(2, "0")}` };
}

async function salvarProgresso(jobId: number, st: St, cursor: unknown, status: string | null) {
  await sql`update bolsa.backfill_jobs set
      processed_records = processed_records + ${st.registros},
      inserted = inserted + ${st.inseridos},
      updated = updated + ${st.atualizados},
      errors = errors + ${st.erros},
      cursor = ${JSON.stringify(cursor)}::jsonb,
      status = coalesce(${status}, status),
      finished_at = case when ${status === "COMPLETED" || status === "FAILED"} then now() else finished_at end,
      detalhe = detalhe || ${JSON.stringify({ ultimas_notas: st.notas })}::jsonb
    where id = ${jobId}`;
  st.registros = 0; st.inseridos = 0; st.atualizados = 0; st.erros = 0;
}

// processa uma partição de contratações; retorna true se concluiu o mês
async function rodarContratacoes(job: any, st: St, deadline: number): Promise<boolean> {
  const { ini, fim } = janelaMes(job.ano, job.mes);
  const cur = job.cursor ?? {};
  let modIdx: number = cur.mod_idx ?? 0;
  let pagina: number = cur.pagina ?? 1;
  let totalFonte: number | null = null;
  let paginasOk = 0, errosHttp = 0;

  while (modIdx < MODALIDADES.length) {
    if (Date.now() > deadline) {
      await salvarProgresso(job.id, st, { mod_idx: modIdx, pagina }, "PARTIAL");
      return false;
    }
    const mod = MODALIDADES[modIdx];
    const url = `${PNCP}/api/consulta/v1/contratacoes/publicacao?dataInicial=${ini}&dataFinal=${fim}&codigoModalidadeContratacao=${mod}&pagina=${pagina}&tamanhoPagina=50`;
    const r = await fetchJson(url, st, "contratacoes");
    if (!r.ok || !r.body) {
      if (r.status === 404 || r.status === 204) { modIdx++; pagina = 1; continue; }
      // falha real (5xx/429/rede): NÃO pula páginas — salva a posição exata e retoma depois (§59)
      errosHttp++; st.erros++; nota(st, `mod ${mod} pag ${pagina}: HTTP ${r.status}`);
      await salvarProgresso(job.id, st, { mod_idx: modIdx, pagina, motivo_parcial: `HTTP ${r.status} em mod ${mod} pág ${pagina}` }, "PARTIAL");
      return false;
    }
    st.paginas++; paginasOk++;
    if (typeof r.body.totalRegistros === "number") totalFonte = (totalFonte ?? 0) + (pagina === 1 ? r.body.totalRegistros : 0);
    for (const c of (r.body.data ?? [])) await upsertLicitacaoHist(c, st);
    await salvarProgresso(job.id, st, { mod_idx: modIdx, pagina, total_fonte: totalFonte }, null);
    if (!r.body.paginasRestantes || r.body.paginasRestantes <= 0) { modIdx++; pagina = 1; }
    else pagina++;
    await sleep(120);
  }
  // numa retomada, totalFonte é parcial — nunca deixa encolher o total conhecido
  await sql`update bolsa.backfill_jobs set expected_records = case when ${totalFonte}::int is null then expected_records
            else greatest(coalesce(expected_records, 0), ${totalFonte}::int) end where id = ${job.id}`;
  await salvarProgresso(job.id, st, { concluido: true }, "COMPLETED");
  return true;
}

async function rodarContratos(job: any, st: St, deadline: number): Promise<boolean> {
  const { ini, fim } = janelaMes(job.ano, job.mes);
  let pagina: number = (job.cursor ?? {}).pagina ?? 1;
  for (;;) {
    if (Date.now() > deadline) {
      await salvarProgresso(job.id, st, { pagina }, "PARTIAL");
      return false;
    }
    const url = `${PNCP}/api/consulta/v1/contratos?dataInicial=${ini}&dataFinal=${fim}&pagina=${pagina}&tamanhoPagina=50`;
    const r = await fetchJson(url, st, "contratos");
    if (!r.ok || !r.body) {
      if (r.status === 404 || r.status === 204) break;
      st.erros++; nota(st, `contratos pag ${pagina}: HTTP ${r.status}`);
      await salvarProgresso(job.id, st, { pagina, motivo_parcial: `HTTP ${r.status}` }, "PARTIAL");
      return false;
    }
    st.paginas++;
    for (const c of (r.body.data ?? [])) await upsertContratoHist(c, st);
    await salvarProgresso(job.id, st, { pagina }, null);
    if (!r.body.paginasRestantes || r.body.paginasRestantes <= 0) break;
    pagina++;
    await sleep(120);
  }
  await salvarProgresso(job.id, st, { concluido: true }, "COMPLETED");
  return true;
}

Deno.serve(async (req: Request) => {
  let p: any = {};
  try { p = await req.json(); } catch { /* corpo vazio */ }
  const deadline = Date.now() + (p.orcamentoMs ?? 45000);
  const st: St = { paginas: 0, registros: 0, inseridos: 0, atualizados: 0, erros: 0, notas: [] };
  const rodadas: unknown[] = [];

  // processa partições da fila até o orçamento acabar (normalmente 1–2 por chamada)
  for (let n = 0; n < (p.maxJobs ?? 2); n++) {
    if (Date.now() > deadline - 5000) break;
    let job: any;
    if (p.job_id && n === 0) {
      const r = await sql`update bolsa.backfill_jobs set status='RUNNING', started_at=coalesce(started_at, now())
                          where id = ${p.job_id} and status in ('QUEUED','PARTIAL','RUNNING') returning *`;
      job = r[0];
    } else {
      const r = await sql`select * from bolsa.backfill_reivindicar('pncp')`;
      job = r[0]?.id ? r[0] : null;
    }
    if (!job) { rodadas.push({ fila: "vazia" }); break; }

    let logId: number | null = null;
    try {
      const lr = await sql`insert into bolsa.coleta_log (fonte_id, job) values ('pncp', ${"backfill:" + job.dataset + ":" + job.ano + "-" + String(job.mes).padStart(2, "0")}) returning id`;
      logId = lr[0].id;
    } catch { /* log não fatal */ }

    let concluiu = false;
    try {
      if (job.dataset === "contratacoes") concluiu = await rodarContratacoes(job, st, deadline);
      else if (job.dataset === "contratos") concluiu = await rodarContratos(job, st, deadline);
      else {
        await sql`update bolsa.backfill_jobs set status='PAUSED', detalhe = detalhe || '{"motivo":"dataset sem executor nesta função"}'::jsonb where id = ${job.id}`;
      }
    } catch (e) {
      st.erros++;
      await salvarProgresso(job.id, st, job.cursor ?? {}, "PARTIAL");
      nota(st, "excecao: " + String((e as Error).message));
    }

    const dep = await sql`select processed_records, inserted, updated, errors, status from bolsa.backfill_jobs where id = ${job.id}`;
    rodadas.push({ job: job.id, dataset: job.dataset, ano: job.ano, mes: job.mes, concluiu, ...dep[0] });

    if (logId != null) {
      try {
        await sql`update bolsa.coleta_log set finalizado_em = now(), paginas = ${st.paginas},
                  registros = ${dep[0]?.processed_records ?? 0}, inseridos = ${dep[0]?.inserted ?? 0},
                  atualizados = ${dep[0]?.updated ?? 0}, erros = ${dep[0]?.errors ?? 0},
                  detalhe = ${JSON.stringify({ backfill: true, job_id: job.id, status: dep[0]?.status })}::jsonb
                  where id = ${logId}`;
      } catch { /* não fatal */ }
    }
    if (!concluiu) break; // orçamento estourou dentro da partição
  }

  return new Response(JSON.stringify({ ok: true, rodadas }), { headers: { "content-type": "application/json" } });
});
