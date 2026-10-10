"""Everything a stage can read: gathered inputs, package files, and upstream products."""
from __future__ import annotations

from dataclasses import dataclass, field
from functools import lru_cache
from typing import Any, Protocol

import cv2
import numpy as np

from ..inputs import ScanInputs
from .stage import Product


class DataSource(Protocol):
    """Read access to a scan's immutable package (manifest and files)."""

    def manifest(self) -> dict | None: ...

    def asset(self, name: str) -> bytes | None: ...


class MemorySource:
    """In-memory source for tests and offline runs."""

    def __init__(self, manifest: dict | None = None, assets: dict[str, bytes] | None = None):
        self._manifest, self._assets = manifest, dict(assets or {})

    def manifest(self) -> dict | None:
        return self._manifest

    def asset(self, name: str) -> bytes | None:
        return self._assets.get(name)


@dataclass
class ScanContext:
    scan_id: str
    inputs: ScanInputs
    source: DataSource = field(default_factory=MemorySource)
    products: dict[str, Product] = field(default_factory=dict)
    config: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self._manifest_loaded = False
        self._manifest: dict | None = None
        self.image = lru_cache(maxsize=64)(self._decode_image)

    def product(self, name: str) -> Product | None:
        return self.products.get(name)

    def json(self, name: str, default: Any = None) -> Any:
        product = self.products.get(name)
        return default if product is None else product.json

    def data(self, name: str, default: Any = None) -> Any:
        product = self.products.get(name)
        return default if product is None or product.data is None else product.data

    def manifest(self) -> dict | None:
        if not self._manifest_loaded:
            self._manifest, self._manifest_loaded = self.source.manifest(), True
        return self._manifest

    def asset(self, name: str) -> bytes | None:
        return self.source.asset(name)

    def _decode_image(self, name: str) -> np.ndarray | None:
        """BGR image for a package keyframe/still (cached). Callers must not modify it in place."""
        data = self.asset(name)
        if not data:
            return None
        image = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
        if image is not None:
            image.setflags(write=False)
        return image
