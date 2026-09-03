#!/usr/bin/env node
// CLI do motor de coleta — implementação de referência local.
// Uso:
//   node engine/jobs/run.mjs delta      [--de 20260901 --ate 20260903] [--paginas 3]
//   node engine/jobs/run.mjs detalhes   [--lote 10]
//   node engine/jobs/run.mjs status
// Observação: em produção a coleta roda como Edge Function no Supabase
// (supabase/functions/coleta-pncp) acionada por pg_cron. Este CLI usa o
// mesmo conector contra um SQLite local (data/bolsa.db).
import { abrirDb } from '../lib/db.mjs';
import { PncpCollector } from '../collectors/pncp.mjs';

const args = process.argv.slice(2);
const cmd = args[0] ?? 'status';
const opt = (nome, padrao) => {
  const i = args.indexOf('--' + nome);
  return i >= 0 ? args[i + 1] : padrao;
};

const db = abrirDb();
const coletor = new PncpCollector(db);

function logRun(job, fn) {
  const ini = new Date().toISOString();
  return fn().then((stats) => {
    db.prepare(`INSERT INTO coleta_log (fonte_id, job, iniciado_em, finalizado_em, paginas, registros, inseridos, atualizados, ignorados, documentos, erros, detalhe)
                VALUES ('pncp', ?, ?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(job, ini, stats.paginas ?? 0, stats.registros ?? 0, stats.inseridos ?? 0,
           stats.atualizados ?? 0, stats.ignorados ?? 0, stats.documentos ?? 0,
           stats.erros ?? 0, JSON.stringify(stats));
    console.log(JSON.stringify({ job, ...stats }, null, 2));
  });
}

if (cmd === 'delta') {
  await logRun('delta', () => coletor.delta({
    dataInicial: opt('de'), dataFinal: opt('ate'),
    maxPaginas: Number(opt('paginas', 3)),
  }));
} else if (cmd === 'detalhes') {
  await logRun('detalhes', () => coletor.detalhes({ maxDetalhes: Number(opt('lote', 10)) }));
} else if (cmd === 'status') {
  const q = (sql) => db.prepare(sql).get();
  console.log(JSON.stringify({
    licitacoes: q('SELECT count(*) n FROM licitacoes').n,
    itens: q('SELECT count(*) n FROM itens').n,
    documentos: q('SELECT count(*) n FROM documentos').n,
    resultados: q('SELECT count(*) n FROM resultados_itens').n,
    fornecedores: q('SELECT count(*) n FROM fornecedores').n,
    contratos: q('SELECT count(*) n FROM contratos').n,
    raw: q('SELECT count(*) n FROM raw_payloads').n,
    eventos: q('SELECT count(*) n FROM eventos').n,
    ultima_coleta: db.prepare('SELECT job, iniciado_em, registros, erros FROM coleta_log ORDER BY id DESC LIMIT 1').get() ?? null,
  }, null, 2));
} else {
  console.error('comando desconhecido:', cmd);
  process.exit(1);
}
