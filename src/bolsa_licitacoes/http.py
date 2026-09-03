from __future__ import annotations

import json
import logging
import random
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from email.message import Message
from typing import Any, Callable, Mapping, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


log = logging.getLogger(__name__)


class PublicApiError(RuntimeError):
    def __init__(self, message: str, *, status: Optional[int] = None, url: str = ""):
        super().__init__(message)
        self.status = status
        self.url = url


@dataclass(frozen=True)
class HttpResponse:
    url: str
    status: int
    headers: Mapping[str, str]
    body: bytes
    duration_ms: int

    def json(self) -> Any:
        if not self.body:
            return None
        return json.loads(self.body.decode("utf-8"))


Transport = Callable[[Request, float], Any]


class PublicHttpClient:
    """Cliente GET conservador com timeout, retry e respeito a Retry-After."""

    def __init__(
        self,
        *,
        timeout: float = 30,
        retries: int = 3,
        user_agent: str = "BolsaDeLicitacoes/0.1",
        transport: Optional[Transport] = None,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.timeout = timeout
        self.retries = retries
        self.user_agent = user_agent
        self.transport = transport
        self.sleep = sleep

    def get(
        self,
        base_url: str,
        *,
        params: Optional[Mapping[str, Any]] = None,
        accept: str = "application/json",
    ) -> HttpResponse:
        clean_params = {k: v for k, v in (params or {}).items() if v is not None}
        query = urlencode(clean_params, doseq=True)
        url = f"{base_url}{'&' if '?' in base_url else '?'}{query}" if query else base_url
        request = Request(
            url,
            headers={"Accept": accept, "User-Agent": self.user_agent},
            method="GET",
        )

        last_error: Optional[BaseException] = None
        for attempt in range(self.retries + 1):
            started = time.monotonic()
            try:
                if self.transport is None and shutil.which("curl"):
                    response = _curl_get(url, accept, self.user_agent, self.timeout)
                    status, headers, body = response
                else:
                    transport = self.transport or (lambda req, timeout: urlopen(req, timeout=timeout))
                    with transport(request, self.timeout) as raw_response:
                        body = raw_response.read()
                        status = int(getattr(raw_response, "status", 200))
                        headers = _headers_dict(getattr(raw_response, "headers", {}))
                duration_ms = int((time.monotonic() - started) * 1000)
                log.info(
                    "http_get",
                    extra={"context": {"url": url, "status": status, "duration_ms": duration_ms}},
                )
                if status == 204:
                    return HttpResponse(url, status, headers, b"", duration_ms)
                if status == 429 or status >= 500:
                    last_error = PublicApiError(f"HTTP transitório {status}", status=status, url=url)
                    if attempt < self.retries:
                        self.sleep(_retry_delay(attempt, None, headers.get("retry-after")))
                        continue
                if status >= 400:
                    detail = body.decode("utf-8", errors="replace")[:1000]
                    raise PublicApiError(f"GET público falhou com HTTP {status}: {detail}", status=status, url=url)
                return HttpResponse(url, status, headers, body, duration_ms)
            except HTTPError as exc:
                body = exc.read()
                status = int(exc.code)
                duration_ms = int((time.monotonic() - started) * 1000)
                if status == 204:
                    return HttpResponse(url, 204, _headers_dict(exc.headers), b"", duration_ms)
                if status == 429 or status >= 500:
                    last_error = exc
                    if attempt < self.retries:
                        self.sleep(_retry_delay(attempt, exc.headers))
                        continue
                detail = body.decode("utf-8", errors="replace")[:1000]
                raise PublicApiError(
                    f"GET público falhou com HTTP {status}: {detail}", status=status, url=url
                ) from exc
            except (URLError, TimeoutError, OSError) as exc:
                last_error = exc
                if attempt < self.retries:
                    self.sleep(_retry_delay(attempt, None))
                    continue
                break

        raise PublicApiError(f"GET público indisponível após retries: {last_error}", url=url)


def _retry_delay(attempt: int, headers: Optional[Message], explicit: Optional[str] = None) -> float:
    raw = explicit
    if headers and not raw:
        raw = headers.get("Retry-After")
    if raw:
        try:
            return min(float(raw), 60.0)
        except ValueError:
            pass
    return min((2**attempt) + random.uniform(0, 0.25), 30.0)


def _headers_dict(headers: Any) -> dict[str, str]:
    if hasattr(headers, "items"):
        return {str(k).lower(): str(v) for k, v in headers.items()}
    return {}


def _curl_get(url: str, accept: str, user_agent: str, timeout: float) -> tuple[int, dict[str, str], bytes]:
    """Transporte subprocess seguro: argumentos sem shell e arquivos temporários isolados."""
    with tempfile.NamedTemporaryFile() as header_file, tempfile.NamedTemporaryFile() as body_file:
        result = subprocess.run(
            [
                shutil.which("curl") or "curl", "-sS", "-L", "--max-time", str(timeout),
                "-H", f"Accept: {accept}", "-H", f"User-Agent: {user_agent}",
                "-D", header_file.name, "-o", body_file.name, "-w", "%{http_code}", url,
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode:
            raise OSError(result.stderr.decode("utf-8", errors="replace")[:1000])
        status = int(result.stdout.decode("ascii")[-3:])
        header_file.seek(0); raw_headers = header_file.read().decode("iso-8859-1", errors="replace")
        body_file.seek(0); body = body_file.read()
    # -L pode produzir vários blocos; o último é a resposta efetiva.
    blocks = [block for block in raw_headers.replace("\r\n", "\n").split("\n\n") if block.strip()]
    final_block = blocks[-1] if blocks else ""
    headers: dict[str, str] = {}
    for line in final_block.splitlines()[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()
    return status, headers, body
