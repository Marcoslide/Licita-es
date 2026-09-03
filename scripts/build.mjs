#!/usr/bin/env node
// Build: gera dist/bolsa.html com o instantâneo real embutido (arquivo único p/ teste e artifact).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const html = readFileSync('index.html', 'utf8');
let snap = '';
try { snap = readFileSync('data/snapshot.js', 'utf8'); } catch { /* sem snapshot: aba F7 mostra estado vazio honesto */ }

const out = html.replace(
  '<script src="data/snapshot.js"></script>',
  snap ? `<script>\n${snap}\n</script>` : '<!-- sem snapshot: aba F7 exibirá estado vazio -->',
);
mkdirSync('dist', { recursive: true });
writeFileSync('dist/bolsa.html', out);
console.log('dist/bolsa.html gerado:', out.length, 'bytes', snap ? '(snapshot real embutido)' : '(SEM snapshot)');
