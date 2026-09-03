from __future__ import annotations

import re
import unicodedata
from math import log2
from dataclasses import asdict, dataclass, field
from difflib import SequenceMatcher, get_close_matches
from typing import Any, Iterable, Mapping, Optional, Sequence


SEARCH_ENGINE_VERSION = "market-search-v1.0"
RERANKER_VERSION = "rules-v1.0"
SYNONYM_DICTIONARY_VERSION = "approved-2026-09-03"
EMBEDDING_MODEL_VERSION: Optional[str] = None

SEARCH_MODES = {"precise", "balanced", "broad", "exact"}
MODE_ALIASES = {
    "smart": "balanced", "intelligent": "balanced", "inteligente": "balanced",
    "equilibrada": "balanced", "equilibrado": "balanced", "precisa": "precise",
    "ampla": "broad", "exata": "exact",
}

STOPWORDS = {
    "a", "ao", "aos", "as", "com", "da", "das", "de", "do", "dos", "e", "em", "na", "nas",
    "no", "nos", "o", "os", "ou", "para", "por", "que", "um", "uma", "uns", "umas", "tipo",
    "aquisicao", "contratacao", "fornecimento", "registro", "preco", "servico", "servicos", "material",
}

ABBREVIATIONS = {
    "comp": "comprimido", "comp.": "comprimido", "cx": "caixa", "pct": "pacote",
    "und": "unidade", "unid": "unidade", "qtd": "quantidade", "med": "medicamento",
}

NOISE_FAMILIES = {
    "escolar": {"escritorio", "odontologica", "rodas", "hospitalar"},
    "hospitalar": {"escolar", "escritorio"},
    "predial": {"automotiva", "veicular"},
}


@dataclass(frozen=True)
class SynonymEntry:
    primary: str
    synonym: str
    category: str
    origin: str = "manual"
    confidence: float = 1.0
    approved: bool = True


# Somente relações aprovadas e auditáveis entram no dicionário global.
APPROVED_SYNONYMS = (
    SynonymEntry("cadeira escolar", "cadeiras escolares", "mobiliario escolar", "linguistic"),
    SynonymEntry("cadeira escolar", "conjunto aluno", "mobiliario escolar", "taxonomy", .94),
    SynonymEntry("cadeira escolar", "conjunto escolar", "mobiliario escolar", "taxonomy", .92),
    SynonymEntry("cadeira escolar", "cadeira para aluno", "mobiliario escolar", "manual", .94),
    SynonymEntry("mobiliario escolar", "conjunto aluno", "mobiliario escolar", "taxonomy", .92),
    SynonymEntry("mobiliario escolar", "conjunto escolar", "mobiliario escolar", "taxonomy", .92),
    SynonymEntry("medicamento", "farmaco", "medicamentos", "taxonomy", .90),
    SynonymEntry("medicamento", "farmaceutico", "medicamentos", "taxonomy", .86),
    SynonymEntry("material hospitalar", "insumo hospitalar", "saude", "taxonomy", .92),
    SynonymEntry("material hospitalar", "medico hospitalar", "saude", "taxonomy", .88),
    SynonymEntry("tecnologia", "informatica", "tecnologia", "taxonomy", .92),
    SynonymEntry("manutencao predial", "conservacao predial", "engenharia", "taxonomy", .92),
    SynonymEntry("generos alimenticios", "alimentos", "alimentacao", "taxonomy", .94),
    SynonymEntry("limpeza", "higienizacao", "limpeza", "taxonomy", .91),
    SynonymEntry("moldura", "emolduramento", "molduras", "manual", .92),
    SynonymEntry("moldura", "porta retrato", "molduras", "manual", .82),
)


@dataclass(frozen=True)
class TechnicalAttribute:
    kind: str
    original: str
    base_value: float
    base_unit: str


@dataclass
class QueryPlan:
    original: str
    normalized: str
    mode: str = "balanced"
    phrases: list[str] = field(default_factory=list)
    must_terms: list[str] = field(default_factory=list)
    should_terms: list[str] = field(default_factory=list)
    exclude_terms: list[str] = field(default_factory=list)
    synonyms: list[str] = field(default_factory=list)
    fuzzy_terms: list[str] = field(default_factory=list)
    core_terms: list[str] = field(default_factory=list)
    catalog_codes: list[str] = field(default_factory=list)
    technical_attributes: list[TechnicalAttribute] = field(default_factory=list)
    correction: Optional[str] = None
    correction_confidence: Optional[float] = None
    include_documents: bool = False

    @property
    def retrieval_terms(self) -> list[str]:
        values = [self.normalized, *self.phrases, *self.must_terms, *self.should_terms]
        if self.mode in {"balanced", "broad"}:
            values.extend(self.fuzzy_terms)
            values.extend(self.synonyms)
        if self.mode == "broad":
            values.extend(entry.category for entry in APPROVED_SYNONYMS if normalize_text(entry.primary) in values)
        return _unique(values)

    def public_dict(self) -> dict[str, Any]:
        result = asdict(self)
        result["technical_attributes"] = [asdict(item) for item in self.technical_attributes]
        result["terms"] = self.retrieval_terms
        result["versions"] = {
            "search_engine": SEARCH_ENGINE_VERSION,
            "embedding_model": EMBEDDING_MODEL_VERSION,
            "reranker": RERANKER_VERSION,
            "synonyms": SYNONYM_DICTIONARY_VERSION,
        }
        return result


@dataclass
class SearchDocument:
    procurement_id: str
    object_text: str
    process_text: str = ""
    organization_text: str = ""
    item_rows: list[dict[str, Any]] = field(default_factory=list)
    document_text: str = ""


@dataclass
class SearchHit:
    procurement_id: str
    match_score: int
    matched_items_count: int
    matched_items: list[dict[str, Any]]
    matched_fields: list[str]
    match_reasons: list[str]
    highlights: list[str]
    specification_warning: Optional[str] = None


class QueryCompiler:
    def __init__(self, synonyms: Sequence[SynonymEntry] = APPROVED_SYNONYMS) -> None:
        self.synonyms = tuple(item for item in synonyms if item.approved)

    def compile(
        self,
        query: str,
        *,
        mode: str = "balanced",
        include: Sequence[str] = (),
        should: Sequence[str] = (),
        exclude: Sequence[str] = (),
        catalog_codes: Sequence[str] = (),
        include_documents: bool = False,
        vocabulary: Iterable[str] = (),
    ) -> QueryPlan:
        original = " ".join(str(query or "").strip().split())[:240]
        selected_mode = MODE_ALIASES.get(str(mode or "").lower(), str(mode or "").lower())
        if selected_mode not in SEARCH_MODES:
            selected_mode = "balanced"

        phrases = [normalize_text(value) for value in re.findall(r'"([^\"]+)"', original) if normalize_text(value)]
        without_phrases = re.sub(r'"[^\"]+"', " ", original)
        boolean_excludes = [normalize_text(value) for value in re.findall(r"(?:\bNOT\b|(?<!\w)-)\s*([\wÀ-ÿ][\wÀ-ÿ-]*(?:\s+[\wÀ-ÿ][\wÀ-ÿ-]*)?)", without_phrases, re.I)]
        without_not = re.sub(r"(?:\bNOT\b|(?<!\w)-)\s*[\wÀ-ÿ][\wÀ-ÿ-]*(?:\s+[\wÀ-ÿ][\wÀ-ÿ-]*)?", " ", without_phrases, flags=re.I)
        normalized = normalize_text(without_not)
        if selected_mode == "exact" and not phrases and normalized:
            phrases = [normalized]

        must_terms = _unique([normalize_text(value) for value in include if normalize_text(value)])
        should_terms = _unique([normalize_text(value) for value in should if normalize_text(value)])
        exclude_terms = _unique([*boolean_excludes, *(normalize_text(value) for value in exclude if normalize_text(value))])
        tokens = meaningful_tokens(normalized)
        core_terms = _core_terms(tokens)
        approved_expansions: list[str] = []
        normalized_sources = {normalized, *phrases, *must_terms, *should_terms}
        for entry in self.synonyms:
            primary, synonym = normalize_text(entry.primary), normalize_text(entry.synonym)
            if any(_phrase_related(source, primary) or _phrase_related(source, synonym) for source in normalized_sources):
                approved_expansions.extend((primary, synonym))

        fuzzy_terms: list[str] = []
        corrections: list[str] = []
        confidence_values: list[float] = []
        vocabulary_values = [*vocabulary, *(entry.primary for entry in self.synonyms), *(entry.synonym for entry in self.synonyms)]
        vocab = sorted({token for value in vocabulary_values for token in meaningful_tokens(normalize_text(str(value))) if len(token) >= 4})
        for token in tokens:
            if token in vocab or len(token) < 4:
                corrections.append(token)
                continue
            if any(_stem_portuguese(candidate) == _stem_portuguese(token) for candidate in vocab):
                corrections.append(token)
                continue
            threshold = _fuzzy_threshold(token)
            candidate = get_close_matches(token, vocab, n=1, cutoff=threshold)
            if candidate:
                similarity = SequenceMatcher(None, token, candidate[0]).ratio()
                fuzzy_terms.append(candidate[0])
                corrections.append(candidate[0])
                confidence_values.append(similarity)
            else:
                corrections.append(token)
        correction = None
        correction_confidence = None
        if fuzzy_terms and corrections:
            correction = " ".join(corrections)
            correction_confidence = min(confidence_values) if confidence_values else None
            core_terms = _core_terms(corrections)

        return QueryPlan(
            original=original,
            normalized=normalized,
            mode=selected_mode,
            phrases=_unique(phrases),
            must_terms=must_terms,
            should_terms=should_terms,
            exclude_terms=exclude_terms,
            synonyms=_unique(approved_expansions),
            fuzzy_terms=_unique(fuzzy_terms),
            core_terms=core_terms,
            catalog_codes=_unique(str(code).strip() for code in catalog_codes if str(code).strip()),
            technical_attributes=extract_technical_attributes(original),
            correction=correction,
            correction_confidence=correction_confidence,
            include_documents=include_documents,
        )


class MarketSearchEngine:
    """Central retrieval and reranking engine used by search, scopes and monitors."""

    def __init__(self, compiler: Optional[QueryCompiler] = None) -> None:
        self.compiler = compiler or QueryCompiler()

    def compile(self, query: str, **kwargs: Any) -> QueryPlan:
        return self.compiler.compile(query, **kwargs)

    def search(self, plan: QueryPlan, documents: Sequence[SearchDocument]) -> list[SearchHit]:
        hits = [hit for document in documents if (hit := self.score(document, plan)) is not None]
        return sorted(hits, key=lambda hit: (-hit.match_score, -hit.matched_items_count, hit.procurement_id))

    def score(self, document: SearchDocument, plan: QueryPlan) -> Optional[SearchHit]:
        if not plan.normalized and not plan.phrases and not plan.must_terms and not plan.catalog_codes:
            return SearchHit(document.procurement_id, 100, 0, [], ["all"], ["Sem termo textual; filtros estruturados aplicados."], [])

        object_text = normalize_text(document.object_text)
        process_text = normalize_text(document.process_text)
        organization_text = normalize_text(document.organization_text)
        items = [(row, normalize_text(str(row.get("descricao") or ""))) for row in document.item_rows]
        document_text = normalize_text(document.document_text) if plan.include_documents else ""
        searchable = " ".join([object_text, process_text, organization_text, *(text for _, text in items), document_text])
        if any(term and term in searchable for term in plan.exclude_terms):
            return None

        exact_phrase = plan.phrases[0] if plan.phrases else plan.normalized
        phrase_object = bool(exact_phrase and exact_phrase in object_text)
        phrase_items = [(row, text) for row, text in items if exact_phrase and exact_phrase in text]
        catalog_items = [(row, text) for row, text in items if str(row.get("catalogo_codigo") or "") in plan.catalog_codes]
        term_sources = [object_text, *(text for _, text in items)]
        core_matches = {term for term in plan.core_terms if any(_token_related(term, text) for text in term_sources)}
        coverage = len(core_matches) / max(1, len(plan.core_terms))
        matched_items = []
        retrieval_terms = plan.retrieval_terms
        for row, text in items:
            item_terms = [term for term in retrieval_terms if _term_matches(term, text)]
            if item_terms or any(row is candidate[0] for candidate in catalog_items):
                matched_items.append({
                    "number": row.get("numero_item"), "description": row.get("descricao"),
                    "catalog_code": row.get("catalogo_codigo"), "terms": item_terms[:6],
                })

        exact_mode_ok = phrase_object or bool(phrase_items) or bool(catalog_items)
        if plan.mode == "exact" and not exact_mode_ok:
            return None
        if plan.must_terms and not all(any(_term_matches(term, text) for text in term_sources) for term in plan.must_terms):
            return None

        direct_matches = [term for term in [plan.normalized, *plan.must_terms, *plan.should_terms] if _term_matches(term, searchable)]
        synonym_matches = [term for term in plan.synonyms if _term_matches(term, searchable)]
        fuzzy_matches = [term for term in plan.fuzzy_terms if _term_matches(term, searchable)]
        document_matches = [term for term in retrieval_terms if document_text and _term_matches(term, document_text)]
        identifier_match = bool(plan.normalized and plan.normalized in process_text)
        organization_match = bool(plan.normalized and _term_matches(plan.normalized, organization_text))
        if not any((exact_mode_ok, direct_matches, synonym_matches, fuzzy_matches, matched_items, core_matches, identifier_match, organization_match, document_matches)):
            return None

        score = 0.0
        fields: list[str] = []
        reasons: list[str] = []
        if phrase_items:
            score += 58
            fields.append("item")
            reasons.append(f"Frase encontrada em {len(phrase_items)} item(ns).")
        if phrase_object:
            score += 48
            fields.append("objeto")
            reasons.append("Frase encontrada no objeto da contratação.")
        if catalog_items:
            score += 46
            fields.append("CATMAT/CATSER")
            reasons.append("Código de catálogo confirmado em item.")
        if matched_items and not phrase_items:
            score += min(44, 28 + len(matched_items) * 4)
            fields.append("item")
            reasons.append(f"{len(matched_items)} item(ns) relacionado(s) à consulta.")
        if plan.core_terms:
            score += 16 + coverage * 28 if coverage else 0
            if coverage:
                reasons.append(f"Cobertura de {round(coverage * 100)}% dos conceitos principais.")
        if direct_matches:
            score += min(20, 8 + len(direct_matches) * 4)
        if synonym_matches and not direct_matches:
            score += min(18, 8 + len(synonym_matches) * 2)
            reasons.append("Correspondência por sinônimo ou taxonomia aprovada.")
        if fuzzy_matches:
            score += min(14, 7 + len(fuzzy_matches) * 2)
            reasons.append("Grafia aproximada corrigida com alta confiança.")
        if identifier_match:
            score += 50
            fields.append("identificador")
            reasons.append("Identificador/processo corresponde à consulta.")
        if organization_match:
            score += 24
            fields.append("órgão")
            reasons.append("Órgão comprador corresponde à consulta.")
        if document_matches and not any((phrase_items, phrase_object, matched_items)):
            score += 8
            fields.append("documento")
            reasons.append("Termo localizado somente em edital/anexo, com peso reduzido.")

        specification_warning = _specification_warning(plan.technical_attributes, object_text, [text for _, text in items])
        if specification_warning:
            score -= 8
        score -= _noise_penalty(plan, searchable)
        threshold = {"exact": 45, "precise": 52, "balanced": 28, "broad": 18}[plan.mode]
        if coverage < _coverage_floor(plan) and not exact_mode_ok and not catalog_items and not synonym_matches and not specification_warning and not identifier_match and not organization_match:
            return None
        effective_threshold = min(threshold, 20) if specification_warning and core_matches else threshold
        if score < effective_threshold:
            return None
        score = max(0, min(100, round(score)))
        highlights = _unique([*core_matches, *direct_matches, *synonym_matches, *fuzzy_matches])[:8]
        return SearchHit(
            procurement_id=document.procurement_id,
            match_score=score,
            matched_items_count=len(matched_items),
            matched_items=matched_items[:8],
            matched_fields=_unique(fields),
            match_reasons=_unique(reasons)[:5],
            highlights=highlights,
            specification_warning=specification_warning,
        )

    def matches_text(self, plan: QueryPlan, text: str) -> bool:
        document = SearchDocument("text", text)
        return self.score(document, plan) is not None


def normalize_text(value: str) -> str:
    text = unicodedata.normalize("NFKD", str(value or ""))
    text = "".join(char for char in text if not unicodedata.combining(char)).lower()
    text = re.sub(r"(?<=\d),(?=\d)", ".", text)
    text = re.sub(r"[^a-z0-9./]+", " ", text)
    text = re.sub(r"\b(\d+(?:\.\d+)?)\s+(mcg|mg|g|kg|ml|l|kw|w|v)\b", r"\1\2", text)
    tokens = [ABBREVIATIONS.get(token, token) for token in text.split()]
    return " ".join(tokens)


def meaningful_tokens(value: str) -> list[str]:
    return [token for token in normalize_text(value).split() if token not in STOPWORDS and len(token) >= 2]


def extract_technical_attributes(value: str) -> list[TechnicalAttribute]:
    normalized = normalize_text(value)
    result: list[TechnicalAttribute] = []
    patterns = (
        ("mass", r"\b(\d+(?:\.\d+)?)\s*(mcg|mg|g|kg)\b"),
        ("volume", r"\b(\d+(?:\.\d+)?)\s*(ml|l|litro|litros)\b"),
        ("power", r"\b(\d+(?:\.\d+)?)\s*(w|kw|watts?)\b"),
        ("voltage", r"\b(\d+(?:\.\d+)?)\s*(v|volts?)\b"),
    )
    factors = {
        "mcg": (0.001, "mg"), "mg": (1, "mg"), "g": (1000, "mg"), "kg": (1_000_000, "mg"),
        "ml": (1, "ml"), "l": (1000, "ml"), "litro": (1000, "ml"), "litros": (1000, "ml"),
        "w": (1, "w"), "watt": (1, "w"), "watts": (1, "w"), "kw": (1000, "w"),
        "v": (1, "v"), "volt": (1, "v"), "volts": (1, "v"),
    }
    for kind, pattern in patterns:
        for match in re.finditer(pattern, normalized):
            amount, unit = float(match.group(1)), match.group(2)
            factor, base_unit = factors[unit]
            result.append(TechnicalAttribute(kind, match.group(0), amount * factor, base_unit))
    return result


def _core_terms(tokens: Sequence[str]) -> list[str]:
    if not tokens:
        return []
    core = [token for token in tokens if not re.fullmatch(r"\d+(?:\.\d+)?", token)]
    return _unique(_stem_portuguese(token) for token in core)


def _stem_portuguese(token: str) -> str:
    if len(token) > 6 and token.endswith("oes"):
        return token[:-3] + "ao"
    if len(token) > 5 and token.endswith("ais"):
        return token[:-3] + "al"
    if len(token) > 5 and token.endswith("res"):
        return token[:-2]
    if len(token) > 4 and token.endswith("s") and not token.endswith("us"):
        return token[:-1]
    return token


def _token_related(term: str, text: str) -> bool:
    target = _stem_portuguese(term)
    return any(_stem_portuguese(token) == target or (len(target) >= 6 and token.startswith(target[:6])) for token in meaningful_tokens(text))


def _term_matches(term: str, text: str) -> bool:
    term = normalize_text(term)
    text = normalize_text(text)
    if not term:
        return False
    if term in text:
        return True
    tokens = meaningful_tokens(term)
    return bool(tokens) and all(_token_related(token, text) for token in tokens)


def _phrase_related(left: str, right: str) -> bool:
    if not left or not right:
        return False
    return left in right or right in left or set(meaningful_tokens(left)) == set(meaningful_tokens(right))


def _fuzzy_threshold(token: str) -> float:
    if len(token) <= 4:
        return .92
    if len(token) <= 7:
        return .83
    return .78


def _coverage_floor(plan: QueryPlan) -> float:
    if len(plan.core_terms) <= 1:
        return 1.0
    return {"exact": 1.0, "precise": 1.0, "balanced": .75, "broad": .5}[plan.mode]


def _noise_penalty(plan: QueryPlan, text: str) -> int:
    penalty = 0
    query_tokens = set(meaningful_tokens(plan.normalized))
    for context, noises in NOISE_FAMILIES.items():
        if context in query_tokens:
            penalty += sum(24 for noise in noises if noise in text and noise not in query_tokens)
    return min(48, penalty)


def _specification_warning(attributes: Sequence[TechnicalAttribute], object_text: str, item_texts: Sequence[str]) -> Optional[str]:
    if not attributes:
        return None
    available = extract_technical_attributes(" ".join([object_text, *item_texts]))
    for expected in attributes:
        same_kind = [item for item in available if item.kind == expected.kind]
        if same_kind and not any(abs(item.base_value - expected.base_value) < .0001 and item.base_unit == expected.base_unit for item in same_kind):
            found = ", ".join(_unique(item.original for item in same_kind)[:3])
            return f"Produto relacionado, mas a especificação encontrada ({found}) difere de {expected.original}."
    return None


def _unique(values: Iterable[Any]) -> list[Any]:
    result: list[Any] = []
    seen = set()
    for value in values:
        if value is None:
            continue
        marker = normalize_text(str(value))
        if marker and marker not in seen:
            seen.add(marker)
            result.append(value)
    return result


def precision_at_k(ranked_ids: Sequence[str], relevant_ids: set[str], k: int = 10) -> float:
    if k <= 0:
        return 0.0
    top = list(ranked_ids)[:k]
    return sum(item in relevant_ids for item in top) / k


def ndcg_at_k(ranked_ids: Sequence[str], grades: Mapping[str, int], k: int = 10) -> float:
    if k <= 0:
        return 0.0
    actual = [max(0, int(grades.get(item, 0))) for item in list(ranked_ids)[:k]]
    ideal = sorted((max(0, int(value)) for value in grades.values()), reverse=True)[:k]
    dcg = sum((2 ** grade - 1) / log2(index + 2) for index, grade in enumerate(actual))
    idcg = sum((2 ** grade - 1) / log2(index + 2) for index, grade in enumerate(ideal))
    return dcg / idcg if idcg else 0.0
