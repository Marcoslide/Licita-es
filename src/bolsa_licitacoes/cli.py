from __future__ import annotations

import argparse
import json
from datetime import date
from pathlib import Path

from .admin_server import serve
from .config import Settings
from .connectors.compras import COMPRAS_MODALITIES, ComprasGovConnector
from .connectors.pncp import PNCP_MODALITIES, PncpConnector
from .db import Database
from .documents import DocumentService
from .http import PublicHttpClient
from .logging import configure_logging
from .replay import replay_pncp_capture, replay_pncp_detail_capture, replay_pncp_entity_capture
from .scheduler import run_scheduler


def main() -> None:
    parser = argparse.ArgumentParser(prog="bolsa-coleta")
    parser.add_argument("--db", help="Caminho do SQLite; sobrescreve BOLSA_DATABASE_PATH")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("init-db")
    sub.add_parser("stats")
    server = sub.add_parser("serve-admin")
    server.add_argument("--host", default="127.0.0.1")
    server.add_argument("--port", type=int, default=8088)
    sub.add_parser("run-scheduler")

    pncp = sub.add_parser("collect-pncp")
    _date_args(pncp)
    pncp.add_argument("--modalities", default=",".join(map(str, PNCP_MODALITIES)))
    pncp.add_argument("--max-pages", type=int, default=1)
    pncp.add_argument("--page-size", type=int, default=10)
    pncp.add_argument("--enrich-limit", type=int, default=1)
    pncp.add_argument("--download-documents", action="store_true")

    proposals = sub.add_parser("collect-pncp-proposals")
    proposals.add_argument("--until", required=True)
    proposals.add_argument("--max-pages", type=int, default=1)
    proposals.add_argument("--page-size", type=int, default=10)

    for name in ("collect-pncp-atas", "collect-pncp-contracts", "collect-pncp-pca"):
        cmd = sub.add_parser(name); _date_args(cmd)
        cmd.add_argument("--max-pages", type=int, default=1); cmd.add_argument("--page-size", type=int, default=10)

    compras = sub.add_parser("collect-compras")
    _date_args(compras)
    compras.add_argument("--modalities", default=",".join(map(str, COMPRAS_MODALITIES)))
    compras.add_argument("--max-pages", type=int, default=1)
    compras.add_argument("--page-size", type=int, default=10)

    replay = sub.add_parser("replay-pncp", help="Reprocessa uma captura JSON real e auditável")
    replay.add_argument("--publication", required=True, type=Path)
    replay.add_argument("--request-url", required=True)
    replay.add_argument("--endpoint", default="/v1/contratacoes/publicacao")
    replay.add_argument("--request-params", default="{}", help="JSON com os parâmetros originais")
    replay.add_argument("--items", type=Path)
    replay.add_argument("--documents", type=Path)
    replay.add_argument("--history", type=Path)

    replay_detail = sub.add_parser("replay-pncp-detail", help="Reprocessa detalhe, itens e resultados JSON reais")
    replay_detail.add_argument("--detail", required=True, type=Path)
    replay_detail.add_argument("--items", type=Path)
    replay_detail.add_argument("--results", type=Path)

    replay_entity = sub.add_parser("replay-pncp-entity", help="Reprocessa ata, contrato ou PCA JSON real")
    replay_entity.add_argument("--entity", required=True, choices=("price_registry_ata", "contract", "annual_procurement_plan"))
    replay_entity.add_argument("--file", required=True, type=Path)
    replay_entity.add_argument("--endpoint", required=True)
    replay_entity.add_argument("--request-url", required=True)

    args = parser.parse_args()
    configure_logging()
    settings = Settings.from_env()
    db = Database(args.db or settings.database_path)
    db.migrate()
    http = PublicHttpClient(timeout=settings.timeout, retries=settings.retries, user_agent=settings.user_agent)
    docs = DocumentService(db, http, settings.documents_path)
    pncp_connector = PncpConnector(db, http, docs)

    if args.command == "init-db":
        print(json.dumps({"database": str(db.path), "tables": db.table_counts()}, ensure_ascii=False, indent=2))
    elif args.command == "stats":
        print(json.dumps(db.table_counts(), ensure_ascii=False, indent=2))
    elif args.command == "serve-admin":
        serve(db, args.host, args.port, settings.admin_api_token)
    elif args.command == "run-scheduler":
        run_scheduler(db, settings)
    elif args.command == "collect-pncp":
        metrics = pncp_connector.collect_publications(
            _date(args.start), _date(args.end), modalities=_ints(args.modalities), max_pages=args.max_pages,
            page_size=args.page_size, enrich_limit=args.enrich_limit, download_documents=args.download_documents,
        )
        print(json.dumps(metrics.__dict__, ensure_ascii=False, indent=2))
    elif args.command == "collect-pncp-proposals":
        metrics = pncp_connector.collect_open_proposals(_date(args.until), max_pages=args.max_pages, page_size=args.page_size)
        print(json.dumps(metrics.__dict__, ensure_ascii=False, indent=2))
    elif args.command == "collect-pncp-atas":
        metrics = pncp_connector.collect_atas(_date(args.start), _date(args.end), max_pages=args.max_pages, page_size=args.page_size)
        print(json.dumps(metrics.__dict__, ensure_ascii=False, indent=2))
    elif args.command == "collect-pncp-contracts":
        metrics = pncp_connector.collect_contracts(_date(args.start), _date(args.end), max_pages=args.max_pages, page_size=args.page_size)
        print(json.dumps(metrics.__dict__, ensure_ascii=False, indent=2))
    elif args.command == "collect-pncp-pca":
        metrics = pncp_connector.collect_pca_updates(_date(args.start), _date(args.end), max_pages=args.max_pages, page_size=args.page_size)
        print(json.dumps(metrics.__dict__, ensure_ascii=False, indent=2))
    elif args.command == "collect-compras":
        metrics = ComprasGovConnector(db, http).collect_procurements(
            _date(args.start), _date(args.end), modalities=_ints(args.modalities),
            max_pages=args.max_pages, page_size=args.page_size,
        )
        print(json.dumps(metrics.__dict__, ensure_ascii=False, indent=2))
    elif args.command == "replay-pncp":
        metrics = replay_pncp_capture(
            db, publication_file=args.publication, request_url=args.request_url,
            request_params=json.loads(args.request_params), endpoint=args.endpoint, items_file=args.items,
            documents_file=args.documents, history_file=args.history, document_service=docs,
        )
        print(json.dumps(metrics.__dict__, ensure_ascii=False, indent=2))
    elif args.command == "replay-pncp-detail":
        metrics = replay_pncp_detail_capture(
            db, detail_file=args.detail, items_file=args.items, results_file=args.results,
        )
        print(json.dumps(metrics.__dict__, ensure_ascii=False, indent=2))
    elif args.command == "replay-pncp-entity":
        metrics = replay_pncp_entity_capture(
            db, entity=args.entity, capture_file=args.file, endpoint=args.endpoint, request_url=args.request_url,
        )
        print(json.dumps(metrics.__dict__, ensure_ascii=False, indent=2))


def _date_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--start", required=True, help="AAAA-MM-DD")
    parser.add_argument("--end", required=True, help="AAAA-MM-DD")


def _date(value: str) -> date:
    return date.fromisoformat(value)


def _ints(value: str):
    return tuple(int(item.strip()) for item in value.split(",") if item.strip())


if __name__ == "__main__":
    main()
