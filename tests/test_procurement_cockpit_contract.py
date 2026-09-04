from __future__ import annotations

import unittest
from pathlib import Path


class ProcurementCockpitContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.html = (Path(__file__).parents[1] / "index.html").read_text()

    def test_detail_preserves_one_real_source_and_progressive_tabs(self) -> None:
        for panel in (
            "overview",
            "requirements",
            "items",
            "pricing",
            "market",
            "strategy",
            "documents",
            "assistant",
        ):
            self.assertIn(f'data-proc-panel="{panel}"', self.html)
        self.assertIn("/api/public/procurement?id=", self.html)
        self.assertIn("/api/public/procurement/enrichment?id=", self.html)

    def test_agenda_is_driven_by_favorites_and_official_dates(self) -> None:
        self.assertIn('data-view="agenda"', self.html)
        self.assertIn("function automaticAgendaEvents()", self.html)
        self.assertIn("p.proposal_start", self.html)
        self.assertIn("p.proposal_end", self.html)
        self.assertIn("function recordAgendaChange", self.html)

    def test_missing_document_text_is_not_presented_as_ai_fact(self) -> None:
        self.assertIn("/api/public/procurement/requirements?id=", self.html)
        self.assertIn("nenhuma exigência é presumida", self.html)
        self.assertIn("Não é possível concluir a habilitação com segurança ainda", self.html)
        self.assertNotIn("Edital.pdf → página 47 → item 8.3.2", self.html)

    def test_procurement_navigation_preserves_context(self) -> None:
        self.assertIn("data-close-procurement", self.html)
        self.assertIn("você continua nesta ficha", self.html)
        self.assertIn('data-market-mode="personal"', self.html)
        self.assertIn('data-market-mode="global"', self.html)

    def test_overview_exposes_decision_signals(self) -> None:
        for label in (
            "VALOR DA OPORTUNIDADE",
            "APTIDÃO DOCUMENTAL",
            "PREÇO VENCEDOR · ESTIMATIVA HISTÓRICA",
            "CONCORRÊNCIA · HISTÓRICO",
            "FASE E EXECUÇÃO",
        ):
            self.assertIn(label, self.html)

    def test_documents_can_be_read_inside_the_procurement_workspace(self) -> None:
        self.assertIn('id="procDocumentViewer"', self.html)
        self.assertIn("function openDocumentViewer", self.html)
        self.assertIn("PDFs e imagens abrem diretamente nesta área", self.html)

    def test_agenda_has_calendar_and_priority_workspace(self) -> None:
        self.assertIn('id="agendaMonthGrid"', self.html)
        self.assertIn('id="agendaSummary"', self.html)
        self.assertIn("function renderAgendaCalendar", self.html)

    def test_pricing_is_private_and_explainable(self) -> None:
        self.assertIn("bolsa.procurement-pricing.v1", self.html)
        self.assertIn("bolsa.procurement-pricing.v2", self.html)
        self.assertIn("MESA PRIVADA DE PRECIFICAÇÃO", self.html)
        self.assertIn("Price to Win ≠ break-even", self.html)
        self.assertIn("COMPOSIÇÃO INVIÁVEL", self.html)

    def test_main_navigation_keeps_the_seven_defined_sections(self) -> None:
        for label in (
            "Visão 360",
            "Edital &amp; requisitos",
            "Itens &amp; preços",
            "Precificação",
            "Mercado",
            "Estratégia",
            "Documentos &amp; timeline",
        ):
            self.assertIn(label, self.html)
        self.assertNotIn('data-proc-tab="updates"', self.html)
        self.assertNotIn('data-proc-tab="artifacts"', self.html)


if __name__ == "__main__":
    unittest.main()
