// ============================================================
// BOLSA — conector Licitações-e (Banco do Brasil) — v1 (modo inspeção)
// Wave 2 #6 aprofundado. www.licitacoes-e.com.br/aop — app JSP real
// (Java, "com.bb.comercioeletronico.aop"). Discovery: form real
// name="fmSituacao" action="listar-licitacoes-comprador.aop" method=post,
// campo codigoTipoEstadoLicitacao com códigos reais do menu:
// 4=Publicadas, 5=Propostas abertas, 6=?, 7=Em homologação, 8=Concluídas.
// ============================================================
const BASE = "https://www.licitacoes-e.com.br";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";

function amostrar(texto: string, termo: string | undefined, inicioPadrao: number, fimPadrao: number): string {
  if (!termo) return texto.slice(inicioPadrao, fimPadrao);
  const idx = texto.indexOf(termo);
  if (idx === -1) return `TERMO_NAO_ENCONTRADO:${termo}`;
  return texto.slice(Math.max(0, idx - 1500), idx + 3000);
}

Deno.serve(async (req: Request) => {
  const body = await req.json().catch(() => ({} as Record<string, unknown>));
  const codigo = String(body.codigo ?? "4");
  const termo = body.termo as string | undefined;

  try {
    // app Java/JSP: provavelmente exige JSESSIONID estabelecido por um GET
    // anterior — sem isso, o POST direto devolvia 500.
    const resIndex = await fetch(`${BASE}/aop/index.jsp`, {
      headers: { "user-agent": UA }, signal: AbortSignal.timeout(15000),
    });
    const setCookie = resIndex.headers.get("set-cookie") ?? "";
    const jsessionid = /JSESSIONID=([^;]+)/.exec(setCookie)?.[1];
    await resIndex.arrayBuffer(); // drena o corpo

    const idComprador = body.idComprador as string | undefined;
    const cookieHeader = jsessionid ? { cookie: `JSESSIONID=${jsessionid}` } : {};

    // diagnostico: chamada real de listarLicitacoesAcompanhaveis() confirmada no
    // JS da pagina — 'PreCaptcha' e nome literal da opcao, so verificando o que
    // volta (nao tentando resolver nada), para documentar o bloqueio com precisao.
    if (body.modo === "precaptcha") {
      const paramsPre = new URLSearchParams({
        opcao: "listarLicitacoesAcompanhaveisPreCaptcha",
        codigoComprador: String(body.codigoComprador ?? "3"),
        nomeComprador: String(body.nomeComprador ?? "BANCO DO BRASIL"),
        codigoSituacao: String(body.codigoSituacao ?? "3"),
        textoSituacao: String(body.textoSituacao ?? "Acolhimento de propostas"),
        quantidade: String(body.quantidade ?? "32"),
      });
      const urlPre = `${BASE}${body.caminho ?? "/licitacoes-acompanhaveis.aop"}`;
      const resPre = await fetch(urlPre, {
        method: "POST",
        headers: { "user-agent": UA, "content-type": "application/x-www-form-urlencoded", referer: `${BASE}/aop/listar-licitacoes-comprador.aop`, ...cookieHeader },
        body: paramsPre.toString(),
        signal: AbortSignal.timeout(15000),
      });
      const textoPre = await resPre.text();
      return new Response(JSON.stringify({
        url: urlPre, status: resPre.status, content_type: resPre.headers.get("content-type"),
        tamanho: textoPre.length, amostra: amostrar(textoPre, termo, 0, 4000),
      }), { headers: { "content-type": "application/json" } });
    }

    if (idComprador) {
      const params2 = new URLSearchParams({
        codigoTipoEstadoLicitacao: codigo, idComprador,
        opcao: "listarLicitacoesAcompanhaveis",
      });
      const res2 = await fetch(`${BASE}/aop/listar-licitacoes-comprador.aop`, {
        method: "POST",
        headers: { "user-agent": UA, "content-type": "application/x-www-form-urlencoded", referer: `${BASE}/aop/index.jsp`, ...cookieHeader },
        body: params2.toString(),
        signal: AbortSignal.timeout(15000),
      });
      const texto2 = await res2.text();
      return new Response(JSON.stringify({
        status: res2.status, tamanho: texto2.length, amostra: amostrar(texto2, termo, 15000, 35000),
      }), { headers: { "content-type": "application/json" } });
    }

    const params = new URLSearchParams({ codigoTipoEstadoLicitacao: codigo, opcao: "listarLicitacoesComprador" });
    const res = await fetch(`${BASE}/aop/listar-licitacoes-comprador.aop`, {
      method: "POST",
      headers: {
        "user-agent": UA,
        "content-type": "application/x-www-form-urlencoded",
        referer: `${BASE}/aop/index.jsp`,
        ...cookieHeader,
      },
      body: params.toString(),
      signal: AbortSignal.timeout(15000),
    });
    const texto = await res.text();
    return new Response(JSON.stringify({
      status: res.status, content_type: res.headers.get("content-type"),
      jsessionid_encontrado: Boolean(jsessionid),
      tamanho: texto.length, amostra: amostrar(texto, termo, 20000, 40000),
    }), { headers: { "content-type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ erro: String((e as Error)?.message ?? e) }), { status: 500, headers: { "content-type": "application/json" } });
  }
});
