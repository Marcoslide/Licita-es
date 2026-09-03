from __future__ import annotations

import logging
import re
import hashlib
import json
from datetime import date
from typing import Any, Iterable, Mapping, Optional

from ..db import Database, utcnow
from ..documents import DocumentService
from ..http import PublicApiError, PublicHttpClient
from ..normalizers import normalize_item, normalize_procurement, normalize_result
from .common import RunMetrics


log = logging.getLogger(__name__)

PNCP_QUERY_BASE = "https://pncp.gov.br/api/consulta"
PNCP_NESTED_BASE = "https://pncp.gov.br/api/pncp"
PNCP_MODALITIES = tuple(range(1, 14))


class PncpConnector:
    def __init__(self, db: Database, http: PublicHttpClient, documents: Optional[DocumentService] = None) -> None:
        self.db = db
        self.http = http
        self.documents = documents
        self.source_id = db.source_id("pncp")

    def collect_publications(
        self,
        start: date,
        end: date,
        *,
        modalities: Iterable[int] = PNCP_MODALITIES,
        max_pages: Optional[int] = None,
        page_size: int = 50,
        enrich_limit: int = 0,
        download_documents: bool = False,
    ) -> RunMetrics:
        _page_size(page_size, maximum=50)
        endpoint = "/v1/contratacoes/publicacao"
        run_id = self.db.start_run(self.source_id, "INCREMENTAL", endpoint, start.isoformat(), end.isoformat())
        metrics = RunMetrics()
        enrich_queue: list[tuple[int, Mapping[str, Any]]] = []
        try:
            for modality in modalities:
                page = 1
                while True:
                    params = {
                        "dataInicial": start.strftime("%Y%m%d"), "dataFinal": end.strftime("%Y%m%d"),
                        "codigoModalidadeContratacao": int(modality), "pagina": page, "tamanhoPagina": page_size,
                    }
                    response = self.http.get(PNCP_QUERY_BASE + endpoint, params=params)
                    metrics.pages += 1
                    metrics.latency_ms += response.duration_ms
                    if response.status == 204 or not response.body:
                        break
                    payload = response.json()
                    records = payload.get("data", [])
                    for record in records:
                        metrics.records_seen += 1
                        external_id = str(record.get("numeroControlePNCP") or _fallback_id(record))
                        raw_id, status = self.db.store_raw(
                            source_id=self.source_id, endpoint=endpoint, request_url=response.url,
                            request_params=params, http_status=response.status, external_id=external_id,
                            entity_hint="procurement", payload=record, source_created_at=record.get("dataInclusao"),
                            source_updated_at=record.get("dataAtualizacaoGlobal") or record.get("dataAtualizacao"),
                        )
                        metrics.raw_status(status)
                        procurement_id = normalize_procurement(
                            self.db, source_id=self.source_id, raw_id=raw_id, payload=record,
                            source_url=response.url, flavor="pncp",
                        )
                        if len(enrich_queue) < enrich_limit:
                            enrich_queue.append((procurement_id, record))
                    total_pages = int(payload.get("totalPaginas") or 0)
                    if not records or page >= total_pages or (max_pages and page >= max_pages):
                        break
                    page += 1
            for procurement_id, record in enrich_queue:
                extra = self.enrich_procurement(procurement_id, record, download_documents=download_documents)
                metrics.pages += extra.pages
                metrics.records_seen += extra.records_seen
                metrics.records_new += extra.records_new
                metrics.records_updated += extra.records_updated
                metrics.records_unchanged += extra.records_unchanged
                metrics.documents_found += extra.documents_found
                metrics.documents_downloaded += extra.documents_downloaded
                metrics.errors += extra.errors
                metrics.latency_ms += extra.latency_ms
            self.db.finish_run(run_id, **metrics.as_dict())
            return metrics
        except Exception as exc:
            metrics.errors += 1
            self._fail(run_id, endpoint, {}, exc, metrics)
            raise

    def collect_open_proposals(self, until: date, *, max_pages: int = 1, page_size: int = 10) -> RunMetrics:
        return self._collect_procurement_page(
            "/v1/contratacoes/proposta", {"dataFinal": until.strftime("%Y%m%d")},
            "OPEN_PROPOSALS", max_pages=max_pages, page_size=page_size,
        )

    def collect_contracts(self, start: date, end: date, *, max_pages: int = 1, page_size: int = 10) -> RunMetrics:
        endpoint = "/v1/contratos"
        return self._collect_generic(
            endpoint, {"dataInicial": start.strftime("%Y%m%d"), "dataFinal": end.strftime("%Y%m%d")},
            "contract", max_pages, page_size, self._normalize_contract,
        )

    def collect_atas(self, start: date, end: date, *, max_pages: int = 1, page_size: int = 10) -> RunMetrics:
        endpoint = "/v1/atas"
        return self._collect_generic(
            endpoint, {"dataInicial": start.strftime("%Y%m%d"), "dataFinal": end.strftime("%Y%m%d")},
            "price_registry_ata", max_pages, page_size, self._normalize_ata,
        )

    def collect_pca_updates(self, start: date, end: date, *, max_pages: int = 1, page_size: int = 10) -> RunMetrics:
        endpoint = "/v1/pca/atualizacao"
        return self._collect_generic(
            endpoint, {"dataInicio": start.strftime("%Y%m%d"), "dataFim": end.strftime("%Y%m%d")},
            "annual_procurement_plan", max_pages, page_size, self._normalize_pca,
        )

    def enrich_procurement(self, procurement_id: int, procurement: Mapping[str, Any], *, download_documents: bool = False) -> RunMetrics:
        metrics = RunMetrics()
        cnpj = (procurement.get("orgaoEntidade") or {}).get("cnpj") or procurement.get("orgaoEntidadeCnpj")
        year = procurement.get("anoCompra") or procurement.get("anoCompraPncp")
        sequence = procurement.get("sequencialCompra") or procurement.get("sequencialCompraPncp")
        if not (cnpj and year and sequence):
            metrics.records_discarded += 1
            return metrics
        prefix = f"/v1/orgaos/{cnpj}/compras/{year}/{sequence}"

        # O detalhe foi migrado para api/consulta; endpoints filhos ainda respondem em api/pncp.
        detail_response = self.http.get(PNCP_QUERY_BASE + prefix)
        metrics.pages += 1
        metrics.latency_ms += detail_response.duration_ms
        detail = detail_response.json()
        raw_id, status = self.db.store_raw(
            source_id=self.source_id, endpoint=prefix, request_url=detail_response.url, request_params={},
            http_status=detail_response.status, external_id=str(detail.get("numeroControlePNCP")),
            entity_hint="procurement_detail", payload=detail, source_created_at=detail.get("dataInclusao"),
            source_updated_at=detail.get("dataAtualizacaoGlobal") or detail.get("dataAtualizacao"),
        )
        metrics.records_seen += 1
        metrics.raw_status(status)
        normalize_procurement(self.db, source_id=self.source_id, raw_id=raw_id, payload=detail, source_url=detail_response.url, flavor="pncp")

        items_response = self.http.get(PNCP_NESTED_BASE + prefix + "/itens", params={"pagina": 1, "tamanhoPagina": 500})
        metrics.pages += 1
        metrics.latency_ms += items_response.duration_ms
        items = items_response.json() or []
        for item in items:
            metrics.records_seen += 1
            number = item.get("numeroItem")
            item_raw_id, status = self.db.store_raw(
                source_id=self.source_id, endpoint=prefix + "/itens", request_url=items_response.url,
                request_params={"pagina": 1, "tamanhoPagina": 500}, http_status=items_response.status,
                external_id=f"{cnpj}:{year}:{sequence}:{number}", entity_hint="procurement_item", payload=item,
                source_created_at=item.get("dataInclusao"), source_updated_at=item.get("dataAtualizacao"),
            )
            metrics.raw_status(status)
            item_id = normalize_item(self.db, source_id=self.source_id, raw_id=item_raw_id, procurement_id=procurement_id, payload=item, source_url=items_response.url)
            if item.get("temResultado"):
                results_url = PNCP_NESTED_BASE + prefix + f"/itens/{number}/resultados"
                result_response = self.http.get(results_url)
                metrics.pages += 1
                metrics.latency_ms += result_response.duration_ms
                for result in result_response.json() or []:
                    metrics.records_seen += 1
                    seq = result.get("sequencialResultado") or 1
                    result_raw_id, raw_status = self.db.store_raw(
                        source_id=self.source_id, endpoint=prefix + f"/itens/{number}/resultados",
                        request_url=result_response.url, request_params={}, http_status=result_response.status,
                        external_id=f"{cnpj}:{year}:{sequence}:{number}:{seq}", entity_hint="procurement_result",
                        payload=result, source_created_at=result.get("dataInclusao"), source_updated_at=result.get("dataAtualizacao"),
                    )
                    metrics.raw_status(raw_status)
                    normalize_result(self.db, source_id=self.source_id, raw_id=result_raw_id, item_id=item_id, payload=result, source_url=result_response.url)

        for suffix, hint in (("/arquivos", "document"), ("/historico", "procurement_history")):
            response = self.http.get(PNCP_NESTED_BASE + prefix + suffix)
            metrics.pages += 1
            metrics.latency_ms += response.duration_ms
            for pos, record in enumerate(response.json() or [], start=1):
                metrics.records_seen += 1
                if hint == "document":
                    ext = f"{cnpj}:{year}:{sequence}:{record.get('sequencialDocumento', pos)}"
                else:
                    ext = f"{cnpj}:{year}:{sequence}:{record.get('logManutencaoDataInclusao', pos)}:{pos}"
                record_raw_id, status = self.db.store_raw(
                    source_id=self.source_id, endpoint=prefix + suffix, request_url=response.url, request_params={},
                    http_status=response.status, external_id=ext, entity_hint=hint, payload=record,
                    source_created_at=record.get("dataPublicacaoPncp") or record.get("logManutencaoDataInclusao"),
                    source_updated_at=record.get("dataAtualizacao"),
                )
                metrics.raw_status(status)
                self.db.mark_processed(record_raw_id)
                if hint == "document":
                    metrics.documents_found += 1
                    if self.documents:
                        _, downloaded = self.documents.register_pncp_document(
                            source_id=self.source_id, raw_id=record_raw_id, procurement_id=procurement_id,
                            payload=record, download=download_documents,
                        )
                        metrics.documents_downloaded += int(downloaded)
        return metrics

    def _collect_procurement_page(self, endpoint: str, base_params: Mapping[str, Any], run_type: str, *, max_pages: int, page_size: int) -> RunMetrics:
        _page_size(page_size, maximum=50)
        run_id = self.db.start_run(self.source_id, run_type, endpoint)
        metrics = RunMetrics()
        try:
            for page in range(1, max_pages + 1):
                params = dict(base_params, pagina=page, tamanhoPagina=page_size)
                response = self.http.get(PNCP_QUERY_BASE + endpoint, params=params)
                metrics.pages += 1; metrics.latency_ms += response.duration_ms
                if response.status == 204 or not response.body: break
                wrapper = response.json(); records = wrapper.get("data", [])
                for record in records:
                    metrics.records_seen += 1
                    ext = str(record.get("numeroControlePNCP") or _fallback_id(record))
                    raw_id, status = self.db.store_raw(source_id=self.source_id, endpoint=endpoint, request_url=response.url,
                        request_params=params, http_status=response.status, external_id=ext, entity_hint="procurement",
                        payload=record, source_created_at=record.get("dataInclusao"), source_updated_at=record.get("dataAtualizacaoGlobal") or record.get("dataAtualizacao"))
                    metrics.raw_status(status)
                    normalize_procurement(self.db, source_id=self.source_id, raw_id=raw_id, payload=record, source_url=response.url, flavor="pncp")
                if not records or page >= int(wrapper.get("totalPaginas") or 0): break
            self.db.finish_run(run_id, **metrics.as_dict()); return metrics
        except Exception as exc:
            metrics.errors += 1; self._fail(run_id, endpoint, base_params, exc, metrics); raise

    def _collect_generic(self, endpoint: str, base_params: Mapping[str, Any], entity_hint: str, max_pages: int, page_size: int, normalizer: Any) -> RunMetrics:
        _page_size(page_size, maximum=500)
        run_id = self.db.start_run(self.source_id, "INCREMENTAL", endpoint)
        metrics = RunMetrics()
        try:
            for page in range(1, max_pages + 1):
                params = dict(base_params, pagina=page, tamanhoPagina=page_size)
                response = self.http.get(PNCP_QUERY_BASE + endpoint, params=params)
                metrics.pages += 1; metrics.latency_ms += response.duration_ms
                if response.status == 204 or not response.body: break
                wrapper = response.json(); records = wrapper.get("data", [])
                for pos, record in enumerate(records, start=1):
                    metrics.records_seen += 1
                    ext = str(_external_id(entity_hint, record, pos))
                    raw_id, status = self.db.store_raw(source_id=self.source_id, endpoint=endpoint, request_url=response.url,
                        request_params=params, http_status=response.status, external_id=ext, entity_hint=entity_hint,
                        payload=record, source_created_at=record.get("dataInclusao"), source_updated_at=record.get("dataAtualizacaoGlobal") or record.get("dataAtualizacao"))
                    metrics.raw_status(status); normalizer(raw_id, record, response.url)
                if not records or page >= int(wrapper.get("totalPaginas") or 0): break
            self.db.finish_run(run_id, **metrics.as_dict()); return metrics
        except Exception as exc:
            metrics.errors += 1; self._fail(run_id, endpoint, base_params, exc, metrics); raise

    def _normalize_ata(self, raw_id: int, record: Mapping[str, Any], url: str) -> None:
        control = record.get("numeroControlePNCP") or record.get("numeroControlePNCPAta") or record.get("numeroControlePncpAta")
        procurement_control = record.get("numeroControlePNCPCompra") or record.get("numeroControlePncpCompra")
        if not procurement_control and control and re.search(r"-\d{6}$", str(control)):
            procurement_control = str(control).rsplit("-", 1)[0]
        with self.db.connect() as conn:
            procurement = conn.execute("SELECT id,organization_id FROM procurements WHERE pncp_control_number=?", (procurement_control,)).fetchone() if procurement_control else None
            conn.execute("INSERT INTO price_registry_atas(pncp_control_number,procurement_id,organization_id,ata_number,validity_start,validity_end,object,source_id,source_external_id,source_url,raw_record_id,source_created_at,source_updated_at,collected_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(pncp_control_number) DO UPDATE SET validity_start=excluded.validity_start,validity_end=excluded.validity_end,raw_record_id=excluded.raw_record_id,collected_at=excluded.collected_at", (control, procurement["id"] if procurement else None, procurement["organization_id"] if procurement else None, record.get("numeroAtaRegistroPreco"), record.get("dataVigenciaInicio"), record.get("dataVigenciaFim"), record.get("objetoContratacao") or record.get("objetoCompra"), self.source_id, control, url, raw_id, record.get("dataInclusao"), record.get("dataAtualizacao"), utcnow()))
            entity = conn.execute("SELECT id FROM price_registry_atas WHERE pncp_control_number=?", (control,)).fetchone()
            if entity:
                conn.execute("INSERT OR IGNORE INTO source_links(entity_type,entity_id,source_id,source_external_id,source_url,raw_record_id) VALUES ('price_registry_ata',?,?,?,?,?)", (entity[0], self.source_id, control, url, raw_id))
        self.db.mark_processed(raw_id)

    def _normalize_contract(self, raw_id: int, record: Mapping[str, Any], url: str) -> None:
        control = record.get("numeroControlePNCP") or record.get("numeroControlePNCPContrato") or record.get("numeroControlePncpContrato")
        procurement_control = record.get("numeroControlePNCPCompra") or record.get("numeroControlePncpCompra")
        supplier_tax = record.get("niFornecedor")
        with self.db.connect() as conn:
            procurement = conn.execute("SELECT id,organization_id FROM procurements WHERE pncp_control_number=?", (procurement_control,)).fetchone() if procurement_control else None
            supplier_id = None
            if supplier_tax:
                conn.execute("INSERT INTO suppliers(tax_id,name,source_id,source_external_id,source_url,raw_record_id,collected_at) VALUES (?,?,?,?,?,?,?) ON CONFLICT(tax_id) DO UPDATE SET name=COALESCE(excluded.name,suppliers.name)", (supplier_tax, record.get("nomeRazaoSocialFornecedor"), self.source_id, supplier_tax, url, raw_id, utcnow()))
                supplier_id = conn.execute("SELECT id FROM suppliers WHERE tax_id=?", (supplier_tax,)).fetchone()[0]
            conn.execute("INSERT INTO contracts(pncp_control_number,procurement_id,organization_id,supplier_id,contract_number,object,initial_value,current_value,signed_at,validity_start,validity_end,source_id,source_external_id,source_url,raw_record_id,source_created_at,source_updated_at,collected_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(pncp_control_number) DO UPDATE SET current_value=excluded.current_value,validity_end=excluded.validity_end,raw_record_id=excluded.raw_record_id,collected_at=excluded.collected_at", (control, procurement["id"] if procurement else None, procurement["organization_id"] if procurement else None, supplier_id, record.get("numeroContratoEmpenho"), record.get("objetoContrato"), record.get("valorInicial"), record.get("valorGlobal"), record.get("dataAssinatura"), record.get("dataVigenciaInicio"), record.get("dataVigenciaFim"), self.source_id, control, url, raw_id, record.get("dataInclusao"), record.get("dataAtualizacao"), utcnow()))
            entity = conn.execute("SELECT id FROM contracts WHERE pncp_control_number=?", (control,)).fetchone()
            if entity:
                conn.execute("INSERT OR IGNORE INTO source_links(entity_type,entity_id,source_id,source_external_id,source_url,raw_record_id) VALUES ('contract',?,?,?,?,?)", (entity[0], self.source_id, control, url, raw_id))
        self.db.mark_processed(raw_id)

    def _normalize_pca(self, raw_id: int, record: Mapping[str, Any], url: str) -> None:
        control = record.get("idPcaPncp") or record.get("numeroControlePNCP")
        if not control and record.get("cnpj") and record.get("sequencialPca") and record.get("anoPca"):
            control = f"{record['cnpj']}-0-{int(record['sequencialPca']):06d}/{record['anoPca']}"
        item = record.get("numeroItem") or record.get("numeroItemPca")
        ext = f"{control}:{item}"
        org = record.get("orgaoEntidade") or {}
        unit = record.get("unidadeOrgao") or {}
        with self.db.connect() as conn:
            tax_id = org.get("cnpj") or record.get("cnpj")
            unit_code = unit.get("codigoUnidade") or record.get("codigoUnidade")
            unit_name = unit.get("nomeUnidade") or record.get("nomeUnidade")
            if tax_id:
                conn.execute("INSERT INTO organizations(tax_id,source_id,source_external_id,source_url,raw_record_id,collected_at) VALUES (?,?,?,?,?,?) ON CONFLICT(tax_id) DO NOTHING", (tax_id, self.source_id, tax_id, url, raw_id, utcnow()))
            org_id = conn.execute("SELECT id FROM organizations WHERE tax_id=?", (tax_id,)).fetchone() if tax_id else None
            if org_id and unit_code is not None:
                conn.execute("INSERT INTO purchasing_units(organization_id,code,name,source_id,source_external_id,source_url,raw_record_id,collected_at) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(organization_id,code) DO UPDATE SET name=COALESCE(excluded.name,purchasing_units.name)", (org_id[0], str(unit_code), unit_name, self.source_id, f"{org_id[0]}:{unit_code}", url, raw_id, utcnow()))
            unit_id = conn.execute("SELECT id FROM purchasing_units WHERE organization_id=? AND code=?", (org_id[0], str(unit_code))).fetchone() if org_id and unit_code is not None else None
            conn.execute("INSERT INTO annual_procurement_plans(pncp_control_number,organization_id,purchasing_unit_id,year,item_number,description,estimated_value,desired_date,source_id,source_external_id,source_url,raw_record_id,source_created_at,source_updated_at,collected_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(source_id,source_external_id) DO UPDATE SET description=excluded.description,estimated_value=excluded.estimated_value,desired_date=excluded.desired_date,raw_record_id=excluded.raw_record_id,collected_at=excluded.collected_at", (control, org_id[0] if org_id else None, unit_id[0] if unit_id else None, record.get("anoPca"), item, record.get("descricao"), record.get("valorTotal") or record.get("valorEstimado"), record.get("dataDesejada"), self.source_id, ext, url, raw_id, record.get("dataInclusao"), record.get("dataAtualizacao"), utcnow()))
            entity = conn.execute("SELECT id FROM annual_procurement_plans WHERE source_id=? AND source_external_id=?", (self.source_id, ext)).fetchone()
            if entity:
                conn.execute("INSERT OR IGNORE INTO source_links(entity_type,entity_id,source_id,source_external_id,source_url,raw_record_id) VALUES ('annual_procurement_plan',?,?,?,?,?)", (entity[0], self.source_id, ext, url, raw_id))
        self.db.mark_processed(raw_id)

    def _fail(self, run_id: int, endpoint: str, params: Mapping[str, Any], exc: Exception, metrics: RunMetrics) -> None:
        status = exc.status if isinstance(exc, PublicApiError) else None
        url = exc.url if isinstance(exc, PublicApiError) else PNCP_QUERY_BASE + endpoint
        self.db.record_error(source_id=self.source_id, run_id=run_id, endpoint=endpoint, request_url=url,
            request_params=params, message=str(exc), http_status=status,
            retryable=(status is None or status == 429 or bool(status and status >= 500)))
        self.db.finish_run(run_id, status="FAILED", error=str(exc), **metrics.as_dict())


def _page_size(value: int, *, maximum: int) -> None:
    if value < 10 or value > maximum:
        raise ValueError(f"tamanhoPagina deve estar entre 10 e {maximum}")


def _fallback_id(record: Mapping[str, Any]) -> str:
    org = record.get("orgaoEntidade") or {}
    return f"{org.get('cnpj')}:{record.get('anoCompra')}:{record.get('sequencialCompra')}"


def _external_id(hint: str, record: Mapping[str, Any], pos: int) -> str:
    if hint == "annual_procurement_plan" and record.get("cnpj") and record.get("sequencialPca") and record.get("anoPca"):
        control = f"{record['cnpj']}-0-{int(record['sequencialPca']):06d}/{record['anoPca']}"
        return f"{control}:{record.get('numeroItem') or record.get('numeroItemPca')}"
    keys = {
        "contract": ("numeroControlePNCP", "numeroControlePNCPContrato", "numeroControlePncpContrato"),
        "price_registry_ata": ("numeroControlePNCP", "numeroControlePNCPAta", "numeroControlePncpAta"),
        "annual_procurement_plan": ("idPcaPncp", "numeroControlePNCP"),
    }.get(hint, ())
    for key in keys:
        if record.get(key):
            suffix = f":{record.get('numeroItem') or record.get('numeroItemPca')}" if hint == "annual_procurement_plan" else ""
            return str(record[key]) + suffix
    serialized = json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":"), default=str)
    return f"{hint}:{pos}:{hashlib.sha256(serialized.encode('utf-8')).hexdigest()}"
