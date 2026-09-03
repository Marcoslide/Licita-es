from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from bolsa_licitacoes.db import Database


class DatabaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.db = Database(Path(self.temp.name) / "test.db")
        self.db.migrate()
        self.source_id = self.db.source_id("pncp")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_raw_record_is_idempotent_and_versions_changes(self) -> None:
        args = dict(
            source_id=self.source_id,
            endpoint="/example",
            request_url="https://example.test/example",
            request_params={"pagina": 1},
            http_status=200,
            external_id="A",
            entity_hint="test",
        )
        first_id, first_status = self.db.store_raw(payload={"value": 1}, **args)
        same_id, same_status = self.db.store_raw(payload={"value": 1}, **args)
        changed_id, changed_status = self.db.store_raw(payload={"value": 2}, **args)

        self.assertEqual("new", first_status)
        self.assertEqual((first_id, "unchanged"), (same_id, same_status))
        self.assertEqual("updated", changed_status)
        self.assertNotEqual(first_id, changed_id)
        with self.db.connect() as conn:
            rows = conn.execute("SELECT version,previous_version_id FROM source_raw_records ORDER BY version").fetchall()
        self.assertEqual([1, 2], [row["version"] for row in rows])
        self.assertEqual(first_id, rows[1]["previous_version_id"])

    def test_migration_creates_requested_tables(self) -> None:
        required = {
            "sources", "source_runs", "source_raw_records", "organizations", "purchasing_units",
            "states", "cities", "procurements", "procurement_items", "procurement_lots",
            "procurement_results", "suppliers", "price_records", "bids", "proposals",
            "price_registry_atas", "contracts", "contract_items", "contract_amendments",
            "commitments", "payments", "annual_procurement_plans", "documents",
            "document_versions", "source_links", "processing_jobs", "collection_errors",
        }
        with self.db.connect() as conn:
            found = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertTrue(required.issubset(found), required - found)

    def test_pca_external_key_is_deterministic(self) -> None:
        from bolsa_licitacoes.connectors.pncp import _external_id
        record = {"cnpj": "00394460000141", "sequencialPca": 1, "anoPca": 2022, "numeroItem": 3}
        self.assertEqual(
            "00394460000141-0-000001/2022:3",
            _external_id("annual_procurement_plan", record, 1),
        )


if __name__ == "__main__":
    unittest.main()
