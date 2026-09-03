from __future__ import annotations

import unittest

from bolsa_licitacoes.supabase_public_api import SupabasePublicApi, expand_search_terms


class FakeClient:
    def __init__(self) -> None:
        self.calls = []

    def get(self, resource, params, *, profile="public", count=False):
        self.calls.append((resource, params, profile, count))
        if resource == "bolsa_vw_resumo":
            return ([{
                "licitacoes": 596, "valor_estimado_total": 2423540684.07, "orgaos": 485,
                "itens": 1568, "resultados": 32, "contratos": 250, "contratos_gov": 94,
                "fornecedores": 283, "documentos": 251, "atas": 150, "pca_itens": 100,
                "empenhos": 26, "valor_empenhado_total": 1000, "valor_pago_total": 500,
                "fontes_ativas": 2, "fontes_total": 4, "recebendo_propostas": 288,
                "ultima_coleta_em": "2026-09-03T02:48:00Z",
            }], None)
        if resource == "bolsa_vw_por_uf":
            return ([{"uf": "MG"}, {"uf": "SP"}], None)
        if resource == "licitacoes":
            return ([{
                "numero_controle_pncp": "07615750000117-1-000063/2026",
                "orgao_cnpj": "07615750000117", "processo": "63/2026",
                "objeto": "Aquisição de materiais hospitalares", "modalidade_nome": "Pregão",
                "situacao_nome": "Divulgada", "valor_total_estimado": 120000,
                "uf": "MG", "municipio_nome": "Belo Horizonte",
            }], 1)
        if resource == "orgaos":
            return ([{"cnpj": "07615750000117", "razao_social": "SECRETARIA DE SAÚDE"}], None)
        if resource in {"itens", "documentos"}:
            return ([], None)
        raise AssertionError(f"Recurso inesperado: {resource}")


class SupabasePublicApiTests(unittest.TestCase):
    def test_semantic_expansion_exposes_related_terms(self) -> None:
        terms, intent = expand_search_terms("molduras")
        self.assertEqual("molduras", intent)
        self.assertIn("emolduramento", terms)
        self.assertIn("quadro", terms)

    def test_live_summary_maps_multi_source_totals(self) -> None:
        summary = SupabasePublicApi(FakeClient()).market_summary()
        self.assertEqual(596, summary["procurements"])
        self.assertEqual(344, summary["contracts"])
        self.assertEqual("supabase-live", summary["data_source"])

    def test_list_accepts_multiple_regions_and_string_ids(self) -> None:
        client = FakeClient()
        result = SupabasePublicApi(client).list_procurements({"uf": ["mg,sp"], "limit": ["10"]})
        self.assertEqual("07615750000117-1-000063/2026", result["items"][0]["id"])
        procurement_call = next(call for call in client.calls if call[0] == "licitacoes")
        self.assertIn(("uf", "in.(MG,SP)"), procurement_call[1])


if __name__ == "__main__":
    unittest.main()
