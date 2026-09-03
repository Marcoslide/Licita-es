from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "index.html").read_text(encoding="utf-8")
MIGRATION = (ROOT / "supabase/migrations/20260903184500_price_monitor_live_memory.sql").read_text(encoding="utf-8")
ARTIFACT_MIGRATION = (ROOT / "supabase/migrations/20260903183000_ai_artifacts.sql").read_text(encoding="utf-8")


class IntelligenceModulesContractTests(unittest.TestCase):
    def test_procurement_has_price_memory_artifact_surfaces(self) -> None:
        for token in ('data-proc-tab="updates"', 'data-proc-tab="price-center"', 'data-proc-tab="artifacts"'):
            self.assertIn(token, HTML)
        self.assertIn("renderPriceCenter", HTML)
        self.assertIn("loadProcurementMemory", HTML)

    def test_ai_answer_can_become_versioned_artifact(self) -> None:
        self.assertIn("Salvar como artefato", HTML)
        self.assertIn("ai_artifact_save_version", HTML)
        self.assertIn("RESTORED", HTML)
        self.assertIn("ai_artifact_versions", ARTIFACT_MIGRATION)

    def test_monitor_reuses_global_collection_and_active_scope(self) -> None:
        self.assertIn('data-view="monitors"', HTML)
        self.assertIn("scopeParams(monitor.scope", HTML)
        self.assertIn("saas_monitor_criar", HTML)
        self.assertNotIn("monitor_v2", HTML)

    def test_public_and_private_layers_are_separated(self) -> None:
        self.assertIn("create table if not exists bolsa.price_observations", MIGRATION)
        self.assertIn("create table if not exists bolsa.change_events", MIGRATION)
        self.assertIn("create table if not exists public.price_baskets", MIGRATION)
        self.assertIn("public.saas_company_can(company_id,'view')", MIGRATION)

    def test_prices_are_typed_and_original_is_preserved(self) -> None:
        self.assertIn("unit_price_original", MIGRATION)
        self.assertIn("unit_price_normalized", MIGRATION)
        self.assertIn("'ESTIMATED'", MIGRATION)
        self.assertIn("'HOMOLOGATED'", MIGRATION)


if __name__ == "__main__":
    unittest.main()
