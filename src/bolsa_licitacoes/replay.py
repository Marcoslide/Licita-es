from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Mapping, Optional

from .connectors.common import RunMetrics
from .connectors.pncp import PncpConnector, _external_id
from .db import Database
from .documents import DocumentService
from .normalizers import normalize_item, normalize_procurement, normalize_result
from .http import PublicHttpClient


def replay_pncp_capture(
    db: Database,
    *,
    publication_file: Path,
    request_url: str,
    request_params: Mapping[str, Any],
    endpoint: str = "/v1/contratacoes/publicacao",
    items_file: Optional[Path] = None,
    documents_file: Optional[Path] = None,
    history_file: Optional[Path] = None,
    document_service: Optional[DocumentService] = None,
) -> RunMetrics:
    """Reprocessa respostas reais capturadas, sem alterar o payload original."""
    source_id = db.source_id("pncp")
    run_id = db.start_run(source_id, "REPLAY", endpoint)
    metrics = RunMetrics(pages=1)
    wrapper = json.loads(publication_file.read_text(encoding="utf-8"))
    records = wrapper.get("data", [])
    first_procurement_id = None
    first = records[0] if records else None
    for record in records:
        metrics.records_seen += 1
        external_id = str(record.get("numeroControlePNCP"))
        raw_id, status = db.store_raw(
            source_id=source_id, endpoint=endpoint, request_url=request_url,
            request_params=request_params, http_status=200, external_id=external_id,
            entity_hint="procurement", payload=record, source_created_at=record.get("dataInclusao"),
            source_updated_at=record.get("dataAtualizacaoGlobal") or record.get("dataAtualizacao"),
        )
        metrics.raw_status(status)
        procurement_id = normalize_procurement(db, source_id=source_id, raw_id=raw_id, payload=record, source_url=request_url, flavor="pncp")
        if first_procurement_id is None:
            first_procurement_id = procurement_id

    if first and first_procurement_id:
        org = first.get("orgaoEntidade") or {}
        cnpj, year, sequence = org.get("cnpj"), first.get("anoCompra"), first.get("sequencialCompra")
        prefix = f"/v1/orgaos/{cnpj}/compras/{year}/{sequence}"
        item_ids = {}
        if items_file:
            metrics.pages += 1
            for item in json.loads(items_file.read_text(encoding="utf-8")):
                metrics.records_seen += 1
                number = item.get("numeroItem")
                raw_id, status = db.store_raw(
                    source_id=source_id, endpoint=prefix + "/itens", request_url="https://pncp.gov.br/api/pncp" + prefix + "/itens",
                    request_params={"pagina": 1, "tamanhoPagina": 10}, http_status=200,
                    external_id=f"{cnpj}:{year}:{sequence}:{number}", entity_hint="procurement_item", payload=item,
                    source_created_at=item.get("dataInclusao"), source_updated_at=item.get("dataAtualizacao"),
                )
                metrics.raw_status(status)
                item_ids[number] = normalize_item(db, source_id=source_id, raw_id=raw_id, procurement_id=first_procurement_id, payload=item, source_url="https://pncp.gov.br/api/pncp" + prefix + "/itens")
        for file_path, suffix, hint in (
            (documents_file, "/arquivos", "document"),
            (history_file, "/historico", "procurement_history"),
        ):
            if not file_path:
                continue
            metrics.pages += 1
            for pos, record in enumerate(json.loads(file_path.read_text(encoding="utf-8")), start=1):
                metrics.records_seen += 1
                external_id = (
                    f"{cnpj}:{year}:{sequence}:{record.get('sequencialDocumento', pos)}"
                    if hint == "document" else
                    f"{cnpj}:{year}:{sequence}:{record.get('logManutencaoDataInclusao', pos)}:{pos}"
                )
                raw_id, status = db.store_raw(
                    source_id=source_id, endpoint=prefix + suffix,
                    request_url="https://pncp.gov.br/api/pncp" + prefix + suffix,
                    request_params={}, http_status=200, external_id=external_id, entity_hint=hint,
                    payload=record, source_created_at=record.get("dataPublicacaoPncp") or record.get("logManutencaoDataInclusao"),
                    source_updated_at=record.get("dataAtualizacao"),
                )
                metrics.raw_status(status); db.mark_processed(raw_id)
                if hint == "document":
                    metrics.documents_found += 1
                    if document_service:
                        document_service.register_pncp_document(source_id=source_id, raw_id=raw_id,
                            procurement_id=first_procurement_id, payload=record, download=False)
    db.finish_run(run_id, **metrics.as_dict())
    return metrics


def replay_pncp_detail_capture(
    db: Database,
    *,
    detail_file: Path,
    items_file: Optional[Path] = None,
    results_file: Optional[Path] = None,
) -> RunMetrics:
    """Reprocessa detalhe/itens/resultados reais, preservando as URLs de origem."""
    source_id = db.source_id("pncp")
    detail = json.loads(detail_file.read_text(encoding="utf-8"))
    cnpj = (detail.get("orgaoEntidade") or {}).get("cnpj")
    year, sequence = detail.get("anoCompra"), detail.get("sequencialCompra")
    prefix = f"/v1/orgaos/{cnpj}/compras/{year}/{sequence}"
    run_id = db.start_run(source_id, "REPLAY", prefix)
    metrics = RunMetrics(pages=1, records_seen=1)
    detail_url = "https://pncp.gov.br/api/consulta" + prefix
    raw_id, status = db.store_raw(
        source_id=source_id, endpoint=prefix, request_url=detail_url, request_params={}, http_status=200,
        external_id=str(detail.get("numeroControlePNCP")), entity_hint="procurement_detail", payload=detail,
        source_created_at=detail.get("dataInclusao"),
        source_updated_at=detail.get("dataAtualizacaoGlobal") or detail.get("dataAtualizacao"),
    )
    metrics.raw_status(status)
    procurement_id = normalize_procurement(db, source_id=source_id, raw_id=raw_id, payload=detail, source_url=detail_url, flavor="pncp")
    item_ids = {}
    if items_file:
        metrics.pages += 1
        for item in json.loads(items_file.read_text(encoding="utf-8")):
            metrics.records_seen += 1
            number = item.get("numeroItem")
            url = "https://pncp.gov.br/api/pncp" + prefix + "/itens"
            item_raw, item_status = db.store_raw(
                source_id=source_id, endpoint=prefix + "/itens", request_url=url,
                request_params={"pagina": 1, "tamanhoPagina": 500}, http_status=200,
                external_id=f"{cnpj}:{year}:{sequence}:{number}", entity_hint="procurement_item", payload=item,
                source_created_at=item.get("dataInclusao"), source_updated_at=item.get("dataAtualizacao"),
            )
            metrics.raw_status(item_status)
            item_ids[number] = normalize_item(db, source_id=source_id, raw_id=item_raw, procurement_id=procurement_id, payload=item, source_url=url)
    if results_file:
        metrics.pages += 1
        for result in json.loads(results_file.read_text(encoding="utf-8")):
            metrics.records_seen += 1
            number, seq = result.get("numeroItem"), result.get("sequencialResultado") or 1
            item_id = item_ids.get(number)
            if not item_id:
                metrics.records_discarded += 1
                continue
            url = "https://pncp.gov.br/api/pncp" + prefix + f"/itens/{number}/resultados"
            result_raw, result_status = db.store_raw(
                source_id=source_id, endpoint=prefix + f"/itens/{number}/resultados", request_url=url,
                request_params={}, http_status=200, external_id=f"{cnpj}:{year}:{sequence}:{number}:{seq}",
                entity_hint="procurement_result", payload=result, source_created_at=result.get("dataInclusao"),
                source_updated_at=result.get("dataAtualizacao"),
            )
            metrics.raw_status(result_status)
            normalize_result(db, source_id=source_id, raw_id=result_raw, item_id=item_id, payload=result, source_url=url)
    db.finish_run(run_id, **metrics.as_dict())
    return metrics


def replay_pncp_entity_capture(
    db: Database,
    *,
    entity: str,
    capture_file: Path,
    endpoint: str,
    request_url: str,
) -> RunMetrics:
    """Reprocessa uma lista/página real de ata, contrato ou item de PCA."""
    source_id = db.source_id("pncp")
    run_id = db.start_run(source_id, "REPLAY", endpoint)
    payload = json.loads(capture_file.read_text(encoding="utf-8"))
    records = payload.get("data", []) if isinstance(payload, dict) else payload
    metrics = RunMetrics(pages=1)
    connector = PncpConnector(db, PublicHttpClient(retries=0))
    normalizers = {
        "price_registry_ata": connector._normalize_ata,
        "contract": connector._normalize_contract,
        "annual_procurement_plan": connector._normalize_pca,
    }
    normalizer = normalizers[entity]
    for pos, record in enumerate(records, start=1):
        metrics.records_seen += 1
        external_id = _external_id(entity, record, pos)
        raw_id, status = db.store_raw(
            source_id=source_id, endpoint=endpoint, request_url=request_url, request_params={}, http_status=200,
            external_id=external_id, entity_hint=entity, payload=record,
            source_created_at=record.get("dataInclusao") or record.get("dataPublicacaoPncp"),
            source_updated_at=record.get("dataAtualizacaoGlobal") or record.get("dataAtualizacao"),
        )
        metrics.raw_status(status); normalizer(raw_id, record, request_url)
    db.finish_run(run_id, **metrics.as_dict())
    return metrics
