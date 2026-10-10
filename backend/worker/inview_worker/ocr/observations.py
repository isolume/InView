"""Text observations from every engine, Apple Vision ingest, and IoU fusion across engines."""
from __future__ import annotations

import json
import math
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


UPRIGHT_FROM_SENSOR = "upright_rotated_right_from_sensor"


def _finite(values, count: int) -> list[float]:
    """Exactly `count` finite floats, or ValueError (rejects NaN/inf, which survive `float()`)."""
    numbers = [float(v) for v in values]
    if len(numbers) != count or not all(math.isfinite(v) for v in numbers):
        raise ValueError("expected finite numbers")
    return numbers


def _upright_box(item: dict) -> list[float]:
    """Normalized top-left box in the upright image the iPhone OCR'd.

    `image_orientation` names how that image relates to the sensor-native frame. Today the iPhone only
    exports `upright_rotated_right_from_sensor`; files from before the field existed are the same. Any
    other orientation is accepted only with `bbox_sensor_norm`, which is rotated into upright coordinates
    (the inverse of `geometry.jpeg_to_sensor_uv`) so all engines share one representation.
    """
    orientation = item.get("image_orientation", UPRIGHT_FROM_SENSOR)
    if orientation == UPRIGHT_FROM_SENSOR:
        return _finite(item["bbox_norm"], 4)
    if "bbox_sensor_norm" in item and orientation == "sensor_native":
        u, v, w, h = _finite(item["bbox_sensor_norm"], 4)
        return [1.0 - v - h, u, h, w]
    raise ValueError(f"unsupported image orientation {orientation!r}")


def parse_vision(raw: bytes | None) -> tuple[list[Observation], int]:
    """Apple Vision OCR observations (`text-observations.json`, schema 1); returns (observations, skipped).

    `bbox_norm` is [x, y, w, h] with a top-left origin on the upright image, `image_size_px` [w, h].
    Entries with non-finite or empty geometry, non-finite confidence, or an unknown orientation are
    skipped individually.
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
            width, height = (int(v) for v in _finite(item["image_size_px"], 2))
            x, y, w, h = _upright_box(item)
            confidence = _finite([item.get("confidence", 0.5)], 1)[0]
            text = " ".join(str(item["text"]).split())
            if width <= 0 or height <= 0 or not text:
                raise ValueError("empty image or text")
            x0, y0 = min(max(x, 0.0), 1.0) * width, min(max(y, 0.0), 1.0) * height
            x1, y1 = min(max(x + w, 0.0), 1.0) * width, min(max(y + h, 0.0), 1.0) * height
            if x1 - x0 < 1 or y1 - y0 < 1:
                raise ValueError("box is empty after clipping to the image")
            quad = np.array([[x0, y1], [x0, y0], [x1, y0], [x1, y1]], np.float32)
            languages = [str(language) for language in item.get("languages") or []]
            found.append(Observation(str(item["frame_id"]), item.get("image_asset"), (width, height), quad, text,
                                     float(np.clip(confidence, 0.0, 1.0)), "apple_vision",
                                     "apple_vision", None, languages))
        except (KeyError, TypeError, ValueError, OverflowError):
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
