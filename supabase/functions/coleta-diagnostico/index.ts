// BOLSA — diagnóstico v4: sonda endpoints públicos (status + amostra de chaves),
// extrai rotas e parâmetros de documentos OpenAPI (/v3/api-docs).
// Nunca envia credenciais; apenas GETs públicos com user-agent identificado.
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";

function chaves(o: unknown, prof = 0): unknown {
  if (Array.isArray(o)) return o.length ? ["array:" + o.length, chaves(o[0], prof + 1)] : "array:0";
  if (o && typeof o === "object" && prof < 3) return Object.keys(o as Record<string, unknown>).slice(0, 34);
  return typeof o;
}

Deno.serve(async (req: Request) => {
  let p: any = {};
  try { p = await req.json(); } catch (_) { /* vazio */ }
  const out: Record<string, unknown>[] = [];

  if (p.apiDocs && Array.isArray(p.detalharRotas)) {
    try {
      const res = await fetch(p.apiDocs, { headers: { accept: "application/json", "user-agent": UA }, signal: AbortSignal.timeout(30000) });
      const doc = await res.json();
      for (const rota of p.detalharRotas.slice(0, 20)) {
        const def = doc?.paths?.[rota]?.get ?? doc?.paths?.[rota];
        const params = (def?.parameters ?? []).map((q: any) => `${q.name}${q.required ? "*" : ""}:${q.schema?.type ?? "?"}`);
        out.push({ rota, params });
      }
    } catch (e) { out.push({ apiDocs: p.apiDocs, erro: String((e as Error).message) }); }
  }

  const urls: string[] = p.urls ?? [];
  const tmo: number = p.timeoutMs ?? 15000;
  for (const url of urls.slice(0, 14)) {
    const item: Record<string, unknown> = { url };
    try {
      const res = await fetch(url, { headers: { accept: "application/json", "user-agent": UA }, signal: AbortSignal.timeout(tmo), redirect: "follow" });
      item.status = res.status;
      const txt = await res.text();
      item.bytes = txt.length;
      if (txt.length < 500) item.snippet = txt;
      try {
        const j = JSON.parse(txt);
        if (j && typeof j === "object" && !Array.isArray(j) && (j as any).paths) {
          item.rotas = Object.keys((j as any).paths).slice(0, 260);
        } else {
          item.shape = chaves(j);
          if (j && typeof j === "object" && !Array.isArray(j)) {
            for (const k of ["totalRegistros", "totalPaginas", "total", "count"]) {
              if ((j as any)[k] != null && typeof (j as any)[k] !== "object") item["meta_" + k] = (j as any)[k];
            }
            const arr = (j as any).resultado ?? (j as any).data ?? null;
            if (Array.isArray(arr) && arr[0]) item.amostra_registro = chaves(arr[0], 1);
          } else if (Array.isArray(j) && j[0]) {
            item.amostra_registro = chaves(j[0], 1);
          }
        }
      } catch { /* snippet já capturado acima */ }
    } catch (e) {
      item.erro = String((e as Error)?.message ?? e);
    }
    out.push(item);
  }
  return new Response(JSON.stringify(out), { headers: { "content-type": "application/json" } });
});
