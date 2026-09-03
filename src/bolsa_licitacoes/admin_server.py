from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

from .db import Database
from .public_api import list_procurements, market_summary, procurement_detail, source_status, state_summary
from .supabase_public_api import SupabasePublicApi, SupabasePublicError, SupabaseRestClient


def serve(
    db: Database,
    host: str = "127.0.0.1",
    port: int = 8088,
    token: str = "",
    *,
    supabase_url: str = "",
    supabase_anon_key: str = "",
) -> None:
    remote = SupabasePublicApi(SupabaseRestClient(supabase_url, supabase_anon_key)) if supabase_url and supabase_anon_key else None

    def public_call(remote_method: str, local_method, *args):
        if remote:
            try:
                return getattr(remote, remote_method)(*args)
            except SupabasePublicError as exc:
                print(f"Supabase public fallback: {exc}")
        return local_method(db, *args)

    class Handler(BaseHTTPRequestHandler):
        server_version = "BolsaAPI"
        sys_version = ""

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            if parsed.path == "/health":
                self._json(200, {"status": "ok", "public_data": "supabase-live" if remote else "sqlite"})
            elif parsed.path == "/api/public/summary":
                self._json(200, public_call("market_summary", market_summary), cache="public, max-age=20")
            elif parsed.path == "/api/public/states":
                self._json(200, public_call("state_summary", state_summary), cache="public, max-age=45")
            elif parsed.path == "/api/public/procurements":
                self._json(200, public_call("list_procurements", list_procurements, parse_qs(parsed.query)), cache="public, max-age=15")
            elif parsed.path == "/api/public/sources":
                self._json(200, public_call("source_status", source_status), cache="public, max-age=20")
            elif parsed.path == "/api/public/procurement" or parsed.path.startswith("/api/public/procurements/"):
                from urllib.parse import unquote
                query = parse_qs(parsed.query)
                procurement_raw = (
                    query.get("id", [""])[0]
                    if parsed.path == "/api/public/procurement"
                    else unquote(parsed.path.rsplit("/", 1)[-1])
                )
                if not procurement_raw:
                    self._json(400, {"error": "procurement id inválido"}); return
                if remote:
                    try:
                        payload = remote.procurement_detail(procurement_raw)
                    except SupabasePublicError as exc:
                        print(f"Supabase detail unavailable: {exc}")
                        payload = None
                else:
                    try:
                        payload = procurement_detail(db, int(procurement_raw))
                    except ValueError:
                        self._json(400, {"error": "procurement id inválido"}); return
                self._json(404 if payload is None else 200, payload or {"error": "not found"}, cache="public, max-age=20")
            elif token and self.headers.get("Authorization") != f"Bearer {token}":
                self._json(401, {"error": "unauthorized"})
            elif parsed.path == "/api/admin/stats":
                self._json(200, db.table_counts())
            elif parsed.path == "/api/admin/sources":
                with db.connect() as conn:
                    rows = [dict(row) for row in conn.execute("SELECT * FROM sources ORDER BY nome")]
                self._json(200, rows)
            elif parsed.path == "/api/admin/runs":
                limit = min(int(parse_qs(parsed.query).get("limit", [50])[0]), 200)
                with db.connect() as conn:
                    rows = [dict(row) for row in conn.execute(
                        "SELECT r.*,s.nome AS source_name,s.slug AS source_slug FROM source_runs r "
                        "JOIN sources s ON s.id=r.source_id ORDER BY r.id DESC LIMIT ?", (limit,)
                    )]
                self._json(200, rows)
            elif parsed.path.startswith("/api/admin/runs/"):
                try:
                    run_id = int(parsed.path.rsplit("/", 1)[-1])
                except ValueError:
                    self._json(400, {"error": "run id inválido"}); return
                with db.connect() as conn:
                    run = conn.execute("SELECT * FROM source_runs WHERE id=?", (run_id,)).fetchone()
                    errors = [dict(row) for row in conn.execute("SELECT * FROM collection_errors WHERE source_run_id=? ORDER BY id", (run_id,))]
                self._json(404 if not run else 200, {"run": dict(run) if run else None, "errors": errors})
            else:
                self._json(404, {"error": "not found"})

        def log_message(self, fmt: str, *args: Any) -> None:
            return

        def _json(self, status: int, payload: Any, cache: str = "no-store") -> None:
            body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", cache)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer((host, port), Handler)
    print(f"Central de fontes: http://{host}:{port}/api/admin/sources")
    server.serve_forever()
