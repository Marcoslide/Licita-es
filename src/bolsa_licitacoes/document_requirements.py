from __future__ import annotations

import io
import re
import zipfile
from dataclasses import dataclass
from typing import Any, Iterable, Mapping
from xml.etree import ElementTree

from .http import PublicHttpClient, PublicApiError


MAX_DOCUMENT_BYTES = 24 * 1024 * 1024
MAX_EXCERPT = 260


REQUIREMENT_RULES = (
    ("LEGAL", "Habilitação jurídica", (r"habilita(?:ção|cao) jur[ií]dica", r"contrato social", r"ato constitutivo")),
    ("FISCAL", "Regularidade fiscal, social e trabalhista", (r"regularidade fiscal", r"certid[aã]o negativa", r"fgts", r"trabalhista")),
    ("TECHNICAL", "Qualificação técnica e atestados", (r"qualifica(?:ção|cao) t[eé]cnica", r"atestado de capacidade", r"acervo t[eé]cnico", r"conselho profissional")),
    ("FINANCIAL", "Qualificação econômico-financeira", (r"econ[oô]mico.financeira", r"balan[cç]o patrimonial", r"patrim[oô]nio l[ií]quido", r"certid[aã]o de fal[eê]ncia")),
    ("SAMPLE", "Amostra, vistoria ou prova de conceito", (r"prova de conceito", r"apresenta(?:ção|cao) de amostra", r"amostra", r"vistoria")),
    ("DELIVERY", "Prazo e local de entrega", (r"prazo de entrega", r"local de entrega", r"entrega dos (?:produtos|materiais|servi[cç]os)")),
    ("WARRANTY", "Garantias e assistência", (r"garantia contratual", r"garantia do (?:produto|objeto)", r"assist[eê]ncia t[eé]cnica")),
    ("PAYMENT", "Pagamento, reajuste e repactuação", (r"condi[cç][oõ]es de pagamento", r"prazo para pagamento", r"reajuste", r"repactua(?:ção|cao)")),
    ("DISPUTE", "Disputa, julgamento e proposta", (r"modo de disputa", r"crit[eé]rio de julgamento", r"proposta comercial", r"intervalo.*lance")),
    ("APPEAL", "Impugnação, esclarecimentos e recursos", (r"impugna(?:ção|cao)", r"pedido de esclarecimento", r"interposi(?:ção|cao) de recurso", r"prazo recursal")),
    ("PENALTY", "Multas, sanções e riscos contratuais", (r"san[cç][oõ]es administrativas", r"multa", r"penalidade", r"inexecu(?:ção|cao)")),
)


@dataclass(frozen=True)
class DocumentPage:
    document_name: str
    page_number: int
    text: str
    source_url: str = ""


def _compact_excerpt(text: str, match_start: int) -> str:
    start = max(0, match_start - 80)
    end = min(len(text), match_start + 180)
    excerpt = re.sub(r"\s+", " ", text[start:end]).strip(" -–—\n\t")
    if start:
        excerpt = "…" + excerpt
    if end < len(text):
        excerpt += "…"
    return excerpt[:MAX_EXCERPT]


def analyze_document_pages(pages: Iterable[DocumentPage]) -> list[dict[str, Any]]:
    page_rows = list(pages)
    output: list[dict[str, Any]] = []
    for code, title, patterns in REQUIREMENT_RULES:
        evidence: list[dict[str, Any]] = []
        for page in page_rows:
            for pattern in patterns:
                match = re.search(pattern, page.text, flags=re.IGNORECASE)
                if not match:
                    continue
                evidence.append({
                    "document": page.document_name,
                    "page": page.page_number,
                    "excerpt": _compact_excerpt(page.text, match.start()),
                    "source_url": page.source_url,
                })
                break
            if len(evidence) >= 3:
                break
        output.append({
            "code": code,
            "title": title,
            "status": "FOUND" if evidence else "NOT_FOUND",
            "evidence": evidence,
        })
    return output


def _pdf_pages(body: bytes, name: str, url: str) -> list[DocumentPage]:
    from pypdf import PdfReader

    reader = PdfReader(io.BytesIO(body), strict=False)
    return [
        DocumentPage(name, index + 1, page.extract_text() or "", url)
        for index, page in enumerate(reader.pages)
    ]


def _docx_pages(body: bytes, name: str, url: str) -> list[DocumentPage]:
    with zipfile.ZipFile(io.BytesIO(body)) as archive:
        xml = archive.read("word/document.xml")
    root = ElementTree.fromstring(xml)
    text = " ".join(node.text or "" for node in root.iter() if node.tag.endswith("}t"))
    return [DocumentPage(name, 1, text, url)]


def extract_pages(body: bytes, name: str, mime: str, url: str = "") -> list[DocumentPage]:
    lowered = name.lower()
    if body.startswith(b"%PDF-") or "pdf" in mime or lowered.endswith(".pdf"):
        return _pdf_pages(body, name, url)
    if lowered.endswith(".docx") or "wordprocessingml" in mime:
        return _docx_pages(body, name, url)
    if mime.startswith("text/") or lowered.endswith((".txt", ".csv")):
        return [DocumentPage(name, 1, body.decode("utf-8", errors="replace"), url)]
    return []


class ProcurementRequirementIndexer:
    def __init__(self, client: PublicHttpClient) -> None:
        self.client = client

    def index(self, documents: Iterable[Mapping[str, Any]], *, max_documents: int = 4) -> dict[str, Any]:
        candidates = sorted(
            list(documents),
            key=lambda row: (0 if re.search(r"edital|termo de refer|tr\b", str(row.get("original_name") or ""), re.I) else 1,
                             str(row.get("original_name") or "")),
        )[:max_documents]
        pages: list[DocumentPage] = []
        examined: list[dict[str, Any]] = []
        errors: list[dict[str, str]] = []
        for document in candidates:
            name = str(document.get("original_name") or document.get("document_type") or "Documento oficial")
            url = str(document.get("source_download_url") or "")
            if not url.startswith(("https://", "http://")):
                errors.append({"document": name, "error": "URL oficial indisponível"})
                continue
            try:
                response = self.client.get(url, accept="application/pdf,application/vnd.openxmlformats-officedocument.wordprocessingml.document,text/plain,*/*")
                if len(response.body) > MAX_DOCUMENT_BYTES:
                    errors.append({"document": name, "error": "Arquivo acima do limite de análise imediata (24 MB)"})
                    continue
                mime = response.headers.get("content-type", "application/octet-stream").split(";", 1)[0]
                extracted = extract_pages(response.body, name, mime, url)
                if not extracted:
                    errors.append({"document": name, "error": "Formato sem extração textual automática"})
                    continue
                pages.extend(extracted)
                examined.append({"document": name, "pages": len(extracted), "source_url": url})
            except (PublicApiError, OSError, ValueError, zipfile.BadZipFile) as exc:
                errors.append({"document": name, "error": str(exc)[:180]})
            except Exception as exc:  # malformed third-party PDF must not break the detail page
                errors.append({"document": name, "error": f"Falha de leitura: {type(exc).__name__}"})
        text_pages = [page for page in pages if page.text.strip()]
        requirements = analyze_document_pages(text_pages)
        return {
            "status": "COMPLETE" if text_pages else "UNAVAILABLE",
            "documents_examined": examined,
            "pages_indexed": len(text_pages),
            "requirements": requirements,
            "found": sum(row["status"] == "FOUND" for row in requirements),
            "errors": errors,
            "method": "deterministic-document-patterns-v1",
        }
