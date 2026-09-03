from __future__ import annotations

import hashlib
import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Mapping, Optional, Union


SOURCE_SEEDS = (
    {
        "nome": "Portal Nacional de Contratações Públicas",
        "slug": "pncp",
        "categoria": "CONTRATACOES_PUBLICAS",
        "url_site": "https://pncp.gov.br/",
        "url_documentacao": "https://pncp.gov.br/api/consulta/swagger-ui/index.html",
        "url_base_api": "https://pncp.gov.br/api/consulta",
        "tipo_acesso": "API_OFICIAL_PUBLICA",
        "tipo_autenticacao": "NENHUMA",
        "credencial_necessaria": 0,
        "frequencia_coleta": "PT10M",
        "limite_requisicoes": "Não publicado; concorrência inicial 1 e paginação controlada",
        "status": "ATIVA",
        "versao_api": "consulta-1.0 / integracao-2.6",
    },
    {
        "nome": "Compras.gov.br — Dados Abertos",
        "slug": "compras-gov",
        "categoria": "CONTRATACOES_PUBLICAS",
        "url_site": "https://dadosabertos.compras.gov.br/",
        "url_documentacao": "https://dadosabertos.compras.gov.br/swagger-ui/index.html",
        "url_base_api": "https://dadosabertos.compras.gov.br",
        "tipo_acesso": "API_OFICIAL_PUBLICA",
        "tipo_autenticacao": "NENHUMA_PARA_MODULOS_PUBLICOS",
        "credencial_necessaria": 0,
        "frequencia_coleta": "PT15M",
        "limite_requisicoes": "Máximo documentado de 500 registros/página",
        "status": "ATIVA",
        "versao_api": "2.0 / OpenAPI 1.0.0",
    },
    {
        "nome": "Portal da Transparência",
        "slug": "portal-transparencia",
        "categoria": "TRANSPARENCIA_E_SANCOES",
        "url_site": "https://portaldatransparencia.gov.br/",
        "url_documentacao": "https://api.portaldatransparencia.gov.br/",
        "url_base_api": "https://api.portaldatransparencia.gov.br/api-de-dados",
        "tipo_acesso": "API_OFICIAL_COM_CHAVE",
        "tipo_autenticacao": "CHAVE_API",
        "credencial_necessaria": 1,
        "frequencia_coleta": "P1D",
        "status": "CREDENCIAL_PENDENTE",
        "versao_api": "v2",
        "observacoes": "Aguardando PORTAL_TRANSPARENCIA_API_TOKEN; nenhum acesso autenticado executado.",
    },
    {
        "nome": "Banco de Preços em Saúde",
        "slug": "bps",
        "categoria": "PRECOS_SAUDE",
        "url_site": "https://www.gov.br/saude/pt-br/acesso-a-informacao/banco-de-precos/banco-de-precos",
        "url_documentacao": None,
        "url_base_api": None,
        "tipo_acesso": "ARQUIVO_OFICIAL_A_MAPEAR",
        "tipo_autenticacao": "NENHUMA",
        "credencial_necessaria": 0,
        "frequencia_coleta": "P1D",
        "status": "MAPEANDO",
        "versao_api": None,
    },
)


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


class Database:
    def __init__(self, path: Union[Path, str]) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        conn = sqlite3.connect(str(self.path), timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA journal_mode=WAL")
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def migrate(self, migration_path: Union[Path, str] = "migrations") -> None:
        migration_root = Path(migration_path)
        paths = sorted(migration_root.glob("*.sql")) if migration_root.is_dir() else [migration_root]
        with self.connect() as conn:
            # A migration inicial cria a própria tabela de controle.
            for index, path in enumerate(paths):
                version = path.stem
                if index and conn.execute("SELECT 1 FROM schema_migrations WHERE version=?", (version,)).fetchone():
                    continue
                conn.executescript(path.read_text(encoding="utf-8"))
                conn.execute("INSERT OR IGNORE INTO schema_migrations(version) VALUES (?)", (version,))
            for source in SOURCE_SEEDS:
                columns = ",".join(source)
                placeholders = ",".join("?" for _ in source)
                # Estado operacional e contadores pertencem à execução; não devem regredir a cada boot.
                updates = ",".join(f"{key}=excluded.{key}" for key in source if key not in {"slug", "status"})
                conn.execute(
                    f"INSERT INTO sources({columns}) VALUES ({placeholders}) "
                    f"ON CONFLICT(slug) DO UPDATE SET {updates}, updated_at=CURRENT_TIMESTAMP",
                    tuple(source.values()),
                )

    def source_id(self, slug: str) -> int:
        with self.connect() as conn:
            row = conn.execute("SELECT id FROM sources WHERE slug=?", (slug,)).fetchone()
        if not row:
            raise KeyError(f"Fonte não cadastrada: {slug}")
        return int(row["id"])

    def start_run(
        self, source_id: int, run_type: str, endpoint: str, start: str = "", end: str = ""
    ) -> int:
        with self.connect() as conn:
            cur = conn.execute(
                "INSERT INTO source_runs(source_id,run_type,endpoint,period_start,period_end) VALUES (?,?,?,?,?)",
                (source_id, run_type, endpoint, start or None, end or None),
            )
            conn.execute("UPDATE sources SET ultima_tentativa=? WHERE id=?", (utcnow(), source_id))
            return int(cur.lastrowid)

    def finish_run(self, run_id: int, *, status: str = "SUCCESS", error: str = "", **metrics: int) -> None:
        allowed = {
            "pages", "records_seen", "records_new", "records_updated", "records_unchanged",
            "records_discarded", "documents_found", "documents_downloaded", "errors", "latency_ms",
        }
        assignments = ["status=?", "finished_at=?", "error_message=?"]
        values: list[Any] = [status, utcnow(), error or None]
        for key, value in metrics.items():
            if key in allowed:
                assignments.append(f"{key}=?")
                values.append(int(value))
        values.append(run_id)
        with self.connect() as conn:
            conn.execute(f"UPDATE source_runs SET {','.join(assignments)} WHERE id=?", values)
            source = conn.execute("SELECT source_id FROM source_runs WHERE id=?", (run_id,)).fetchone()
            if source:
                if status == "SUCCESS":
                    conn.execute(
                        "UPDATE sources SET status='OPERANDO', ultima_coleta_sucesso=?, "
                        "quantidade_registros=quantidade_registros+? WHERE id=?",
                        (utcnow(), int(metrics.get("records_new", 0)), source["source_id"]),
                    )
                else:
                    conn.execute(
                        "UPDATE sources SET status='ATENCAO', quantidade_erros=quantidade_erros+1 WHERE id=?",
                        (source["source_id"],),
                    )

    def record_error(
        self,
        *,
        source_id: int,
        run_id: int,
        endpoint: str,
        request_url: str,
        request_params: Mapping[str, Any],
        message: str,
        http_status: Optional[int] = None,
        retryable: bool = False,
    ) -> None:
        with self.connect() as conn:
            conn.execute(
                "INSERT INTO collection_errors(source_id,source_run_id,endpoint,request_url,request_params,"
                "http_status,error_type,message,retryable) VALUES (?,?,?,?,?,?,?,?,?)",
                (source_id, run_id, endpoint, request_url, canonical_json(request_params), http_status,
                 "HTTP" if http_status else "RUNTIME", message, int(retryable)),
            )

    def store_raw(
        self,
        *,
        source_id: int,
        endpoint: str,
        request_url: str,
        request_params: Mapping[str, Any],
        http_status: int,
        external_id: str,
        entity_hint: str,
        payload: Any,
        source_created_at: Optional[str] = None,
        source_updated_at: Optional[str] = None,
    ) -> tuple[int, str]:
        serialized = canonical_json(payload)
        digest = hashlib.sha256(serialized.encode("utf-8")).hexdigest()
        with self.connect() as conn:
            previous = conn.execute(
                "SELECT id,payload_hash,version FROM source_raw_records "
                "WHERE source_id=? AND endpoint=? AND external_id=? ORDER BY version DESC LIMIT 1",
                (source_id, endpoint, external_id),
            ).fetchone()
            if previous and previous["payload_hash"] == digest:
                return int(previous["id"]), "unchanged"
            version = int(previous["version"]) + 1 if previous else 1
            cur = conn.execute(
                "INSERT INTO source_raw_records(source_id,endpoint,request_url,request_params,http_status,"
                "external_id,entity_hint,payload_original,payload_hash,source_created_at,source_updated_at,"
                "collected_at,version,previous_version_id) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (source_id, endpoint, request_url, canonical_json(request_params), http_status, external_id,
                 entity_hint, serialized, digest, source_created_at, source_updated_at, utcnow(), version,
                 int(previous["id"]) if previous else None),
            )
            return int(cur.lastrowid), "updated" if previous else "new"

    def mark_processed(self, raw_id: int, error: str = "") -> None:
        with self.connect() as conn:
            conn.execute(
                "UPDATE source_raw_records SET processing_status=?,processing_error=? WHERE id=?",
                ("ERROR" if error else "PROCESSED", error or None, raw_id),
            )

    def table_counts(self) -> dict[str, int]:
        tables = (
            "sources", "source_runs", "source_raw_records", "organizations", "purchasing_units",
            "procurements", "procurement_items", "procurement_results", "suppliers",
            "price_registry_atas", "contracts", "annual_procurement_plans", "documents",
            "document_versions", "source_links", "collection_errors",
        )
        with self.connect() as conn:
            return {table: int(conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]) for table in tables}


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), default=str)
