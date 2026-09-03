// HTTP público com timeout, retry exponencial + jitter e ritmo (§53-55).
// Nunca burla autenticação, CAPTCHA ou bloqueio — somente endpoints públicos.
const UA = 'BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function criarHttp({ intervaloMs = 120, timeoutMs = 12000, tentativas = 3, onRaw } = {}) {
  let ultimo = 0;
  return {
    async json(url, contexto) {
      const espera = ultimo + intervaloMs - Date.now();
      if (espera > 0) await sleep(espera);
      for (let t = 0; t < tentativas; t++) {
        ultimo = Date.now();
        try {
          const res = await fetch(url, {
            headers: { accept: 'application/json', 'user-agent': UA },
            signal: AbortSignal.timeout(timeoutMs),
          });
          if (res.status === 204) return { ok: true, status: 204, body: null };
          if (res.ok) {
            const txt = await res.text();
            if (onRaw) await onRaw({ url, contexto, status: res.status, corpo: txt || 'null' });
            return { ok: true, status: res.status, body: txt ? JSON.parse(txt) : null };
          }
          if (res.status === 404) return { ok: false, status: 404, body: null };
          if (res.status === 429 || res.status >= 500) { await sleep(500 * 2 ** t + Math.random() * 400); continue; }
          return { ok: false, status: res.status, body: null };
        } catch {
          await sleep(500 * 2 ** t + Math.random() * 400);
        }
      }
      return { ok: false, status: 0, body: null };
    },
  };
}
