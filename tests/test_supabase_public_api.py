from __future__ import annotations

import unittest

from bolsa_licitacoes.supabase_public_api import SupabasePublicApi, expand_search_terms


class FakeClient:
    def __init__(self) -> None:
        self.calls = []

    def get(self, resource, params, *, profile="public", count=False):
        self.calls.append((resource, params, profile, count))
        values = dict(params)
        if int(values.get("offset", "0")) > 0:
            return ([], 0 if count else None)
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
                "valor_total_homologado": 90000,
                "modo_disputa": "Aberto", "srp": True,
                "uf": "MG", "municipio_nome": "Belo Horizonte",
                "data_publicacao_pncp": "2026-08-15T12:00:00Z",
                "data_encerramento_proposta": "2026-09-10T12:00:00Z",
            }], 1)
        if resource == "orgaos":
            return ([{"cnpj": "07615750000117", "razao_social": "SECRETARIA DE SAÚDE"}], None)
        if resource == "itens":
            return ([{
                "numero_controle_pncp": "07615750000117-1-000063/2026",
                "descricao": "Material hospitalar descartável", "quantidade": 100,
                "unidade": "UN", "valor_unitario_estimado": 12.5,
                "valor_total_estimado": 1250, "catalogo_codigo": "12345",
                "material_ou_servico": "MATERIAL",
                "criterio_julgamento": "Menor preço", "orcamento_sigiloso": False,
            }], None)
        if resource == "resultados_itens":
            return ([{
                "numero_controle_pncp": "07615750000117-1-000063/2026",
                "fornecedor_ni": "12345678000100", "fornecedor_nome": "FORNECEDOR TESTE",
                "valor_total_homologado": 1000, "valor_unitario_homologado": 10,
                "quantidade_homologada": 100, "percentual_desconto": 20,
                "data_resultado": "2026-08-28T12:00:00Z",
            }], None)
        if resource == "contratos":
            return ([], None)
        if resource == "contratos_gov":
            return ([], None)
        if resource == "atas":
            return ([], None)
        if resource == "pca_itens":
            return ([{
                "id": 1, "orgao_cnpj": "07615750000117", "ano_pca": 2027,
                "descricao": "Material hospitalar descartável", "categoria_nome": "Saúde",
                "quantidade": 500, "valor_total": 5000, "data_desejada": "2027-03-01",
                "catalogo_codigo": "12345",
            }], None)
        if resource == "documentos":
            return ([], None)
        if resource == "fontes":
            return ([{"id": "pncp", "nome": "PNCP", "status": "ATIVA", "ultimo_sucesso_em": "2026-09-03T12:00:00Z", "capabilities": {}}], None)
        if resource == "coleta_log":
            return ([{"fonte_id": "pncp", "job": "incremental", "finalizado_em": "2026-09-03T12:00:00Z", "registros": 1, "inseridos": 1, "atualizados": 0, "erros": 0}], None)
        raise AssertionError(f"Recurso inesperado: {resource}")


class SupplierHistoryFakeClient(FakeClient):
    def get(self, resource, params, *, profile="public", count=False):
        values = dict(params)
        if resource not in {"licitacoes", "resultados_itens"}:
            return super().get(resource, params, profile=profile, count=count)
        self.calls.append((resource, params, profile, count))
        if int(values.get("offset", "0")) > 0:
            return ([], 0 if count else None)
        if resource == "licitacoes":
            rows = [{
                "numero_controle_pncp": f"00000000000000-1-00000{index}/2026",
                "orgao_cnpj": "07615750000117", "processo": f"{index}/2026",
                "objeto": "Aquisição de materiais hospitalares", "modalidade_nome": "Pregão",
                "situacao_nome": "Homologada", "valor_total_estimado": 1000,
                "valor_total_homologado": 500,
                "uf": "MG", "municipio_nome": "Belo Horizonte",
                "data_publicacao_pncp": f"2026-0{8 if index < 3 else 9}-15T12:00:00Z",
                "data_encerramento_proposta": "2026-09-10T12:00:00Z",
            } for index in range(1, 4)]
            return (rows, len(rows) if count else None)
        return ([
            {"numero_controle_pncp": "00000000000000-1-000001/2026", "numero_item": 1,
             "fornecedor_ni": "12.345.678/0001-00", "fornecedor_nome": "EMPRESA HISTÓRICA LTDA",
             "valor_total_homologado": 100, "valor_unitario_homologado": 10,
             "quantidade_homologada": 10, "percentual_desconto": 10, "data_resultado": "2026-08-20"},
            {"numero_controle_pncp": "00000000000000-1-000001/2026", "numero_item": 2,
             "fornecedor_ni": "12345678000100", "fornecedor_nome": "Empresa Histórica Ltda",
             "valor_total_homologado": 200, "valor_unitario_homologado": 20,
             "quantidade_homologada": 10, "percentual_desconto": 8, "data_resultado": "2026-08-20"},
            {"numero_controle_pncp": "00000000000000-1-000003/2026", "numero_item": 1,
             "fornecedor_ni": "12345678000100", "fornecedor_nome": "EMPRESA HISTÓRICA LTDA",
             "valor_total_homologado": 400, "valor_unitario_homologado": 40,
             "quantidade_homologada": 10, "percentual_desconto": 5, "data_resultado": "2026-09-02"},
            {"numero_controle_pncp": "00000000000000-1-000002/2026", "numero_item": 1,
             "fornecedor_ni": "99999999000199", "fornecedor_nome": "OUTRO FORNECEDOR",
             "valor_total_homologado": 50, "valor_unitario_homologado": 5,
             "quantidade_homologada": 10, "percentual_desconto": 2, "data_resultado": "2026-08-21"},
        ], None)


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

    def test_combined_scope_filters_are_sent_to_the_same_query(self) -> None:
        client = FakeClient()
        result = SupabasePublicApi(client).list_procurements({
            "q": ["material hospitalar"], "mode": ["exact"], "uf": ["MG"],
            "city": ["Belo Horizonte"], "modality": ["Pregão"],
            "min_value": ["500000"], "max_value": ["2000000"], "period": ["180"],
        })
        procurement_call = next(call for call in client.calls if call[0] == "licitacoes")
        params = procurement_call[1]
        self.assertIn(("uf", "eq.MG"), params)
        self.assertIn(("municipio_nome", "ilike.*Belo Horizonte*"), params)
        self.assertIn(("modalidade_nome", "ilike.*Pregão*"), params)
        self.assertIn(("valor_total_estimado", "gte.500000.0"), params)
        self.assertIn(("valor_total_estimado", "lte.2000000.0"), params)
        self.assertEqual("exact", result["search"]["mode"])
        self.assertEqual(["material hospitalar"], result["search"]["terms"])

    def test_contextual_analytics_never_fall_back_to_global_values(self) -> None:
        result = SupabasePublicApi(FakeClient()).list_procurements({
            "q": ["material hospitalar"], "uf": ["MG"], "facets": ["1"], "limit": ["10"],
        })
        facets = result["facets"]
        self.assertEqual(1, result["total"])
        self.assertEqual(120000, facets["estimated_value"])
        self.assertEqual("MG", facets["states"][0]["code"])
        self.assertEqual("SECRETARIA DE SAÚDE", facets["top_organizations"][0]["name"])
        self.assertEqual("FORNECEDOR TESTE", facets["top_suppliers"][0]["name"])
        self.assertEqual(1, facets["pca"]["count"])
        self.assertFalse(facets["prices"]["available"], "uma amostra isolada não pode virar média")

    def test_detail_intelligence_labels_observed_results_without_claiming_revenue(self) -> None:
        detail = {
            "items": [{"description": "Material hospitalar descartável", "catalog_item_code": "12345"}],
            "procurement": {"id": "07615750000117-1-000063/2026"},
        }
        result = SupabasePublicApi(FakeClient()).procurement_intelligence(detail)
        self.assertTrue(result["available"])
        self.assertEqual("FORNECEDOR TESTE", result["competitors"][0]["name"])
        self.assertEqual(1, result["competitors"][0]["wins"])
        self.assertIn("não representam faturamento contábil", result["method_note"])

    def test_detail_exposes_structured_dispute_and_item_conditions(self) -> None:
        detail = SupabasePublicApi(FakeClient()).procurement_detail("07615750000117-1-000063/2026")
        self.assertEqual("Aberto", detail["procurement"]["dispute_mode"])
        self.assertTrue(detail["procurement"]["is_price_registry"])
        self.assertEqual("Menor preço", detail["items"][0]["judgment_criterion"])
        self.assertFalse(detail["items"][0]["confidential_budget"])

    def test_market_research_uses_one_scope_and_separates_financial_stages(self) -> None:
        result = SupabasePublicApi(FakeClient()).market_research({
            "q": ["material hospitalar"], "uf": ["MG"], "period": ["365"],
        })
        self.assertEqual("material hospitalar", result["scope"]["q"])
        self.assertEqual("MG", result["scope"]["uf"])
        self.assertEqual(120000, result["overview"]["financials"]["estimated"])
        self.assertEqual(90000, result["overview"]["financials"]["homologated"])
        self.assertIsNone(result["overview"]["financials"]["paid"])
        self.assertEqual("valor homologado observado", result["suppliers"][0]["share_basis"])
        self.assertEqual(1, result["report_summary"]["observed_months"])
        self.assertEqual(1, result["report_summary"]["procurements_per_month"])
        self.assertEqual(1, result["report_summary"]["awarded_procurements_per_month"])
        self.assertEqual(1, result["report_summary"]["suppliers"])
        self.assertEqual(120000, result["buyers"][0]["estimated_per_month"])
        self.assertEqual(1000, result["suppliers"][0]["homologated_per_month"])
        self.assertFalse(result["availability"]["company_profile"]["available"])
        self.assertIn("mesmo resultado filtrado", result["methodology"]["scope_rule"])

    def test_supplier_history_groups_cnpj_and_exposes_latest_month(self) -> None:
        result = SupabasePublicApi(SupplierHistoryFakeClient()).market_research({})
        supplier = next(row for row in result["suppliers"] if row["id"] == "12345678000100")
        self.assertEqual(2, supplier["wins"], "dois itens do mesmo processo contam como uma vitória")
        self.assertEqual(3, supplier["homologated_items"])
        self.assertEqual(700, supplier["homologated_value"])
        self.assertEqual("2026-09", supplier["latest_month"])
        self.assertEqual(1, supplier["latest_month_wins"])
        self.assertEqual(400, supplier["latest_month_homologated_value"])
        self.assertEqual(350, supplier["average_homologated_ticket"])
        self.assertEqual("2026-09", result["supplier_metrics"]["latest_result_month"])


if __name__ == "__main__":
    unittest.main()
