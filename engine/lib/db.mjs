// Banco local de referência (SQLite via node:sqlite — Node >= 22).
// Em produção o mesmo modelo roda em Postgres (supabase/migrations).
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const AQUI = dirname(fileURLToPath(import.meta.url));

export function abrirDb(caminho = join(AQUI, '..', '..', 'data', 'bolsa.db')) {
  const db = new DatabaseSync(caminho);
  db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;');
  db.exec(readFileSync(join(AQUI, '..', 'schema.sql'), 'utf8'));
  return db;
}

export const sha256 = (s) => createHash('sha256').update(s).digest('hex');

export function gravarRaw(db, { url, contexto, status, corpo }) {
  db.prepare(`INSERT OR IGNORE INTO raw_payloads (fonte_id, url, contexto, http_status, content_hash, payload)
              VALUES ('pncp', ?, ?, ?, ?, ?)`)
    .run(url, contexto ?? null, status ?? null, sha256(corpo), corpo);
}

export function upsert(db, tabela, chaves, row) {
  const cols = Object.keys(row);
  const marcadores = cols.map(() => '?').join(',');
  const updates = cols.filter((c) => !chaves.includes(c) && c !== 'first_seen_at')
    .map((c) => `${c}=excluded.${c}`).join(',');
  const sql = `INSERT INTO ${tabela} (${cols.join(',')}) VALUES (${marcadores})
               ON CONFLICT (${chaves.join(',')}) DO UPDATE SET ${updates}`;
  db.prepare(sql).run(...cols.map((c) => row[c] ?? null));
}
