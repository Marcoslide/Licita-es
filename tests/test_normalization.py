from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from bolsa_licitacoes.db import Database
from bolsa_licitacoes.normalizers import normalize_item, normalize_procurement, normalize_result


PNCP = {
    "numeroControlePNCP": "01010446000160-1-000022/2025",
    "anoCompra": 2025,
    "sequencialCompra": 22,
    "numeroCompra": "90003",
    "processo": "24.9.000014727-5",
    "objetoCompra": "Serviço editorial",
    "modalidadeId": 6,
    "modalidadeNome": "Pregão - Eletrônico",
    "orgaoEntidade": {"cnpj": "01010446000160", "razaoSocial": "CREMEGO", "esferaId": "F", "poderId": "E"},
    "unidadeOrgao": {"codigoUnidade": "926829", "nomeUnidade": "CREMEGO", "ufSigla": "GO", "ufNome": "Goiás", "codigoIbge": "5208707", "municipioNome": "Goiânia"},
}

COMPRAS = {
    "idCompra": "92682905900032025",
    "numeroControlePNCP": PNCP["numeroControlePNCP"],
    "anoCompraPncp": 2025,
    "sequencialCompraPncp": 22,
    "orgaoEntidadeCnpj": "01010446000160",
    "orgaoEntidadeRazaoSocial": "CREMEGO",
    "unidadeOrgaoCodigoUnidade": "926829",
    "unidadeOrgaoNomeUnidade": "CREMEGO",
    "unidadeOrgaoUfSigla": "GO",
    "unidadeOrgaoCodigoIbge": 5208707,
    "unidadeOrgaoMunicipioNome": "GOIÂNIA",
    "objetoCompra": "Serviço editorial consolidado",
    "modalidadeIdPncp": 6,
}


class NormalizationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.db = Database(Path(self.temp.name) / "test.db")
        self.db.migrate()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _raw(self, source_id, endpoint, external_id, payload):
        return self.db.store_raw(source_id=source_id, endpoint=endpoint, request_url="https://source.test",
            request_params={}, http_status=200, external_id=external_id, entity_hint="procurement", payload=payload)[0]

    def test_cross_source_procurement_is_consolidated_with_two_links(self) -> None:
        pncp_id = self.db.source_id("pncp")
        compras_id = self.db.source_id("compras-gov")
        raw1 = self._raw(pncp_id, "/pncp", PNCP["numeroControlePNCP"], PNCP)
        procurement1 = normalize_procurement(self.db, source_id=pncp_id, raw_id=raw1, payload=PNCP, source_url="https://pncp.test", flavor="pncp")
        raw2 = self._raw(compras_id, "/compras", COMPRAS["idCompra"], COMPRAS)
        procurement2 = normalize_procurement(self.db, source_id=compras_id, raw_id=raw2, payload=COMPRAS, source_url="https://compras.test", flavor="compras")
        self.assertEqual(procurement1, procurement2)
        with self.db.connect() as conn:
            self.assertEqual(1, conn.execute("SELECT COUNT(*) FROM procurements").fetchone()[0])
            self.assertEqual(2, conn.execute("SELECT COUNT(*) FROM source_links WHERE entity_type='procurement'").fetchone()[0])

    def test_item_result_supplier_relationship(self) -> None:
        source_id = self.db.source_id("pncp")
        raw = self._raw(source_id, "/pncp", PNCP["numeroControlePNCP"], PNCP)
        procurement_id = normalize_procurement(self.db, source_id=source_id, raw_id=raw, payload=PNCP, source_url="u", flavor="pncp")
        item = {"numeroItem": 1, "descricao": "Livro", "quantidade": 2500, "temResultado": True}
        item_raw = self._raw(source_id, "/itens", "item-1", item)
        item_id = normalize_item(self.db, source_id=source_id, raw_id=item_raw, procurement_id=procurement_id, payload=item, source_url="u")
        result = {"sequencialResultado": 1, "niFornecedor": "12345678000199", "nomeRazaoSocialFornecedor": "Fornecedor", "valorUnitarioHomologado": 10}
        result_raw = self._raw(source_id, "/resultados", "resultado-1", result)
        normalize_result(self.db, source_id=source_id, raw_id=result_raw, item_id=item_id, payload=result, source_url="u")
        with self.db.connect() as conn:
            joined = conn.execute("SELECT s.tax_id,r.unit_value FROM procurement_results r JOIN suppliers s ON s.id=r.supplier_id").fetchone()
        self.assertEqual("12345678000199", joined["tax_id"])
        self.assertEqual(10, joined["unit_value"])


if __name__ == "__main__":
    unittest.main()
