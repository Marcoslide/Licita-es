from __future__ import annotations

import json
import re
import threading
import time
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


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

    def list_procurements(self, query: Mapping[str, list[str]]) -> dict[str, Any]:
        limit = _bounded_int(_first(query, "limit"), default=25, minimum=1, maximum=100)
        offset = _bounded_int(_first(query, "offset"), default=0, minimum=0, maximum=100_000)
        requested_ufs = [
            item.strip().upper()
            for item in (_first(query, "uf") or "").split(",")
            if item.strip().upper() in UF_NAMES
        ]
        text = (_first(query, "q") or "").strip()[:120]
        sort = (_first(query, "sort") or "recent").strip().lower()
        period = (_first(query, "period") or "").strip().lower()
        status = (_first(query, "status") or "").strip().lower()
        want_facets = (_first(query, "facets") or "").lower() in {"1", "true", "yes"}
        terms, intent = expand_search_terms(text)

        filters: list[tuple[str, str]] = []
        logical: list[str] = []
        if len(requested_ufs) == 1:
            filters.append(("uf", f"eq.{requested_ufs[0]}"))
        elif requested_ufs:
            filters.append(("uf", f"in.({','.join(requested_ufs)})"))
        if period == "today":
            today = datetime.now(timezone.utc).date().isoformat()
            filters.append(("data_publicacao_pncp", f"gte.{today}T00:00:00Z"))
        elif period in {"7", "30", "365"}:
            since = (datetime.now(timezone.utc) - timedelta(days=int(period))).isoformat()
            filters.append(("data_publicacao_pncp", f"gte.{since}"))

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
                return self._empty_result(limit, offset, text, terms, intent)
            filters.append(("numero_controle_pncp", f"in.({','.join(keys)})"))

        if text:
            conditions = []
            for term in terms:
                token = _pg_token(term)
                conditions.append(f"objeto.ilike.*{token}*")
            original = _pg_token(text)
            conditions.extend((f"processo.ilike.*{original}*", f"numero_controle_pncp.ilike.*{original}*"))
            related_keys = self._search_related_keys(terms)
            if related_keys:
                conditions.append(f"numero_controle_pncp.in.({','.join(related_keys)})")
            logical.append(f"or({','.join(conditions)})")

        if len(logical) == 1:
            filters.append(("or", f"({logical[0][3:-1]})"))
        elif logical:
            filters.append(("and", f"({','.join(logical)})"))

        order = {
            "value": "valor_total_estimado.desc.nullslast,data_publicacao_pncp.desc",
            "deadline": "data_encerramento_proposta.asc.nullslast,data_publicacao_pncp.desc",
            "recent": "data_publicacao_pncp.desc.nullslast,last_seen_at.desc",
        }.get(sort, "data_publicacao_pncp.desc.nullslast,last_seen_at.desc")
        select = (
            "numero_controle_pncp,orgao_cnpj,unidade_codigo,numero_compra,processo,objeto,modalidade_nome,"
            "situacao_nome,data_abertura_proposta,data_encerramento_proposta,valor_total_estimado,"
            "valor_total_homologado,data_publicacao_pncp,source_updated_at,last_seen_at,uf,municipio_nome,"
            "link_sistema_origem"
        )
        params = [("select", select), *filters, ("order", order), ("limit", str(limit)), ("offset", str(offset))]
        rows, total = self.client.get("licitacoes", params, profile="bolsa", count=True)
        items = self._enrich_procurements(rows)
        facets = self._facets(filters) if want_facets else None
        return {
            "total": total if total is not None else len(items), "limit": limit, "offset": offset, "items": items,
            "search": ({"query": text, "mode": "semantic", "intent": intent, "terms": terms} if text else None),
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

    def _enrich_procurements(self, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
        ncps = [str(row.get("numero_controle_pncp")) for row in rows if row.get("numero_controle_pncp")]
        org_ids = sorted({str(row.get("orgao_cnpj")) for row in rows if row.get("orgao_cnpj")})
        org_names = self._organization_names(org_ids)
        item_counts = self._related_counts("itens", ncps)
        document_counts = self._related_counts("documentos", ncps)
        result = []
        for row in rows:
            ncp = str(row.get("numero_controle_pncp") or "")
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
            })
        return result

    def _organization_names(self, ids: list[str]) -> dict[str, str]:
        if not ids:
            return {}
        rows, _ = self.client.get(
            "orgaos", [("select", "cnpj,razao_social"), ("cnpj", f"in.({','.join(ids[:500])})"), ("limit", "500")], profile="bolsa",
        )
        return {str(row.get("cnpj")): str(row.get("razao_social") or row.get("cnpj")) for row in rows}

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

    def _facets(self, filters: list[tuple[str, str]]) -> dict[str, Any]:
        rows, _ = self.client.get(
            "licitacoes",
            [("select", "uf,orgao_cnpj,valor_total_estimado,data_encerramento_proposta"), *filters, ("limit", "1000")],
            profile="bolsa",
        )
        states: dict[str, dict[str, Any]] = {}
        for row in rows:
            code = str(row.get("uf") or "").upper()
            if code not in UF_NAMES:
                continue
            state = states.setdefault(code, {"code": code, "name": UF_NAMES[code], "procurements": 0, "estimated_value": 0.0, "organizations": set()})
            state["procurements"] += 1
            state["estimated_value"] += _float(row.get("valor_total_estimado"))
            if row.get("orgao_cnpj"):
                state["organizations"].add(str(row["orgao_cnpj"]))
        organizations = {str(row.get("orgao_cnpj")) for row in rows if row.get("orgao_cnpj")}
        return {
            "states": sorted(({
                **state, "organizations": len(state["organizations"]), "cities": 0,
                "top_organizations": [], "last_collected_at": None,
            } for state in states.values()), key=lambda state: state["procurements"], reverse=True),
            "organizations": len(organizations), "estimated_value": sum(_float(row.get("valor_total_estimado")) for row in rows),
            "records_sampled": len(rows),
        }

    def _empty_result(self, limit: int, offset: int, text: str, terms: list[str], intent: Optional[str]) -> dict[str, Any]:
        return {
            "total": 0, "limit": limit, "offset": offset, "items": [],
            "search": ({"query": text, "mode": "semantic", "intent": intent, "terms": terms} if text else None),
            "facets": {"states": [], "organizations": 0, "estimated_value": 0, "records_sampled": 0},
            "data_source": "supabase-live",
        }

    def _cached(self, key: str, ttl: int, loader):
        now = time.monotonic()
        with self._cache_lock:
            cached = self._cache.get(key)
            if cached and cached[0] > now:
                return cached[1]
        value = loader()
        with self._cache_lock:
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
