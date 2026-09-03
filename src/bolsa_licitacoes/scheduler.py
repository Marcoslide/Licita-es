from __future__ import annotations

import logging
import os
import signal
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Callable
from zoneinfo import ZoneInfo

from .config import Settings
from .connectors.compras import ComprasGovConnector
from .connectors.pncp import PncpConnector
from .db import Database
from .documents import DocumentService
from .http import PublicHttpClient


log = logging.getLogger(__name__)


@dataclass
class ScheduledTask:
    name: str
    interval: int
    callback: Callable[[], None]
    next_run: float


def run_scheduler(db: Database, settings: Settings) -> None:
    """Executa coletas pequenas sem sobreposição; cada conector audita sua própria execução."""
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    http = PublicHttpClient(
        timeout=settings.timeout,
        retries=settings.retries,
        user_agent=settings.user_agent,
    )
    documents = DocumentService(db, http, settings.documents_path)
    pncp = PncpConnector(db, http, documents)
    compras = ComprasGovConnector(db, http)
    timezone = ZoneInfo(os.getenv("TZ", "America/Sao_Paulo"))
    run_on_start = _bool_env("BOLSA_SCHEDULER_RUN_ON_START", True)
    initial = time.monotonic() if run_on_start else time.monotonic() + 60

    def today():
        return datetime.now(timezone).date()

    tasks = [
        ScheduledTask(
            "pncp-publications",
            _positive_int("BOLSA_PNCP_INTERVAL_SECONDS", 900),
            lambda: pncp.collect_publications(
                today(), today(),
                modalities=_csv_ints("BOLSA_PNCP_MODALITIES", "6"),
                max_pages=_positive_int("BOLSA_MAX_PAGES_PER_RUN", 1),
                page_size=_positive_int("BOLSA_PAGE_SIZE", 10),
                enrich_limit=_non_negative_int("BOLSA_ENRICH_LIMIT", 1),
                download_documents=_bool_env("BOLSA_DOWNLOAD_DOCUMENTS", False),
            ),
            initial,
        ),
        ScheduledTask(
            "compras-publications",
            _positive_int("BOLSA_COMPRAS_INTERVAL_SECONDS", 3600),
            lambda: compras.collect_procurements(
                today().replace(day=1), today(),
                modalities=_csv_ints("BOLSA_COMPRAS_MODALITIES", "5"),
                max_pages=_positive_int("BOLSA_MAX_PAGES_PER_RUN", 1),
                page_size=_positive_int("BOLSA_PAGE_SIZE", 10),
            ),
            initial + 30,
        ),
        ScheduledTask(
            "pncp-contracts",
            _positive_int("BOLSA_CONTRACTS_INTERVAL_SECONDS", 86400),
            lambda: pncp.collect_contracts(
                today() - timedelta(days=1), today(),
                max_pages=_positive_int("BOLSA_MAX_PAGES_PER_RUN", 1),
                page_size=_positive_int("BOLSA_PAGE_SIZE", 10),
            ),
            initial + 60,
        ),
    ]

    log.info("scheduler_started", extra={"context": {"tasks": [task.name for task in tasks]}})
    while not stop.is_set():
        now = time.monotonic()
        due = [task for task in tasks if task.next_run <= now]
        if not due:
            stop.wait(min(max(min(task.next_run for task in tasks) - now, 0.1), 5.0))
            continue
        task = min(due, key=lambda item: item.next_run)
        started = time.monotonic()
        try:
            log.info("scheduled_task_started", extra={"context": {"task": task.name}})
            task.callback()
            log.info("scheduled_task_finished", extra={"context": {"task": task.name}})
        except Exception:
            log.exception("scheduled_task_failed", extra={"context": {"task": task.name}})
        task.next_run = max(task.next_run + task.interval, started + task.interval)


def _csv_ints(name: str, default: str) -> tuple[int, ...]:
    return tuple(int(value.strip()) for value in os.getenv(name, default).split(",") if value.strip())


def _positive_int(name: str, default: int) -> int:
    value = int(os.getenv(name, str(default)))
    if value <= 0:
        raise ValueError(f"{name} deve ser maior que zero")
    return value


def _non_negative_int(name: str, default: int) -> int:
    value = int(os.getenv(name, str(default)))
    if value < 0:
        raise ValueError(f"{name} não pode ser negativo")
    return value


def _bool_env(name: str, default: bool) -> bool:
    return os.getenv(name, str(default)).strip().lower() in {"1", "true", "yes", "sim"}
