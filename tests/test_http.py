from __future__ import annotations

import io
import unittest
from email.message import Message
from urllib.error import HTTPError

from bolsa_licitacoes.http import PublicHttpClient


class FakeResponse:
    def __init__(self, body: bytes, status: int = 200) -> None:
        self._body = body
        self.status = status
        self.headers = Message()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self) -> bytes:
        return self._body


class HttpTests(unittest.TestCase):
    def test_retries_500_then_succeeds(self) -> None:
        attempts = []

        def transport(request, timeout):
            attempts.append(request.full_url)
            if len(attempts) == 1:
                raise HTTPError(request.full_url, 500, "boom", Message(), io.BytesIO(b"{}"))
            return FakeResponse(b'{"ok": true}')

        sleeps = []
        client = PublicHttpClient(retries=1, transport=transport, sleep=sleeps.append)
        response = client.get("https://example.test/api", params={"pagina": 1})
        self.assertEqual({"ok": True}, response.json())
        self.assertEqual(2, len(attempts))
        self.assertEqual(1, len(sleeps))

    def test_204_has_no_payload(self) -> None:
        client = PublicHttpClient(retries=0, transport=lambda request, timeout: FakeResponse(b"", 204))
        response = client.get("https://example.test/empty")
        self.assertEqual(204, response.status)
        self.assertIsNone(response.json())


if __name__ == "__main__":
    unittest.main()
