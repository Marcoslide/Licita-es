from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from bolsa_licitacoes.db import Database
from bolsa_licitacoes.normalizers import normalize_item, normalize_procurement
from bolsa_licitacoes.public_api import list_procurements, market_summary, procurement_detail, state_summary


class PublicApiQueryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.db = Database(Path(self.temp.name) / "test.db")
        self.db.migrate()
        source_id = self.db.source_id("pncp")
        self.payload = {
            "numeroControlePNCP": "01010446000160-1-000022/2026",
            "anoCompra": 2026,
            "sequencialCompra": 22,
            "numeroCompra": "90003",
            "processo": "24.9.000014727-5",
            "objetoCompra": "Aquisição de livros e material editorial",
            "modalidadeId": 6,
            "modalidadeNome": "Pregão - Eletrônico",
            "situacaoCompraNome": "Divulgada no PNCP",
            "dataAberturaProposta": "2026-09-03T08:00:00",
            "dataEncerramentoProposta": "2026-09-17T09:00:00",
            "valorTotalEstimado": 125000.50,
            "orgaoEntidade": {"cnpj": "01010446000160", "razaoSocial": "CONSELHO EDITORIAL"},
            "unidadeOrgao": {
                "codigoUnidade": "926829", "nomeUnidade": "UNIDADE CENTRAL", "ufSigla": "GO",
                "ufNome": "Goiás", "codigoIbge": "5208707", "municipioNome": "Goiânia",
            },
        }
        raw_id = self.db.store_raw(
            source_id=source_id, endpoint="/contratacoes", request_url="https://pncp.test/consulta",
            request_params={}, http_status=200, external_id=self.payload["numeroControlePNCP"],
            entity_hint="procurement", payload=self.payload,
        )[0]
        self.procurement_id = normalize_procurement(
            self.db, source_id=source_id, raw_id=raw_id, payload=self.payload,
            source_url="https://pncp.test/processo", flavor="pncp",
        )
        item = {"numeroItem": 1, "descricao": "Livro técnico", "quantidade": 20, "unidadeMedida": "UN"}
        item_raw = self.db.store_raw(
            source_id=source_id, endpoint="/itens", request_url="https://pncp.test/itens",
            request_params={}, http_status=200, external_id="item-1", entity_hint="procurement_item", payload=item,
        )[0]
        normalize_item(
            self.db, source_id=source_id, raw_id=item_raw, procurement_id=self.procurement_id,
            payload=item, source_url="https://pncp.test/itens",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_summary_and_state_aggregates_are_real(self) -> None:
        summary = market_summary(self.db)
        self.assertEqual(1, summary["procurements"])
        self.assertEqual(125000.50, summary["estimated_value"])
        self.assertEqual(1, summary["items"])
        states = state_summary(self.db)
        self.assertEqual("GO", states[0]["code"])
        self.assertEqual(1, states[0]["procurements"])
        self.assertEqual("CONSELHO EDITORIAL", states[0]["top_organizations"][0]["legal_name"])

    def test_procurement_search_filters_and_detail(self) -> None:
        result = list_procurements(self.db, {"uf": ["go"], "q": ["livros"], "limit": ["10"]})
        self.assertEqual(1, result["total"])
        self.assertEqual(self.procurement_id, result["items"][0]["id"])
        self.assertEqual("Goiânia", result["items"][0]["city_name"])
        self.assertEqual(1, result["items"][0]["items_count"])
        self.assertEqual(0, list_procurements(self.db, {"uf": ["MG"]})["total"])
        self.assertEqual(1, list_procurements(self.db, {"status": ["open"], "period": ["365"]})["total"])
        self.assertEqual(0, list_procurements(self.db, {"status": ["results"]})["total"])

        detail = procurement_detail(self.db, self.procurement_id)
        self.assertIsNotNone(detail)
        self.assertEqual("CONSELHO EDITORIAL", detail["procurement"]["organization_name"])
        self.assertEqual("Livro técnico", detail["items"][0]["description"])
        self.assertEqual("pncp", detail["sources"][0]["slug"])

    def test_public_indexes_cover_dashboard_filters(self) -> None:
        with self.db.connect() as conn:
            names = {row[0] for row in conn.execute("SELECT name FROM sqlite_schema WHERE type='index'")}
            self.assertIn("idx_purchasing_units_state_id", names)
            plan = " ".join(str(row[3]) for row in conn.execute(
                "EXPLAIN QUERY PLAN SELECT id FROM purchasing_units WHERE state_id=?", (1,)
            ).fetchall())
        self.assertIn("idx_purchasing_units_state_id", plan)


if __name__ == "__main__":
    unittest.main()
