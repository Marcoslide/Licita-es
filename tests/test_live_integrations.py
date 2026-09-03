from __future__ import annotations

import os
import unittest

from bolsa_licitacoes.http import PublicHttpClient


@unittest.skipUnless(os.getenv("RUN_LIVE_API_TESTS") == "1", "integração pública opt-in")
class LivePublicIntegrationTests(unittest.TestCase):
    def test_compras_gov_returns_real_procurement_shape(self) -> None:
        response = PublicHttpClient(timeout=20, retries=0).get(
            "https://dadosabertos.compras.gov.br/modulo-contratacoes/1_consultarContratacoes_PNCP_14133",
            params={
                "pagina": 1,
                "tamanhoPagina": 10,
                "dataPublicacaoPncpInicial": "2025-02-01",
                "dataPublicacaoPncpFinal": "2025-02-28",
                "codigoModalidade": 5,
            },
        )
        payload = response.json()
        self.assertEqual(200, response.status)
        self.assertGreater(payload["totalRegistros"], 0)
        self.assertTrue(payload["resultado"])
        sample = payload["resultado"][0]
        self.assertRegex(sample["numeroControlePNCP"], r"^\d{14}-1-\d{6}/\d{4}$")
        self.assertIn("objetoCompra", sample)


if __name__ == "__main__":
    unittest.main()
