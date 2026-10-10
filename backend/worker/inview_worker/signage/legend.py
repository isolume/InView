"""Legend/background separation on a sign plate, WCAG contrast, and legend connected components."""
from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

# WCAG 2.x: 3:1 for large text and graphical objects (1.4.3 / 1.4.11), 4.5:1 for normal text.
CONTRAST_GRAPHICS_MIN = 3.0
CONTRAST_TEXT_MIN = 4.5


def _linear(channel: np.ndarray) -> np.ndarray:
    c = np.asarray(channel, np.float64) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def relative_luminance(bgr) -> float:
    """WCAG 2.x relative luminance of an sRGB color given as B, G, R (0..255)."""
    b, g, r = _linear(np.asarray(bgr, np.float64)[:3])
    return float(0.2126 * r + 0.7152 * g + 0.0722 * b)


def contrast_ratio(bgr_a, bgr_b) -> float:
    la, lb = sorted((relative_luminance(bgr_a), relative_luminance(bgr_b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


@dataclass
class Legend:
    mask: np.ndarray                 # uint8 legend mask (255) in plate-crop coordinates
    legend_bgr: tuple[int, int, int]
    background_bgr: tuple[int, int, int]
    contrast_ratio: float
    polarity: str                    # light_on_dark | dark_on_light
    legend_fraction: float


def split(crop: np.ndarray, region: np.ndarray | None = None, seed: int = 0) -> Legend | None:
    """Two-cluster k-means (Lab) inside `region`; the minority cluster is the legend.

    Cluster colors are the per-cluster median of the original sRGB pixels, so the contrast ratio is
    measured on what the camera recorded (exposure and white balance affect it: screening only).
    """
    if region is None:
        region = np.full(crop.shape[:2], 255, np.uint8)
    inside = region > 0
    if inside.sum() < 50:
        return None
    lab = cv2.cvtColor(np.ascontiguousarray(crop), cv2.COLOR_BGR2LAB)
    samples = lab[inside].astype(np.float32)
    if float(samples.std(axis=0).max()) < 4:
        return None  # uniform patch: no legend
    cv2.setRNGSeed(seed)
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.5)
    _, labels, _ = cv2.kmeans(samples, 2, None, criteria, 3, cv2.KMEANS_PP_CENTERS)
    labels = labels.ravel()
    counts = np.bincount(labels, minlength=2)
    legend_label = int(np.argmin(counts))
    if counts[legend_label] == counts[1 - legend_label]:
        legend_label = 1  # deterministic tie-break
    pixels = crop[inside]
    legend_bgr = np.median(pixels[labels == legend_label], axis=0)
    background_bgr = np.median(pixels[labels != legend_label], axis=0)
    mask = np.zeros(crop.shape[:2], np.uint8)
    mask[inside] = np.where(labels == legend_label, 255, 0).astype(np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
    ratio = contrast_ratio(legend_bgr, background_bgr)
    polarity = ("light_on_dark" if relative_luminance(legend_bgr) > relative_luminance(background_bgr)
                else "dark_on_light")
    return Legend(mask, tuple(int(c) for c in legend_bgr), tuple(int(c) for c in background_bgr),
                  round(float(ratio), 2), polarity, round(float(counts[legend_label] / counts.sum()), 4))


@dataclass
class Component:
    label: int
    bbox: tuple[int, int, int, int]  # x, y, w, h in crop coordinates
    area: int
    centroid: tuple[float, float]

    @property
    def x2(self) -> int:
        return self.bbox[0] + self.bbox[2]

    @property
    def y2(self) -> int:
        return self.bbox[1] + self.bbox[3]


def components(mask: np.ndarray, min_area: int) -> tuple[np.ndarray, list[Component]]:
    count, labels, stats, centroids = cv2.connectedComponentsWithStats((mask > 0).astype(np.uint8), connectivity=8)
    found = [Component(i, tuple(int(v) for v in stats[i, :4]), int(stats[i, 4]), (float(centroids[i, 0]), float(centroids[i, 1])))
             for i in range(1, count) if stats[i, 4] >= min_area]
    return labels, found


def bbox_gap(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> float:
    dx = max(0, max(a[0], b[0]) - min(a[0] + a[2], b[0] + b[2]))
    dy = max(0, max(a[1], b[1]) - min(a[1] + a[3], b[1] + b[3]))
    return float(np.hypot(dx, dy))


def union_bbox(boxes) -> tuple[int, int, int, int]:
    boxes = list(boxes)
    x0, y0 = min(b[0] for b in boxes), min(b[1] for b in boxes)
    x1, y1 = max(b[0] + b[2] for b in boxes), max(b[1] + b[3] for b in boxes)
    return x0, y0, x1 - x0, y1 - y0


def group(parts: list[Component], gap_ratio: float = 0.15) -> list[list[Component]]:
    """Union components whose boxes are closer than `gap_ratio` × the larger one's extent, or nested."""
    parent = list(range(len(parts)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, a in enumerate(parts):
        for j in range(i + 1, len(parts)):
            b = parts[j]
            extent = max(a.bbox[2], a.bbox[3], b.bbox[2], b.bbox[3])
            if bbox_gap(a.bbox, b.bbox) <= gap_ratio * extent:
                parent[find(i)] = find(j)
    groups: dict[int, list[Component]] = {}
    for i, part in enumerate(parts):
        groups.setdefault(find(i), []).append(part)
    return sorted(groups.values(), key=lambda g: (min(p.bbox[0] for p in g), min(p.bbox[1] for p in g)))
