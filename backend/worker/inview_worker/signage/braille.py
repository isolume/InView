"""Braille dot-grid evidence: `SimpleBlobDetector` dots that sit on a regular lattice.

Braille cells are 2 × 3 dots with a uniform dot pitch (ADA 703.3.1: 0.090–0.100 in within a cell,
0.241–0.300 in between cells). We accept a blob set when the dots are similar in size, most nearest
neighbors are one pitch apart, and the dots fall onto at most a few rows per line spaced one pitch
apart. In photos braille is often invisible (same color as the plate), so absence is not evidence.
"""
from __future__ import annotations

import cv2
import numpy as np


def _detector(min_d: float, max_d: float, color: int):
    params = cv2.SimpleBlobDetector_Params()
    params.filterByColor, params.blobColor = True, color
    params.filterByArea = True
    params.minArea, params.maxArea = float(np.pi * (min_d / 2) ** 2), float(np.pi * (max_d / 2) ** 2)
    params.filterByCircularity, params.minCircularity = True, 0.65
    params.filterByConvexity, params.minConvexity = True, 0.8
    params.filterByInertia, params.minInertiaRatio = True, 0.45
    params.minThreshold, params.maxThreshold, params.thresholdStep = 30, 230, 10
    params.minDistBetweenBlobs = max(1.0, min_d)
    return cv2.SimpleBlobDetector_create(params)


def _cluster_1d(values: np.ndarray, tolerance: float) -> list[float]:
    centers: list[list[float]] = []
    for value in np.sort(values):
        if centers and value - np.mean(centers[-1]) <= tolerance:
            centers[-1].append(float(value))
        else:
            centers.append([float(value)])
    return [float(np.mean(c)) for c in centers]


def lattice(points: np.ndarray, sizes: np.ndarray) -> dict | None:
    """Regular-spacing check on dot centers (pixels); returns grid stats or None."""
    if len(points) < 6:
        return None
    if sizes.std() / max(sizes.mean(), 1e-6) > 0.35:
        return None
    distances = np.linalg.norm(points[:, None] - points[None], axis=-1)
    np.fill_diagonal(distances, np.inf)
    nearest = distances.min(axis=1)
    pitch = float(np.median(nearest))
    if pitch < 1.5 * sizes.mean() * 0.5 or pitch > 4 * sizes.mean():
        return None  # dots touching or too sparse for braille
    regular = np.mean((nearest > 0.75 * pitch) & (nearest < 1.3 * pitch))
    if regular < 0.8:
        return None
    # Undo camera roll: the lattice's dominant axis from nearest-neighbor directions (mod 90°).
    partner = distances.argmin(axis=1)
    vectors = points[partner] - points
    angles = np.arctan2(vectors[:, 1], vectors[:, 0])
    roll = float(np.angle(np.mean(np.exp(4j * angles)))) / 4
    c, s = np.cos(-roll), np.sin(-roll)
    points = (points - points.mean(axis=0)) @ np.array([[c, -s], [s, c]]).T
    rows = _cluster_1d(points[:, 1], 0.3 * pitch)
    on_rows = np.mean([np.min(np.abs(np.array(rows) - y)) < 0.3 * pitch for y in points[:, 1]])
    gaps = np.diff(rows)
    if on_rows < 0.9 or not len(gaps) or np.any(gaps < 0.7 * pitch):
        return None
    # Within a braille line consecutive rows are one pitch apart (lines are separated by more).
    in_line = gaps[gaps < 1.5 * pitch]
    if not len(in_line) or np.mean(np.abs(in_line - pitch) < 0.3 * pitch) < 0.8:
        return None
    columns = _cluster_1d(points[:, 0], 0.3 * pitch)
    return {"dots": int(len(points)), "rows": len(rows), "columns": len(columns),
            "dot_pitch_px": round(pitch, 2), "cells_estimate": max(1, round(len(columns) / 2))}


def detect(gray: np.ndarray, max_dot_fraction: float = 0.06) -> dict | None:
    """Look for a braille dot lattice anywhere in `gray` (a plate crop)."""
    h, w = gray.shape[:2]
    if min(h, w) < 16:
        return None
    max_d = max(4.0, max_dot_fraction * min(h, w))
    best = None
    for color in (255, 0):
        keypoints = _detector(2.0, max_d, color).detect(gray)
        if len(keypoints) < 6 or len(keypoints) > 400:
            continue
        points = np.float64([k.pt for k in keypoints])
        sizes = np.float64([k.size for k in keypoints])
        found = lattice(points, sizes)
        if found and (best is None or found["dots"] > best["dots"]):
            xs, ys = points[:, 0], points[:, 1]
            found["bbox_px"] = [int(xs.min() - sizes.max()), int(ys.min() - sizes.max()),
                                int(np.ptp(xs) + 2 * sizes.max()), int(np.ptp(ys) + 2 * sizes.max())]
            found["dot_color"] = "light" if color == 255 else "dark"
            best = found
    return best
