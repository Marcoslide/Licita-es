// BOLSA — diagnóstico v5: sonda endpoints públicos (status + amostra de chaves),
// extrai rotas e parâmetros de documentos OpenAPI (/v3/api-docs), e agora também
// resume páginas HTML (título, framework JS, indícios de captcha/anti-bot,
// indícios de API/swagger, trecho bruto) para discovery técnico de fontes novas.
// Nunca envia credenciais; apenas GETs públicos com user-agent identificado.
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";

function chaves(o: unknown, prof = 0): unknown {
  if (Array.isArray(o)) return o.length ? ["array:" + o.length, chaves(o[0], prof + 1)] : "array:0";
  if (o && typeof o === "object" && prof < 3) return Object.keys(o as Record<string, unknown>).slice(0, 34);
  return typeof o;
}

function resumoHtml(txt: string): Record<string, unknown> {
  const title = /<title[^>]*>([^<]{1,200})<\/title>/i.exec(txt)?.[1]?.trim() ?? null;
  const scripts = [...txt.matchAll(/<script[^>]+src=["']([^"']+)["']/gi)].map((m) => m[1]).slice(0, 40);
  const frameworks: string[] = [];
  const marca = (nome: string, re: RegExp) => { if (re.test(txt)) frameworks.push(nome); };
  marca("react", /react(-dom)?[.\-@]|data-reactroot|__NEXT_DATA__/i);
  marca("angular", /ng-app|ng-version|angular\.js|zone\.js/i);
  marca("vue", /vue\.js|__NUXT__|v-app/i);
  marca("jquery", /jquery[.\-]/i);
  marca("wordpress", /wp-content|wp-includes/i);
  const antiBot: string[] = [];
  const marcaBot = (nome: string, re: RegExp) => { if (re.test(txt)) antiBot.push(nome); };
  marcaBot("recaptcha", /recaptcha|grecaptcha/i);
  marcaBot("hcaptcha", /hcaptcha/i);
  marcaBot("cloudflare_challenge", /cf-chl|cf_chl|challenges\.cloudflare\.com|__cf_bm/i);
  marcaBot("turnstile", /turnstile/i);
  const apiHints: string[] = [];
  const marcaApi = (nome: string, re: RegExp) => { if (re.test(txt)) apiHints.push(nome); };
  marcaApi("swagger_ui", /swagger-ui|swagger\.json|swagger\.io/i);
  marcaApi("openapi", /openapi\.json|\/v3\/api-docs/i);
  marcaApi("graphql", /graphql/i);
  marcaApi("api_path_ref", /["'](\/api\/[a-z0-9_\-\/]+)["']/i);
  const linksApi = [...new Set([...txt.matchAll(/["'](\/?api\/[a-zA-Z0-9_\-\/]{2,60})["']/g)].map((m) => m[1]))].slice(0, 20);
  const forms = [...txt.matchAll(/<form[^>]*action=["']([^"']*)["']/gi)].map((m) => m[1]).slice(0, 10);
  return { title, scripts_amostra: scripts.slice(0, 10), frameworks, anti_bot: antiBot, api_hints: apiHints, links_api_encontrados: linksApi, forms_action: forms };
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
  const bruto: boolean = p.bruto === true;
  const brutoMax: number = p.brutoMax ?? 4000;
  const aceitar = p.aceitaHtml === false ? "application/json" : "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8";
  for (const url of urls.slice(0, 14)) {
    const item: Record<string, unknown> = { url };
    try {
      const res = await fetch(url, { headers: { accept: aceitar, "user-agent": UA }, signal: AbortSignal.timeout(tmo), redirect: "follow" });
      item.status = res.status;
      item.status_final_url = res.url !== url ? res.url : undefined;
      item.content_type = res.headers.get("content-type");
      item.server = res.headers.get("server") ?? res.headers.get("x-powered-by") ?? undefined;
      const txt = await res.text();
      item.bytes = txt.length;
      if (txt.length < 500) item.snippet = txt;
      let ehJson = false;
      try {
        const j = JSON.parse(txt);
        ehJson = true;
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
      } catch { /* não é JSON — trata como HTML abaixo */ }
      if (!ehJson && txt.length >= 500) {
        item.html_resumo = resumoHtml(txt);
      }
      if (bruto) item.bruto = txt.slice(0, brutoMax);
    } catch (e) {
      item.erro = String((e as Error)?.message ?? e);
    }
    out.push(item);
  }
  return new Response(JSON.stringify(out), { headers: { "content-type": "application/json" } });
});
