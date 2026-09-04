// ============================================================
// BOLSA — baixar-documento v1 — PARTE A2 (fechamento Wave 1)
//
// Prova ponta-a-ponta de documentos do motor genérico:
//   URL original → download → SHA-256 → tamanho → Storage (memoria-bruta,
//   content-addressed) → vínculo (fonte_id/entidade/chave) → recuperação
//   (GET de volta + reconfere hash).
//
// Dedup real: se o SHA-256 já existe em bolsa.documento_bytes, não baixa
// nem sobe de novo — só cria o vínculo em bolsa.documento_download.
//
// Mesmo padrão de upload/credenciais do coleta-historico-transp (Storage
// REST direto, SUPABASE_SERVICE_ROLE_KEY em authorization+apikey) — não
// inventa um mecanismo novo de acesso ao Storage.
// ============================================================
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 15, connect_timeout: 10 });
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "memoria-bruta";
const UA = "BolsaLicitacoes/0.1 (coleta de dados publicos; +https://github.com/Marcoslide/Licita-es)";

function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function extensaoDe(url: string, contentType: string | null): string {
  const m = /\.([a-z0-9]{2,5})(?:\?|#|$)/i.exec(url);
  if (m) return m[1].toLowerCase();
  if (contentType?.includes("pdf")) return "pdf";
  return "bin";
}

interface ItemEntrada { fonte_id: string; chave: string; url: string; entidade?: string }
interface ItemResultado {
  fonte_id: string; chave: string; url: string;
  ok: boolean; erro?: string;
  sha256?: string; tamanho_bytes?: number; content_type?: string | null; storage_path?: string;
  dedup?: boolean; upload_ok?: boolean; recuperado_ok?: boolean; hashes_conferem?: boolean;
}

async function processarItem(item: ItemEntrada): Promise<ItemResultado> {
  const entidade = item.entidade ?? "documento_processo";
  try {
    const res = await fetch(item.url, { headers: { "user-agent": UA }, signal: AbortSignal.timeout(20000) });
    if (!res.ok) return { fonte_id: item.fonte_id, chave: item.chave, url: item.url, ok: false, erro: `download HTTP ${res.status}` };
    const buf = await res.arrayBuffer();
    const contentType = res.headers.get("content-type");
    const sha256 = hex(await crypto.subtle.digest("SHA-256", buf));
    const tamanho = buf.byteLength;
    const storagePath = `documentos/${sha256}.${extensaoDe(item.url, contentType)}`;

    const existente = await sql`select storage_path from bolsa.documento_bytes where sha256 = ${sha256}`;
    let uploadOk = true;
    let dedup = false;
    if (existente.length > 0) {
      dedup = true;
    } else {
      const up = await fetch(`${SUPABASE_URL}/storage/v1/object/${BUCKET}/${storagePath}`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY,
          "content-type": contentType || "application/octet-stream", "x-upsert": "true",
        },
        body: buf,
      });
      uploadOk = up.ok;
      if (!uploadOk) {
        const corpo = (await up.text().catch(() => "")).slice(0, 300);
        return { fonte_id: item.fonte_id, chave: item.chave, url: item.url, ok: false, erro: `upload HTTP ${up.status}: ${corpo}` };
      }
      await sql`insert into bolsa.documento_bytes (sha256, tamanho_bytes, content_type, storage_path)
                values (${sha256}, ${tamanho}, ${contentType}, ${storagePath})
                on conflict (sha256) do nothing`;
    }

    await sql`insert into bolsa.documento_download (fonte_id, entidade, chave, url_original, sha256)
              values (${item.fonte_id}, ${entidade}, ${item.chave}, ${item.url}, ${sha256})
              on conflict (fonte_id, entidade, chave) do update set url_original = excluded.url_original, sha256 = excluded.sha256`;

    // recuperação real: baixa de volta do Storage e reconfere o hash
    const getRes = await fetch(`${SUPABASE_URL}/storage/v1/object/${BUCKET}/${storagePath}`, {
      headers: { authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY },
    });
    const recuperadoOk = getRes.ok;
    let hashesConferem = false;
    if (recuperadoOk) {
      const bufRecuperado = await getRes.arrayBuffer();
      const shaRecuperado = hex(await crypto.subtle.digest("SHA-256", bufRecuperado));
      hashesConferem = shaRecuperado === sha256 && bufRecuperado.byteLength === tamanho;
    }

    return {
      fonte_id: item.fonte_id, chave: item.chave, url: item.url, ok: true,
      sha256, tamanho_bytes: tamanho, content_type: contentType, storage_path: storagePath,
      dedup, upload_ok: uploadOk, recuperado_ok: recuperadoOk, hashes_conferem: hashesConferem,
    };
  } catch (e) {
    return { fonte_id: item.fonte_id, chave: item.chave, url: item.url, ok: false, erro: String((e as Error)?.message ?? e) };
  }
}

Deno.serve(async (req: Request) => {
  try {
    const body = await req.json().catch(() => ({}));
    const itens: ItemEntrada[] = Array.isArray(body?.itens) ? body.itens : [];
    if (itens.length === 0) {
      return new Response(JSON.stringify({ erro: "body deve conter itens: [{fonte_id, chave, url}]" }), { status: 400, headers: { "content-type": "application/json" } });
    }
    const resultados: ItemResultado[] = [];
    for (const item of itens) resultados.push(await processarItem(item));
    return new Response(JSON.stringify({ resultados }), { headers: { "content-type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ erro: String((e as Error)?.message ?? e) }), { status: 500, headers: { "content-type": "application/json" } });
  }
});
