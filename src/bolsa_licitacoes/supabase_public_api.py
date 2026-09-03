from __future__ import annotations

import json
import re
import statistics
import threading
import time
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .market_search import MarketSearchEngine, QueryPlan, SearchDocument, SearchHit
from .market_search import normalize_text


UF_NAMES = {
    "AC": "Acre", "AL": "Alagoas", "AP": "Amapá", "AM": "Amazonas", "BA": "Bahia",
    "CE": "Ceará", "DF": "Distrito Federal", "ES": "Espírito Santo", "GO": "Goiás",
    "MA": "Maranhão", "MT": "Mato Grosso", "MS": "Mato Grosso do Sul", "MG": "Minas Gerais",
    "PA": "Pará", "PB": "Paraíba", "PR": "Paraná", "PE": "Pernambuco", "PI": "Piauí",
    "RJ": "Rio de Janeiro", "RN": "Rio Grande do Norte", "RS": "Rio Grande do Sul",
    "RO": "Rondônia", "RR": "Roraima", "SC": "Santa Catarina", "SP": "São Paulo",
    "SE": "Sergipe", "TO": "Tocantins",
}

SEMANTIC_GROUPS = {
    "material hospitalar": (
        "material hospitalar", "médico hospitalar", "insumo hospitalar", "ambulatorial",
        "cirúrgico", "seringa", "cateter", "luva", "equipo", "bomba de infusão",
    ),
    "medicamentos": (
        "medicamento", "fármaco", "antibiótico", "comprimido", "solução injetável",
        "ceftriaxona", "amoxicilina", "farmacêutico",
    ),
    "tecnologia": (
        "tecnologia", "informática", "software", "computador", "notebook", "servidor",
        "licença", "sistema de informação",
    ),
    "veículos e frota": (
        "veículo", "automóvel", "caminhão", "frota", "manutenção automotiva", "combustível", "pneu",
    ),
    "obras e engenharia": (
        "engenharia", "construção", "obra", "reforma", "manutenção predial", "infraestrutura",
    ),
    "alimentação": (
        "alimento", "gêneros alimentícios", "merenda", "refeição", "cesta básica", "nutrição",
    ),
    "limpeza": (
        "limpeza", "higiene", "saneante", "detergente", "desinfetante", "conservação",
    ),
    "molduras": (
        "moldura", "emolduramento", "quadro", "porta-retrato", "perfil de alumínio", "acabamento",
    ),
}


class SupabasePublicError(RuntimeError):
    pass


class SupabaseRestClient:
    def __init__(self, base_url: str, anon_key: str, timeout: float = 15.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.anon_key = anon_key
        self.timeout = timeout

    def get(
        self,
        resource: str,
        params: list[tuple[str, str]],
        *,
        profile: str = "public",
        count: bool = False,
    ) -> tuple[list[dict[str, Any]], Optional[int]]:
        query = urlencode(params, doseq=True, safe="(),.*:-_")
        request = Request(
            f"{self.base_url}/rest/v1/{resource}?{query}",
            headers={
                "Accept": "application/json",
                "Accept-Profile": profile,
                "apikey": self.anon_key,
                "Authorization": f"Bearer {self.anon_key}",
                **({"Prefer": "count=exact"} if count else {}),
            },
        )
        try:
            with urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8") or "[]")
                content_range = response.headers.get("Content-Range", "")
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:500]
            raise SupabasePublicError(f"Supabase HTTP {exc.code}: {detail}") from exc
        except (URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise SupabasePublicError(f"Supabase indisponível: {exc}") from exc
        if not isinstance(payload, list):
            raise SupabasePublicError("Resposta inesperada do Supabase")
        total: Optional[int] = None
        if "/" in content_range:
            raw_total = content_range.rsplit("/", 1)[-1]
            if raw_total.isdigit():
                total = int(raw_total)
        return payload, total


class SupabasePublicApi:
    def __init__(self, client: SupabaseRestClient) -> None:
        self.client = client
        self.search_engine = MarketSearchEngine()
        self._cache: dict[str, tuple[float, Any]] = {}
        self._cache_lock = threading.Lock()

    def market_summary(self) -> dict[str, Any]:
        def load() -> dict[str, Any]:
            rows, _ = self.client.get("bolsa_vw_resumo", [("select", "*"), ("limit", "1")])
            if not rows:
                raise SupabasePublicError("Resumo nacional vazio")
            row = rows[0]
            states, _ = self.client.get("bolsa_vw_por_uf", [("select", "uf")])
            latest = row.get("ultima_coleta_em")
            return {
                "procurements": _int(row.get("licitacoes")),
                "estimated_value": _float(row.get("valor_estimado_total")),
                "organizations": _int(row.get("orgaos")),
                "purchasing_units": _int(row.get("orgaos")),
                "states": len(states),
                "items": _int(row.get("itens")),
                "results": _int(row.get("resultados")),
                "contracts": _int(row.get("contratos")) + _int(row.get("contratos_gov")),
                "contracts_pncp": _int(row.get("contratos")),
                "contracts_gov": _int(row.get("contratos_gov")),
                "suppliers": _int(row.get("fornecedores")),
                "documents": _int(row.get("documentos")),
                "price_registry_atas": _int(row.get("atas")),
                "pca_items": _int(row.get("pca_itens")),
                "commitments": _int(row.get("empenhos")),
                "committed_value": _float(row.get("valor_empenhado_total")),
                "paid_value": _float(row.get("valor_pago_total")),
                "active_sources": _int(row.get("fontes_ativas")),
                "total_sources": _int(row.get("fontes_total")),
                "open_procurements": _int(row.get("recebendo_propostas")),
                "last_collected_at": latest,
                "data_source": "supabase-live",
                "latest_run": {
                    "status": "SUCCESS", "finished_at": latest, "records_seen": _int(row.get("licitacoes")),
                    "records_new": 0, "records_updated": 0, "errors": 0, "source_slug": "pncp",
                },
            }

        return self._cached("summary", 20, load)

    def state_summary(self) -> list[dict[str, Any]]:
        def load() -> list[dict[str, Any]]:
            rows, _ = self.client.get(
                "licitacoes",
                [("select", "uf,municipio_nome,orgao_cnpj,valor_total_estimado,last_seen_at"), ("limit", "1000")],
                profile="bolsa",
            )
            org_ids = sorted({str(row.get("orgao_cnpj")) for row in rows if row.get("orgao_cnpj")})
            org_names = self._organization_names(org_ids)
            grouped: dict[str, dict[str, Any]] = {}
            org_values: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
            for row in rows:
                uf = str(row.get("uf") or "").upper()
                if uf not in UF_NAMES:
                    continue
                bucket = grouped.setdefault(uf, {
                    "code": uf, "name": UF_NAMES[uf], "procurements": 0, "estimated_value": 0.0,
                    "organizations": set(), "cities": set(), "last_collected_at": None,
                })
                bucket["procurements"] += 1
                value = _float(row.get("valor_total_estimado"))
                bucket["estimated_value"] += value
                if row.get("orgao_cnpj"):
                    bucket["organizations"].add(str(row["orgao_cnpj"]))
                    org_values[uf][str(row["orgao_cnpj"])].append(value)
                if row.get("municipio_nome"):
                    bucket["cities"].add(str(row["municipio_nome"]))
                seen = row.get("last_seen_at")
                if seen and (not bucket["last_collected_at"] or str(seen) > str(bucket["last_collected_at"])):
                    bucket["last_collected_at"] = seen
            result = []
            for uf, bucket in grouped.items():
                top = sorted(
                    ((cnpj, len(values), sum(values)) for cnpj, values in org_values[uf].items()),
                    key=lambda item: (item[1], item[2]), reverse=True,
                )[:3]
                result.append({
                    **bucket,
                    "organizations": len(bucket["organizations"]),
                    "cities": len(bucket["cities"]),
                    "top_organizations": [
                        {"legal_name": org_names.get(cnpj, cnpj), "procurements": count, "estimated_value": value}
                        for cnpj, count, value in top
                    ],
                })
            return sorted(result, key=lambda row: (row["estimated_value"], row["procurements"]), reverse=True)

        return self._cached("states", 45, load)

    def search_suggestions(self, query: Mapping[str, list[str]]) -> dict[str, Any]:
        text = (_first(query, "q") or "").strip()[:80]
        normalized = normalize_text(text)
        if len(normalized) < 2:
            return {"query": text, "items": [], "data_source": "supabase-live"}

        def load_index() -> list[dict[str, Any]]:
            item_rows = self._all_rows(
                "itens", [("select", "descricao,catalogo_codigo,material_ou_servico")], maximum=5000,
            )
            procurement_rows = self._all_rows(
                "licitacoes", [("select", "objeto")], maximum=5000,
            )
            counts: Counter[tuple[str, str, str]] = Counter()
            for row in item_rows:
                label = " ".join(str(row.get("descricao") or "").split())[:160]
                if label:
                    counts[(label, "item", str(row.get("catalogo_codigo") or ""))] += 1
            for row in procurement_rows:
                label = " ".join(str(row.get("objeto") or "").split())[:160]
                if label:
                    counts[(label, "objeto", "")] += 1
            return [
                {"label": label, "type": kind, "catalog_code": code or None, "volume": volume}
                for (label, kind, code), volume in counts.most_common(2500)
            ]

        index = self._cached("search-suggestion-index", 60, load_index)
        terms = normalized.split()
        ranked = []
        for item in index:
            label = normalize_text(item["label"])
            coverage = sum(term in label for term in terms) / max(1, len(terms))
            if not coverage:
                continue
            starts = int(label.startswith(normalized))
            phrase = int(normalized in label)
            score = starts * 100 + phrase * 50 + coverage * 30 + min(20, item["volume"])
            ranked.append((score, len(label), item))
        ranked.sort(key=lambda value: (-value[0], value[1], -value[2]["volume"]))
        return {"query": text, "items": [item for _, _, item in ranked[:8]], "data_source": "supabase-live"}

    def search_debug(self, query: Mapping[str, list[str]]) -> dict[str, Any]:
        payload = self.list_procurements({**query, "limit": ["10"], "offset": ["0"], "facets": ["0"]})
        return {
            "search": payload.get("search"), "candidate_count": payload.get("total", 0),
            "top_results": [{
                "id": item.get("id"), "object": item.get("object"), "match_score": item.get("match_score"),
                "matched_fields": item.get("matched_fields"), "match_reasons": item.get("match_reasons"),
                "matched_items": item.get("matched_items"), "specification_warning": item.get("specification_warning"),
            } for item in payload.get("items", [])],
        }

    def list_procurements(self, query: Mapping[str, list[str]]) -> dict[str, Any]:
        started_at = time.monotonic()
        limit = _bounded_int(_first(query, "limit"), default=25, minimum=1, maximum=100)
        offset = _bounded_int(_first(query, "offset"), default=0, minimum=0, maximum=100_000)
        requested_ufs = [
            item.strip().upper()
            for item in (_first(query, "uf") or "").split(",")
            if item.strip().upper() in UF_NAMES
        ]
        text = (_first(query, "q") or "").strip()[:120]
        search_mode = (_first(query, "mode") or "balanced").strip().lower()
        city = (_first(query, "city") or "").strip()[:100]
        organization = (_first(query, "organization") or "").strip()[:120]
        supplier = (_first(query, "supplier") or "").strip()[:120]
        modality = (_first(query, "modality") or "").strip()[:120]
        catalog_code = (_first(query, "catalog") or "").strip()[:80]
        sort = (_first(query, "sort") or ("relevance" if text else "recent")).strip().lower()
        period = (_first(query, "period") or "").strip().lower()
        closing_within = _bounded_int(_first(query, "closing_within"), default=0, minimum=0, maximum=365)
        status = (_first(query, "status") or "").strip().lower()
        want_facets = (_first(query, "facets") or "").lower() in {"1", "true", "yes"}
        include_terms = _query_list(query, "include")
        should_terms = _query_list(query, "should")
        exclude_terms = _query_list(query, "exclude")
        exact_phrase = (_first(query, "exact_phrase") or "").strip()[:120]
        if exact_phrase:
            text = f'{text} "{exact_phrase}"'.strip()
        include_documents = (_first(query, "include_documents") or "").lower() in {"1", "true", "yes"}

        filters: list[tuple[str, str]] = []
        logical: list[str] = []
        if len(requested_ufs) == 1:
            filters.append(("uf", f"eq.{requested_ufs[0]}"))
        elif requested_ufs:
            filters.append(("uf", f"in.({','.join(requested_ufs)})"))
        if city:
            filters.append(("municipio_nome", f"ilike.*{_pg_token(city)}*"))
        if organization:
            org_ids = self._organization_ids(organization)
            if not org_ids:
                return self._empty_result(limit, offset, text, [], None, search_mode)
            filters.append(("orgao_cnpj", f"in.({','.join(org_ids)})"))
        if supplier:
            supplier_keys = self._supplier_procurement_keys(supplier)
            if not supplier_keys:
                return self._empty_result(limit, offset, text, [], None, search_mode)
            filters.append(("numero_controle_pncp", f"in.({','.join(supplier_keys)})"))
        if catalog_code:
            catalog_keys = self._catalog_procurement_keys(catalog_code)
            if not catalog_keys:
                return self._empty_result(limit, offset, text, [], None, search_mode)
            filters.append(("numero_controle_pncp", f"in.({','.join(catalog_keys)})"))
        if modality:
            modalities = [_pg_token(item) for item in modality.split(",") if _pg_token(item)]
            if len(modalities) == 1:
                filters.append(("modalidade_nome", f"ilike.*{modalities[0]}*"))
            elif modalities:
                filters.append(("or", f"({','.join(f'modalidade_nome.ilike.*{item}*' for item in modalities)})"))

        min_value = _optional_float(_first(query, "min_value"))
        max_value = _optional_float(_first(query, "max_value"))
        if min_value is not None:
            filters.append(("valor_total_estimado", f"gte.{min_value}"))
        if max_value is not None:
            filters.append(("valor_total_estimado", f"lte.{max_value}"))

        if period == "today":
            today = datetime.now(timezone.utc).date().isoformat()
            filters.append(("data_publicacao_pncp", f"gte.{today}T00:00:00Z"))
        elif _period_days(period):
            since = (datetime.now(timezone.utc) - timedelta(days=_period_days(period))).isoformat()
            filters.append(("data_publicacao_pncp", f"gte.{since}"))
        if _first(query, "from"):
            filters.append(("data_publicacao_pncp", f"gte.{_first(query, 'from')}"))
        if _first(query, "to"):
            filters.append(("data_publicacao_pncp", f"lte.{_first(query, 'to')}"))
        if closing_within:
            now = datetime.now(timezone.utc)
            filters.append(("data_encerramento_proposta", f"gte.{now.isoformat()}"))
            filters.append(("data_encerramento_proposta", f"lte.{(now + timedelta(days=closing_within)).isoformat()}"))

        if status == "open":
            logical.append("or(data_encerramento_proposta.is.null,data_encerramento_proposta.gte.now)")
        elif status == "published_today":
            today = datetime.now(timezone.utc).date().isoformat()
            filters.append(("data_publicacao_pncp", f"gte.{today}T00:00:00Z"))
        elif status == "failed":
            logical.append("or(situacao_nome.ilike.*desert*,situacao_nome.ilike.*fracass*)")
        elif status in {"results", "contracts"}:
            table, column = ("resultados_itens", "numero_controle_pncp") if status == "results" else ("contratos", "numero_controle_pncp_compra")
            related, _ = self.client.get(table, [("select", column), (column, "not.is.null"), ("limit", "1000")], profile="bolsa")
            keys = sorted({str(row.get(column)) for row in related if row.get(column)})
            if not keys:
                return self._empty_result(limit, offset, text, [], None, search_mode)
            filters.append(("numero_controle_pncp", f"in.({','.join(keys)})"))

        if len(logical) == 1:
            filters.append(("or", f"({logical[0][3:-1]})"))
        elif logical:
            filters.append(("and", f"({','.join(logical)})"))

        select = (
            "numero_controle_pncp,orgao_cnpj,unidade_codigo,numero_compra,processo,objeto,modalidade_nome,"
            "situacao_nome,data_abertura_proposta,data_encerramento_proposta,valor_total_estimado,"
            "valor_total_homologado,data_publicacao_pncp,source_updated_at,last_seen_at,uf,municipio_nome,"
            "link_sistema_origem"
        )
        cache_scope = {key: list(value) for key, value in query.items() if key not in {"limit", "offset", "sort", "facets"}}
        dataset_key = "search-dataset:" + json.dumps(cache_scope, ensure_ascii=False, sort_keys=True)

        def load_dataset():
            loaded_rows = self._all_rows("licitacoes", [("select", select), *filters])
            loaded_ncps = [str(row.get("numero_controle_pncp") or "") for row in loaded_rows if row.get("numero_controle_pncp")]
            loaded_items = self._related_rows(
                "itens", "numero_controle_pncp,numero_item,descricao,catalogo_codigo,material_ou_servico,"
                "quantidade,unidade,valor_unitario_estimado,valor_total_estimado", loaded_ncps,
            )
            loaded_org_ids = sorted({str(row.get("orgao_cnpj")) for row in loaded_rows if row.get("orgao_cnpj")})
            loaded_orgs = self._organization_names(loaded_org_ids)
            loaded_vocabulary = [
                *(str(row.get("objeto") or "") for row in loaded_rows),
                *(str(item.get("descricao") or "") for item in loaded_items),
            ]
            return loaded_rows, loaded_items, loaded_orgs, loaded_vocabulary

        candidate_rows, item_rows, org_names, vocabulary = self._cached(dataset_key, 20, load_dataset)
        items_by_ncp: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for item in item_rows:
            items_by_ncp[str(item.get("numero_controle_pncp") or "")].append(item)
        plan = self.search_engine.compile(
            text, mode=search_mode, include=include_terms, should=should_terms, exclude=exclude_terms,
            catalog_codes=[item for item in catalog_code.split(",") if item],
            include_documents=include_documents, vocabulary=vocabulary,
        )
        documents = [SearchDocument(
            procurement_id=str(row.get("numero_controle_pncp") or ""),
            object_text=str(row.get("objeto") or ""),
            process_text=f"{row.get('processo') or ''} {row.get('numero_controle_pncp') or ''}",
            organization_text=org_names.get(str(row.get("orgao_cnpj") or ""), ""),
            item_rows=items_by_ncp.get(str(row.get("numero_controle_pncp") or ""), []),
        ) for row in candidate_rows]
        search_active = bool(text or catalog_code or include_terms or should_terms or exclude_terms)
        ranked_hits = self.search_engine.search(plan, documents) if search_active else []
        hit_by_ncp = {hit.procurement_id: hit for hit in ranked_hits}
        row_by_ncp = {str(row.get("numero_controle_pncp") or ""): row for row in candidate_rows}
        matched_rows = ([row_by_ncp[hit.procurement_id] for hit in ranked_hits if hit.procurement_id in row_by_ncp]
                        if search_active else candidate_rows)
        if search_active and sort != "relevance":
            matched_keys = set(hit_by_ncp)
            matched_rows = _sort_procurement_rows(
                [row for row in candidate_rows if str(row.get("numero_controle_pncp") or "") in matched_keys], sort,
            )
        elif not search_active:
            matched_rows = _sort_procurement_rows(matched_rows, sort)
        total = len(matched_rows)
        page_rows = matched_rows[offset:offset + limit]
        terms = plan.retrieval_terms
        intent = plan.synonyms[0] if plan.synonyms else None
        items = self._enrich_procurements(page_rows, query=text, terms=terms, search_mode=plan.mode, hits=hit_by_ncp)
        facets = self._facets(
            filters, terms=terms, text=text, catalog_code=catalog_code, scope=query,
            rows_override=matched_rows, plan=plan if search_active else None,
        ) if want_facets else None
        return {
            "total": total, "limit": limit, "offset": offset, "items": items,
            "search": ({**plan.public_dict(), "intent": intent, "latency_ms": round((time.monotonic() - started_at) * 1000, 1)} if search_active else None),
            "facets": facets,
            "data_source": "supabase-live",
        }

    def procurement_detail(self, procurement_id: str) -> Optional[dict[str, Any]]:
        ncp = procurement_id.strip()[:100]
        rows, _ = self.client.get(
            "licitacoes", [("select", "*"), ("numero_controle_pncp", f"eq.{ncp}"), ("limit", "1")], profile="bolsa",
        )
        if not rows:
            return None
        row = rows[0]
        org_names = self._organization_names([str(row.get("orgao_cnpj"))] if row.get("orgao_cnpj") else [])
        unit_name = None
        if row.get("orgao_cnpj") and row.get("unidade_codigo"):
            units, _ = self.client.get(
                "unidades",
                [("select", "nome"), ("orgao_cnpj", f"eq.{row['orgao_cnpj']}"), ("codigo", f"eq.{row['unidade_codigo']}"), ("limit", "1")],
                profile="bolsa",
            )
            unit_name = units[0].get("nome") if units else None
        item_rows, _ = self.client.get("itens", [("select", "*"), ("numero_controle_pncp", f"eq.{ncp}"), ("order", "numero_item"), ("limit", "1000")], profile="bolsa")
        document_rows, _ = self.client.get("documentos", [("select", "*"), ("numero_controle_pncp", f"eq.{ncp}"), ("order", "sequencial_documento"), ("limit", "1000")], profile="bolsa")
        result_rows, _ = self.client.get("resultados_itens", [("select", "*"), ("numero_controle_pncp", f"eq.{ncp}"), ("order", "numero_item"), ("limit", "1000")], profile="bolsa")
        contract_rows, _ = self.client.get("contratos", [("select", "*"), ("numero_controle_pncp_compra", f"eq.{ncp}"), ("limit", "100")], profile="bolsa")
        source_url = row.get("link_sistema_origem") or _pncp_url(ncp)
        procurement = {
            "id": ncp, "pncp_control_number": ncp, "purchase_number": row.get("numero_compra"),
            "process_number": row.get("processo"), "object": row.get("objeto"),
            "modality_name": row.get("modalidade_nome"), "status_name": row.get("situacao_nome"),
            "proposal_start": row.get("data_abertura_proposta"), "proposal_end": row.get("data_encerramento_proposta"),
            "estimated_value": _float(row.get("valor_total_estimado")), "homologated_value": _float(row.get("valor_total_homologado")),
            "source_system": "pncp", "source_url": source_url, "source_created_at": row.get("data_publicacao_pncp"),
            "source_updated_at": row.get("source_updated_at"), "collected_at": row.get("last_seen_at"),
            "organization_name": org_names.get(str(row.get("orgao_cnpj")), row.get("orgao_cnpj")),
            "purchasing_unit_name": unit_name, "state_code": row.get("uf"), "city_name": row.get("municipio_nome"),
            "legal_basis": row.get("amparo_legal"), "additional_information": row.get("informacao_complementar"),
        }
        items = [{
            "id": item.get("id"), "item_number": item.get("numero_item"), "description": item.get("descricao"),
            "material_or_service": item.get("material_ou_servico"), "quantity": item.get("quantidade"),
            "unit": item.get("unidade"), "estimated_unit_value": item.get("valor_unitario_estimado"),
            "estimated_total_value": item.get("valor_total_estimado"), "status_name": item.get("situacao_fonte"),
            "has_result": item.get("tem_resultado"), "catalog_item_code": item.get("catalogo_codigo"),
        } for item in item_rows]
        documents = [{
            "id": document.get("id"), "original_name": document.get("titulo"),
            "document_type": document.get("tipo_documento"), "source_download_url": document.get("url"),
            "published_at": document.get("data_publicacao"), "download_status": "AVAILABLE", "current_version": 1,
        } for document in document_rows]
        results = [{
            "item_number": result.get("numero_item"), "supplier_id": result.get("fornecedor_ni"),
            "supplier_name": result.get("fornecedor_nome"), "quantity": result.get("quantidade_homologada"),
            "unit_value": result.get("valor_unitario_homologado"), "total_value": result.get("valor_total_homologado"),
            "discount_percent": result.get("percentual_desconto"), "result_date": result.get("data_resultado"),
        } for result in result_rows]
        contracts = [{
            "id": contract.get("numero_controle_pncp"), "pncp_control_number": contract.get("numero_controle_pncp"),
            "contract_number": contract.get("numero_contrato"), "object": contract.get("objeto"),
            "initial_value": contract.get("valor_inicial"), "current_value": contract.get("valor_global"),
            "supplier_name": contract.get("fornecedor_nome"), "signed_at": contract.get("data_assinatura"),
            "validity_start": contract.get("vigencia_inicio"), "validity_end": contract.get("vigencia_fim"),
        } for contract in contract_rows]
        return {
            "procurement": procurement, "items": items, "documents": documents, "results": results,
            "sources": [{"nome": "Portal Nacional de Contratações Públicas", "slug": "pncp", "source_url": source_url, "collected_at": row.get("last_seen_at")}],
            "contracts": contracts, "data_source": "supabase-live",
        }

    def source_status(self) -> list[dict[str, Any]]:
        def load() -> list[dict[str, Any]]:
            sources, _ = self.client.get("fontes", [("select", "id,nome,status,ultimo_sucesso_em,capabilities"), ("order", "nome")], profile="bolsa")
            logs, _ = self.client.get("coleta_log", [("select", "fonte_id,job,finalizado_em,registros,inseridos,atualizados,erros"), ("order", "iniciado_em.desc"), ("limit", "100")], profile="bolsa")
            latest: dict[str, dict[str, Any]] = {}
            for log in logs:
                latest.setdefault(str(log.get("fonte_id")), log)
            result = []
            for source in sources:
                source_id = str(source.get("id"))
                log = latest.get(source_id, {})
                active = source.get("status") == "ATIVA"
                result.append({
                    "nome": source.get("nome"), "slug": source_id.replace("_", "-"),
                    "status": "OPERANDO" if active else source.get("status"),
                    "source_status": source.get("status"), "capabilities": source.get("capabilities") or {},
                    "ultima_tentativa": log.get("finalizado_em"), "ultima_coleta_sucesso": source.get("ultimo_sucesso_em"),
                    "quantidade_registros": _int(log.get("registros")), "quantidade_erros": _int(log.get("erros")),
                    "last_run_status": "SUCCESS" if active else source.get("status"),
                    "last_records_seen": _int(log.get("registros")), "last_records_new": _int(log.get("inseridos")),
                    "last_finished_at": log.get("finalizado_em") or source.get("ultimo_sucesso_em"),
                })
            return result

        return self._cached("sources", 25, load)

    def _enrich_procurements(
        self, rows: list[dict[str, Any]], *, query: str = "", terms: Optional[list[str]] = None,
        search_mode: str = "balanced", hits: Optional[Mapping[str, SearchHit]] = None,
    ) -> list[dict[str, Any]]:
        ncps = [str(row.get("numero_controle_pncp")) for row in rows if row.get("numero_controle_pncp")]
        org_ids = sorted({str(row.get("orgao_cnpj")) for row in rows if row.get("orgao_cnpj")})
        org_names = self._organization_names(org_ids)
        item_counts = self._related_counts("itens", ncps)
        document_counts = self._related_counts("documentos", ncps)
        result = []
        for row in rows:
            ncp = str(row.get("numero_controle_pncp") or "")
            object_text = str(row.get("objeto") or "")
            hit = hits.get(ncp) if hits else None
            match_reason = hit.match_reasons[0] if hit and hit.match_reasons else None
            if query and not hit:
                if _fold(query) in _fold(object_text):
                    match_reason = f'O objeto contém a busca "{query}".'
                elif any(_fold(term) in _fold(object_text) for term in (terms or [])):
                    match_reason = "O objeto contém um termo relacionado interpretado pela busca inteligente."
                elif search_mode == "exact":
                    match_reason = "Um item, órgão ou identificador vinculado corresponde à busca exata."
                else:
                    match_reason = "Um item ou órgão vinculado corresponde a um termo semanticamente relacionado."
            result.append({
                "id": ncp, "pncp_control_number": ncp, "purchase_number": row.get("numero_compra"),
                "process_number": row.get("processo"), "object": row.get("objeto"),
                "modality_name": row.get("modalidade_nome"), "status_name": row.get("situacao_nome"),
                "proposal_start": row.get("data_abertura_proposta"), "proposal_end": row.get("data_encerramento_proposta"),
                "estimated_value": _float(row.get("valor_total_estimado")), "homologated_value": _float(row.get("valor_total_homologado")),
                "source_system": "pncp", "source_url": row.get("link_sistema_origem") or _pncp_url(ncp),
                "source_created_at": row.get("data_publicacao_pncp"), "source_updated_at": row.get("source_updated_at"),
                "collected_at": row.get("last_seen_at"),
                "organization_name": org_names.get(str(row.get("orgao_cnpj")), row.get("orgao_cnpj") or "Órgão não informado"),
                "purchasing_unit_name": None, "state_code": row.get("uf"), "city_name": row.get("municipio_nome"),
                "items_count": item_counts.get(ncp, 0), "documents_count": document_counts.get(ncp, 0),
                "match_reason": match_reason,
                "match_score": hit.match_score if hit else None,
                "matched_items_count": hit.matched_items_count if hit else 0,
                "matched_items": hit.matched_items if hit else [],
                "matched_fields": hit.matched_fields if hit else [],
                "match_reasons": hit.match_reasons if hit else [],
                "highlights": hit.highlights if hit else [],
                "specification_warning": hit.specification_warning if hit else None,
            })
        return result

    def _organization_names(self, ids: list[str]) -> dict[str, str]:
        if not ids:
            return {}
        rows, _ = self.client.get(
            "orgaos", [("select", "cnpj,razao_social"), ("cnpj", f"in.({','.join(ids[:500])})"), ("limit", "500")], profile="bolsa",
        )
        return {str(row.get("cnpj")): str(row.get("razao_social") or row.get("cnpj")) for row in rows}

    def _organization_ids(self, search: str) -> list[str]:
        clean = search.strip()
        if re.fullmatch(r"\d{14}", clean):
            return [clean]
        terms = [_pg_token(item) for item in clean.split(",") if _pg_token(item)]
        conditions = ",".join(f"razao_social.ilike.*{term}*" for term in terms[:5])
        rows, _ = self.client.get(
            "orgaos", [("select", "cnpj"), ("or", f"({conditions})"), ("limit", "500")], profile="bolsa",
        )
        return sorted({str(row.get("cnpj")) for row in rows if row.get("cnpj")})

    def _supplier_procurement_keys(self, search: str) -> list[str]:
        clean = _pg_token(search)
        conditions = [f"fornecedor_nome.ilike.*{clean}*"]
        if re.fullmatch(r"\d{11,14}", search.strip()):
            conditions.append(f"fornecedor_ni.eq.{search.strip()}")
        rows, _ = self.client.get(
            "resultados_itens",
            [("select", "numero_controle_pncp"), ("or", f"({','.join(conditions)})"), ("limit", "1000")],
            profile="bolsa",
        )
        return sorted({str(row.get("numero_controle_pncp")) for row in rows if row.get("numero_controle_pncp")})

    def _catalog_procurement_keys(self, search: str) -> list[str]:
        codes = [_pg_token(item) for item in search.split(",") if _pg_token(item)]
        conditions = ",".join(f"catalogo_codigo.eq.{code}" for code in codes[:20])
        rows, _ = self.client.get(
            "itens",
            [("select", "numero_controle_pncp"), ("or", f"({conditions})"), ("limit", "1000")],
            profile="bolsa",
        )
        return sorted({str(row.get("numero_controle_pncp")) for row in rows if row.get("numero_controle_pncp")})

    def _related_counts(self, table: str, ncps: list[str]) -> Counter[str]:
        if not ncps:
            return Counter()
        rows, _ = self.client.get(
            table,
            [("select", "numero_controle_pncp"), ("numero_controle_pncp", f"in.({','.join(ncps)})"), ("limit", "1000")],
            profile="bolsa",
        )
        return Counter(str(row.get("numero_controle_pncp")) for row in rows if row.get("numero_controle_pncp"))

    def _search_related_keys(self, terms: list[str]) -> list[str]:
        if not terms:
            return []
        item_conditions = ",".join(f"descricao.ilike.*{_pg_token(term)}*" for term in terms)
        item_rows, _ = self.client.get(
            "itens", [("select", "numero_controle_pncp"), ("or", f"({item_conditions})"), ("limit", "1000")], profile="bolsa",
        )
        org_conditions = ",".join(f"razao_social.ilike.*{_pg_token(term)}*" for term in terms[:5])
        org_rows, _ = self.client.get(
            "orgaos", [("select", "cnpj"), ("or", f"({org_conditions})"), ("limit", "200")], profile="bolsa",
        )
        org_ids = [str(row.get("cnpj")) for row in org_rows if row.get("cnpj")]
        keys = {str(row.get("numero_controle_pncp")) for row in item_rows if row.get("numero_controle_pncp")}
        if org_ids:
            org_lics, _ = self.client.get(
                "licitacoes", [("select", "numero_controle_pncp"), ("orgao_cnpj", f"in.({','.join(org_ids)})"), ("limit", "1000")], profile="bolsa",
            )
            keys.update(str(row.get("numero_controle_pncp")) for row in org_lics if row.get("numero_controle_pncp"))
        return sorted(keys)[:300]

    def _facets(
        self, filters: list[tuple[str, str]], *, terms: list[str], text: str, catalog_code: str,
        scope: Mapping[str, list[str]], rows_override: Optional[list[dict[str, Any]]] = None,
        plan: Optional[QueryPlan] = None,
    ) -> dict[str, Any]:
        rows = rows_override if rows_override is not None else self._all_rows(
            "licitacoes",
            [("select", "numero_controle_pncp,uf,municipio_nome,orgao_cnpj,modalidade_nome,situacao_nome,"
                        "valor_total_estimado,data_publicacao_pncp,data_encerramento_proposta") , *filters],
        )
        matches_scope_text = lambda value: self.search_engine.matches_text(plan, value) if plan else _matches_terms(value, terms)
        states: dict[str, dict[str, Any]] = {}
        cities: dict[tuple[str, str], dict[str, Any]] = {}
        org_stats: dict[str, dict[str, Any]] = {}
        modalities: Counter[str] = Counter()
        statuses: Counter[str] = Counter()
        timeline: dict[str, dict[str, Any]] = {}
        now = datetime.now(timezone.utc)
        new_since = now - timedelta(days=7)
        open_count = new_count = failed_count = 0
        for row in rows:
            code = str(row.get("uf") or "").upper()
            if code not in UF_NAMES:
                continue
            state = states.setdefault(code, {
                "code": code, "name": UF_NAMES[code], "procurements": 0, "estimated_value": 0.0,
                "organizations": set(), "city_names": set(), "organization_stats": {},
            })
            state["procurements"] += 1
            value = _float(row.get("valor_total_estimado"))
            state["estimated_value"] += value
            if row.get("orgao_cnpj"):
                org_id = str(row["orgao_cnpj"])
                state["organizations"].add(org_id)
                state_org = state["organization_stats"].setdefault(org_id, {"procurements": 0, "estimated_value": 0.0})
                state_org["procurements"] += 1
                state_org["estimated_value"] += value
                org = org_stats.setdefault(org_id, {"procurements": 0, "estimated_value": 0.0})
                org["procurements"] += 1
                org["estimated_value"] += value
            city_name = str(row.get("municipio_nome") or "").strip()
            if city_name:
                state["city_names"].add(city_name)
                city = cities.setdefault((code, city_name), {"name": city_name, "state_code": code, "procurements": 0, "estimated_value": 0.0})
                city["procurements"] += 1
                city["estimated_value"] += value
            if row.get("modalidade_nome"):
                modalities[str(row["modalidade_nome"])] += 1
            if row.get("situacao_nome"):
                statuses[str(row["situacao_nome"])] += 1
                folded_status = _fold(str(row["situacao_nome"]))
                if "desert" in folded_status or "fracass" in folded_status:
                    failed_count += 1
            end_at = _parse_datetime(row.get("data_encerramento_proposta"))
            if end_at is None or end_at >= now:
                open_count += 1
            published_at = _parse_datetime(row.get("data_publicacao_pncp"))
            if published_at:
                if published_at >= new_since:
                    new_count += 1
                month = published_at.strftime("%Y-%m")
                point = timeline.setdefault(month, {"month": month, "procurements": 0, "estimated_value": 0.0})
                point["procurements"] += 1
                point["estimated_value"] += value

        organizations = sorted(org_stats)
        org_names = self._organization_names(organizations)
        top_organizations = sorted(({
            "id": org_id, "name": org_names.get(org_id, org_id), **stats,
        } for org_id, stats in org_stats.items()), key=lambda item: (item["estimated_value"], item["procurements"]), reverse=True)[:10]
        ncps = [str(row.get("numero_controle_pncp")) for row in rows if row.get("numero_controle_pncp")]
        item_rows = self._related_rows(
            "itens", "numero_controle_pncp,descricao,quantidade,unidade,valor_unitario_estimado,"
            "valor_total_estimado,catalogo_codigo,material_ou_servico", ncps,
        )
        matching_items = [
            row for row in item_rows
            if (text and (self.search_engine.matches_text(plan, str(row.get("descricao") or "")) if plan else _matches_terms(str(row.get("descricao") or ""), terms)))
            or (catalog_code and str(row.get("catalogo_codigo") or "") in catalog_code.split(","))
        ]
        price_groups: dict[tuple[str, str], list[float]] = defaultdict(list)
        quantities: dict[tuple[str, str], float] = defaultdict(float)
        group_labels: dict[tuple[str, str], str] = {}
        for item in matching_items:
            unit = _normalize_unit(item.get("unidade"))
            description = " ".join(str(item.get("descricao") or "Item sem descrição").split())
            catalog = str(item.get("catalogo_codigo") or "").strip()
            specification = f"CATÁLOGO {catalog}" if catalog else _description_signature(description)
            group = (specification, unit)
            group_labels[group] = description[:180]
            price = _float(item.get("valor_unitario_estimado"))
            if price > 0:
                price_groups[group].append(price)
            quantities[group] += _float(item.get("quantidade"))
        dominant_group = max(price_groups, key=lambda group: len(price_groups[group]), default=None)
        dominant_prices = price_groups.get(dominant_group, []) if dominant_group else []
        dominant_unit = dominant_group[1] if dominant_group else None
        price_available = len(dominant_prices) >= 2
        price_summary = {
            "available": price_available, "unit": dominant_unit,
            "basis": group_labels.get(dominant_group) if dominant_group else None,
            "samples": len(dominant_prices), "quantity": quantities.get(dominant_group, 0.0) if dominant_group else 0.0,
            "average": statistics.fmean(dominant_prices) if dominant_prices else None,
            "median": statistics.median(dominant_prices) if dominant_prices else None,
            "minimum": min(dominant_prices) if dominant_prices else None,
            "maximum": max(dominant_prices) if dominant_prices else None,
            "groups": [{"basis": group_labels.get(group), "unit": group[1], "samples": len(values)} for group, values in sorted(price_groups.items(), key=lambda item: len(item[1]), reverse=True)[:5]],
            "note": (
                f"Calculado apenas para a especificação comparável predominante em {dominant_unit}; outras descrições e unidades foram separadas."
                if price_available else "São necessárias ao menos duas amostras com a mesma especificação e unidade neste escopo."
            ),
        }

        result_rows = self._related_rows(
            "resultados_itens", "numero_controle_pncp,fornecedor_ni,fornecedor_nome,valor_total_homologado,"
            "valor_unitario_homologado,quantidade_homologada,percentual_desconto", ncps,
        )
        supplier_stats: dict[str, dict[str, Any]] = {}
        for result in result_rows:
            supplier_id = str(result.get("fornecedor_ni") or result.get("fornecedor_nome") or "Não informado")
            supplier_stat = supplier_stats.setdefault(supplier_id, {
                "id": supplier_id, "name": result.get("fornecedor_nome") or supplier_id,
                "wins": 0, "homologated_value": 0.0, "discounts": [],
            })
            supplier_stat["wins"] += 1
            supplier_stat["homologated_value"] += _float(result.get("valor_total_homologado"))
            if result.get("percentual_desconto") is not None:
                supplier_stat["discounts"].append(_float(result.get("percentual_desconto")))
        top_suppliers = []
        for supplier_stat in sorted(supplier_stats.values(), key=lambda item: (item["homologated_value"], item["wins"]), reverse=True)[:10]:
            discounts = supplier_stat.pop("discounts")
            supplier_stat["average_discount"] = statistics.fmean(discounts) if discounts else None
            top_suppliers.append(supplier_stat)

        requested_states = {item.strip().upper() for item in (_first(scope, "uf") or "").split(",") if item.strip()}
        requested_city = _fold(_first(scope, "city") or "")
        requested_org = _fold(_first(scope, "organization") or "")
        requested_supplier = _fold(_first(scope, "supplier") or "")
        min_scope_value = _optional_float(_first(scope, "min_value"))
        max_scope_value = _optional_float(_first(scope, "max_value"))
        scope_days = _period_days(_first(scope, "period") or "")
        scope_since = now - timedelta(days=scope_days) if scope_days else None
        selected_ncps = set(ncps)

        all_contract_rows = self._all_rows(
            "contratos", [("select", "numero_controle_pncp_compra,numero_contrato,objeto,orgao_cnpj,fornecedor_nome,"
                                      "valor_global,valor_inicial,data_assinatura,vigencia_fim,uf,municipio_nome")],
        )
        contract_rows = []
        for contract in all_contract_rows:
            object_searchable = str(contract.get("objeto") or "")
            if text and str(contract.get("numero_controle_pncp_compra") or "") not in selected_ncps and not matches_scope_text(object_searchable):
                continue
            if requested_states and str(contract.get("uf") or "").upper() not in requested_states:
                continue
            if requested_city and requested_city not in _fold(str(contract.get("municipio_nome") or "")):
                continue
            if requested_org and requested_org not in _fold(f"{contract.get('orgao_cnpj') or ''} {org_names.get(str(contract.get('orgao_cnpj')), '')}"):
                continue
            if requested_supplier and requested_supplier not in _fold(str(contract.get("fornecedor_nome") or "")):
                continue
            contract_value = _float(contract.get("valor_global") or contract.get("valor_inicial"))
            if min_scope_value is not None and contract_value < min_scope_value:
                continue
            if max_scope_value is not None and contract_value > max_scope_value:
                continue
            if scope_since and (_parse_datetime(contract.get("data_assinatura")) or datetime.min.replace(tzinfo=timezone.utc)) < scope_since:
                continue
            contract_rows.append(contract)

        gov_geography_unavailable = bool(requested_states or requested_city)
        government_contracts = []
        if not gov_geography_unavailable:
            all_government_contracts = self._all_rows(
                "contratos_gov", [("select", "id_fonte,numero,orgao_nome,uasg_nome,fornecedor_nome,objeto,categoria,"
                                               "vigencia_inicio,vigencia_fim,valor_global,valor_inicial,situacao")],
            )
            for contract in all_government_contracts:
                object_searchable = " ".join(str(contract.get(key) or "") for key in ("objeto", "categoria"))
                organization_searchable = " ".join(str(contract.get(key) or "") for key in ("orgao_nome", "uasg_nome"))
                if text and not matches_scope_text(object_searchable):
                    continue
                if requested_org and requested_org not in _fold(organization_searchable):
                    continue
                if requested_supplier and requested_supplier not in _fold(str(contract.get("fornecedor_nome") or "")):
                    continue
                contract_value = _float(contract.get("valor_global") or contract.get("valor_inicial"))
                if min_scope_value is not None and contract_value < min_scope_value:
                    continue
                if max_scope_value is not None and contract_value > max_scope_value:
                    continue
                if scope_since and (_parse_datetime(contract.get("vigencia_inicio")) or datetime.min.replace(tzinfo=timezone.utc)) < scope_since:
                    continue
                government_contracts.append(contract)
        expiring_limit = now + timedelta(days=180)
        expiring_contracts = []
        for contract in contract_rows:
            end_at = _parse_datetime(contract.get("vigencia_fim"))
            if end_at and now <= end_at <= expiring_limit:
                expiring_contracts.append({
                    "number": contract.get("numero_contrato"), "object": contract.get("objeto"),
                    "supplier": contract.get("fornecedor_nome"), "value": _float(contract.get("valor_global") or contract.get("valor_inicial")),
                    "validity_end": contract.get("vigencia_fim"), "state_code": contract.get("uf"), "city": contract.get("municipio_nome"),
                })
        for contract in government_contracts:
            end_at = _parse_datetime(contract.get("vigencia_fim"))
            if end_at and now <= end_at <= expiring_limit:
                expiring_contracts.append({
                    "number": contract.get("numero"), "object": contract.get("objeto"),
                    "supplier": contract.get("fornecedor_nome"), "value": _float(contract.get("valor_global") or contract.get("valor_inicial")),
                    "validity_end": contract.get("vigencia_fim"), "state_code": None, "city": None,
                })
        expiring_contracts.sort(key=lambda item: str(item.get("validity_end") or ""))

        all_ata_rows = self._all_rows(
            "atas", [("select", "numero_controle_pncp_compra,numero_controle_pncp_ata,numero_ata,objeto,orgao_cnpj,"
                                  "uf,municipio_nome,data_assinatura,vigencia_fim,cancelado")],
        )
        ata_rows = []
        for ata in all_ata_rows:
            if text and str(ata.get("numero_controle_pncp_compra") or "") not in selected_ncps and not matches_scope_text(str(ata.get("objeto") or "")):
                continue
            if requested_states and str(ata.get("uf") or "").upper() not in requested_states:
                continue
            if requested_city and requested_city not in _fold(str(ata.get("municipio_nome") or "")):
                continue
            if requested_org and requested_org not in _fold(f"{ata.get('orgao_cnpj') or ''} {org_names.get(str(ata.get('orgao_cnpj')), '')}"):
                continue
            if scope_since and (_parse_datetime(ata.get("data_assinatura")) or datetime.min.replace(tzinfo=timezone.utc)) < scope_since:
                continue
            ata_rows.append(ata)
        active_atas = [row for row in ata_rows if not row.get("cancelado")]
        expiring_atas = []
        for ata in active_atas:
            end_at = _parse_datetime(ata.get("vigencia_fim"))
            if end_at and now <= end_at <= expiring_limit:
                expiring_atas.append({
                    "number": ata.get("numero_ata") or ata.get("numero_controle_pncp_ata"),
                    "object": ata.get("objeto"), "validity_end": ata.get("vigencia_fim"),
                    "state_code": ata.get("uf"), "city": ata.get("municipio_nome"),
                })
        expiring_atas.sort(key=lambda item: str(item.get("validity_end") or ""))

        pca_rows = self._all_rows(
            "pca_itens",
            [("select", "id,orgao_cnpj,ano_pca,descricao,categoria_nome,quantidade,valor_total,data_desejada,catalogo_codigo")],
        )
        scoped_orgs = set(organizations)
        future_items = []
        for item in pca_rows:
            if scoped_orgs and str(item.get("orgao_cnpj") or "") not in scoped_orgs:
                continue
            if text and not matches_scope_text(f"{item.get('descricao') or ''} {item.get('categoria_nome') or ''}"):
                continue
            future_items.append({
                "id": item.get("id"), "description": item.get("descricao"), "category": item.get("categoria_nome"),
                "quantity": _float(item.get("quantidade")), "estimated_value": _float(item.get("valor_total")),
                "desired_at": item.get("data_desejada"), "catalog_code": item.get("catalogo_codigo"),
                "organization_name": org_names.get(str(item.get("orgao_cnpj")), item.get("orgao_cnpj")),
            })
        future_items.sort(key=lambda item: item["estimated_value"], reverse=True)

        return {
            "states": sorted(({
                "code": state["code"], "name": state["name"], "procurements": state["procurements"],
                "estimated_value": state["estimated_value"], "organizations": len(state["organizations"]),
                "cities": len(state["city_names"]), "last_collected_at": None,
                "top_organizations": [{"legal_name": org_names.get(org_id, org_id), **stats} for org_id, stats in sorted(
                    state["organization_stats"].items(), key=lambda item: (item[1]["estimated_value"], item[1]["procurements"]), reverse=True,
                )[:3]],
            } for state in states.values()), key=lambda state: state["procurements"], reverse=True),
            "organizations": len(organizations), "estimated_value": sum(_float(row.get("valor_total_estimado")) for row in rows),
            "open_procurements": open_count, "new_procurements": new_count, "failed_procurements": failed_count,
            "cities": sorted(cities.values(), key=lambda item: (item["estimated_value"], item["procurements"]), reverse=True)[:12],
            "top_organizations": top_organizations,
            "modalities": [{"name": name, "procurements": count} for name, count in modalities.most_common(10)],
            "statuses": [{"name": name, "procurements": count} for name, count in statuses.most_common(10)],
            "timeline": [timeline[key] for key in sorted(timeline)[-24:]],
            "prices": price_summary,
            "top_suppliers": top_suppliers,
            "results_count": len(result_rows),
            "contracts": {
                "count": len(contract_rows) + len(government_contracts),
                "pncp_count": len(contract_rows), "federal_count": len(government_contracts),
                "value": sum(_float(row.get("valor_global") or row.get("valor_inicial")) for row in [*contract_rows, *government_contracts]),
                "expiring": expiring_contracts[:12],
            },
            "atas": {"count": len(active_atas), "expiring": expiring_atas[:12]},
            "pca": {"count": len(future_items), "items": future_items[:12]},
            "availability": {
                "competition": {"available": False, "reason": "A fonte atual não publica o histórico completo de participantes e lances para este recorte."},
                "suppliers": {"available": bool(result_rows), "reason": None if result_rows else "Ainda não há resultados homologados vinculados neste escopo."},
                "prices": {"available": price_available, "reason": price_summary["note"]},
                "pca": {"available": bool(future_items), "reason": None if future_items else "Nenhum item de PCA relacionado foi localizado no escopo atual."},
                "federal_contracts": {
                    "available": not gov_geography_unavailable,
                    "reason": "Contratos.gov não fornece UF/município neste conjunto; os contratos federais foram excluídos do recorte geográfico."
                    if gov_geography_unavailable else None,
                },
            },
            "records_sampled": len(rows),
        }

    def _all_rows(self, resource: str, params: list[tuple[str, str]], *, maximum: int = 5000) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        batch = 1000
        while len(rows) < maximum:
            page, _ = self.client.get(
                resource, [*params, ("limit", str(min(batch, maximum - len(rows)))), ("offset", str(len(rows)))], profile="bolsa",
            )
            rows.extend(page)
            if len(page) < batch:
                break
        return rows

    def _related_rows(
        self, resource: str, select: str, ncps: list[str], *, key: str = "numero_controle_pncp",
    ) -> list[dict[str, Any]]:
        if not ncps:
            return []
        if len(ncps) > 100:
            selected = set(ncps)
            return [row for row in self._all_rows(resource, [("select", select)]) if str(row.get(key) or "") in selected]
        rows: list[dict[str, Any]] = []
        for start in range(0, len(ncps), 60):
            batch = ncps[start:start + 60]
            page, _ = self.client.get(
                resource, [("select", select), (key, f"in.({','.join(batch)})"), ("limit", "1000")], profile="bolsa",
            )
            rows.extend(page)
        return rows

    def _empty_result(
        self, limit: int, offset: int, text: str, terms: list[str], intent: Optional[str], search_mode: str = "smart",
    ) -> dict[str, Any]:
        return {
            "total": 0, "limit": limit, "offset": offset, "items": [],
            "search": ({"query": text, "mode": search_mode, "intent": intent, "terms": terms} if text else None),
            "facets": {
                "states": [], "organizations": 0, "estimated_value": 0, "open_procurements": 0,
                "new_procurements": 0, "failed_procurements": 0, "cities": [], "top_organizations": [],
                "modalities": [], "statuses": [], "timeline": [], "top_suppliers": [], "results_count": 0,
                "prices": {"available": False, "unit": None, "samples": 0, "quantity": 0, "average": None,
                           "median": None, "minimum": None, "maximum": None, "groups": [],
                           "note": "Nenhum resultado encontrado para este contexto."},
                "contracts": {"count": 0, "pncp_count": 0, "federal_count": 0, "value": 0, "expiring": []},
                "atas": {"count": 0, "expiring": []},
                "pca": {"count": 0, "items": []},
                "availability": {
                    "competition": {"available": False, "reason": "Sem dados neste escopo."},
                    "suppliers": {"available": False, "reason": "Sem resultados homologados neste escopo."},
                    "prices": {"available": False, "reason": "Sem preços comparáveis neste escopo."},
                    "pca": {"available": False, "reason": "Sem itens de PCA neste escopo."},
                    "federal_contracts": {"available": False, "reason": "Sem dados neste escopo."},
                },
                "records_sampled": 0,
            },
            "data_source": "supabase-live",
        }

    def _cached(self, key: str, ttl: int, loader):
        now = time.monotonic()
        with self._cache_lock:
            cached = self._cache.get(key)
            if cached and cached[0] > now:
                return cached[1]
            value = loader()
            self._cache[key] = (now + ttl, value)
        return value


def expand_search_terms(query: str) -> tuple[list[str], Optional[str]]:
    clean = " ".join(query.strip().lower().split())
    if not clean:
        return [], None
    normalized = _fold(clean)
    selected: list[str] = [clean]
    intent: Optional[str] = None
    for group, terms in SEMANTIC_GROUPS.items():
        candidates = (group, *terms)
        if any(_fold(candidate) in normalized or normalized in _fold(candidate) for candidate in candidates):
            intent = group
            selected.extend(terms)
            break
    if len(clean.split()) > 1:
        selected.extend(word for word in clean.split() if len(word) >= 4)
    unique = []
    seen = set()
    for term in selected:
        term = " ".join(term.split())[:60]
        marker = _fold(term)
        if marker and marker not in seen:
            seen.add(marker)
            unique.append(term)
    return unique[:12], intent


def _fold(value: str) -> str:
    import unicodedata
    return "".join(ch for ch in unicodedata.normalize("NFD", value) if unicodedata.category(ch) != "Mn").lower()


def _pg_token(value: str) -> str:
    return re.sub(r"[(),.*]", " ", value).strip()[:60]


def _query_list(query: Mapping[str, list[str]], key: str) -> list[str]:
    values: list[str] = []
    for raw in query.get(key, []):
        values.extend(item.strip() for item in str(raw).split(",") if item.strip())
    return values[:30]


def _sort_procurement_rows(rows: list[dict[str, Any]], sort: str) -> list[dict[str, Any]]:
    if sort == "value":
        return sorted(rows, key=lambda row: (_float(row.get("valor_total_estimado")), str(row.get("data_publicacao_pncp") or "")), reverse=True)
    if sort == "deadline":
        return sorted(rows, key=lambda row: (not bool(row.get("data_encerramento_proposta")), str(row.get("data_encerramento_proposta") or "9999")))
    return sorted(rows, key=lambda row: (str(row.get("data_publicacao_pncp") or ""), str(row.get("last_seen_at") or "")), reverse=True)


def _matches_terms(value: str, terms: list[str]) -> bool:
    folded = _fold(value)
    return any(_fold(term) in folded for term in terms if term)


def _normalize_unit(value: Any) -> str:
    unit = " ".join(str(value or "NÃO INFORMADA").upper().split())
    aliases = {
        "UN": "UNIDADE", "UND": "UNIDADE", "UNID": "UNIDADE", "UNIDADE(S)": "UNIDADE",
        "CX": "CAIXA", "PCT": "PACOTE", "KG.": "KG", "L": "LITRO", "LT": "LITRO",
    }
    return aliases.get(unit, unit)[:60]


def _description_signature(value: str) -> str:
    words = re.findall(r"[a-z0-9]+", _fold(value))
    ignored = {"de", "da", "do", "das", "dos", "para", "com", "sem", "em", "e", "a", "o"}
    meaningful = [word for word in words if word not in ignored]
    return " ".join(meaningful[:10]) or "item-sem-especificacao"


def _parse_datetime(value: Any) -> Optional[datetime]:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except (TypeError, ValueError):
        return None


def _period_days(value: str) -> int:
    clean = value.strip().lower()
    if clean.endswith("m") and clean[:-1].isdigit():
        return max(1, min(3650, int(clean[:-1]) * 30))
    if clean.endswith("y") and clean[:-1].isdigit():
        return max(1, min(3650, int(clean[:-1]) * 365))
    if clean.isdigit():
        return max(1, min(3650, int(clean)))
    return 0


def _pncp_url(ncp: str) -> str:
    match = re.match(r"(\d{14})-\d+-(\d+)/(\d{4})$", ncp)
    if not match:
        return "https://pncp.gov.br/app/editais"
    cnpj, sequence, year = match.groups()
    return f"https://pncp.gov.br/app/editais/{cnpj}/{year}/{int(sequence)}"


def _first(query: Mapping[str, list[str]], key: str) -> Optional[str]:
    values = query.get(key)
    return values[0] if values else None


def _bounded_int(value: Optional[str], *, default: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value) if value is not None else default
    except (TypeError, ValueError):
        parsed = default
    return max(minimum, min(maximum, parsed))


def _int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _float(value: Any) -> float:
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def _optional_float(value: Optional[str]) -> Optional[float]:
    if value is None or not str(value).strip():
        return None
    try:
        return float(str(value).replace(",", "."))
    except (TypeError, ValueError):
        return None
