"""Text-line detection: OpenCV DNN DB (multi-scale + CLAHE, rotated NMS) with an MSER fallback."""
from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
from typing import Protocol

import cv2
import numpy as np

from .imaging import clahe, order_quad, quad_size

DB_MEAN = (123.675, 116.28, 103.53)
DB_SCALE = tuple(1.0 / 255.0 / np.array([0.229, 0.224, 0.225]))


@dataclass
class Region:
    quad: np.ndarray        # ordered [bl, tl, tr, br] float32 pixels in the source image
    score: float
    detector: str           # db_ppocrv3 | mser


class Detector(Protocol):
    name: str

    def detect(self, bgr: np.ndarray) -> list[Region]: ...


def _round32(value: float) -> int:
    return max(32, int(round(value / 32.0)) * 32)


def input_sizes(width: int, height: int, long_sides=(736, 1280), max_upscale: float = 2.0) -> list[tuple[int, int]]:
    """Aspect-preserving DB input sizes (multiples of 32), capped at `max_upscale` × the image."""
    longest = max(width, height)
    sizes = []
    for side in long_sides:
        side = min(side, longest * max_upscale)
        size = (_round32(width * side / longest), _round32(height * side / longest))
        if size not in sizes:
            sizes.append(size)
    return sizes


def rotated_nms(regions: list[Region], iou_threshold: float = 0.3) -> list[Region]:
    """Merge overlapping detections from several scales/variants (`cv2.dnn.NMSBoxesRotated`)."""
    if not regions:
        return []
    rects = [cv2.minAreaRect(r.quad.astype(np.float32)) for r in regions]
    keep = cv2.dnn.NMSBoxesRotated(rects, [float(r.score) for r in regions], 0.0, iou_threshold)
    keep = np.asarray(keep, dtype=int).reshape(-1)
    return [regions[i] for i in sorted(keep.tolist(), key=lambda i: (-regions[i].score, i))]


@lru_cache(maxsize=4)
def _db_model(path: str):
    return cv2.dnn_TextDetectionModel_DB(cv2.dnn.readNet(path))


class DbDetector:
    """PP-OCRv3 Differentiable-Binarization detector run at several scales and on a CLAHE copy."""

    name = "db_ppocrv3"

    def __init__(self, model_path: str, long_sides=(736, 1280), use_clahe: bool = True,
                 binary_threshold: float = 0.3, polygon_threshold: float = 0.5, unclip_ratio: float = 2.0,
                 min_score: float = 0.6, min_height_px: float = 6.0, max_candidates: int = 200):
        self.model = _db_model(str(model_path))
        self.long_sides, self.use_clahe = tuple(long_sides), use_clahe
        self.min_score, self.min_height_px = min_score, min_height_px
        self.model.setBinaryThreshold(binary_threshold)
        self.model.setPolygonThreshold(polygon_threshold)
        self.model.setUnclipRatio(unclip_ratio)
        self.model.setMaxCandidates(max_candidates)

    def _run(self, bgr: np.ndarray, size: tuple[int, int]) -> list[Region]:
        self.model.setInputParams(1.0 / 255.0, size, DB_MEAN, True)
        self.model.setInputScale(DB_SCALE)
        quads, scores = self.model.detect(bgr)
        found = []
        for quad, score in zip(quads, np.asarray(scores).reshape(-1)):
            if score < self.min_score:
                continue
            ordered = order_quad(quad)
            if quad_size(ordered)[1] < self.min_height_px:
                continue
            found.append(Region(ordered, float(score), self.name))
        return found

    def detect(self, bgr: np.ndarray) -> list[Region]:
        height, width = bgr.shape[:2]
        sizes = input_sizes(width, height, self.long_sides)
        regions = [r for size in sizes for r in self._run(bgr, size)]
        if self.use_clahe:
            regions += self._run(clahe(bgr), sizes[0])
        return rotated_nms(regions)


class MserDetector:
    """Offline fallback: MSER character candidates chained into text lines (axis-aligned)."""

    name = "mser"

    def detect(self, bgr: np.ndarray) -> list[Region]:
        gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
        height, width = gray.shape
        mser = cv2.MSER_create(5, 30, int(0.02 * width * height))
        _, boxes = mser.detectRegions(gray)
        chars = [b for b in boxes if 0.008 * height <= b[3] <= 0.15 * height and 0.1 <= b[2] / b[3] <= 2.5]
        if len(chars) < 3:
            return []
        mask = np.zeros_like(gray)
        for x, y, w, h in chars:
            mask[y:y + h, x:x + w] = 255
        char_height = int(np.median([b[3] for b in chars]))
        kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (max(3, int(0.8 * char_height)), 1))
        joined = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
        contours, _ = cv2.findContours(joined, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        centers = np.array([[x + w / 2, y + h / 2] for x, y, w, h in chars])
        found = []
        for contour in contours:
            x, y, w, h = cv2.boundingRect(contour)
            inside = int(((centers[:, 0] >= x) & (centers[:, 0] <= x + w)
                          & (centers[:, 1] >= y) & (centers[:, 1] <= y + h)).sum())
            if inside < 3 or w < 1.5 * h or h > 0.2 * height:
                continue
            contrast = float(gray[y:y + h, x:x + w].std())
            if contrast < 20:
                continue
            pad = max(2, h // 5)
            x0, y0, x1, y1 = max(0, x - pad), max(0, y - pad), min(width, x + w + pad), min(height, y + h + pad)
            quad = np.array([[x0, y1], [x0, y0], [x1, y0], [x1, y1]], np.float32)
            found.append(Region(quad, round(min(1.0, inside / 10) * min(1.0, contrast / 64), 3), self.name))
        return sorted(found, key=lambda r: (-r.score, float(r.quad[1, 1]), float(r.quad[1, 0])))
