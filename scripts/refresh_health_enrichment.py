#!/usr/bin/env python3
"""Continuously refresh the official BPS/CMED read-only index with atomic swaps."""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sqlite3
import sys
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urljoin
from urllib.request import Request, urlopen

from build_health_enrichment import create_schema, import_bps, import_cmed


BPS_PACKAGE_API = (
    "https://dadosabertos.saude.gov.br/api/3/action/package_show"
    "?id=04f08f8f-09fd-48f4-a853-c3c6368f20be"
)
CMED_PAGE = "https://www.gov.br/anvisa/pt-br/assuntos/medicamentos/cmed/precos"


def fetch(url: str, user_agent: str, *, binary: bool = False) -> bytes | str:
    request = Request(url, headers={"User-Agent": user_agent, "Accept": "*/*"})
    with urlopen(request, timeout=120) as response:
        payload = response.read()
    return payload if binary else payload.decode("utf-8", errors="replace")


def discover_bps(user_agent: str, first_year: int) -> list[dict[str, str]]:
    resources: list[dict[str, str]] = []
    try:
        payload = json.loads(str(fetch(BPS_PACKAGE_API, user_agent)))
        for resource in payload.get("result", {}).get("resources", []):
            url = str(resource.get("url") or "")
            match = re.search(r"/(20\d{2})_csv\.zip$", url, re.I)
            if match and int(match.group(1)) >= first_year:
                resources.append({
                    "year": match.group(1), "url": url,
                    "updated_at": str(resource.get("last_modified") or resource.get("metadata_modified") or ""),
                })
    except Exception as exc:
        print(f"BPS metadata API unavailable, using official URL pattern: {exc}", flush=True)
    if not resources:
        current_year = datetime.now(UTC).year
        resources = [{
            "year": str(year),
            "url": f"https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/BPS/csv/{year}_csv.zip",
            "updated_at": "discovered-by-official-pattern",
        } for year in range(first_year, current_year + 1)]
    unique = {item["year"]: item for item in resources}
    return [unique[year] for year in sorted(unique)]


def discover_cmed(user_agent: str) -> dict[str, str]:
    page = str(fetch(CMED_PAGE, user_agent))
    matches = re.findall(
        r'href=["\']([^"\']*xls_conformidade_gov_[^"\']*\.xlsx(?:/@@download/file)?)["\']',
        html.unescape(page), re.I,
    )
    if not matches:
        raise RuntimeError("A planilha PMVG da CMED não foi localizada na página oficial")
    url = urljoin(CMED_PAGE, matches[0])
    return {"url": url, "version": url}


def build(output: Path, bps: list[dict[str, str]], cmed: dict[str, str], user_agent: str) -> dict[str, object]:
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="health-refresh-", dir=output.parent) as raw_temp:
        temp = Path(raw_temp)
        bps_paths = []
        for resource in bps:
            path = temp / f"bps-{resource['year']}.zip"
            path.write_bytes(bytes(fetch(resource["url"], user_agent, binary=True)))
            bps_paths.append(path)
        cmed_path = temp / "cmed-pmvg.xlsx"
        cmed_path.write_bytes(bytes(fetch(cmed["url"], user_agent, binary=True)))
        next_path = temp / "health_enrichment.db"
        connection = sqlite3.connect(next_path)
        try:
            create_schema(connection)
            bps_count = import_bps(connection, bps_paths)
            cmed_count = import_cmed(connection, cmed_path)
            metadata = {
                "built_at": datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z"),
                "bps_records": str(bps_count), "cmed_records": str(cmed_count),
                "bps_sources": json.dumps(bps, ensure_ascii=False),
                "cmed_source": json.dumps(cmed, ensure_ascii=False),
            }
            connection.executemany("insert into metadata(key,value) values (?,?)", metadata.items())
            connection.execute("analyze")
            connection.commit()
            if connection.execute("pragma quick_check").fetchone()[0] != "ok":
                raise RuntimeError("SQLite quick_check falhou")
            if bps_count < 1000 or cmed_count < 1000:
                raise RuntimeError(f"Carga oficial abaixo do mínimo seguro: BPS={bps_count}, CMED={cmed_count}")
        finally:
            connection.close()
        os.replace(next_path, output)
    return {"bps_records": bps_count, "cmed_records": cmed_count, "output": str(output)}


def refresh(output: Path, state_path: Path, first_year: int, user_agent: str, force: bool = False) -> dict[str, object]:
    bps = discover_bps(user_agent, first_year)
    cmed = discover_cmed(user_agent)
    signature = json.dumps({"bps": bps, "cmed": cmed}, ensure_ascii=False, sort_keys=True)
    previous = json.loads(state_path.read_text()) if state_path.is_file() else {}
    if not force and output.is_file() and previous.get("signature") == signature:
        return {"updated": False, "reason": "Nenhuma nova publicação oficial detectada."}
    result = build(output, bps, cmed, user_agent)
    state_path.write_text(json.dumps({
        "signature": signature,
        "updated_at": datetime.now(UTC).isoformat(timespec="seconds"),
        **result,
    }, ensure_ascii=False, indent=2))
    return {"updated": True, **result}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--first-year", type=int, default=2023)
    parser.add_argument("--interval-seconds", type=int, default=86400)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    user_agent = os.getenv("BOLSA_HTTP_USER_AGENT", "BolsaDeLicitacoes/0.1")
    while True:
        try:
            print(json.dumps(refresh(args.output, args.state, args.first_year, user_agent, args.force), ensure_ascii=False), flush=True)
        except Exception as exc:
            print(json.dumps({"updated": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr, flush=True)
            if args.once:
                raise
        if args.once:
            return
        time.sleep(max(3600, args.interval_seconds))


if __name__ == "__main__":
    main()
