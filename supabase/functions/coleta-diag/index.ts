// ============================================================
// BOLSA — diagnóstico HTTP genérico para discovery (Wave 3)
// Uso interno/temporário: busca uma URL qualquer e devolve status +
// amostra (por offset ou por busca de termo). Não persiste nada.
// ============================================================
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";

function amostrar(texto: string, termo: string | undefined, inicioPadrao: number, fimPadrao: number): string {
  if (!termo) return texto.slice(inicioPadrao, fimPadrao);
  const idx = texto.indexOf(termo);
  if (idx === -1) return `TERMO_NAO_ENCONTRADO:${termo}`;
  return texto.slice(Math.max(0, idx - 1500), idx + 3000);
}

function todasOcorrencias(texto: string, termo: string, janela: number): string[] {
  const trechos: string[] = [];
  let idx = texto.indexOf(termo);
  while (idx !== -1 && trechos.length < 15) {
    trechos.push(texto.slice(Math.max(0, idx - 200), idx + janela));
    idx = texto.indexOf(termo, idx + termo.length);
  }
  return trechos;
}

Deno.serve(async (req: Request) => {
  const body = await req.json().catch(() => ({} as Record<string, unknown>));
  const url = String(body.url ?? "");
  const termo = body.termo as string | undefined;
  const metodo = String(body.metodo ?? "GET");
  const inicio = Number(body.inicio ?? 0);
  const fim = Number(body.fim ?? 4000);

  // encadeia 2 requisições preservando o cookie da primeira (Set-Cookie ->
  // Cookie), para apps que amarram um token/redirect a uma sessão (ex.:
  // e-LIC SC, JSESSIONID etc.) — evita o falso-negativo de duas fetches
  // independentes e sem estado.
  if (body.modo === "cadeia2") {
    const r1 = await fetch(String(body.url1), {
      headers: { "user-agent": UA }, signal: AbortSignal.timeout(15000),
    });
    const setCookie = r1.headers.get("set-cookie") ?? "";
    const t1 = await r1.text();
    const m = body.regexRedirect ? new RegExp(String(body.regexRedirect)).exec(t1) : null;
    const url2raw = body.url2 ? String(body.url2) : (m ? m[1] : "");
    const url2 = new URL(url2raw, String(body.url1)).toString();
    const cookieHeader = setCookie ? { cookie: setCookie.split(";")[0] } : {};
    const r2 = await fetch(url2, {
      headers: { "user-agent": UA, ...cookieHeader }, signal: AbortSignal.timeout(15000),
    });
    const t2 = await r2.text();
    return new Response(JSON.stringify({
      status1: r1.status, set_cookie: setCookie, url2_usado: url2,
      status2: r2.status, tamanho2: t2.length, amostra2: amostrar(t2, termo, inicio, fim),
    }), { headers: { "content-type": "application/json" } });
  }

  try {
    const opcoes: RequestInit = {
      method: metodo,
      headers: { "user-agent": UA, ...(body.headers as Record<string, string> | undefined ?? {}) },
      signal: AbortSignal.timeout(20000),
    };
    if (metodo === "POST" && body.corpoJson !== undefined) {
      opcoes.body = JSON.stringify(body.corpoJson);
    } else if (metodo === "POST" && body.corpo) {
      const params = new URLSearchParams(body.corpo as Record<string, string>);
      opcoes.body = params.toString();
      opcoes.headers = { ...opcoes.headers, "content-type": "application/x-www-form-urlencoded" };
    }
    const res = await fetch(url, opcoes);
    const texto = await res.text();

    if (body.modo === "todas" && termo) {
      const janela = Number(body.janela ?? 600);
      return new Response(JSON.stringify({
        url, status: res.status, tamanho: texto.length,
        ocorrencias: todasOcorrencias(texto, termo, janela),
      }), { headers: { "content-type": "application/json" } });
    }

    return new Response(JSON.stringify({
      url, status: res.status, content_type: res.headers.get("content-type"),
      tamanho: texto.length, amostra: amostrar(texto, termo, inicio, fim),
    }), { headers: { "content-type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ erro: String((e as Error)?.message ?? e) }), { status: 500, headers: { "content-type": "application/json" } });
  }
});
