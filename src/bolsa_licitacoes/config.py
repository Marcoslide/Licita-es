from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    database_path: Path
    documents_path: Path
    timeout: float
    retries: int
    user_agent: str
    admin_api_token: str

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            database_path=Path(os.getenv("BOLSA_DATABASE_PATH", "data/bolsa_licitacoes.db")),
            documents_path=Path(os.getenv("BOLSA_DOCUMENTS_PATH", "data/documents")),
            timeout=float(os.getenv("BOLSA_HTTP_TIMEOUT", "30")),
            retries=int(os.getenv("BOLSA_HTTP_RETRIES", "3")),
            user_agent=os.getenv(
                "BOLSA_HTTP_USER_AGENT",
                "BolsaDeLicitacoes/0.1 (+contato-do-operador)",
            ),
            admin_api_token=os.getenv("BOLSA_ADMIN_API_TOKEN", ""),
        )
