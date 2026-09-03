from __future__ import annotations

import json
import tempfile
import unittest
from datetime import date
from pathlib import Path

from bolsa_licitacoes.connectors.compras import ComprasGovConnector
from bolsa_licitacoes.connectors.pncp import PncpConnector
from bolsa_licitacoes.db import Database
from bolsa_licitacoes.http import HttpResponse
from bolsa_licitacoes.normalizers import normalize_procurement


def compras_record(control: str, sequence: int):
    return {
        "idCompra": f"id-{sequence}", "numeroControlePNCP": control,
        "anoCompraPncp": 2025, "sequencialCompraPncp": sequence,
        "orgaoEntidadeCnpj": "01010446000160", "orgaoEntidadeRazaoSocial": "Órgão",
        "unidadeOrgaoCodigoUnidade": "1", "objetoCompra": f"Objeto {sequence}",
    }


class PagingHttp:
    def __init__(self):
        self.calls = []

    def get(self, url, params=None, accept="application/json"):
        self.calls.append(dict(params or {}))
        page = params["pagina"]
        record = compras_record(f"01010446000160-1-{page:06d}/2025", page)
        body = json.dumps({"resultado": [record], "totalRegistros": 2, "totalPaginas": 2, "paginasRestantes": 2-page}).encode()
        return HttpResponse(url, 200, {}, body, 1)


class ConnectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = Database(Path(self.temp.name) / "test.db"); self.db.migrate()

    def tearDown(self):
        self.temp.cleanup()

    def test_compras_paginates_until_total_pages(self):
        http = PagingHttp()
        metrics = ComprasGovConnector(self.db, http).collect_procurements(
            date(2025, 1, 1), date(2025, 1, 2), modalities=(5,), max_pages=None, page_size=10
        )
        self.assertEqual([1, 2], [call["pagina"] for call in http.calls])
        self.assertEqual(2, metrics.pages)
        with self.db.connect() as conn:
            self.assertEqual(2, conn.execute("SELECT COUNT(*) FROM procurements").fetchone()[0])

    def test_ata_and_contract_link_to_procurement(self):
        source_id = self.db.source_id("pncp")
        procurement = {
            "numeroControlePNCP": "01010446000160-1-000022/2025", "anoCompra": 2025,
            "sequencialCompra": 22, "orgaoEntidade": {"cnpj": "01010446000160", "razaoSocial": "Órgão"},
            "unidadeOrgao": {"codigoUnidade": "1"},
        }
        raw_id = self.db.store_raw(source_id=source_id, endpoint="/p", request_url="u", request_params={},
            http_status=200, external_id=procurement["numeroControlePNCP"], entity_hint="procurement", payload=procurement)[0]
        procurement_id = normalize_procurement(self.db, source_id=source_id, raw_id=raw_id, payload=procurement, source_url="u", flavor="pncp")
        connector = PncpConnector(self.db, PagingHttp())
        ata = {"numeroControlePNCP": "01010446000160-1-000022/2025-000001", "numeroAtaRegistroPreco": "1"}
        ata_raw = self.db.store_raw(source_id=source_id, endpoint="/a", request_url="u", request_params={}, http_status=200,
            external_id=ata["numeroControlePNCP"], entity_hint="price_registry_ata", payload=ata)[0]
        connector._normalize_ata(ata_raw, ata, "u")
        contract = {"numeroControlePNCP": "01010446000160-2-000001/2025", "numeroControlePncpCompra": procurement["numeroControlePNCP"], "numeroContratoEmpenho": "C1"}
        contract_raw = self.db.store_raw(source_id=source_id, endpoint="/c", request_url="u", request_params={}, http_status=200,
            external_id=contract["numeroControlePNCP"], entity_hint="contract", payload=contract)[0]
        connector._normalize_contract(contract_raw, contract, "u")
        with self.db.connect() as conn:
            self.assertEqual(procurement_id, conn.execute("SELECT procurement_id FROM price_registry_atas").fetchone()[0])
            self.assertEqual(procurement_id, conn.execute("SELECT procurement_id FROM contracts").fetchone()[0])


if __name__ == "__main__":
    unittest.main()
