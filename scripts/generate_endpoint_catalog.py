#!/usr/bin/env python3
"""Gera catálogo Markdown determinístico a partir de um OpenAPI oficial baixado."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("spec", type=Path)
    parser.add_argument("--public-only", action="store_true")
    args = parser.parse_args()
    spec = json.loads(args.spec.read_text(encoding="utf-8"))
    title = spec.get("info", {}).get("title", "API")
    version = spec.get("info", {}).get("version", "")
    print(f"# Catálogo de endpoints — {title}\n")
    print(f"Gerado do contrato OpenAPI oficial (`{spec.get('openapi')}`, versão `{version}`).\n")
    print("Todos os endpoints abaixo são apenas catalogados. O coletor usa somente operações GET públicas; rotas de autenticação, usuários e módulos restritos não são chamadas.\n")
    print("| Método | Endpoint | Finalidade | Parâmetros | HTTP |")
    print("|---|---|---|---|---|")
    for route, methods in sorted(spec.get("paths", {}).items()):
        for method, operation in methods.items():
            if method.lower() not in {"get", "post", "put", "patch", "delete"}:
                continue
            if args.public_only and (method.lower() != "get" or route.startswith(("/alice/", "/usuarios/", "/autenticacao/"))):
                continue
            params = []
            for param in operation.get("parameters", []):
                schema = param.get("schema", {})
                required = "*" if param.get("required") else ""
                limits = ""
                if schema.get("minimum") is not None or schema.get("maximum") is not None:
                    limits = f" [{schema.get('minimum','')}..{schema.get('maximum','')}]"
                params.append(f"`{param.get('name')}`{required}:{schema.get('type','?')}{limits}")
            responses = ", ".join(f"`{code}`" for code in operation.get("responses", {}))
            summary = (operation.get("summary") or operation.get("description") or "DADO NÃO DISPONÍVEL NA FONTE CONSULTADA").replace("\n", " ")
            print(f"| {method.upper()} | `{route}` | {summary} | {'; '.join(params) or '—'} | {responses or '—'} |")
    print("\n`*` = obrigatório. Os limites exibidos vêm do schema OpenAPI, quando publicados.\n")


if __name__ == "__main__":
    main()
