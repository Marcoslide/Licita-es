from __future__ import annotations

from datetime import date
from typing import Any, Iterable, Mapping, Optional

from ..db import Database
from ..http import PublicApiError, PublicHttpClient
from ..normalizers import normalize_procurement
from .common import RunMetrics


COMPRAS_BASE = "https://dadosabertos.compras.gov.br"
# Códigos próprios do SIASG/Compras.gov; não são os IDs de modalidade do PNCP.
COMPRAS_MODALITIES = (1, 2, 3, 4, 5, 6, 7, 12, 20, 22, 33, 44, 57)


class ComprasGovConnector:
    def __init__(self, db: Database, http: PublicHttpClient) -> None:
        self.db = db
        self.http = http
        self.source_id = db.source_id("compras-gov")

    def collect_procurements(
        self,
        start: date,
        end: date,
        *,
        modalities: Iterable[int] = COMPRAS_MODALITIES,
        max_pages: Optional[int] = 1,
        page_size: int = 10,
    ) -> RunMetrics:
        if page_size < 1 or page_size > 500:
            raise ValueError("tamanhoPagina deve estar entre 1 e 500 no Compras.gov")
        endpoint = "/modulo-contratacoes/1_consultarContratacoes_PNCP_14133"
        run_id = self.db.start_run(self.source_id, "INCREMENTAL", endpoint, start.isoformat(), end.isoformat())
        metrics = RunMetrics()
        last_params: Mapping[str, Any] = {}
        try:
            for modality in modalities:
                page = 1
                while True:
                    params = {
                        "pagina": page,
                        "tamanhoPagina": page_size,
                        "dataPublicacaoPncpInicial": start.isoformat(),
                        "dataPublicacaoPncpFinal": end.isoformat(),
                        "codigoModalidade": int(modality),
                    }
                    last_params = params
                    response = self.http.get(COMPRAS_BASE + endpoint, params=params)
                    metrics.pages += 1
                    metrics.latency_ms += response.duration_ms
                    wrapper = response.json() or {}
                    records = wrapper.get("resultado", [])
                    for record in records:
                        metrics.records_seen += 1
                        external_id = str(record.get("idCompra") or record.get("numeroControlePNCP"))
                        raw_id, status = self.db.store_raw(
                            source_id=self.source_id,
                            endpoint=endpoint,
                            request_url=response.url,
                            request_params=params,
                            http_status=response.status,
                            external_id=external_id,
                            entity_hint="procurement",
                            payload=record,
                            source_created_at=record.get("dataInclusaoPncp"),
                            source_updated_at=record.get("dataAtualizacaoPncp") or record.get("dataAualizacaoPncp"),
                        )
                        metrics.raw_status(status)
                        normalize_procurement(
                            self.db,
                            source_id=self.source_id,
                            raw_id=raw_id,
                            payload=record,
                            source_url=response.url,
                            flavor="compras",
                        )
                    total_pages = int(wrapper.get("totalPaginas") or 0)
                    if not records or page >= total_pages or (max_pages and page >= max_pages):
                        break
                    page += 1
            self.db.finish_run(run_id, **metrics.as_dict())
            return metrics
        except Exception as exc:
            metrics.errors += 1
            status = exc.status if isinstance(exc, PublicApiError) else None
            url = exc.url if isinstance(exc, PublicApiError) else COMPRAS_BASE + endpoint
            self.db.record_error(
                source_id=self.source_id,
                run_id=run_id,
                endpoint=endpoint,
                request_url=url,
                request_params=last_params,
                message=str(exc),
                http_status=status,
                retryable=(status is None or status == 429 or bool(status and status >= 500)),
            )
            self.db.finish_run(run_id, status="FAILED", error=str(exc), **metrics.as_dict())
            raise
