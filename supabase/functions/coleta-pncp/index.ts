// ============================================================
// BOLSA DE LICITAÇÕES — PncpCollector (Edge Function) v4
// Escrita via conexão direta ao Postgres (SUPABASE_DB_URL).
// Fluxo: LISTAGEM -> LICITAÇÃO -> ITENS -> DOCUMENTOS -> RESULTADOS -> CONTRATOS
// Camadas: RAW imutável -> normalizada. Eventos de alteração, checkpoint,
// idempotência por identificador oficial, log de coleta, validação de dados.
// Somente endpoints PÚBLICOS do PNCP. Ritmo com atraso + retry/backoff.
// ============================================================
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });

const PNCP = "https://pncp.gov.br";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";
const UFS = new Set(["AC","AL","AP","AM","BA","CE","DF","ES","GO","MA","MT","MS","MG","PA","PB","PR","PE","PI","RJ","RN","RS","RO","RR","SC","SP","SE","TO"]);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function cnpjValido(c: string | null): boolean {
  if (!c) return false;
  const n = c.replace(/\D/g, "");
  if (n.length !== 14 || /^(\d)\1+$/.test(n)) return false;
  const calc = (len: number) => {
    const w = len === 12 ? [5,4,3,2,9,8,7,6,5,4,3,2] : [6,5,4,3,2,9,8,7,6,5,4,3,2];
    const s2 = w.reduce((a, p, i) => a + p * +n[i], 0);
    const r = s2 % 11; return r < 2 ? 0 : 11 - r;
  };
  return calc(12) === +n[12] && calc(13) === +n[13];
}

interface Stats { paginas: number; registros: number; inseridos: number; atualizados: number; ignorados: number; documentos: number; erros: number; eventos: number; itens: number; resultados: number; contratos: number; fornecedores: number; detalhes: string[]; }
const novoStats = (): Stats => ({ paginas: 0, registros: 0, inseridos: 0, atualizados: 0, ignorados: 0, documentos: 0, erros: 0, eventos: 0, itens: 0, resultados: 0, contratos: 0, fornecedores: 0, detalhes: [] });
const nota = (s: Stats, m: string) => { if (s.detalhes.length < 10) s.detalhes.push(m); };

async function fetchJson(url: string, stats: Stats, tentativas = 3): Promise<{ ok: boolean; status: number; body: unknown | null }> {
  let ultimoErro = "";
  for (let t = 0; t < tentativas; t++) {
    try {
      const res = await fetch(url, { headers: { accept: "application/json", "user-agent": UA }, signal: AbortSignal.timeout(15000) });
      if (res.status === 204) return { ok: true, status: 204, body: null };
      if (res.ok) {
        const txt = await res.text();
        const body = txt ? JSON.parse(txt) : null;
        try {
          const hash = await sha256(txt || "null");
          const contexto = url.includes("/contratacoes/") ? "contratacoes" : url.includes("/resultados") ? "resultados" : url.includes("/itens") ? "itens" : url.includes("/arquivos") ? "arquivos" : url.includes("/contratos") ? "contratos" : "outro";
          await sql`insert into bolsa.raw_payloads (fonte_id, url, contexto, http_status, content_hash, payload)
                    values ('pncp', ${url}, ${contexto}, ${res.status}, ${hash}, ${txt || "null"}::jsonb)
                    on conflict (url, content_hash) do nothing`;
        } catch (e) { nota(stats, "raw: " + String((e as Error).message)); }
        return { ok: true, status: res.status, body };
      }
      await res.body?.cancel();
      if (res.status === 404) return { ok: false, status: 404, body: null };
      if (res.status === 429 || res.status >= 500) { await sleep(400 * 2 ** t + Math.random() * 300); continue; }
      return { ok: false, status: res.status, body: null };
    } catch (e) {
      ultimoErro = String((e as Error)?.message ?? e);
      await sleep(400 * 2 ** t + Math.random() * 300);
    }
  }
  stats.erros++;
  if (ultimoErro) nota(stats, `fetch ${url.slice(0, 80)}: ${ultimoErro}`);
  return { ok: false, status: 0, body: null };
}

async function dq(entidade: string, chave: string, campo: string, problema: string, valor: unknown) {
  try { await sql`insert into bolsa.data_quality_issues (entidade, chave, campo, problema, valor) values (${entidade}, ${chave}, ${campo}, ${problema}, ${String(valor ?? "")})`; } catch { /* não fatal */ }
}

const CAMPOS_EVENTO: [string, string][] = [
  ["data_abertura_proposta", "DATA_SESSAO_ALTERADA"],
  ["data_encerramento_proposta", "DATA_SESSAO_ALTERADA"],
  ["valor_total_estimado", "VALOR_ESTIMADO_ALTERADO"],
  ["valor_total_homologado", "VALOR_HOMOLOGADO_ALTERADO"],
  ["situacao_nome", "SITUACAO_ALTERADA"],
  ["objeto", "OBJETO_ALTERADO"],
];
const normVal = (v: unknown) => (v == null ? null : String(v));

async function upsertLicitacoes(regs: any[], stats: Stats) {
  for (const c of regs) {
    const ncp = c.numeroControlePNCP ?? null;
    if (!ncp) { stats.ignorados++; await dq("licitacao", "-", "numero_controle_pncp", "ausente", null); continue; }
    const org = c.orgaoEntidade ?? {}; const un = c.unidadeOrgao ?? {};
    try {
      if (org.cnpj) {
        if (!cnpjValido(org.cnpj)) await dq("orgao", org.cnpj, "cnpj", "cnpj_invalido", org.cnpj);
        await sql`insert into bolsa.orgaos (cnpj, razao_social, poder_id, esfera_id, last_seen_at, source_payload)
                  values (${org.cnpj}, ${org.razaoSocial ?? null}, ${org.poderId ?? null}, ${org.esferaId ?? null}, now(), ${JSON.stringify(org)}::jsonb)
                  on conflict (cnpj) do update set razao_social = excluded.razao_social, last_seen_at = now()`;
        if (un.codigoUnidade != null) {
          if (un.ufSigla && !UFS.has(un.ufSigla)) await dq("unidade", `${org.cnpj}/${un.codigoUnidade}`, "uf", "uf_invalida", un.ufSigla);
          await sql`insert into bolsa.unidades (orgao_cnpj, codigo, nome, uf, municipio_nome, codigo_ibge)
                    values (${org.cnpj}, ${String(un.codigoUnidade)}, ${un.nomeUnidade ?? null}, ${un.ufSigla ?? null}, ${un.municipioNome ?? null}, ${un.codigoIbge != null ? String(un.codigoIbge) : null})
                    on conflict (orgao_cnpj, codigo) do update set nome = excluded.nome, uf = excluded.uf, municipio_nome = excluded.municipio_nome`;
        }
      }
      const novo = {
        ncp,
        orgao_cnpj: org.cnpj ?? null,
        unidade_codigo: un.codigoUnidade != null ? String(un.codigoUnidade) : null,
        ano_compra: c.anoCompra ?? null,
        sequencial_compra: c.sequencialCompra ?? null,
        numero_compra: c.numeroCompra ?? null,
        processo: c.processo ?? null,
        modalidade_id: c.modalidadeId ?? null,
        modalidade_nome: c.modalidadeNome ?? null,
        modo_disputa: c.modoDisputaNome ?? null,
        situacao_id: c.situacaoCompraId ?? null,
        situacao_nome: c.situacaoCompraNome ?? null,
        srp: typeof c.srp === "boolean" ? c.srp : null,
        instrumento: c.tipoInstrumentoConvocatorioNome ?? null,
        objeto: c.objetoCompra ?? null,
        valor_total_estimado: c.valorTotalEstimado ?? null,
        valor_total_homologado: c.valorTotalHomologado ?? null,
        data_publicacao_pncp: c.dataPublicacaoPncp ?? null,
        data_abertura_proposta: c.dataAberturaProposta ?? null,
        data_encerramento_proposta: c.dataEncerramentoProposta ?? null,
        uf: un.ufSigla ?? null,
        municipio_nome: un.municipioNome ?? null,
        codigo_ibge: un.codigoIbge != null ? String(un.codigoIbge) : null,
        amparo_legal: c.amparoLegal?.nome ?? null,
        informacao_complementar: c.informacaoComplementar ?? null,
        link_sistema_origem: c.linkSistemaOrigem ?? null,
        usuario_nome: c.usuarioNome ?? null,
        source_updated_at: c.dataAtualizacao ?? null,
      };
      const antesRows = await sql`select data_abertura_proposta::text, data_encerramento_proposta::text, valor_total_estimado::text,
                                         valor_total_homologado::text, situacao_nome, objeto
                                  from bolsa.licitacoes where numero_controle_pncp = ${ncp}`;
      const antes = antesRows[0] ?? null;
      await sql`insert into bolsa.licitacoes (
          numero_controle_pncp, fonte_id, orgao_cnpj, unidade_codigo, ano_compra, sequencial_compra,
          numero_compra, processo, modalidade_id, modalidade_nome, modo_disputa, situacao_id, situacao_nome,
          situacao_fonte, srp, instrumento, objeto, valor_total_estimado, valor_total_homologado,
          data_publicacao_pncp, data_abertura_proposta, data_encerramento_proposta, uf, municipio_nome,
          codigo_ibge, amparo_legal, informacao_complementar, link_sistema_origem, usuario_nome,
          source_updated_at, source_payload, last_seen_at)
        values (${ncp}, 'pncp', ${novo.orgao_cnpj}, ${novo.unidade_codigo}, ${novo.ano_compra}, ${novo.sequencial_compra},
          ${novo.numero_compra}, ${novo.processo}, ${novo.modalidade_id}, ${novo.modalidade_nome}, ${novo.modo_disputa}, ${novo.situacao_id}, ${novo.situacao_nome},
          ${novo.situacao_nome}, ${novo.srp}, ${novo.instrumento}, ${novo.objeto}, ${novo.valor_total_estimado}, ${novo.valor_total_homologado},
          ${novo.data_publicacao_pncp}, ${novo.data_abertura_proposta}, ${novo.data_encerramento_proposta}, ${novo.uf}, ${novo.municipio_nome},
          ${novo.codigo_ibge}, ${novo.amparo_legal}, ${novo.informacao_complementar}, ${novo.link_sistema_origem}, ${novo.usuario_nome},
          ${novo.source_updated_at}, ${JSON.stringify(c)}::jsonb, now())
        on conflict (numero_controle_pncp) do update set
          orgao_cnpj = excluded.orgao_cnpj, unidade_codigo = excluded.unidade_codigo,
          ano_compra = excluded.ano_compra, sequencial_compra = excluded.sequencial_compra,
          numero_compra = excluded.numero_compra, processo = excluded.processo,
          modalidade_id = excluded.modalidade_id, modalidade_nome = excluded.modalidade_nome,
          modo_disputa = excluded.modo_disputa, situacao_id = excluded.situacao_id,
          situacao_nome = excluded.situacao_nome, situacao_fonte = excluded.situacao_fonte,
          srp = excluded.srp, instrumento = excluded.instrumento, objeto = excluded.objeto,
          valor_total_estimado = excluded.valor_total_estimado, valor_total_homologado = excluded.valor_total_homologado,
          data_publicacao_pncp = excluded.data_publicacao_pncp, data_abertura_proposta = excluded.data_abertura_proposta,
          data_encerramento_proposta = excluded.data_encerramento_proposta, uf = excluded.uf,
          municipio_nome = excluded.municipio_nome, codigo_ibge = excluded.codigo_ibge,
          amparo_legal = excluded.amparo_legal, informacao_complementar = excluded.informacao_complementar,
          link_sistema_origem = excluded.link_sistema_origem, usuario_nome = excluded.usuario_nome,
          source_updated_at = excluded.source_updated_at, source_payload = excluded.source_payload,
          last_seen_at = now()`;
      if (!antes) {
        stats.inseridos++;
        await sql`insert into bolsa.eventos (entidade, chave, tipo, fonte_id) values ('licitacao', ${ncp}, 'NOVO_REGISTRO', 'pncp')`;
        stats.eventos++;
      } else {
        let mudou = false;
        for (const [campo, tipo] of CAMPOS_EVENTO) {
          const a = normVal((antes as any)[campo]);
          const b = normVal((novo as any)[campo]);
          if (campo.startsWith("data_") && a && b) {
            // comparação robusta de datas (texto da fonte vs timestamptz)
            if (new Date(a).getTime() === new Date(b).getTime()) continue;
          }
          if (campo.startsWith("valor_") && a != null && b != null && Number(a) === Number(b)) continue;
          if (a !== b && !(a == null && b == null)) {
            mudou = true;
            await sql`insert into bolsa.eventos (entidade, chave, tipo, campo, valor_anterior, valor_novo, fonte_id)
                      values ('licitacao', ${ncp}, ${tipo}, ${campo}, ${a}, ${b}, 'pncp')`;
            stats.eventos++;
          }
        }
        if (mudou) stats.atualizados++; else stats.ignorados++;
      }
      stats.registros++;
      // Motor genérico (bolsa.registrar_estado) rodando em PARALELO à lógica
      // de eventos acima — prova real em produção (P3-B da estabilização),
      // sem substituir o caminho antigo ainda: alimenta bolsa.estado_atual/
      // estado_versoes com os mesmos 6 campos observados, gerando diff e
      // evento de forma genérica (sem CAMPOS_EVENTO hardcoded). Falha aqui
      // nunca derruba a coleta principal.
      try {
        // IMPORTANTE: nunca fazer JSON.stringify(obj) manual aqui — o driver
        // postgres.js já serializa objeto JS -> jsonb sozinho ao ver o cast
        // ::jsonb; stringificar antes faz dupla-serialização (o valor grava
        // como STRING contendo o texto do JSON, não como objeto). Foi assim
        // que a corrupção em bolsa.estado_atual.dados aconteceu (achado e
        // corrigido em 2026-09-04, ver migration fix_registrar_estado_guarda_tipo_jsonb).
        await sql`select bolsa.registrar_estado('licitacao', ${ncp}, 'pncp', ${sql.json({
          data_abertura_proposta: novo.data_abertura_proposta,
          data_encerramento_proposta: novo.data_encerramento_proposta,
          valor_total_estimado: novo.valor_total_estimado,
          valor_total_homologado: novo.valor_total_homologado,
          situacao_nome: novo.situacao_nome,
          objeto: novo.objeto,
        })}::jsonb)`;
      } catch (e) { nota(stats, `motor genérico ${ncp}: ` + String((e as Error).message)); }
    } catch (e) {
      stats.erros++; nota(stats, `lic ${ncp}: ` + String((e as Error).message));
    }
  }
}

async function jobDelta(p: any, stats: Stats, deadline: number) {
  const ymd = (d: Date) => d.toISOString().slice(0, 10).replace(/-/g, "");
  const dataInicial = p.dataInicial ?? ymd(new Date(Date.now() - 864e5));
  const dataFinal = p.dataFinal ?? ymd(new Date());
  const modalidades: number[] = p.modalidades ?? [6, 8, 4, 9, 12];
  const maxPaginas = p.maxPaginas ?? 2;
  const tam = p.tamanhoPagina ?? 50;
  const ckChave = `pncp:delta:${dataInicial}-${dataFinal}`;
  const ckRows = await sql`select valor from bolsa.checkpoints where chave = ${ckChave}`;
  const progresso: Record<string, number> = (ckRows[0]?.valor as any)?.paginaPorModalidade ?? {};

  for (const mod of modalidades) {
    let pag = (progresso[mod] ?? 0) + 1;
    for (let n = 0; n < maxPaginas; n++, pag++) {
      if (Date.now() > deadline) { nota(stats, "tempo esgotado no delta"); return; }
      const url = `${PNCP}/api/consulta/v1/contratacoes/publicacao?dataInicial=${dataInicial}&dataFinal=${dataFinal}&codigoModalidadeContratacao=${mod}&pagina=${pag}&tamanhoPagina=${tam}`;
      const r = await fetchJson(url, stats);
      if (!r.ok || !r.body) { if (r.status !== 404 && r.status !== 204) nota(stats, `modalidade ${mod} pag ${pag}: HTTP ${r.status}`); break; }
      const body: any = r.body; stats.paginas++;
      await upsertLicitacoes(body.data ?? [], stats);
      progresso[mod] = pag;
      // Bug real encontrado em 2026-09-04 (achado durante P3-B): este insert
      // gravava `valor` como STRING (JSON duplamente serializado) em vez de
      // objeto — bolsa.checkpoints.valor->>'paginaPorModalidade' sempre lia
      // undefined, então o delta reiniciava a paginação do zero a cada
      // execução. Corrigido com sql.json() (serialização única e correta).
      await sql`insert into bolsa.checkpoints (chave, valor, atualizado_em)
                values (${ckChave}, ${sql.json({ paginaPorModalidade: progresso, dataInicial, dataFinal })}::jsonb, now())
                on conflict (chave) do update set valor = excluded.valor, atualizado_em = now()`;
      if (!body.paginasRestantes || body.paginasRestantes <= 0) break;
      await sleep(100);
    }
  }
}

async function jobDetalhes(p: any, stats: Stats, deadline: number) {
  const lote = p.maxDetalhes ?? 8;
  const asc = p.ordem === "asc";
  const pubDe = p.pubDe ?? null;
  const pubAte = p.pubAte ?? null;
  const pend = asc
    ? await sql`select numero_controle_pncp, orgao_cnpj, ano_compra, sequencial_compra
                from bolsa.licitacoes where itens_coletados_em is null
                and (${pubDe}::timestamptz is null or data_publicacao_pncp >= ${pubDe}::timestamptz)
                and (${pubAte}::timestamptz is null or data_publicacao_pncp <= ${pubAte}::timestamptz)
                order by data_publicacao_pncp asc limit ${lote}`
    : await sql`select numero_controle_pncp, orgao_cnpj, ano_compra, sequencial_compra
                from bolsa.licitacoes where itens_coletados_em is null
                and (${pubDe}::timestamptz is null or data_publicacao_pncp >= ${pubDe}::timestamptz)
                and (${pubAte}::timestamptz is null or data_publicacao_pncp <= ${pubAte}::timestamptz)
                order by data_publicacao_pncp desc limit ${lote}`;
  for (const lic of pend) {
    if (Date.now() > deadline) { nota(stats, "tempo esgotado nos detalhes"); break; }
    if (!lic.orgao_cnpj || !lic.ano_compra || !lic.sequencial_compra) { await dq("licitacao", lic.numero_controle_pncp, "chave_detalhe", "faltam cnpj/ano/sequencial", null); await sql`update bolsa.licitacoes set itens_coletados_em = now() where numero_controle_pncp = ${lic.numero_controle_pncp}`; continue; }
    const base = `${PNCP}/api/pncp/v1/orgaos/${lic.orgao_cnpj}/compras/${lic.ano_compra}/${lic.sequencial_compra}`;
    const itensAll: any[] = [];
    for (let pag = 1; pag <= 5; pag++) {
      const r = await fetchJson(`${base}/itens?pagina=${pag}&tamanhoPagina=100`, stats);
      if (!r.ok || !Array.isArray(r.body) || (r.body as any[]).length === 0) break;
      itensAll.push(...(r.body as any[]));
      if ((r.body as any[]).length < 100) break;
      await sleep(100);
    }
    for (const i of itensAll) {
      if (i.numeroItem == null) continue;
      try {
        await sql`insert into bolsa.itens (numero_controle_pncp, numero_item, descricao, material_ou_servico, quantidade, unidade,
                    valor_unitario_estimado, valor_total_estimado, categoria_id, categoria_nome, criterio_julgamento,
                    situacao_fonte, beneficio, ncm_nbs, catalogo_codigo, tem_resultado, orcamento_sigiloso,
                    source_updated_at, source_payload, last_seen_at)
                  values (${lic.numero_controle_pncp}, ${i.numeroItem}, ${i.descricao ?? null}, ${i.materialOuServicoNome ?? i.materialOuServico ?? null}, ${i.quantidade ?? null}, ${i.unidadeMedida ?? null},
                    ${i.valorUnitarioEstimado ?? null}, ${i.valorTotal ?? null}, ${i.itemCategoriaId ?? null}, ${i.itemCategoriaNome ?? null}, ${i.criterioJulgamentoNome ?? null},
                    ${i.situacaoCompraItemNome ?? null}, ${i.tipoBeneficioNome ?? null}, ${i.ncmNbsCodigo ?? null}, ${i.codigoItemCatalogo != null ? String(i.codigoItemCatalogo) : (i.catalogoCodigoItem != null ? String(i.catalogoCodigoItem) : null)}, ${typeof i.temResultado === "boolean" ? i.temResultado : null}, ${typeof i.orcamentoSigiloso === "boolean" ? i.orcamentoSigiloso : null},
                    ${i.dataAtualizacao ?? null}, ${JSON.stringify(i)}::jsonb, now())
                  on conflict (numero_controle_pncp, numero_item) do update set
                    descricao = excluded.descricao, situacao_fonte = excluded.situacao_fonte,
                    tem_resultado = excluded.tem_resultado, source_payload = excluded.source_payload,
                    source_updated_at = excluded.source_updated_at, last_seen_at = now()`;
        stats.itens++;
      } catch (e) { stats.erros++; nota(stats, "item: " + String((e as Error).message)); }
    }
    const rDocs = await fetchJson(`${base}/arquivos?pagina=1&tamanhoPagina=50`, stats);
    if (rDocs.ok && Array.isArray(rDocs.body)) {
      for (const d of rDocs.body as any[]) {
        try {
          await sql`insert into bolsa.documentos (numero_controle_pncp, sequencial_documento, titulo, tipo_documento, url, status_ativo, data_publicacao, source_payload, last_seen_at)
                    values (${lic.numero_controle_pncp}, ${d.sequencialDocumento ?? null}, ${d.titulo ?? null}, ${d.tipoDocumentoNome ?? null}, ${d.url ?? d.uri ?? null}, ${typeof d.statusAtivo === "boolean" ? d.statusAtivo : null}, ${d.dataPublicacaoPncp ?? null}, ${JSON.stringify(d)}::jsonb, now())
                    on conflict (numero_controle_pncp, seq_key, url_key) do update set
                      titulo = excluded.titulo, tipo_documento = excluded.tipo_documento,
                      status_ativo = excluded.status_ativo, last_seen_at = now()`;
          stats.documentos++;
        } catch (e) { stats.erros++; nota(stats, "doc: " + String((e as Error).message)); }
      }
    }
    let algumResultado = false;
    for (const it of itensAll.filter((i: any) => i.temResultado === true).slice(0, p.maxResultadosPorLicitacao ?? 12)) {
      if (Date.now() > deadline) break;
      const rr = await fetchJson(`${base}/itens/${it.numeroItem}/resultados`, stats);
      if (rr.ok && Array.isArray(rr.body)) {
        for (const res of rr.body as any[]) {
          const ni = res.niFornecedor ?? null;
          try {
            if (ni) {
              if (res.tipoPessoa === "PJ" && !cnpjValido(ni)) await dq("fornecedor", ni, "ni", "cnpj_invalido", ni);
              await sql`insert into bolsa.fornecedores (ni, tipo_pessoa, nome, porte, last_seen_at)
                        values (${ni}, ${res.tipoPessoa ?? null}, ${res.nomeRazaoSocialFornecedor ?? null}, ${res.porteFornecedorNome ?? null}, now())
                        on conflict (ni) do update set nome = excluded.nome, porte = excluded.porte, last_seen_at = now()`;
              stats.fornecedores++;
            }
            await sql`insert into bolsa.resultados_itens (numero_controle_pncp, numero_item, sequencial_resultado, fornecedor_ni, fornecedor_nome, tipo_pessoa, porte, quantidade_homologada, valor_unitario_homologado, valor_total_homologado, percentual_desconto, situacao_fonte, data_resultado, source_payload, last_seen_at)
                      values (${lic.numero_controle_pncp}, ${it.numeroItem}, ${res.sequencialResultado ?? null}, ${ni}, ${res.nomeRazaoSocialFornecedor ?? null}, ${res.tipoPessoa ?? null}, ${res.porteFornecedorNome ?? null}, ${res.quantidadeHomologada ?? null}, ${res.valorUnitarioHomologado ?? null}, ${res.valorTotalHomologado ?? null}, ${res.percentualDesconto ?? null}, ${res.situacaoCompraItemResultadoNome ?? (res.situacaoCompraItemResultadoId != null ? String(res.situacaoCompraItemResultadoId) : null)}, ${res.dataResultado ?? null}, ${JSON.stringify(res)}::jsonb, now())
                      on conflict (numero_controle_pncp, numero_item, fornecedor_ni_key, seq_key) do update set
                        valor_unitario_homologado = excluded.valor_unitario_homologado,
                        valor_total_homologado = excluded.valor_total_homologado,
                        situacao_fonte = excluded.situacao_fonte, last_seen_at = now()`;
            stats.resultados++; algumResultado = true;
          } catch (e) { stats.erros++; nota(stats, "res: " + String((e as Error).message)); }
        }
      }
      await sleep(100);
    }
    await sql`update bolsa.licitacoes set itens_coletados_em = now(), arquivos_coletados_em = now(),
              resultados_coletados_em = case when ${algumResultado} then now() else resultados_coletados_em end
              where numero_controle_pncp = ${lic.numero_controle_pncp}`;
    await sleep(100);
  }
}

async function jobContratos(p: any, stats: Stats, deadline: number) {
  const ymd = (d: Date) => d.toISOString().slice(0, 10).replace(/-/g, "");
  const dataInicial = p.dataInicial ?? ymd(new Date(Date.now() - 2 * 864e5));
  const dataFinal = p.dataFinal ?? ymd(new Date());
  const maxPaginas = p.maxPaginas ?? 2;
  for (let pag = 1; pag <= maxPaginas; pag++) {
    if (Date.now() > deadline) break;
    const url = `${PNCP}/api/consulta/v1/contratos?dataInicial=${dataInicial}&dataFinal=${dataFinal}&pagina=${pag}&tamanhoPagina=${p.tamanhoPagina ?? 50}`;
    const r = await fetchJson(url, stats);
    if (!r.ok || !r.body) break;
    const body: any = r.body; stats.paginas++;
    for (const c of (body.data ?? []) as any[]) {
      const ncp = c.numeroControlePNCP ?? null;
      if (!ncp) { stats.ignorados++; continue; }
      const o = c.orgaoEntidade ?? {}; const u = c.unidadeOrgao ?? {};
      try {
        if (o.cnpj) {
          await sql`insert into bolsa.orgaos (cnpj, razao_social, poder_id, esfera_id, last_seen_at, source_payload)
                    values (${o.cnpj}, ${o.razaoSocial ?? null}, ${o.poderId ?? null}, ${o.esferaId ?? null}, now(), ${JSON.stringify(o)}::jsonb)
                    on conflict (cnpj) do update set last_seen_at = now()`;
        }
        if (c.niFornecedor) {
          await sql`insert into bolsa.fornecedores (ni, tipo_pessoa, nome, last_seen_at)
                    values (${c.niFornecedor}, ${c.tipoPessoa ?? null}, ${c.nomeRazaoSocialFornecedor ?? null}, now())
                    on conflict (ni) do update set nome = excluded.nome, last_seen_at = now()`;
          stats.fornecedores++;
        }
        await sql`insert into bolsa.contratos (numero_controle_pncp, numero_controle_pncp_compra, numero_contrato, ano_contrato, processo, categoria, tipo, objeto, orgao_cnpj, unidade_codigo, uf, municipio_nome, fornecedor_ni, fornecedor_nome, valor_inicial, valor_global, data_assinatura, vigencia_inicio, vigencia_fim, data_publicacao_pncp, source_updated_at, source_payload, last_seen_at)
                  values (${ncp}, ${c.numeroControlePncpCompra ?? c.numeroControlePNCPCompra ?? null}, ${c.numeroContratoEmpenho ?? null}, ${c.anoContrato ?? null}, ${c.processo ?? null}, ${c.categoriaProcessoNome ?? null}, ${c.tipoContratoNome ?? null}, ${c.objetoContrato ?? null}, ${o.cnpj ?? null}, ${u.codigoUnidade != null ? String(u.codigoUnidade) : null}, ${u.ufSigla ?? null}, ${u.municipioNome ?? null}, ${c.niFornecedor ?? null}, ${c.nomeRazaoSocialFornecedor ?? null}, ${c.valorInicial ?? null}, ${c.valorGlobal ?? null}, ${c.dataAssinatura ?? null}, ${c.dataVigenciaInicio ?? null}, ${c.dataVigenciaFim ?? null}, ${c.dataPublicacaoPncp ?? null}, ${c.dataAtualizacao ?? null}, ${JSON.stringify(c)}::jsonb, now())
                  on conflict (numero_controle_pncp) do update set
                    valor_global = excluded.valor_global, vigencia_fim = excluded.vigencia_fim,
                    source_updated_at = excluded.source_updated_at, source_payload = excluded.source_payload,
                    last_seen_at = now()`;
        stats.contratos++; stats.registros++;
      } catch (e) { stats.erros++; nota(stats, `contrato ${ncp}: ` + String((e as Error).message)); }
    }
    if (!body.paginasRestantes || body.paginasRestantes <= 0) break;
    await sleep(100);
  }
}

async function jobDiag(): Promise<Record<string, unknown>> {
  const out: Record<string, unknown> = {};
  try {
    const r = await sql`insert into bolsa.coleta_log (fonte_id, job) values ('pncp', 'diag') returning id`;
    out.db_insert = "ok id=" + r[0].id;
  } catch (e) { out.db_insert = "ERRO: " + String((e as Error).message); }
  try {
    const r = await fetch(`${PNCP}/api/consulta/v1/contratacoes/publicacao?dataInicial=20260901&dataFinal=20260902&codigoModalidadeContratacao=6&pagina=1&tamanhoPagina=10`, { headers: { accept: "application/json", "user-agent": UA }, signal: AbortSignal.timeout(20000) });
    const txt = await r.text();
    out.pncp_status = r.status;
    out.pncp_total = txt.length > 2 ? (JSON.parse(txt).totalRegistros ?? null) : null;
  } catch (e) { out.pncp_erro = String((e as Error)?.message ?? e); }
  return out;
}

Deno.serve(async (req: Request) => {
  let p: any = {};
  try { p = await req.json(); } catch (_) { /* corpo vazio */ }
  const job: string = p.job ?? "delta";
  if (job === "diag") return new Response(JSON.stringify(await jobDiag()), { headers: { "content-type": "application/json" } });

  const stats = novoStats();
  const deadline = Date.now() + (p.orcamentoMs ?? 35000);
  let logId: number | null = null;
  try {
    const r = await sql`insert into bolsa.coleta_log (fonte_id, job) values ('pncp', ${job}) returning id`;
    logId = r[0].id;
  } catch (e) { nota(stats, "coleta_log: " + String((e as Error).message)); }

  try {
    if (job === "delta") { await jobDelta(p, stats, deadline); await jobDetalhes(p, stats, deadline); }
    else if (job === "detalhes") await jobDetalhes(p, stats, deadline);
    else if (job === "contratos") await jobContratos(p, stats, deadline);
    else if (job === "backfill") await jobDelta(p, stats, deadline);
    else return new Response(JSON.stringify({ erro: "job desconhecido" }), { status: 400 });
    const statusFonte = stats.erros > 0 && stats.paginas === 0 && stats.itens === 0 ? "TEMPORARILY_UNAVAILABLE" : "ATIVA";
    await sql`update bolsa.fontes set status = ${statusFonte}, ultimo_sucesso_em = case when ${statusFonte === "ATIVA"} then now() else ultimo_sucesso_em end where id = 'pncp'`;
  } catch (e) {
    stats.erros++; nota(stats, "excecao: " + String((e as Error).message));
  }

  if (logId != null) {
    try {
      await sql`update bolsa.coleta_log set finalizado_em = now(), paginas = ${stats.paginas}, registros = ${stats.registros},
                inseridos = ${stats.inseridos}, atualizados = ${stats.atualizados}, ignorados = ${stats.ignorados},
                documentos = ${stats.documentos}, erros = ${stats.erros},
                detalhe = ${sql.json({ job, params: p, eventos: stats.eventos, itens: stats.itens, resultados: stats.resultados, contratos: stats.contratos, fornecedores: stats.fornecedores, notas: stats.detalhes })}::jsonb
                where id = ${logId}`;
    } catch { /* log não fatal */ }
  }
  return new Response(JSON.stringify({ ok: true, job, ...stats }), { headers: { "content-type": "application/json" } });
});
