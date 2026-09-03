from __future__ import annotations

import html
import json
import re
import sqlite3
import statistics
import threading
import time
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


BPS_SOURCE_PAGE = "https://dadosabertos.saude.gov.br/dataset/bps"
CMED_SOURCE_PAGE = "https://www.gov.br/anvisa/pt-br/assuntos/medicamentos/cmed/precos"
DOU_SEARCH_BASE = "https://www.in.gov.br/consulta/-/buscar/dou"

STOPWORDS = {
    "a", "ao", "aos", "as", "com", "da", "das", "de", "do", "dos", "e", "em", "para", "por",
    "tipo", "uso", "material", "caracteristicas", "adicionais", "apresentacao", "unidade", "fornecimento",
}
MEDICINE_CUES = {
    "mg", "ml", "comprimido", "capsula", "ampola", "frasco", "solucao", "injetavel", "dosagem",
    "concentracao", "medicamento", "farmaco", "principio", "farmaceutica", "farmaceutico",
}


def normalize_text(value: object) -> str:
    text = unicodedata.normalize("NFKD", str(value or ""))
    text = "".join(char for char in text if not unicodedata.combining(char)).lower()
    return " ".join(re.sub(r"[^a-z0-9]+", " ", text).split())


def _number(value: object) -> float:
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def _percentile(values: list[float], fraction: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    index = (len(ordered) - 1) * fraction
    lower = int(index)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (index - lower)


class HealthPriceIndex:
    def __init__(self, path: Path | str | None) -> None:
        self.path = Path(path) if path else None

    @property
    def available(self) -> bool:
        return bool(self.path and self.path.is_file())

    def metadata(self) -> dict[str, str]:
        if not self.available:
            return {}
        with self._connect() as connection:
            return {str(row[0]): str(row[1]) for row in connection.execute("select key,value from metadata")}

    def enrich(self, items: Iterable[dict[str, Any]], state_code: str | None = None) -> dict[str, Any]:
        if not self.available:
            return {
                "available": False,
                "reason": "Índice oficial BPS/CMED ainda não foi instalado neste servidor.",
                "items": [],
                "sources": self._sources(),
            }
        enriched: list[dict[str, Any]] = []
        with self._connect() as connection:
            for item in list(items)[:80]:
                description = str(item.get("description") or "").strip()
                if not description:
                    continue
                bps_rows, match_method = self._bps_rows(connection, item)
                cmed_rows, cmed_method = self._cmed_rows(connection, description, bps_rows)
                if not bps_rows and not cmed_rows:
                    continue
                enriched.append({
                    "item_number": item.get("item_number"),
                    "description": description,
                    "catalog_code": item.get("catalog_item_code"),
                    "bps": self._bps_summary(bps_rows, item.get("unit"), match_method),
                    "cmed": self._cmed_summary(cmed_rows, cmed_method, state_code),
                })
        return {
            "available": True,
            "matched_items": len(enriched),
            "items": enriched,
            "sources": self._sources(),
            "method_note": (
                "CATMAT e registro Anvisa têm prioridade. Correspondências textuais só são exibidas quando a "
                "descrição/apresentação é compatível; preços permanecem separados por unidade."
            ),
            "metadata": self.metadata(),
        }

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        return connection

    def _bps_rows(self, connection: sqlite3.Connection, item: dict[str, Any]) -> tuple[list[sqlite3.Row], str | None]:
        catalog = re.sub(r"\D", "", str(item.get("catalog_item_code") or ""))
        if catalog:
            rows = connection.execute(
                "select * from bps_prices where catmat_code=? and unit_price>0 order by purchase_date desc limit 5000",
                (catalog,),
            ).fetchall()
            if rows:
                return rows, "CATMAT exato"
        description = normalize_text(item.get("description"))
        tokens = [token for token in description.split() if len(token) >= 4 and token not in STOPWORDS][:5]
        if not tokens:
            return [], None
        query = " AND ".join(f'"{token}"' for token in tokens[:3])
        try:
            candidates = connection.execute(
                "select p.* from bps_fts f join bps_prices p on p.id=f.rowid "
                "where bps_fts match ? and p.unit_price>0 limit 600",
                (query,),
            ).fetchall()
        except sqlite3.OperationalError:
            candidates = []
        required = set(tokens[:2])
        rows = [row for row in candidates if required.issubset(set(str(row["description_key"]).split()))]
        return rows, "descrição técnica compatível" if rows else None

    def _cmed_rows(
        self, connection: sqlite3.Connection, description: str, bps_rows: list[sqlite3.Row]
    ) -> tuple[list[sqlite3.Row], str | None]:
        registrations = []
        for row in bps_rows:
            registration = str(row["anvisa_registration"] or "")
            if registration and registration not in registrations:
                registrations.append(registration)
            if len(registrations) >= 20:
                break
        if registrations:
            placeholders = ",".join("?" for _ in registrations)
            rows = connection.execute(
                f"select * from cmed_prices where registration in ({placeholders}) limit 16", registrations
            ).fetchall()
            if rows:
                return rows, "registro Anvisa confirmado pelo BPS"
        normalized = normalize_text(description)
        if not (set(normalized.split()) & MEDICINE_CUES):
            return [], None
        active = normalize_text(description.split(",", 1)[0])
        if not active or len(active) < 4:
            return [], None
        rows = connection.execute(
            "select * from cmed_prices where substance_key=? or product_key=? limit 16", (active, active)
        ).fetchall()
        if not rows:
            rows = connection.execute(
                "select * from cmed_prices where substance_key like ? limit 16", (active + ";%",)
            ).fetchall()
        return rows, "princípio ativo e apresentação compatíveis" if rows else None

    @staticmethod
    def _bps_summary(rows: list[sqlite3.Row], requested_unit: object, method: str | None) -> dict[str, Any]:
        if not rows:
            return {"available": False, "reason": "Nenhuma compra comparável localizada no BPS."}
        groups: dict[str, list[sqlite3.Row]] = defaultdict(list)
        for row in rows:
            groups[normalize_text(row["unit"] or "não informada")].append(row)
        requested = normalize_text(requested_unit)
        selected_key = requested if requested in groups else max(groups, key=lambda key: len(groups[key]))
        selected = groups[selected_key]
        prices = [_number(row["unit_price"]) for row in selected if _number(row["unit_price"]) > 0]
        suppliers: dict[str, dict[str, Any]] = {}
        for row in selected:
            key = str(row["supplier_cnpj"] or row["supplier_name"] or "não informado")
            entry = suppliers.setdefault(key, {"name": row["supplier_name"] or "Não informado", "purchases": 0, "value": 0.0})
            entry["purchases"] += 1
            entry["value"] += _number(row["total_price"])
        return {
            "available": bool(prices),
            "match_method": method,
            "confidence": "alta" if method == "CATMAT exato" else "moderada",
            "unit": selected[0]["unit"] or "Não informada",
            "samples": len(prices),
            "average": statistics.fmean(prices) if prices else None,
            "median": statistics.median(prices) if prices else None,
            "minimum": min(prices) if prices else None,
            "maximum": max(prices) if prices else None,
            "p25": _percentile(prices, 0.25),
            "p75": _percentile(prices, 0.75),
            "years": sorted({int(row["source_year"]) for row in selected}),
            "latest_purchase_date": max((row["purchase_date"] or "" for row in selected), default=None) or None,
            "other_units": [{"unit": group[0]["unit"] or "Não informada", "samples": len(group)} for key, group in groups.items() if key != selected_key][:6],
            "top_suppliers": sorted(suppliers.values(), key=lambda entry: (entry["purchases"], entry["value"]), reverse=True)[:5],
            "observations": [{
                "date": row["purchase_date"], "institution": row["institution_name"], "city": row["city"],
                "state_code": row["state_code"], "supplier": row["supplier_name"],
                "quantity": row["quantity"], "unit_price": row["unit_price"], "total_price": row["total_price"],
            } for row in selected[:5]],
        }

    @staticmethod
    def _cmed_summary(rows: list[sqlite3.Row], method: str | None, state_code: str | None) -> dict[str, Any]:
        if not rows:
            return {"available": False, "reason": "Nenhuma apresentação compatível localizada na CMED."}
        return {
            "available": True,
            "match_method": method,
            "confidence": "alta" if method and "registro" in method else "moderada",
            "state_code": state_code,
            "presentations": [{
                "substance": row["substance"], "product": row["product"], "presentation": row["presentation"],
                "laboratory": row["laboratory"], "registration": row["registration"],
                "price_regime": row["price_regime"], "pf_no_tax": row["pf_no_tax"],
                "pf_zero": row["pf_zero"], "pf_eighteen": row["pf_eighteen"],
                "pmvg_no_tax": row["pmvg_no_tax"], "pmvg_zero": row["pmvg_zero"],
                "pmvg_eighteen": row["pmvg_eighteen"], "cap": row["cap"],
                "hospital_restriction": row["hospital_restriction"], "label": row["label"],
                "published_at": row["published_at"],
            } for row in rows[:8]],
            "regulatory_note": (
                "PF e PMVG são tetos regulatórios, não preços médios. A aplicação depende da apresentação, "
                "tributação, CAP e natureza da compra."
            ),
        }

    @staticmethod
    def _sources() -> list[dict[str, str]]:
        return [
            {"name": "Banco de Preços em Saúde — Ministério da Saúde", "url": BPS_SOURCE_PAGE},
            {"name": "CMED — Anvisa", "url": CMED_SOURCE_PAGE},
        ]


class DouSearch:
    def __init__(self, timeout: float = 10.0, user_agent: str = "BolsaLicitacoes/0.1") -> None:
        self.timeout = timeout
        self.user_agent = user_agent
        self._cache: dict[str, tuple[float, dict[str, Any]]] = {}
        self._lock = threading.Lock()

    def search(self, procurement: dict[str, Any]) -> dict[str, Any]:
        process = str(procurement.get("process_number") or "").strip()
        if len(process) < 4:
            return self._empty("O processo não possui identificador suficiente para uma busca confiável no DOU.")
        cache_key = "|".join((process, str(procurement.get("organization_name") or ""), str(procurement.get("city_name") or "")))
        with self._lock:
            cached = self._cache.get(cache_key)
            if cached and cached[0] > time.monotonic():
                return cached[1]
        params = {"q": f'"{process}"', "exactDate": "all", "sortType": "0"}
        search_url = f"{DOU_SEARCH_BASE}?{urlencode(params)}"
        request = Request(search_url, headers={"User-Agent": self.user_agent, "Accept": "text/html"})
        try:
            with urlopen(request, timeout=self.timeout) as response:
                page = response.read().decode("utf-8", errors="replace")
        except (HTTPError, URLError, TimeoutError) as exc:
            return {**self._empty("A pesquisa oficial do DOU está temporariamente indisponível."), "search_url": search_url, "error": type(exc).__name__}
        match = re.search(
            r'<script id="_br_com_seatecnologia_in_buscadou_BuscaDouPortlet_params" type="application/json">\s*(.*?)\s*</script>',
            page, re.DOTALL,
        )
        if not match:
            return {**self._empty("A pesquisa oficial não retornou uma resposta estruturada."), "search_url": search_url}
        try:
            payload = json.loads(html.unescape(match.group(1)))
        except json.JSONDecodeError:
            return {**self._empty("A resposta estruturada do DOU não pôde ser interpretada."), "search_url": search_url}
        results = []
        for item in payload.get("jsonArray", []):
            scored = self._score(item, procurement)
            if scored["match_score"] < 45:
                continue
            results.append(scored)
        results.sort(key=lambda item: (item["match_score"], item.get("published_at") or ""), reverse=True)
        output = {
            "available": True,
            "query": process,
            "search_url": search_url,
            "results": results[:6],
            "total_candidates": len(payload.get("jsonArray", [])),
            "matched": len(results),
            "source": {"name": "Diário Oficial da União — Imprensa Nacional", "url": "https://www.in.gov.br/"},
            "method_note": "Busca exata pelo processo, seguida de validação por órgão, cidade e termos do objeto.",
        }
        with self._lock:
            self._cache[cache_key] = (time.monotonic() + 900, output)
        return output

    @staticmethod
    def _score(item: dict[str, Any], procurement: dict[str, Any]) -> dict[str, Any]:
        raw_content = re.sub(r"<[^>]+>", " ", html.unescape(str(item.get("content") or "")))
        raw_title = re.sub(r"<[^>]+>", " ", html.unescape(str(item.get("title") or "")))
        hierarchy = str(item.get("hierarchyStr") or "")
        haystack = normalize_text(" ".join((raw_title, raw_content, hierarchy)))
        org = normalize_text(procurement.get("organization_name"))
        city = normalize_text(procurement.get("city_name"))
        object_tokens = [token for token in normalize_text(procurement.get("object")).split() if len(token) >= 5 and token not in STOPWORDS]
        org_tokens = [token for token in org.split() if len(token) >= 4 and token not in STOPWORDS]
        org_overlap = sum(1 for token in set(org_tokens) if token in haystack)
        object_overlap = sum(1 for token in set(object_tokens[:12]) if token in haystack)
        score = 35
        reasons = ["número do processo localizado"]
        if city and city in haystack:
            score += 25
            reasons.append("município compatível")
        if org_overlap >= 2:
            score += 30
            reasons.append("órgão compatível")
        elif org_overlap == 1:
            score += 12
        if object_overlap >= 3:
            score += 25
            reasons.append("objeto compatível")
        elif object_overlap >= 1:
            score += 8
        url_title = str(item.get("urlTitle") or "")
        return {
            "title": " ".join(raw_title.split()), "published_at": item.get("pubDate"),
            "section": item.get("pubName"), "edition": item.get("editionNumber"),
            "page": item.get("numberPage"), "act_type": item.get("artType"),
            "organization_path": hierarchy, "excerpt": " ".join(raw_content.split())[:600],
            "source_url": f"https://www.in.gov.br/web/dou/-/{quote(url_title, safe='/-')}",
            "match_score": min(score, 100), "match_reasons": reasons,
        }

    @staticmethod
    def _empty(reason: str) -> dict[str, Any]:
        return {
            "available": False, "reason": reason, "results": [], "matched": 0,
            "source": {"name": "Diário Oficial da União — Imprensa Nacional", "url": "https://www.in.gov.br/"},
        }
