"""Compatibility layer: the sign pass now lives in `inview_worker.signage`.

Kept so existing imports (`signs.detect`, `signs.locate`, `signs.analyze`, `signs.Detection`) keep
working; new code should import from `inview_worker.signage` directly.
"""
from __future__ import annotations

from typing import Callable

import numpy as np

from .inputs import Frame
from .signage import analyze as _analyze
from .signage import placement
from .signage.plates import PLATE_COLORS, Detection, detect, iou as _iou, recognize, sign_plates, text_regions

MERGE_DISTANCE_M = _analyze.MERGE_DISTANCE_M

__all__ = ["PLATE_COLORS", "MERGE_DISTANCE_M", "Detection", "analyze", "detect", "locate", "recognize",
           "sign_plates", "text_regions", "_iou"]


def locate(detection: Detection, frame: Frame, width: int, height: int) -> list[float] | None:
    """Median depth position of the samples under the detection's box (sensor-native u/v)."""
    return placement.locate(detection.bbox, frame, width, height)


def analyze(frames: list[Frame], read_image: Callable[[str], np.ndarray | None], **kwargs) -> tuple[list[dict], int]:
    """Returns assessed, merged signs and the number of keyframes examined."""
    return _analyze.analyze(frames, read_image, **kwargs)
