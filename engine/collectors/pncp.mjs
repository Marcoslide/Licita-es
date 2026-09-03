// ============================================================
// PncpCollector — implementação de referência (Node/SQLite).
// A mesma lógica roda em produção como Edge Function
// (supabase/functions/coleta-pncp). Interface: PublicSourceCollector.
// Capabilities do PNCP: licitações ✔ itens ✔ documentos ✔
// resultados ✔ contratos ✔ atas ✔(pendente) pca ✔(pendente)
// pagamentos ✖ lances ✖ (§86-87)
// ============================================================
import { criarHttp } from '../lib/http.mjs';
import { gravarRaw, upsert } from '../lib/db.mjs';

const PNCP = 'https://pncp.gov.br';
const UFS = new Set(['AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO']);

export function cnpjValido(c) {
  if (!c) return false;
  const n = String(c).replace(/\D/g, '');
  if (n.length !== 14 || /^(\d)\1+$/.test(n)) return false;
  const calc = (len) => {
    const w = len === 12 ? [5,4,3,2,9,8,7,6,5,4,3,2] : [6,5,4,3,2,9,8,7,6,5,4,3,2];
    const s = w.reduce((a, p, i) => a + p * +n[i], 0);
    const r = s % 11; return r < 2 ? 0 : 11 - r;
  };
  return calc(12) === +n[12] && calc(13) === +n[13];
}

// campos monitorados para eventos de histórico (§20-21)
export const CAMPOS_EVENTO = [
  ['data_abertura_proposta', 'DATA_SESSAO_ALTERADA'],
  ['data_encerramento_proposta', 'DATA_SESSAO_ALTERADA'],
  ['valor_total_estimado', 'VALOR_ESTIMADO_ALTERADO'],
  ['valor_total_homologado', 'VALOR_HOMOLOGADO_ALTERADO'],
  ['situacao_nome', 'SITUACAO_ALTERADA'],
  ['objeto', 'OBJETO_ALTERADO'],
];

export function normalizarContratacao(c) {
  const org = c.orgaoEntidade ?? {}; const un = c.unidadeOrgao ?? {};
  return {
    numero_controle_pncp: c.numeroControlePNCP ?? null,
    fonte_id: 'pncp',
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
    situacao_fonte: c.situacaoCompraNome ?? null,          // texto original preservado (§18/§44)
    srp: typeof c.srp === 'boolean' ? (c.srp ? 1 : 0) : null,
    instrumento: c.tipoInstrumentoConvocatorioNome ?? null,
    objeto: c.objetoCompra ?? null,                        // source_object_description — nunca alterado
    valor_total_estimado: c.valorTotalEstimado ?? null,    // NULL ≠ 0 (§35)
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
    source_payload: JSON.stringify(c),                     // §27: payload original preservado
  };
}

export class PncpCollector {
  constructor(db, opts = {}) {
    this.db = db;
    this.http = criarHttp({ onRaw: async (r) => gravarRaw(db, r), ...opts });
  }

  dq(entidade, chave, campo, problema, valor) {
    this.db.prepare('INSERT INTO data_quality_issues (entidade, chave, campo, problema, valor) VALUES (?,?,?,?,?)')
      .run(entidade, chave, campo, problema, String(valor ?? ''));
  }

  // aplica um lote de contratações (usado tanto pela coleta ao vivo quanto pelo replay do RAW)
  aplicarContratacoes(regs, stats) {
    const agora = new Date().toISOString();
    for (const c of regs) {
      const r = normalizarContratacao(c);
      if (!r.numero_controle_pncp) { stats.ignorados++; this.dq('licitacao', '-', 'numero_controle_pncp', 'ausente', null); continue; }
      const o = c.orgaoEntidade, u = c.unidadeOrgao;
      if (o?.cnpj) {
        if (!cnpjValido(o.cnpj)) this.dq('orgao', o.cnpj, 'cnpj', 'cnpj_invalido', o.cnpj);
        upsert(this.db, 'orgaos', ['cnpj'], { cnpj: o.cnpj, razao_social: o.razaoSocial ?? null, poder_id: o.poderId ?? null, esfera_id: o.esferaId ?? null, last_seen_at: agora, source_payload: JSON.stringify(o) });
        if (u?.codigoUnidade != null) {
          if (u.ufSigla && !UFS.has(u.ufSigla)) this.dq('unidade', `${o.cnpj}/${u.codigoUnidade}`, 'uf', 'uf_invalida', u.ufSigla);
          upsert(this.db, 'unidades', ['orgao_cnpj', 'codigo'], { orgao_cnpj: o.cnpj, codigo: String(u.codigoUnidade), nome: u.nomeUnidade ?? null, uf: u.ufSigla ?? null, municipio_nome: u.municipioNome ?? null, codigo_ibge: u.codigoIbge != null ? String(u.codigoIbge) : null });
        }
      }
      const antes = this.db.prepare(
        `SELECT data_abertura_proposta, data_encerramento_proposta, valor_total_estimado,
                valor_total_homologado, situacao_nome, objeto
         FROM licitacoes WHERE numero_controle_pncp = ?`).get(r.numero_controle_pncp);
      if (!antes) {
        stats.inseridos++;
        this.db.prepare(`INSERT INTO eventos (entidade, chave, tipo, fonte_id) VALUES ('licitacao', ?, 'NOVO_REGISTRO', 'pncp')`).run(r.numero_controle_pncp);
      } else {
        let mudou = false;
        for (const [campo, tipo] of CAMPOS_EVENTO) {
          const a = antes[campo] == null ? null : String(antes[campo]);
          const b = r[campo] == null ? null : String(r[campo]);
          if (a !== b) {
            mudou = true;
            this.db.prepare(`INSERT INTO eventos (entidade, chave, tipo, campo, valor_anterior, valor_novo, fonte_id)
                             VALUES ('licitacao', ?, ?, ?, ?, ?, 'pncp')`).run(r.numero_controle_pncp, tipo, campo, a, b);
            stats.eventos++;
          }
        }
        mudou ? stats.atualizados++ : stats.ignorados++;
      }
      upsert(this.db, 'licitacoes', ['numero_controle_pncp'], { ...r, last_seen_at: agora });
      stats.registros++;
    }
  }

  // LISTAGEM → paginação com checkpoint (§45-46)
  async delta({ dataInicial, dataFinal, modalidades = [6, 8, 4, 9, 12], maxPaginas = 3, tamanhoPagina = 50 } = {}) {
    const ymd = (d) => d.toISOString().slice(0, 10).replace(/-/g, '');
    dataInicial ??= ymd(new Date(Date.now() - 864e5));
    dataFinal ??= ymd(new Date());
    const stats = { paginas: 0, registros: 0, inseridos: 0, atualizados: 0, ignorados: 0, eventos: 0, erros: 0 };
    const ckChave = `pncp:delta:${dataInicial}-${dataFinal}`;
    const ck = this.db.prepare('SELECT valor FROM checkpoints WHERE chave = ?').get(ckChave);
    const progresso = ck ? JSON.parse(ck.valor).paginaPorModalidade ?? {} : {};

    for (const mod of modalidades) {
      let pag = (progresso[mod] ?? 0) + 1;
      for (let n = 0; n < maxPaginas; n++, pag++) {
        const url = `${PNCP}/api/consulta/v1/contratacoes/publicacao?dataInicial=${dataInicial}&dataFinal=${dataFinal}&codigoModalidadeContratacao=${mod}&pagina=${pag}&tamanhoPagina=${tamanhoPagina}`;
        const r = await this.http.json(url, 'contratacoes');
        if (!r.ok || !r.body) { if (r.status === 0) stats.erros++; break; }
        stats.paginas++;
        this.aplicarContratacoes(r.body.data ?? [], stats);
        progresso[mod] = pag;
        upsert(this.db, 'checkpoints', ['chave'], { chave: ckChave, valor: JSON.stringify({ paginaPorModalidade: progresso, dataInicial, dataFinal }), atualizado_em: new Date().toISOString() });
        if (!r.body.paginasRestantes || r.body.paginasRestantes <= 0) break;
      }
    }
    return stats;
  }

  // DETALHES: itens + documentos + resultados de licitações pendentes
  async detalhes({ maxDetalhes = 10 } = {}) {
    const agora = new Date().toISOString();
    const stats = { itens: 0, documentos: 0, resultados: 0, fornecedores: 0, erros: 0 };
    const pend = this.db.prepare(
      `SELECT numero_controle_pncp, orgao_cnpj, ano_compra, sequencial_compra
       FROM licitacoes WHERE itens_coletados_em IS NULL
       ORDER BY data_publicacao_pncp DESC LIMIT ?`).all(maxDetalhes);
    for (const lic of pend) {
      if (!lic.orgao_cnpj || !lic.ano_compra || !lic.sequencial_compra) continue;
      const base = `${PNCP}/api/pncp/v1/orgaos/${lic.orgao_cnpj}/compras/${lic.ano_compra}/${lic.sequencial_compra}`;
      const itens = [];
      for (let pag = 1; pag <= 5; pag++) {
        const r = await this.http.json(`${base}/itens?pagina=${pag}&tamanhoPagina=100`, 'itens');
        if (!r.ok || !Array.isArray(r.body) || r.body.length === 0) break;
        itens.push(...r.body);
        if (r.body.length < 100) break;
      }
      for (const i of itens) {
        if (i.numeroItem == null) continue;
        upsert(this.db, 'itens', ['numero_controle_pncp', 'numero_item'], {
          numero_controle_pncp: lic.numero_controle_pncp,
          numero_item: i.numeroItem,
          descricao: i.descricao ?? null,
          material_ou_servico: i.materialOuServicoNome ?? i.materialOuServico ?? null,
          quantidade: i.quantidade ?? null,
          unidade: i.unidadeMedida ?? null,
          valor_unitario_estimado: i.valorUnitarioEstimado ?? null,
          valor_total_estimado: i.valorTotal ?? null,
          categoria_id: i.itemCategoriaId ?? null,
          categoria_nome: i.itemCategoriaNome ?? null,
          criterio_julgamento: i.criterioJulgamentoNome ?? null,
          situacao_fonte: i.situacaoCompraItemNome ?? null,
          beneficio: i.tipoBeneficioNome ?? null,
          ncm_nbs: i.ncmNbsCodigo ?? null,
          catalogo_codigo: i.codigoItemCatalogo != null ? String(i.codigoItemCatalogo) : null,
          tem_resultado: typeof i.temResultado === 'boolean' ? (i.temResultado ? 1 : 0) : null,
          orcamento_sigiloso: typeof i.orcamentoSigiloso === 'boolean' ? (i.orcamentoSigiloso ? 1 : 0) : null,
          source_updated_at: i.dataAtualizacao ?? null,
          source_payload: JSON.stringify(i),
          last_seen_at: agora,
        });
        stats.itens++;
      }
      const rDocs = await this.http.json(`${base}/arquivos?pagina=1&tamanhoPagina=50`, 'arquivos');
      if (rDocs.ok && Array.isArray(rDocs.body)) {
        for (const d of rDocs.body) {
          this.db.prepare(
            `INSERT INTO documentos (numero_controle_pncp, sequencial_documento, titulo, tipo_documento, url, status_ativo, data_publicacao, source_payload, last_seen_at)
             VALUES (?,?,?,?,?,?,?,?,?)
             ON CONFLICT (numero_controle_pncp, ifnull(sequencial_documento,0), ifnull(url,'-'))
             DO UPDATE SET titulo=excluded.titulo, tipo_documento=excluded.tipo_documento,
                           status_ativo=excluded.status_ativo, last_seen_at=excluded.last_seen_at`)
            .run(lic.numero_controle_pncp, d.sequencialDocumento ?? null, d.titulo ?? null,
                 d.tipoDocumentoNome ?? null, d.url ?? d.uri ?? null,
                 typeof d.statusAtivo === 'boolean' ? (d.statusAtivo ? 1 : 0) : null,
                 d.dataPublicacaoPncp ?? null, JSON.stringify(d), agora);
          stats.documentos++;
        }
      }
      let algumResultado = false;
      for (const it of itens.filter((i) => i.temResultado === true).slice(0, 12)) {
        const rr = await this.http.json(`${base}/itens/${it.numeroItem}/resultados`, 'resultados');
        if (rr.ok && Array.isArray(rr.body)) {
          for (const res of rr.body) {
            const ni = res.niFornecedor ?? null;
            if (ni) {
              if (res.tipoPessoa === 'PJ' && !cnpjValido(ni)) this.dq('fornecedor', ni, 'ni', 'cnpj_invalido', ni);
              upsert(this.db, 'fornecedores', ['ni'], { ni, tipo_pessoa: res.tipoPessoa ?? null, nome: res.nomeRazaoSocialFornecedor ?? null, porte: res.porteFornecedorNome ?? null, last_seen_at: agora });
              stats.fornecedores++;
            }
            this.db.prepare(
              `INSERT INTO resultados_itens (numero_controle_pncp, numero_item, sequencial_resultado, fornecedor_ni, fornecedor_nome, tipo_pessoa, porte, quantidade_homologada, valor_unitario_homologado, valor_total_homologado, percentual_desconto, situacao_fonte, data_resultado, source_payload, last_seen_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT (numero_controle_pncp, numero_item, ifnull(fornecedor_ni,'-'), ifnull(sequencial_resultado,0))
               DO UPDATE SET valor_unitario_homologado=excluded.valor_unitario_homologado,
                             valor_total_homologado=excluded.valor_total_homologado,
                             situacao_fonte=excluded.situacao_fonte, last_seen_at=excluded.last_seen_at`)
              .run(lic.numero_controle_pncp, it.numeroItem, res.sequencialResultado ?? null, ni,
                   res.nomeRazaoSocialFornecedor ?? null, res.tipoPessoa ?? null, res.porteFornecedorNome ?? null,
                   res.quantidadeHomologada ?? null, res.valorUnitarioHomologado ?? null, res.valorTotalHomologado ?? null,
                   res.percentualDesconto ?? null, res.situacaoCompraItemResultadoNome ?? null, res.dataResultado ?? null,
                   JSON.stringify(res), agora);
            stats.resultados++;
            algumResultado = true;
          }
        }
      }
      this.db.prepare(
        `UPDATE licitacoes SET itens_coletados_em = ?, arquivos_coletados_em = ?
         ${''}, resultados_coletados_em = CASE WHEN ? THEN ? ELSE resultados_coletados_em END
         WHERE numero_controle_pncp = ?`)
        .run(agora, agora, algumResultado ? 1 : 0, agora, lic.numero_controle_pncp);
    }
    return stats;
  }
}
