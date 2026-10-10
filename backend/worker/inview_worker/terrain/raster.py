"""Raster primitives for the 2.5D terrain model: mesh sampling, per-cell reductions, NaN-aware filters.

Everything works on the shared `geometry.Grid` (column = +X, row = +Z). Rasters are float32 with NaN
for "no evidence"; OpenCV filters never see NaN (they are filled or masked first).
"""
from __future__ import annotations

import cv2
import numpy as np

from ..geometry import Grid

_LATTICES: dict[int, np.ndarray] = {}
_CHUNK_POINTS = 2_000_000


def _lattice(subdivisions: int) -> np.ndarray:
    """Barycentric weights (M, 3) of a regular lattice on a triangle, vertices included."""
    if subdivisions not in _LATTICES:
        i, j = np.meshgrid(np.arange(subdivisions + 1), np.arange(subdivisions + 1), indexing="ij")
        keep = i + j <= subdivisions
        a, b = i[keep] / subdivisions, j[keep] / subdivisions
        _LATTICES[subdivisions] = np.column_stack((1 - a - b, a, b))
    return _LATTICES[subdivisions]


def sample_triangles(vertices: np.ndarray, triangles: np.ndarray, spacing: float,
                     max_subdivisions: int = 256) -> tuple[np.ndarray, np.ndarray]:
    """Dense points on every triangle (lattice spacing <= `spacing`) and the source triangle index.

    A barycentric lattice samples the exact triangle plane, so a sample's Y is the surface height at
    its X/Z; sampling at half the grid resolution touches every cell a triangle covers.
    """
    if not len(triangles):
        return np.zeros((0, 3)), np.zeros(0, np.int64)
    corners = vertices[triangles]
    edges = np.linalg.norm(corners - np.roll(corners, 1, axis=1), axis=2).max(axis=1)
    subdivisions = np.clip(np.ceil(edges / spacing), 1, max_subdivisions).astype(np.int64)
    points, owners = [], []
    for s in np.unique(subdivisions):
        weights = _lattice(int(s))
        chosen = np.flatnonzero(subdivisions == s)
        step = max(1, _CHUNK_POINTS // len(weights))
        for start in range(0, len(chosen), step):
            batch = chosen[start:start + step]
            points.append(np.einsum("mk,tkd->tmd", weights, corners[batch]).reshape(-1, 3))
            owners.append(np.repeat(batch, len(weights)))
    return np.concatenate(points), np.concatenate(owners)


def cell_index(grid: Grid, xz: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Flat row-major cell index of each X/Z point and the mask of points inside the grid."""
    cells = grid.int_cells(xz) if len(xz) else np.zeros((0, 2), np.int32)
    inside = grid.inside(cells)
    flat = cells[:, 1].astype(np.int64) * grid.width + cells[:, 0]
    return flat, inside


def cell_min(grid: Grid, flat: np.ndarray, values: np.ndarray) -> np.ndarray:
    """Per-cell minimum (NaN where no sample)."""
    out = np.full(grid.width * grid.height, np.inf)
    np.minimum.at(out, flat, values)
    out[np.isinf(out)] = np.nan
    return out.reshape(grid.height, grid.width).astype(np.float32)


def cell_count(grid: Grid, flat: np.ndarray) -> np.ndarray:
    return np.bincount(flat, minlength=grid.width * grid.height).reshape(grid.height, grid.width)


def fill_nearest(values: np.ndarray) -> np.ndarray:
    """Replace NaN with the nearest known value (distance-transform labels); all-NaN -> zeros."""
    known = np.isfinite(values)
    if known.all():
        return values.astype(np.float32, copy=True)
    if not known.any():
        return np.zeros_like(values, dtype=np.float32)
    _, labels = cv2.distanceTransformWithLabels(np.where(known, 0, 255).astype(np.uint8), cv2.DIST_L2, 5,
                                                labelType=cv2.DIST_LABEL_PIXEL)
    lookup = np.zeros(labels.max() + 1, np.float32)
    lookup[labels[known]] = values[known]
    return lookup[labels]


def nan_median(values: np.ndarray, ksize: int = 3) -> np.ndarray:
    """Edge-preserving median that ignores unknown cells and keeps them unknown."""
    known = np.isfinite(values)
    if not known.any():
        return values.copy()
    smoothed = cv2.medianBlur(fill_nearest(values), ksize)
    return np.where(known, smoothed, np.nan).astype(np.float32)


def nan_range(values: np.ndarray, ksize: int) -> np.ndarray:
    """Local max - min over known neighbours (morphological gradient); 0 where unknown."""
    known = np.isfinite(values)
    kernel = np.ones((ksize, ksize), np.uint8)
    high = cv2.dilate(np.where(known, values, -1e6).astype(np.float32), kernel)
    low = cv2.erode(np.where(known, values, 1e6).astype(np.float32), kernel)
    return np.where(known, high - low, 0).astype(np.float32)


def disk(radius_cells: int) -> np.ndarray:
    size = 2 * max(1, radius_cells) + 1
    return cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (size, size))


def gradient(values: np.ndarray, resolution: float, sigma_cells: float = 1.0) -> tuple[np.ndarray, np.ndarray]:
    """dY/dX and dY/dZ (rise/run) of a NaN-free raster: Gaussian pre-smoothing + 5x5 Sobel."""
    smooth = cv2.GaussianBlur(values.astype(np.float32), (0, 0), sigma_cells) if sigma_cells > 0 else values
    derivative, smoothing = cv2.getDerivKernels(1, 0, 5)
    # Response of the kernel to a unit-slope plane: sum(k_i * i) for the derivative times sum(smoothing).
    scale = float((derivative.ravel() * np.arange(-2, 3)).sum() * smoothing.sum()) * resolution
    gx = cv2.Sobel(smooth, cv2.CV_32F, 1, 0, ksize=5, borderType=cv2.BORDER_REPLICATE) / scale
    gz = cv2.Sobel(smooth, cv2.CV_32F, 0, 1, ksize=5, borderType=cv2.BORDER_REPLICATE) / scale
    return gx, gz


def polygon_xz(grid: Grid, mask: np.ndarray, epsilon_m: float = 0.05,
               window: tuple[slice, slice] | None = None) -> list[list[float]]:
    """Outline of the largest blob of `mask` in map coordinates (simplified with approxPolyDP).

    `window` is the crop `mask` was taken from, so its pixel offsets are added back."""
    contours, _ = cv2.findContours(mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return []
    contour = max(contours, key=cv2.contourArea)
    poly = cv2.approxPolyDP(contour, max(0.5, epsilon_m / grid.resolution), True).reshape(-1, 2)
    if len(poly) < 3:
        poly = cv2.boxPoints(cv2.minAreaRect(contour))
    r0, c0 = (window[0].start, window[1].start) if window else (0, 0)
    return [grid.world(float(c) + c0, float(r) + r0) for c, r in poly]


def footprint(grid: Grid, corners: np.ndarray) -> np.ndarray:
    """uint8 mask (255) of the X/Z convex hull of 3D corners, e.g. a RoomPlan box."""
    mask = np.zeros((grid.height, grid.width), np.uint8)
    hull = cv2.convexHull(np.round(grid.cells(corners[:, [0, 2]])).astype(np.int32))
    cv2.fillPoly(mask, [hull], 255)
    return mask


def crop(stats: np.ndarray, label: int, shape: tuple[int, int], margin: int) -> tuple[slice, slice]:
    """Window around a connected component's bounding box (from connectedComponentsWithStats)."""
    x, y, w, h = (int(v) for v in stats[label, :4])
    return (slice(max(y - margin, 0), min(y + h + margin, shape[0])),
            slice(max(x - margin, 0), min(x + w + margin, shape[1])))
