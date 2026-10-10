"""Minimal authenticated client for the InView Rust backend (stdlib only)."""
from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


class BackendError(RuntimeError):
    def __init__(self, status: int, code: str | None, message: str):
        super().__init__(f"{status} {code or 'error'}: {message}")
        self.status, self.code = status, code


@dataclass
class Backend:
    base_url: str
    token: str | None = None
    timeout: float = 120

    def _request(self, method: str, path: str, body: bytes | None = None,
                 content_type: str = "application/json") -> bytes:
        url = self.base_url.rstrip("/") + path
        request = urllib.request.Request(url, data=body, method=method)
        request.add_header("Accept", "application/json")
        # ngrok's free tier otherwise answers non-browser clients with an HTML interstitial.
        request.add_header("ngrok-skip-browser-warning", "1")
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")
        if body is not None:
            request.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            payload = error.read()
            try:
                details = json.loads(payload)["error"]
                raise BackendError(error.code, details.get("code"), details.get("message", "")) from None
            except (ValueError, KeyError, TypeError):
                raise BackendError(error.code, None, payload[:200].decode(errors="replace")) from None

    def get_json(self, path: str) -> Any:
        return json.loads(self._request("GET", path))

    def optional_json(self, path: str) -> Any | None:
        """Returns None for a 404/422 (missing scan layer), raising other failures."""
        try:
            return self.get_json(path)
        except BackendError as error:
            if error.status in (404, 422):
                return None
            raise

    def get_bytes(self, path: str) -> bytes:
        return self._request("GET", path)

    def put_json(self, path: str, value: Any) -> Any:
        return json.loads(self._request("PUT", path, json.dumps(value, separators=(",", ":")).encode()))

    @staticmethod
    def segment(value: str) -> str:
        return urllib.parse.quote(value, safe="")
