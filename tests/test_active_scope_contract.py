from __future__ import annotations

import unittest
from pathlib import Path


class ActiveScopeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.html = (Path(__file__).parents[1] / "index.html").read_text()

    def test_dashboard_has_one_explicit_market_scope(self) -> None:
        self.assertEqual(1, self.html.count("let activeMarketScope="))
        self.assertIn("function scopeParams(scope=activeMarketScope", self.html)
        self.assertIn("function applyMarketScope(next", self.html)

    def test_visible_analytics_share_the_same_response_facets(self) -> None:
        render_flow = (
            "renderContextKpis(root);renderContextBrief(root);"
            "applyRealStates(facets.states||[],scopeEntries().length>0);"
            "applyRealLists(data.recent.items||[],data.value.items||[],data.deadline.items||[]);"
            "renderScopeAnalytics(facets,root.total)"
        )
        self.assertIn(render_flow, self.html)

    def test_simulated_secondary_panels_cannot_reappear_in_real_mode(self) -> None:
        self.assertIn('body[data-data-mode="real"] .depth-secondary{display:none!important}', self.html)

    def test_market_search_controls_expose_one_shared_hybrid_scope(self) -> None:
        for mode in ("precise", "balanced", "broad", "exact"):
            self.assertIn(f'data-search-mode="{mode}"', self.html)
        for field in ("includeTerms", "shouldTerms", "excludeTerms", "exactPhrase", "includeDocuments"):
            self.assertIn(field, self.html)
        self.assertIn("/api/public/search/suggest", self.html)
        self.assertIn("match_score", self.html)

    def test_market_research_center_reuses_the_active_scope(self) -> None:
        self.assertIn("/api/public/market/research?", self.html)
        self.assertIn("function refreshMarketResearch()", self.html)
        self.assertIn("CENTRAL DE PESQUISA DE MERCADO", self.html)
        self.assertIn("todos os blocos abaixo usam exatamente este contexto", self.html)

    def test_home_exposes_a_real_market_preview_and_file_mode_api(self) -> None:
        self.assertIn('id="marketPreview"', self.html)
        self.assertIn("function renderMarketPreview(f,total)", self.html)
        self.assertIn("PRÉVIA · INTELIGÊNCIA DE MERCADO", self.html)
        self.assertIn("location.protocol==='file:'?'https://bolsa.frontlinetec.com.br'", self.html)

    def test_brazil_map_has_a_public_file_mode_fallback(self) -> None:
        self.assertIn("const publicMap='https://bolsa.frontlinetec.com.br/terminal/assets/brasil-estados.geojson'", self.html)
        self.assertIn("location.protocol==='file:'?[publicMap]", self.html)


if __name__ == "__main__":
    unittest.main()
