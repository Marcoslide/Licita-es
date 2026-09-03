from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class RunMetrics:
    pages: int = 0
    records_seen: int = 0
    records_new: int = 0
    records_updated: int = 0
    records_unchanged: int = 0
    records_discarded: int = 0
    documents_found: int = 0
    documents_downloaded: int = 0
    errors: int = 0
    latency_ms: int = 0
    notes: list[str] = field(default_factory=list)

    def raw_status(self, status: str) -> None:
        if status == "new":
            self.records_new += 1
        elif status == "updated":
            self.records_updated += 1
        else:
            self.records_unchanged += 1

    def as_dict(self) -> dict[str, int]:
        return {
            key: int(getattr(self, key))
            for key in (
                "pages", "records_seen", "records_new", "records_updated", "records_unchanged",
                "records_discarded", "documents_found", "documents_downloaded", "errors", "latency_ms",
            )
        }
