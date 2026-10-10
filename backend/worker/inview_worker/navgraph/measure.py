"""Raster measurements along graph polylines: line of sight, clear width, slope, hazards.

Clear-width rules (screening, conservative because unknown space counts as non-walkable):
- Skeleton edges run along the medial axis, so the clear width at each sample is twice its distance
  to the nearest non-walkable cell, minus one cell for the discrete distance transform; the edge
  reports the minimum along its pixel path.
- Connectors (doors, places, regions) are straight lines that need not be medial. Their width is the
  minimum perpendicular cross-section: rays cast both ways at right angles to the line until they
  leave the walkable raster (capped at `cross_section_max_m`), like `doors.measure_clear_width`.
"""
from __future__ import annotations

import cv2
import numpy as np


def dense(path: np.ndarray, step_px: float = 0.5) -> np.ndarray:
    """Resample a polyline so consecutive samples are at most `step_px` apart."""
    path = np.asarray(path, dtype=np.float64)
    out = [path[:1]]
    for a, b in zip(path[:-1], path[1:]):
        n = max(1, int(np.ceil(np.linalg.norm(b - a) / step_px)))
        t = np.arange(1, n + 1, dtype=np.float64)[:, None] / n
        out.append(a + (b - a) * t)
    return np.vstack(out)


def cells(points: np.ndarray, shape: tuple[int, int]) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """(rows, cols, inside) for float (col, row) points."""
    cols = np.round(points[:, 0]).astype(np.int64)
    rows = np.round(points[:, 1]).astype(np.int64)
    inside = (rows >= 0) & (cols >= 0) & (rows < shape[0]) & (cols < shape[1])
    return np.clip(rows, 0, shape[0] - 1), np.clip(cols, 0, shape[1] - 1), inside


def clear_line(mask: np.ndarray, a, b) -> bool:
    """True when every cell on the straight segment a->b is set in `mask`."""
    rows, cols, inside = cells(dense(np.array([a, b], dtype=np.float64)), mask.shape)
    return bool(inside.all() and (mask[rows, cols] > 0).all())


def exit_then_clear(walkable: np.ndarray, a, b) -> bool:
    """The segment may start inside an obstacle (a wall-mounted place) but once it reaches walkable
    space it must stay there until `b`."""
    rows, cols, inside = cells(dense(np.array([a, b], dtype=np.float64)), walkable.shape)
    if not inside.all():
        return False
    ok = walkable[rows, cols] > 0
    first = int(np.argmax(ok)) if ok.any() else len(ok)
    return bool(ok[first:].all()) and first < len(ok)


def path_clear(mask: np.ndarray, path: np.ndarray) -> bool:
    rows, cols, inside = cells(dense(path), mask.shape)
    return bool(inside.all() and (mask[rows, cols] > 0).all())


def medial_width_m(dt: np.ndarray, path: np.ndarray, resolution: float) -> float:
    rows, cols, _ = cells(dense(path), dt.shape)
    minimum = float(dt[rows, cols].min())
    return max(resolution, (2 * minimum - 1) * resolution)


def _ray(walkable: np.ndarray, starts: np.ndarray, direction: np.ndarray, limit_px: float) -> np.ndarray:
    """Free run (pixels) from each start along `direction` before leaving the walkable raster."""
    steps = np.arange(0.0, limit_px + 0.5, 0.5)
    probe = starts[:, None, :] + steps[None, :, None] * direction[None, None, :]
    rows, cols, inside = cells(probe.reshape(-1, 2), walkable.shape)
    blocked = (~inside | (walkable[rows, cols] == 0)).reshape(len(starts), len(steps))
    first = np.where(blocked.any(axis=1), blocked.argmax(axis=1), len(steps) - 1)
    return steps[first]


def cross_section_width_m(walkable: np.ndarray, dt: np.ndarray, a, b, resolution: float,
                          limit_m: float) -> float:
    """Minimum perpendicular free span along the straight segment a->b (a point: medial width)."""
    a, b = np.asarray(a, dtype=np.float64), np.asarray(b, dtype=np.float64)
    length = float(np.linalg.norm(b - a))
    if length < 0.5:
        return medial_width_m(dt, np.array([a, b]), resolution)
    along = (b - a) / length
    normal = np.array([-along[1], along[0]])
    samples = dense(np.array([a, b]))
    rows, cols, _ = cells(samples, walkable.shape)
    samples = samples[walkable[rows, cols] > 0]
    if not len(samples):
        return resolution
    limit_px = limit_m / resolution
    span = _ray(walkable, samples, normal, limit_px) + _ray(walkable, samples, -normal, limit_px)
    # Each ray stops inside the first blocked cell: remove that half-cell per side.
    return max(resolution, (float(span.min()) - 1.0) * resolution)


def hazard_mask(hazard: dict, grid, shape: tuple[int, int], radius_m: float) -> np.ndarray | None:
    mask = np.zeros(shape, np.uint8)
    polygon = hazard.get("polygon_xz_m")
    if polygon and len(polygon) >= 3:
        pts = np.round(grid.cells(np.asarray(polygon, dtype=np.float64))).astype(np.int32)
        cv2.fillPoly(mask, [pts], 255)
    position = hazard.get("position_m")
    if position is not None and len(position) == 3 and not mask.any():
        centre = grid.cells(np.array([[position[0], position[2]]], dtype=np.float64))[0]
        cv2.circle(mask, (int(round(centre[0])), int(round(centre[1]))),
                   max(1, int(round(radius_m / grid.resolution))), 255, -1)
    return mask if mask.any() else None


def touches(mask: np.ndarray, path: np.ndarray) -> bool:
    rows, cols, inside = cells(dense(path), mask.shape)
    return bool((mask[rows[inside], cols[inside]] > 0).any())


def profile(elevation: np.ndarray, path: np.ndarray, resolution: float) -> tuple[np.ndarray, np.ndarray]:
    """(distance along path in m, elevation), preserving unknown samples as NaN."""
    samples = dense(path, 1.0)
    rows, cols, inside = cells(samples, elevation.shape)
    s = np.concatenate(([0.0], np.cumsum(np.linalg.norm(np.diff(samples, axis=0), axis=1)))) * resolution
    h = np.where(inside, elevation[rows, cols], np.nan)
    return s, h


def slope_and_step(elevation: np.ndarray, path: np.ndarray, resolution: float,
                   baseline_m: float) -> tuple[float | None, float | None, bool]:
    """Maximum |rise/run| over runs of at least `baseline_m`, and the largest rise between
    neighbouring samples (a step indicator), plus whether the whole edge was measured.

    Missing cells never establish a safe maximum slope or absence of steps. A measured rise may
    still rule an edge out even when the rest of the edge is unknown.
    """
    s, h = profile(elevation, path, resolution)
    if len(s) < 2 or np.isfinite(h).sum() < 2:
        return None, None, False
    rises = np.abs(np.diff(h))
    gaps = np.diff(s)
    adjacent = np.isfinite(rises) & (gaps <= 1.5 * resolution + 1e-9)
    max_rise = float(rises[adjacent].max()) if adjacent.any() else None
    if not np.isfinite(h).all():
        return None, max_rise, False
    total = float(s[-1] - s[0])
    if total <= 1e-9:
        return 0.0, max_rise, True
    baseline = min(baseline_m, total)
    j = np.searchsorted(s, s + baseline - 1e-9)
    valid = j < len(s)
    if not valid.any():
        return float(abs(h[-1] - h[0]) / total), max_rise, True
    i = np.nonzero(valid)[0]
    slopes = np.abs(h[j[valid]] - h[i]) / np.maximum(s[j[valid]] - s[i], 1e-9)
    return float(slopes.max()), max_rise, True
