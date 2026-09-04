import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
HTML = (ROOT / "index.html").read_text(encoding="utf-8")
SQL = (ROOT / "supabase/migrations/20260903235900_intelligent_inbox.sql").read_text(
    encoding="utf-8"
)


class IntelligentInboxContractTests(unittest.TestCase):
    def test_frontend_has_complete_inbox_workspace(self):
        for marker in (
            'data-view="inbox"',
            'id="view-inbox"',
            'id="inboxFolders"',
            'id="inboxList"',
            'id="inboxReader"',
            'id="inboxHomeSummary"',
            'id="inboxAskForm"',
        ):
            self.assertIn(marker, HTML)

    def test_frontend_supports_required_user_actions(self):
        for action in (
            "READ",
            "UNREAD",
            "IMPORTANT",
            "ARCHIVE",
            "SNOOZE_1H",
            "SNOOZE_TOMORROW",
            "ASSIGN",
            "RESOLVE",
            "REOPEN",
        ):
            self.assertIn(action, HTML)
        for folder in (
            "INBOX",
            "UNREAD",
            "PRIORITY",
            "ACTION",
            "ASSIGNED",
            "SNOOZED",
            "IMPORTANT",
            "ARCHIVED",
        ):
            self.assertIn(folder, HTML)

    def test_fallback_is_built_from_real_existing_sources(self):
        self.assertIn("allAgendaEvents()", HTML)
        self.assertIn("agendaHistory()", HTML)
        self.assertIn("/api/public/procurements?", HTML)
        self.assertNotIn("INBOX_DEMO", HTML)
        self.assertNotIn("mockInbox", HTML)

    def test_database_reuses_event_sources_instead_of_creating_another_engine(self):
        self.assertIn("public.saas_monitor_eventos", SQL)
        self.assertIn("bolsa.change_events", SQL)
        self.assertIn("public.ai_artifact_events", SQL)
        self.assertNotIn("create table if not exists public.notifications", SQL.lower())

    def test_database_separates_shared_event_from_user_state(self):
        self.assertIn("create table if not exists public.saas_inbox_messages", SQL.lower())
        self.assertIn("create table if not exists public.saas_inbox_recipients", SQL.lower())
        self.assertIn("create table if not exists public.saas_inbox_event_receipts", SQL.lower())
        self.assertIn("primary key (message_id,user_id)", SQL.lower())
        self.assertIn("unique (company_id,event_key)", SQL.lower())
        self.assertIn("grouping_key", SQL)

    def test_database_enforces_company_and_user_boundaries(self):
        self.assertIn("public.saas_company_can(company_id,'view')", SQL)
        self.assertIn("using (user_id=auth.uid())", SQL)
        self.assertIn("enable row level security", SQL.lower())
        self.assertIn("public.saas_inbox_audit", SQL)

    def test_rpc_contract_supports_listing_materialization_and_bulk_actions(self):
        for function in (
            "saas_inbox_materialize_real",
            "saas_inbox_list",
            "saas_inbox_action",
            "saas_inbox_bulk_action",
            "saas_inbox_mark_all_read",
        ):
            self.assertIn(f"function public.{function}", SQL.lower())


if __name__ == "__main__":
    unittest.main()
