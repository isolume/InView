"""OpenCV-zoo text models: pinned URLs and SHA-256 checksums, cached downloads, charsets.

Files are fetched on first use from Hugging Face at a pinned commit, verified, and written atomically
(temporary file in the cache directory, then `os.replace`). Nothing here raises for a missing model:
`ModelStore.path` returns None and the caller falls back (MSER detection, Tesseract, or regions
without text).

Cache directory: `INVIEW_MODEL_DIR`, default `~/.cache/inview-worker/models`.
Downloads are disabled with `INVIEW_MODEL_DOWNLOAD=0`, and by default while pytest runs (tests never
use the network) unless `INVIEW_MODEL_DOWNLOAD=1` opts in.
"""
from __future__ import annotations

import hashlib
import logging
import os
import re
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator

log = logging.getLogger(__name__)

_HF = "https://huggingface.co/opencv"
_DET_REV = "c299e81aedeaf5d4f741fccccea491fb32db005f"   # opencv/text_detection_ppocr
_REC_REV = "6487ac545965a2c277aff293e2fdded8b0e6f9b9"   # opencv/text_recognition_crnn


@dataclass(frozen=True)
class ModelSpec:
    key: str
    filename: str
    url: str
    sha256: str
    size: int


MODELS: dict[str, ModelSpec] = {spec.key: spec for spec in (
    # PP-OCRv3 Differentiable Binarization detector (the zoo's EN and CN files are byte-identical).
    ModelSpec("detector_db", "text_detection_en_ppocrv3_2023may.onnx",
              f"{_HF}/text_detection_ppocr/resolve/{_DET_REV}/text_detection_en_ppocrv3_2023may.onnx",
              "03f550c6b406fda8bf54bd8327815f6c7e2edd98cea02348c93d879254366587", 2_423_490),
    # CRNN-CTC recognizers. EN: 36 lowercase alphanumerics (grayscale input). CH: 94 printable ASCII,
    # case-sensitive (colour input). CN: 3944 Chinese + Latin characters (colour input).
    ModelSpec("crnn_en", "text_recognition_CRNN_EN_2021sep.onnx",
              f"{_HF}/text_recognition_crnn/resolve/{_REC_REV}/text_recognition_CRNN_EN_2021sep.onnx",
              "a84b1f6e11a65c2d733cb0cc1f014aae3f99051e3f11447dc282faa678eee544", 33_823_087),
    ModelSpec("crnn_ch", "text_recognition_CRNN_CH_2021sep.onnx",
              f"{_HF}/text_recognition_crnn/resolve/{_REC_REV}/text_recognition_CRNN_CH_2021sep.onnx",
              "2dc566fd01ac2118b25c6960508ebd758b64c421a2bfa78dc05401ada6737e0b", 64_906_971),
    ModelSpec("crnn_cn", "text_recognition_CRNN_CN_2021nov.onnx",
              f"{_HF}/text_recognition_crnn/resolve/{_REC_REV}/text_recognition_CRNN_CN_2021nov.onnx",
              "c760bf82d684b87dfabb288e6c0f92d41a8cd6c1780661ca2c3cd10c2065a9ba", 72_807_160),
    # The zoo's reference implementation, which carries the CRNN charsets (CHARSET_EN_36/CH_94/CN_3944).
    ModelSpec("crnn_charsets", "text_recognition_crnn_reference.py",
              f"{_HF}/text_recognition_crnn/resolve/{_REC_REV}/crnn.py",
              "349e7262b1d1e87041d56cad30d062685acec5dce9e9f333f030bdc36d283004", 19_493),
)}

# Recognizer key -> (charset name in the reference file, grayscale input).
RECOGNIZERS: dict[str, tuple[str, bool]] = {
    "crnn_en": ("CHARSET_EN_36", True),
    "crnn_ch": ("CHARSET_CH_94", False),
    "crnn_cn": ("CHARSET_CN_3944", False),
}


def default_model_dir() -> Path:
    return Path(os.environ.get("INVIEW_MODEL_DIR") or Path.home() / ".cache" / "inview-worker" / "models")


def downloads_enabled() -> bool:
    flag = os.environ.get("INVIEW_MODEL_DOWNLOAD", "").strip().lower()
    if flag in {"0", "false", "no", "off"}:
        return False
    if flag in {"1", "true", "yes", "on"}:
        return True
    return "PYTEST_CURRENT_TEST" not in os.environ


def _urllib_fetch(url: str) -> Iterator[bytes]:
    request = urllib.request.Request(url, headers={"User-Agent": "inview-worker"})
    with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310 - pinned https URLs
        while chunk := response.read(1 << 20):
            yield chunk


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while chunk := handle.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


class ModelStore:
    """Checksummed model cache. `fetch(url)` yields byte chunks (injectable for tests)."""

    def __init__(self, root: Path | str | None = None, allow_download: bool | None = None,
                 fetch: Callable[[str], Iterator[bytes]] = _urllib_fetch,
                 specs: dict[str, ModelSpec] | None = None):
        self.root = Path(root) if root is not None else default_model_dir()
        self.allow_download = downloads_enabled() if allow_download is None else allow_download
        self.fetch = fetch
        self.specs = MODELS if specs is None else specs
        self.errors: dict[str, str] = {}
        self._verified: dict[str, Path] = {}

    def cached(self, key: str) -> bool:
        """True when the file is present with the right checksum (never downloads)."""
        spec = self.specs[key]
        target = self.root / spec.filename
        if key in self._verified:
            return True
        if target.is_file() and target.stat().st_size == spec.size and sha256_file(target) == spec.sha256:
            self._verified[key] = target
            return True
        return False

    def path(self, key: str) -> Path | None:
        """Verified local path, downloading when allowed; None (with `errors[key]`) otherwise."""
        if self.cached(key):
            return self._verified[key]
        spec = self.specs[key]
        if not self.allow_download:
            self.errors[key] = "not cached and downloads are disabled"
            return None
        try:
            self._download(spec)
        except Exception as error:  # noqa: BLE001 - offline or corrupt: callers fall back
            log.warning("model %s unavailable: %s", spec.filename, error)
            self.errors[key] = f"{type(error).__name__}: {error}"
            return None
        self._verified[key] = self.root / spec.filename
        self.errors.pop(key, None)
        return self._verified[key]

    def _download(self, spec: ModelSpec) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        digest, size = hashlib.sha256(), 0
        handle = tempfile.NamedTemporaryFile(dir=self.root, prefix=f".{spec.filename}.", suffix=".part", delete=False)
        try:
            with handle:
                for chunk in self.fetch(spec.url):
                    digest.update(chunk)
                    size += len(chunk)
                    handle.write(chunk)
            if digest.hexdigest() != spec.sha256:
                raise ValueError(f"checksum mismatch for {spec.filename}: {digest.hexdigest()} ({size} bytes)")
            os.replace(handle.name, self.root / spec.filename)
        except BaseException:
            Path(handle.name).unlink(missing_ok=True)
            raise
        log.info("downloaded %s (%d bytes)", spec.filename, size)


def parse_charsets(source: str) -> dict[str, list[str]]:
    """Charsets from the zoo's reference `crnn.py` (one character per line in triple quotes)."""
    found = {}
    for name, body in re.findall(r"(CHARSET_\w+) = '''(.*?)'''", source, re.S):
        found[name] = list("".join(body.splitlines()))
    return found
