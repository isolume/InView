"""Text observations from every engine, Apple Vision ingest, and IoU fusion across engines."""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from .imaging import bbox_of, iou_xywh

VISION_ASSET = "text-observations.json"


@dataclass
class Observation:
    frame_id: str
    image_asset: str | None
    image_size: tuple[int, int]            # (width, height) of the image the quad refers to
    quad: np.ndarray                       # ordered [bl, tl, tr, br] pixels
    text: str
    confidence: float
    engine: str                            # opencv_dnn | tesseract | apple_vision | opencv_mser
    detector: str
    model: str | None = None
    languages: list[str] = field(default_factory=list)
    readings: list[dict[str, Any]] = field(default_factory=list)

    def __post_init__(self) -> None:
        if not self.readings:
            self.readings = [self.reading()]

    def reading(self) -> dict[str, Any]:
        entry = {"engine": self.engine, "text": self.text, "confidence": round(float(self.confidence), 4)}
        if self.model:
            entry["model"] = self.model
        return entry

    @property
    def bbox_px(self) -> list[int]:
        return bbox_of(self.quad, *self.image_size)

    @property
    def bbox_norm(self) -> tuple[float, float, float, float]:
        x, y, w, h = self.bbox_px
        width, height = self.image_size
        return x / width, y / height, w / width, h / height


def parse_vision(raw: bytes | None) -> tuple[list[Observation], int]:
    """Apple Vision OCR observations (`text-observations.json`, schema 1); returns (observations, skipped).

    `bbox_norm` is [x, y, w, h] with a top-left origin on the upright image, `image_size_px` [w, h].
    """
    if not raw:
        return [], 0
    try:
        document = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return [], 1
    items = document.get("observations") if isinstance(document, dict) else None
    if not isinstance(items, list):
        return [], 1
    found, skipped = [], 0
    for item in items:
        try:
            width, height = (int(v) for v in item["image_size_px"])
            x, y, w, h = (float(v) for v in item["bbox_norm"])
            text = " ".join(str(item["text"]).split())
            if width <= 0 or height <= 0 or w <= 0 or h <= 0 or not text:
                raise ValueError("empty box or text")
            x0, y0 = max(0.0, x) * width, max(0.0, y) * height
            x1, y1 = min(1.0, x + w) * width, min(1.0, y + h) * height
            quad = np.array([[x0, y1], [x0, y0], [x1, y0], [x1, y1]], np.float32)
            languages = [str(language) for language in item.get("languages") or []]
            found.append(Observation(str(item["frame_id"]), item.get("image_asset"), (width, height), quad, text,
                                     float(np.clip(float(item.get("confidence", 0.5)), 0.0, 1.0)), "apple_vision",
                                     "apple_vision", None, languages))
        except (KeyError, TypeError, ValueError):
            skipped += 1
    return found, skipped


def _rank(observation: Observation) -> tuple[bool, float]:
    return bool(observation.text), observation.confidence


def fuse(primary: list[Observation], secondary: list[Observation], iou_threshold: float = 0.3) -> tuple[list[Observation], int]:
    """Merge two engines' observations of the same text (same frame, normalised-box IoU).

    Pairs are matched greedily by IoU. The merged observation keeps every engine's reading in
    `readings` and takes text, confidence and geometry from the better one (non-empty text first,
    then higher confidence). Returns (observations, number of fused pairs).
    """
    pairs = []
    for i, a in enumerate(primary):
        for j, b in enumerate(secondary):
            if a.frame_id == b.frame_id:
                overlap = iou_xywh(a.bbox_norm, b.bbox_norm)
                if overlap >= iou_threshold:
                    pairs.append((-overlap, i, j))
    used_a, used_b, merged = set(), set(), []
    for _, i, j in sorted(pairs):
        if i in used_a or j in used_b:
            continue
        used_a.add(i)
        used_b.add(j)
        a, b = primary[i], secondary[j]
        best, other = (a, b) if _rank(a) >= _rank(b) else (b, a)
        readings = sorted(a.readings + b.readings, key=lambda r: (-r["confidence"], r["engine"], r["text"]))
        merged.append(Observation(best.frame_id, best.image_asset, best.image_size, best.quad, best.text,
                                  best.confidence, best.engine, best.detector, best.model,
                                  best.languages or other.languages, readings))
    rest = [a for i, a in enumerate(primary) if i not in used_a] + [b for j, b in enumerate(secondary) if j not in used_b]
    return merged + rest, len(merged)
