from __future__ import annotations

import hashlib
import io
import mimetypes
import re
import zipfile
from pathlib import Path
from typing import Any, Mapping, Optional, Union

from .db import Database, utcnow
from .http import PublicHttpClient


class DocumentService:
    def __init__(self, db: Database, http: PublicHttpClient, storage_root: Union[Path, str]) -> None:
        self.db = db
        self.http = http
        self.storage_root = Path(storage_root)
        self.storage_root.mkdir(parents=True, exist_ok=True)

    def register_pncp_document(
        self,
        *,
        source_id: int,
        raw_id: int,
        procurement_id: int,
        payload: Mapping[str, Any],
        download: bool,
    ) -> tuple[int, bool]:
        external_id = f"{payload.get('cnpj')}:{payload.get('anoCompra')}:{payload.get('sequencialCompra')}:{payload.get('sequencialDocumento')}"
        url = str(payload.get("url") or payload.get("uri"))
        with self.db.connect() as conn:
            conn.execute(
                "INSERT INTO documents(procurement_id,original_name,document_type,source_download_url,published_at,"
                "source_id,source_external_id,source_url,raw_record_id,source_created_at,collected_at) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(source_id,source_external_id) DO UPDATE SET "
                "original_name=excluded.original_name,document_type=excluded.document_type,source_download_url=excluded.source_download_url,"
                "published_at=excluded.published_at,raw_record_id=excluded.raw_record_id,collected_at=excluded.collected_at",
                (procurement_id, payload.get("titulo"), payload.get("tipoDocumentoNome"), url,
                 payload.get("dataPublicacaoPncp"), source_id, external_id, url, raw_id,
                 payload.get("dataPublicacaoPncp"), utcnow()),
            )
            doc_id = int(conn.execute("SELECT id FROM documents WHERE source_id=? AND source_external_id=?", (source_id, external_id)).fetchone()[0])
        if not download:
            return doc_id, False
        return doc_id, self.download(doc_id, url, payload.get("titulo"))

    def download(self, document_id: int, url: str, title: Optional[str] = None) -> bool:
        response = self.http.get(url, accept="*/*")
        digest = hashlib.sha256(response.body).hexdigest()
        reported_mime = response.headers.get("content-type", "application/octet-stream").split(";", 1)[0]
        mime = _detect_mime(response.body, reported_mime)
        suffix = mimetypes.guess_extension(mime) or _suffix_from_title(title) or ".bin"
        storage_key = f"{digest[:2]}/{digest}{suffix}"
        target = self.storage_root / storage_key
        with self.db.connect() as conn:
            existing = conn.execute(
                "SELECT id FROM document_versions WHERE document_id=? AND sha256=?", (document_id, digest)
            ).fetchone()
            if existing:
                conn.execute("UPDATE documents SET download_status='DOWNLOADED' WHERE id=?", (document_id,))
                return False
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(response.body)
            version = int(conn.execute(
                "SELECT COALESCE(MAX(version),0)+1 FROM document_versions WHERE document_id=?", (document_id,)
            ).fetchone()[0])
            conn.execute(
                "INSERT INTO document_versions(document_id,version,storage_key,mime_type,size_bytes,sha256) VALUES (?,?,?,?,?,?)",
                (document_id, version, storage_key, mime, len(response.body), digest),
            )
            conn.execute(
                "UPDATE documents SET current_version=?,download_status='DOWNLOADED' WHERE id=?",
                (version, document_id),
            )
        return True


def _suffix_from_title(title: Optional[str]) -> str:
    if not title:
        return ""
    match = re.search(r"(\.[A-Za-z0-9]{1,8})$", title)
    return match.group(1).lower() if match else ""


def _detect_mime(body: bytes, reported: str) -> str:
    """Corrige o MIME genérico frequentemente devolvido pelo endpoint do PNCP."""
    if reported and reported != "application/octet-stream":
        return reported
    if body.startswith(b"%PDF-"):
        return "application/pdf"
    if body.startswith(b"PK\x03\x04"):
        try:
            with zipfile.ZipFile(io.BytesIO(body)) as archive:
                names = set(archive.namelist())
            if "word/document.xml" in names:
                return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            if "xl/workbook.xml" in names:
                return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            if "ppt/presentation.xml" in names:
                return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        except zipfile.BadZipFile:
            pass
        return "application/zip"
    return reported or "application/octet-stream"
