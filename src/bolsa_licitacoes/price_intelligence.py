from __future__ import annotations

import math
import re
import statistics
import unicodedata
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping


UNIT_ALIASES = {
    "un": "UN", "und": "UN", "unid": "UN", "unidade": "UN", "peca": "UN", "pc": "UN",
    "cx": "CX", "caixa": "CX", "pct": "PCT", "pacote": "PCT", "kit": "KIT",
    "kg": "KG", "quilo": "KG", "g": "G", "grama": "G", "l": "L", "litro": "L",
    "ml": "ML", "m": "M", "metro": "M", "m2": "M2", "m²": "M2", "m3": "M3", "m³": "M3",
    "h": "H", "hora": "H", "diaria": "DIARIA", "servico": "SERVICO",
}

STOPWORDS = {
    "a", "as", "ao", "aos", "com", "da", "das", "de", "do", "dos", "e", "em", "para", "por",
    "aquisicao", "contratacao", "fornecimento", "material", "servico", "unidade",
}

ESSENTIAL_PATTERNS = {
    "concentracao": re.compile(r"\b\d+(?:[.,]\d+)?\s*(?:mg|mcg|g|ml|ui)(?:\s*/\s*\d+(?:[.,]\d+)?\s*ml)?\b", re.I),
    "memoria": re.compile(r"\b(?:\d+)\s*(?:gb|tb)\b", re.I),
    "dimensao": re.compile(r"\b\d+(?:[.,]\d+)?\s*(?:mm|cm|m|pol(?:egadas?)?|\")\b", re.I),
    "aro": re.compile(r"\baro\s*\d+\b", re.I),
}


def fold(value: Any) -> str:
    text = unicodedata.normalize("NFKD", str(value or ""))
    return "".join(char for char in text if not unicodedata.combining(char)).lower().strip()


def normalize_unit(value: Any) -> str | None:
    clean = fold(value).replace(".", "").replace(" ", "")
    return UNIT_ALIASES.get(clean) or (clean.upper()[:24] if clean else None)


def description_tokens(value: Any) -> set[str]:
    return {
        token for token in re.findall(r"[a-z0-9]+", fold(value))
        if len(token) > 2 and token not in STOPWORDS
    }


def essential_attributes(value: Any) -> dict[str, tuple[str, ...]]:
    text = fold(value)
    return {
        name: tuple(sorted(set(match.replace(" ", "") for match in pattern.findall(text))))
        for name, pattern in ESSENTIAL_PATTERNS.items() if pattern.findall(text)
    }


def _parse_date(value: Any) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def normalize_observation(row: Mapping[str, Any]) -> dict[str, Any]:
    observation = dict(row)
    raw_price = _number(row.get("unit_price_original", row.get("unit_price")))
    original_unit = normalize_unit(row.get("original_unit", row.get("unit")))
    package_quantity = _number(row.get("package_quantity"))
    normalized_price = raw_price
    normalized_unit = original_unit
    status = "NORMALIZED"
    conversion = None
    if original_unit in {"CX", "PCT", "KIT"}:
        if package_quantity and package_quantity > 0:
            normalized_price = raw_price / package_quantity
            normalized_unit = "UN"
            conversion = f"{raw_price:.6f} / {package_quantity:g} = {normalized_price:.6f}"
        else:
            status = "UNKNOWN_PACKAGE"
    elif not original_unit:
        status = "UNKNOWN_UNIT"
    observation.update({
        "unit_price_original": raw_price,
        "original_unit": original_unit,
        "unit_price_normalized": normalized_price,
        "normalized_unit": normalized_unit,
        "normalization_status": status,
        "conversion_explanation": conversion,
        "essential_attributes": essential_attributes(row.get("description_original", row.get("description"))),
    })
    return observation


def comparability(target: Mapping[str, Any], candidate: Mapping[str, Any]) -> tuple[int, list[str], list[str]]:
    target = normalize_observation(target)
    candidate = normalize_observation(candidate)
    score = 0.0
    reasons: list[str] = []
    exclusions: list[str] = []

    target_catalog = str(target.get("catalog_code") or target.get("catmat") or target.get("catser") or "").strip()
    candidate_catalog = str(candidate.get("catalog_code") or candidate.get("catmat") or candidate.get("catser") or "").strip()
    if target_catalog and candidate_catalog:
        if target_catalog == candidate_catalog:
            score += 48
            reasons.append("CATMAT/CATSER idêntico")
        else:
            exclusions.append("catálogo incompatível")

    left = description_tokens(target.get("description_original", target.get("description")))
    right = description_tokens(candidate.get("description_original", candidate.get("description")))
    overlap = len(left & right) / max(1, len(left | right))
    score += min(30, overlap * 42)
    if overlap >= .55:
        reasons.append("descrição técnica muito semelhante")
    elif overlap >= .25:
        reasons.append("descrição parcialmente semelhante")

    target_unit = target.get("normalized_unit")
    candidate_unit = candidate.get("normalized_unit")
    if target_unit and candidate_unit and target_unit == candidate_unit:
        score += 15
        reasons.append(f"unidade compatível ({target_unit})")
    elif target_unit and candidate_unit:
        exclusions.append("unidade incompatível")
        score = min(score, 39)
    else:
        exclusions.append("unidade não normalizada")

    target_attrs = target.get("essential_attributes") or {}
    candidate_attrs = candidate.get("essential_attributes") or {}
    for name, target_values in target_attrs.items():
        candidate_values = candidate_attrs.get(name)
        if candidate_values and set(target_values).isdisjoint(candidate_values):
            exclusions.append(f"atributo essencial divergente: {name}")
            score = min(score, 34)

    reference_date = _parse_date(candidate.get("reference_date"))
    if reference_date:
        age_days = max(0, (datetime.now(timezone.utc) - reference_date).days)
        score += 7 if age_days <= 365 else 4 if age_days <= 1095 else 1
        reasons.append("registro recente" if age_days <= 365 else "registro histórico")

    quality = _number(candidate.get("quality_score"))
    if quality:
        score += min(5, quality / 20)
    return max(0, min(100, round(score))), reasons, list(dict.fromkeys(exclusions))


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def build_price_basket(
    target: Mapping[str, Any], observations: Iterable[Mapping[str, Any]], *, minimum_score: int = 60,
) -> dict[str, Any]:
    evaluated: list[dict[str, Any]] = []
    dedupe: set[tuple[Any, ...]] = set()
    for raw in observations:
        candidate = normalize_observation(raw)
        key = (
            candidate.get("procurement_id"), candidate.get("item_number"), candidate.get("supplier_id"),
            candidate.get("price_type"), candidate.get("unit_price_original"), candidate.get("reference_date"),
        )
        if key in dedupe:
            continue
        dedupe.add(key)
        score, reasons, exclusions = comparability(target, candidate)
        candidate.update({"comparability_score": score, "match_reasons": reasons, "exclusion_reasons": exclusions})
        candidate["included"] = score >= minimum_score and candidate["normalization_status"] == "NORMALIZED"
        evaluated.append(candidate)

    provisional = [row for row in evaluated if row["included"] and row["unit_price_normalized"] > 0]
    values = [row["unit_price_normalized"] for row in provisional]
    p25, p75 = percentile(values, .25), percentile(values, .75)
    if len(values) >= 4 and p25 is not None and p75 is not None:
        spread = p75 - p25
        low, high = p25 - 1.5 * spread, p75 + 1.5 * spread
        for row in provisional:
            row["possible_outlier"] = row["unit_price_normalized"] < low or row["unit_price_normalized"] > high
    else:
        for row in provisional:
            row["possible_outlier"] = False

    selected = [row for row in provisional if not row["possible_outlier"]]
    for row in provisional:
        if row["possible_outlier"]:
            row["included"] = False
            row["exclusion_reasons"].append("possível outlier pelo critério IQR")
    values = [row["unit_price_normalized"] for row in selected]
    mean = statistics.fmean(values) if values else None
    median = statistics.median(values) if values else None
    stdev = statistics.stdev(values) if len(values) >= 2 else None
    stats = {
        "samples": len(values), "mean": mean, "median": median,
        "minimum": min(values) if values else None, "maximum": max(values) if values else None,
        "p10": percentile(values, .10), "p25": percentile(values, .25), "p50": percentile(values, .50),
        "p75": percentile(values, .75), "p90": percentile(values, .90), "standard_deviation": stdev,
        "coefficient_of_variation": (stdev / mean) if stdev is not None and mean else None,
        "iqr": (percentile(values, .75) - percentile(values, .25)) if values else None,
        "total_quantity": sum(_number(row.get("quantity")) for row in selected),
        "total_value": sum(_number(row.get("total_price")) for row in selected),
        "organizations": len({row.get("agency_id") for row in selected if row.get("agency_id")}),
        "suppliers": len({row.get("supplier_id") for row in selected if row.get("supplier_id")}),
        "states": len({row.get("state_code") for row in selected if row.get("state_code")}),
    }
    high = sum(1 for row in evaluated if row["comparability_score"] >= 75)
    quality = round(min(100, (min(len(selected), 30) / 30 * 35) + (high / max(1, len(evaluated)) * 45) + (20 if values else 0)))
    return {
        "target": normalize_observation(target), "statistics": stats, "quality_score": quality,
        "observations": sorted(evaluated, key=lambda row: (-row["comparability_score"], -row["unit_price_normalized"])),
        "methodology": {
            "found": len(evaluated), "normalized": sum(row["normalization_status"] == "NORMALIZED" for row in evaluated),
            "high_comparability": high, "selected": len(selected),
            "outliers_flagged": sum(bool(row.get("possible_outlier")) for row in evaluated),
            "minimum_score": minimum_score, "comparison_model_version": "price-comparability-v1",
            "normalization_version": "unit-normalization-v1",
        },
    }


def _number(value: Any) -> float:
    try:
        number = float(value or 0)
        return number if math.isfinite(number) else 0.0
    except (TypeError, ValueError):
        return 0.0
