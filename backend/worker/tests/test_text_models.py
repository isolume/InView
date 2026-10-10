"""Model manager: pinned checksums, atomic cached downloads, offline behaviour (no network)."""
import hashlib

import pytest

from inview_worker.ocr import models
from inview_worker.ocr.models import ModelSpec, ModelStore

PAYLOAD = b"fake onnx bytes" * 1000
SPEC = ModelSpec("toy", "toy.onnx", "https://example.invalid/toy.onnx", hashlib.sha256(PAYLOAD).hexdigest(), len(PAYLOAD))


def fetcher(payload=PAYLOAD, calls=None):
    def fetch(url):
        if calls is not None:
            calls.append(url)
        for start in range(0, len(payload), 4096):
            yield payload[start:start + 4096]
    return fetch


def test_download_verifies_and_caches(tmp_path):
    calls = []
    store = ModelStore(tmp_path, True, fetcher(calls=calls), {"toy": SPEC})
    path = store.path("toy")
    assert path == tmp_path / "toy.onnx" and path.read_bytes() == PAYLOAD
    assert store.path("toy") == path and calls == [SPEC.url]
    # A fresh store finds the verified file without fetching.
    assert ModelStore(tmp_path, True, fetcher(calls=calls), {"toy": SPEC}).path("toy") == path
    assert len(calls) == 1
    assert not list(tmp_path.glob("*.part"))


def test_checksum_mismatch_leaves_nothing_behind(tmp_path):
    store = ModelStore(tmp_path, True, fetcher(b"tampered"), {"toy": SPEC})
    assert store.path("toy") is None
    assert "checksum mismatch" in store.errors["toy"]
    assert list(tmp_path.iterdir()) == []


def test_corrupt_cache_is_replaced(tmp_path):
    (tmp_path / "toy.onnx").write_bytes(b"x" * len(PAYLOAD))
    store = ModelStore(tmp_path, True, fetcher(), {"toy": SPEC})
    assert not store.cached("toy")
    assert store.path("toy").read_bytes() == PAYLOAD


def test_offline_and_disabled_downloads_return_none(tmp_path):
    def offline(url):
        raise OSError("network unreachable")
        yield b""  # pragma: no cover

    store = ModelStore(tmp_path, True, offline, {"toy": SPEC})
    assert store.path("toy") is None and "network unreachable" in store.errors["toy"]
    disabled = ModelStore(tmp_path, False, fetcher(), {"toy": SPEC})
    assert disabled.path("toy") is None and "disabled" in disabled.errors["toy"]


def test_download_policy(monkeypatch, tmp_path):
    monkeypatch.delenv("INVIEW_MODEL_DOWNLOAD", raising=False)
    assert models.downloads_enabled() is True
    monkeypatch.setenv("INVIEW_MODEL_DOWNLOAD", "1")
    assert models.downloads_enabled() is True
    monkeypatch.setenv("INVIEW_MODEL_DOWNLOAD", "0")
    assert models.downloads_enabled() is False
    monkeypatch.setenv("INVIEW_MODEL_DIR", str(tmp_path))
    assert ModelStore().root == tmp_path


def test_oversized_download_is_stopped_and_removed(tmp_path):
    def oversized(url):
        yield PAYLOAD
        yield b"extra"
        raise AssertionError("download must stop at the size limit")

    store = ModelStore(tmp_path, True, oversized, {"toy": SPEC})
    assert store.path("toy") is None
    assert "exceeds expected size" in store.errors["toy"]
    assert list(tmp_path.iterdir()) == []


def test_unreadable_cache_uses_the_offline_fallback(tmp_path, monkeypatch):
    (tmp_path / "toy.onnx").write_bytes(PAYLOAD)

    def unreadable(path):
        raise PermissionError("unreadable model")

    monkeypatch.setattr(models, "sha256_file", unreadable)
    store = ModelStore(tmp_path, False, specs={"toy": SPEC})
    assert store.path("toy") is None


def test_parse_charsets_matches_reference_layout():
    source = "class X:\n    CHARSET_EN_36 = '''0\n1\na\n'''\n    CHARSET_CH_94 = '''\n0\n~'''\n"
    assert models.parse_charsets(source) == {"CHARSET_EN_36": ["0", "1", "a"], "CHARSET_CH_94": ["0", "~"]}


@pytest.mark.skipif(not ModelStore(allow_download=False).cached("crnn_charsets"), reason="CRNN charsets not cached")
def test_cached_reference_charsets_have_expected_sizes():
    path = ModelStore(allow_download=False).path("crnn_charsets")
    charsets = models.parse_charsets(path.read_text(encoding="utf-8"))
    assert {k: len(v) for k, v in charsets.items()} == {"CHARSET_EN_36": 36, "CHARSET_CH_94": 94, "CHARSET_CN_3944": 3944}
