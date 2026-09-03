from __future__ import annotations

import unittest

from bolsa_licitacoes.market_search import (
    MarketSearchEngine, SearchDocument, extract_technical_attributes, ndcg_at_k, normalize_text, precision_at_k,
)


class MarketSearchEngineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.engine = MarketSearchEngine()
        self.documents = [
            SearchDocument("school", "Registro de preços para mobiliário escolar", item_rows=[
                {"numero_item": 4, "descricao": "Conjunto aluno com cadeira escolar infantil", "catalogo_codigo": "CAT-10"},
                {"numero_item": 5, "descricao": "Mesa escolar infantil", "catalogo_codigo": "CAT-11"},
            ]),
            SearchDocument("office", "Aquisição de cadeira de escritório giratória", item_rows=[
                {"numero_item": 1, "descricao": "Cadeira executiva para escritório", "catalogo_codigo": "CAT-20"},
            ]),
            SearchDocument("school-computers", "Aquisição de computadores para escolas municipais"),
            SearchDocument("medicine-1g", "Aquisição de medicamentos", item_rows=[
                {"numero_item": 9, "descricao": "Ceftriaxona sódica 1 g solução injetável", "catalogo_codigo": "BR123"},
            ]),
            SearchDocument("medicine-500mg", "Aquisição de medicamentos", item_rows=[
                {"numero_item": 3, "descricao": "Ceftriaxona 500 mg frasco ampola", "catalogo_codigo": "BR124"},
            ]),
        ]
        self.vocabulary = [
            row.get("descricao", "") for document in self.documents for row in document.item_rows
        ]

    def search(self, query: str, mode: str = "balanced"):
        plan = self.engine.compile(query, mode=mode, vocabulary=self.vocabulary)
        return plan, self.engine.search(plan, self.documents)

    def test_normalization_handles_accents_punctuation_and_plural(self) -> None:
        self.assertEqual("mobiliario escolar", normalize_text("  MOBILIÁRIO--escolar! "))
        _, singular = self.search("cadeira escolar")
        _, plural = self.search("cadeiras escolares")
        self.assertEqual("school", singular[0].procurement_id)
        self.assertEqual("school", plural[0].procurement_id)

    def test_typo_is_corrected_using_real_index_vocabulary(self) -> None:
        plan, hits = self.search("caderia escolar")
        self.assertEqual("cadeira escolar", plan.correction)
        self.assertGreaterEqual(plan.correction_confidence or 0, .8)
        self.assertEqual("school", hits[0].procurement_id)
        self.assertNotIn("school-computers", [hit.procurement_id for hit in hits])

    def test_plural_is_not_reported_as_a_typo(self) -> None:
        plan, _ = self.search("cadeiras escolares")
        self.assertIsNone(plan.correction)

    def test_exact_mode_requires_literal_phrase_in_object_or_item(self) -> None:
        _, hits = self.search('"cadeira escolar"', "exact")
        self.assertEqual(["school"], [hit.procurement_id for hit in hits])

    def test_noise_is_excluded_from_first_results(self) -> None:
        _, hits = self.search("cadeira escolar")
        self.assertEqual("school", hits[0].procurement_id)
        self.assertNotIn("office", [hit.procurement_id for hit in hits[:1]])

    def test_negative_keyword_is_a_hard_constraint(self) -> None:
        plan = self.engine.compile("cadeira NOT escritório", vocabulary=self.vocabulary)
        hits = self.engine.search(plan, self.documents)
        self.assertEqual(["school"], [hit.procurement_id for hit in hits])

    def test_item_match_consolidates_procurement_and_explains_match(self) -> None:
        _, hits = self.search("ceftriaxona")
        self.assertEqual(2, len(hits))
        self.assertEqual(1, hits[0].matched_items_count)
        self.assertIn("item", hits[0].matched_fields)
        self.assertTrue(hits[0].match_reasons)

    def test_specification_prioritizes_exact_equivalent_unit(self) -> None:
        _, hits = self.search("ceftriaxona 1g")
        self.assertEqual("medicine-1g", hits[0].procurement_id)
        other = next(hit for hit in hits if hit.procurement_id == "medicine-500mg")
        self.assertIsNotNone(other.specification_warning)

    def test_unit_normalization_keeps_original_and_converts_known_units(self) -> None:
        attrs = extract_technical_attributes("embalagem 1 kg e frasco 1 litro")
        self.assertEqual((1_000_000, "mg"), (attrs[0].base_value, attrs[0].base_unit))
        self.assertEqual((1000, "ml"), (attrs[1].base_value, attrs[1].base_unit))

    def test_catalog_is_a_signal_and_not_the_only_retrieval_path(self) -> None:
        plan = self.engine.compile("", catalog_codes=["CAT-10"])
        hits = self.engine.search(plan, self.documents)
        self.assertEqual(["school"], [hit.procurement_id for hit in hits])
        self.assertIn("CATMAT/CATSER", hits[0].matched_fields)

    def test_ranking_metrics_support_golden_set_comparisons(self) -> None:
        ranked = ["school", "office", "medicine-1g"]
        self.assertEqual(.2, precision_at_k(ranked, {"school", "medicine-1g"}, 10))
        self.assertGreater(ndcg_at_k(ranked, {"school": 3, "medicine-1g": 2, "office": 0}, 3), .8)


if __name__ == "__main__":
    unittest.main()
