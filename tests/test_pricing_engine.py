from __future__ import annotations

import unittest
from decimal import Decimal

from bolsa_licitacoes.pricing_engine import calculate_pricing, redistribute_composition


class PricingEngineTests(unittest.TestCase):
    def test_break_even_solves_percentage_costs(self) -> None:
        result = calculate_pricing(
            [
                {"name": "Compra", "category": "DIRECT", "amount": "900.00"},
                {"name": "Tributos", "category": "TAX", "calculation_type": "PERCENT_REVENUE", "revenue_rate": "0.10"},
            ],
            sale_price="1200.00",
            desired_margin="0.15",
            minimum_margin="0.05",
        )
        self.assertEqual(result["break_even"], Decimal("1000.00"))
        self.assertEqual(result["desired_margin_price"], Decimal("1200.00"))
        self.assertEqual(result["profit"], Decimal("180.00"))
        self.assertEqual(result["actual_margin"], Decimal("0.1500"))

    def test_below_break_even_is_explicit_loss(self) -> None:
        result = calculate_pricing(
            [{"name": "Custo", "category": "DIRECT", "amount": "1000"}],
            sale_price="999.99",
            minimum_margin="0.02",
        )
        self.assertEqual(result["zone"], "LOSS")
        self.assertEqual(result["profit"], Decimal("-0.01"))

    def test_redistribution_is_exact_to_the_cent(self) -> None:
        result = redistribute_composition(
            [
                {"name": "Custo travado", "mode": "LOCKED", "original_amount": "300"},
                {"name": "Tributo", "mode": "PERCENTAGE", "revenue_rate": "0.10"},
                {"name": "Operação", "mode": "ADJUSTABLE", "original_amount": "400", "minimum_amount": "250"},
                {"name": "Margem", "mode": "MARGIN", "original_amount": "200"},
            ],
            "900.01",
        )
        self.assertTrue(result["feasible"])
        self.assertEqual(result["calculated_total"], Decimal("900.01"))
        self.assertEqual(result["lines"][0]["amount"], Decimal("300.00"))

    def test_impossible_composition_does_not_fake_profit(self) -> None:
        result = redistribute_composition(
            [
                {"name": "Custo travado", "mode": "LOCKED", "original_amount": "800"},
                {"name": "Tributo", "mode": "PERCENTAGE", "revenue_rate": "0.20"},
                {"name": "Operação", "mode": "ADJUSTABLE", "original_amount": "100", "minimum_amount": "100"},
            ],
            "1000",
        )
        self.assertFalse(result["feasible"])
        self.assertEqual(result["shortfall"], Decimal("100.00"))

    def test_rounding_uses_decimal_not_binary_float(self) -> None:
        result = calculate_pricing(
            [{"name": "Custo", "category": "DIRECT", "amount": "0.10"}],
            sale_price="0.30",
            desired_margin="0.10",
        )
        self.assertEqual(result["fixed_cost"], Decimal("0.10"))
        self.assertEqual(result["profit"], Decimal("0.20"))


if __name__ == "__main__":
    unittest.main()
