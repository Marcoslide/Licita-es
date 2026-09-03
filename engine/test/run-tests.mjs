#!/usr/bin/env node
// Testes do conector PNCP (§47 idempotência, §21 detecção de alteração, §58 validação).
// A fixture em fixtures/contratacoes_fixture.json contém PAYLOADS REAIS coletados do
// PNCP (dados públicos, com proveniência) — usada apenas para testar o parser offline.
import { strict as assert } from 'node:assert';
import { readFileSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { abrirDb } from '../lib/db.mjs';
import { PncpCollector, normalizarContratacao, cnpjValido } from '../collectors/pncp.mjs';

const AQUI = dirname(fileURLToPath(import.meta.url));
const TMP = join(AQUI, 'bolsa-teste.db');
for (const suf of ['', '-wal', '-shm']) { try { rmSync(TMP + suf); } catch { /* ok */ } }

const fixture = JSON.parse(readFileSync(join(AQUI, 'fixtures', 'contratacoes_fixture.json'), 'utf8'));
assert.ok(Array.isArray(fixture.data) && fixture.data.length >= 2, 'fixture precisa de >= 2 contratações');

const db = abrirDb(TMP);
const coletor = new PncpCollector(db);
let passaram = 0;
const teste = (nome, fn) => { fn(); passaram++; console.log('✔', nome); };

teste('normalização preserva payload original e usa NULL para ausente (§27/§35)', () => {
  const r = normalizarContratacao(fixture.data[0]);
  assert.equal(r.numero_controle_pncp, fixture.data[0].numeroControlePNCP);
  assert.ok(r.source_payload.includes(fixture.data[0].numeroControlePNCP));
  const sem = normalizarContratacao({ numeroControlePNCP: 'X', objetoCompra: 'y' });
  assert.equal(sem.valor_total_estimado, null);   // ausente = NULL, nunca 0
  assert.equal(sem.srp, null);
});

teste('validação de CNPJ por dígitos verificadores (§58)', () => {
  const cnpjReal = fixture.data[0]?.orgaoEntidade?.cnpj;
  if (cnpjReal) assert.ok(cnpjValido(cnpjReal), 'CNPJ real da fixture deve validar');
  assert.ok(!cnpjValido('11111111111111'));
  assert.ok(!cnpjValido('12345678000190'));
});

teste('idempotência: aplicar o mesmo lote duas vezes não duplica (§47/§79)', () => {
  const s1 = { paginas: 0, registros: 0, inseridos: 0, atualizados: 0, ignorados: 0, eventos: 0, erros: 0 };
  coletor.aplicarContratacoes(fixture.data, s1);
  const n1 = db.prepare('SELECT count(*) n FROM licitacoes').get().n;
  const s2 = { paginas: 0, registros: 0, inseridos: 0, atualizados: 0, ignorados: 0, eventos: 0, erros: 0 };
  coletor.aplicarContratacoes(fixture.data, s2);
  const n2 = db.prepare('SELECT count(*) n FROM licitacoes').get().n;
  assert.equal(n1, n2, 'contagem não pode mudar na 2ª aplicação');
  assert.equal(s2.inseridos, 0, '2ª aplicação não insere nada');
  assert.ok(s2.ignorados >= fixture.data.length - 1, '2ª aplicação ignora inalterados');
});

teste('detecção de alteração gera evento com antes/depois (§21/§80)', () => {
  const alterado = structuredClone(fixture.data[0]);
  const antes = alterado.dataAberturaProposta ?? null;
  alterado.dataAberturaProposta = '2099-12-31T10:00:00';
  const s = { paginas: 0, registros: 0, inseridos: 0, atualizados: 0, ignorados: 0, eventos: 0, erros: 0 };
  coletor.aplicarContratacoes([alterado], s);
  assert.equal(s.atualizados, 1);
  const ev = db.prepare(
    `SELECT * FROM eventos WHERE chave = ? AND tipo = 'DATA_SESSAO_ALTERADA' ORDER BY id DESC LIMIT 1`)
    .get(alterado.numeroControlePNCP);
  assert.ok(ev, 'evento DATA_SESSAO_ALTERADA deve existir');
  assert.equal(ev.valor_novo, '2099-12-31T10:00:00');
  assert.equal(ev.valor_anterior, antes == null ? null : String(antes));
});

teste('NOVO_REGISTRO registrado no first_seen (§22)', () => {
  const n = db.prepare(`SELECT count(*) n FROM eventos WHERE tipo = 'NOVO_REGISTRO'`).get().n;
  assert.equal(n, fixture.data.length);
});

console.log(`\n${passaram} testes OK`);
for (const suf of ['', '-wal', '-shm']) { try { rmSync(TMP + suf); } catch { /* ok */ } }
