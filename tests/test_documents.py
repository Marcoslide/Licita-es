from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path

from bolsa_licitacoes.db import Database
from bolsa_licitacoes.documents import DocumentService, _detect_mime
from bolsa_licitacoes.http import HttpResponse


class FakeHttp:
    def get(self, url, accept="*/*"):
        return HttpResponse(url, 200, {"content-type": "application/pdf"}, b"%PDF-test", 1)


class DocumentTests(unittest.TestCase):
    def test_octet_stream_is_sniffed_from_content(self) -> None:
        self.assertEqual("application/pdf", _detect_mime(b"%PDF-1.7\n", "application/octet-stream"))

    def test_identical_file_is_not_downloaded_twice(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Database(Path(tmp) / "test.db"); db.migrate()
            service = DocumentService(db, FakeHttp(), Path(tmp) / "objects")
            source_id = db.source_id("pncp")
            with db.connect() as conn:
                conn.execute("INSERT INTO documents(source_download_url,source_id,source_external_id) VALUES (?,?,?)", ("https://x/doc", source_id, "doc"))
                doc_id = conn.execute("SELECT id FROM documents").fetchone()[0]
            self.assertTrue(service.download(doc_id, "https://x/doc", "edital.pdf"))
            self.assertFalse(service.download(doc_id, "https://x/doc", "edital.pdf"))
            digest = hashlib.sha256(b"%PDF-test").hexdigest()
            self.assertTrue((Path(tmp) / "objects" / digest[:2] / f"{digest}.pdf").exists())
            with db.connect() as conn:
                self.assertEqual(1, conn.execute("SELECT COUNT(*) FROM document_versions").fetchone()[0])


if __name__ == "__main__":
    unittest.main()
