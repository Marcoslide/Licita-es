from __future__ import annotations

import unittest

from bolsa_licitacoes.document_requirements import DocumentPage, analyze_document_pages


class DocumentRequirementTests(unittest.TestCase):
    def test_finds_requirements_with_document_and_page(self) -> None:
        rows = analyze_document_pages([
            DocumentPage("Edital.pdf", 12, "A qualificação técnica exige atestado de capacidade técnica."),
            DocumentPage("TR.pdf", 7, "O prazo de entrega será de 10 dias após a ordem de fornecimento."),
        ])
        technical = next(row for row in rows if row["code"] == "TECHNICAL")
        delivery = next(row for row in rows if row["code"] == "DELIVERY")
        self.assertEqual(technical["status"], "FOUND")
        self.assertEqual(technical["evidence"][0]["page"], 12)
        self.assertEqual(delivery["evidence"][0]["document"], "TR.pdf")

    def test_absence_is_not_reported_as_requirement(self) -> None:
        rows = analyze_document_pages([DocumentPage("Aviso.txt", 1, "Objeto: aquisição de materiais.")])
        self.assertTrue(all(row["status"] == "NOT_FOUND" for row in rows))


if __name__ == "__main__":
    unittest.main()
