from __future__ import annotations

import unittest

from bolsa_licitacoes.price_intelligence import build_price_basket, comparability, normalize_observation


class PriceIntelligenceTests(unittest.TestCase):
    def test_package_is_only_converted_when_quantity_is_known(self) -> None:
        known = normalize_observation({"unit_price": 100, "unit": "CX", "package_quantity": 10})
        unknown = normalize_observation({"unit_price": 100, "unit": "CX"})
        self.assertEqual(10, known["unit_price_normalized"])
        self.assertEqual("UN", known["normalized_unit"])
        self.assertEqual("UNKNOWN_PACKAGE", unknown["normalization_status"])
        self.assertEqual(100, unknown["unit_price_original"])

    def test_essential_attribute_mismatch_caps_comparability(self) -> None:
        target = {"description": "ceftriaxona 1 g frasco", "catalog_code": "123", "unit": "UN"}
        other = {"description": "ceftriaxona 500 mg frasco", "catalog_code": "123", "unit": "UN"}
        score, _, exclusions = comparability(target, other)
        self.assertLess(score, 40)
        self.assertTrue(any("concentracao" in item for item in exclusions))

    def test_duplicate_sources_become_one_observation(self) -> None:
        target = {"description": "seringa 10 ml", "catalog_code": "9", "unit": "UN"}
        observation = {
            "procurement_id": "p1", "item_number": 1, "supplier_id": "s1", "price_type": "HOMOLOGATED",
            "description": "seringa 10 ml", "catalog_code": "9", "unit": "UN", "unit_price": 11,
        }
        basket = build_price_basket(target, [observation, dict(observation)])
        self.assertEqual(1, basket["methodology"]["found"])

    def test_outlier_is_flagged_not_erased(self) -> None:
        target = {"description": "luva nitrilica", "catalog_code": "77", "unit": "UN"}
        rows = [{
            "procurement_id": f"p{i}", "item_number": 1, "supplier_id": f"s{i}", "price_type": "HOMOLOGATED",
            "description": "luva nitrilica", "catalog_code": "77", "unit": "UN", "unit_price": price,
        } for i, price in enumerate([90, 91, 92, 93, 95, 940])]
        basket = build_price_basket(target, rows)
        outlier = next(row for row in basket["observations"] if row["unit_price_original"] == 940)
        self.assertTrue(outlier["possible_outlier"])
        self.assertFalse(outlier["included"])
        self.assertEqual(6, basket["methodology"]["found"])
        self.assertEqual(5, basket["methodology"]["selected"])


if __name__ == "__main__":
    unittest.main()
