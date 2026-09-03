from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "index.html").read_text(encoding="utf-8")
MIGRATION = (ROOT / "supabase/migrations/20260903193000_procurement_pricing_engine.sql").read_text(encoding="utf-8")


class PricingWorkspaceContractTests(unittest.TestCase):
    def test_pricing_has_progressive_workspaces(self) -> None:
        for view in ("summary", "costs", "scenarios", "composition", "bids", "versions"):
            self.assertIn(f'data-pricing-view="{view}"', HTML)
        self.assertIn("Importar CSV", HTML)
        self.assertIn("Plano manual de lance", HTML)

    def test_critical_math_uses_integer_cents_in_browser(self) -> None:
        self.assertIn("parseCents=value=>parseDecimalParts(value,2)", HTML)
        self.assertIn("BigInt(10000-rateBps)", HTML)
        self.assertIn("roundDiv", HTML)

    def test_private_data_is_company_scoped(self) -> None:
        self.assertIn("company_id uuid not null references public.saas_empresas", MIGRATION)
        self.assertIn("public.saas_company_can(company_id,'view')", MIGRATION)
        self.assertIn("pricing_workspace_save", MIGRATION)
        self.assertIn("amount_cents bigint", MIGRATION)
        self.assertIn("revenue_rate_bps integer", MIGRATION)

    def test_live_memory_receives_private_cost_change(self) -> None:
        self.assertIn("COMPANY_COST_UPDATED", HTML)
        self.assertIn("POSSIVEL_IMPACTO", HTML)
        self.assertIn("recalculation_jobs", MIGRATION)


if __name__ == "__main__":
    unittest.main()
