"""Elevation profile along a straight map segment, for graph edges and route checks."""
from __future__ import annotations

import numpy as np

from ..contracts import Thresholds
from .elevation import HeightMap


def segment_profile(hm: HeightMap, a_xz, b_xz, level_change_tol_m: float = 0.02,
                    slope_window_m: float = 0.5) -> dict:
    """Rise, largest level change, running/cross slope and step-free screening between two points.

    `level_change_tol_m` absorbs sensor noise (ADA 303.2 allows 6.4 mm vertical, 12.7 mm beveled).
    Level changes are only measured between adjacent samples (half a cell apart), never across
    unknown gaps; running slope uses `slope_window_m` windows whose samples are all known and contain
    no level change. If any part of the segment lacks measured evidence, `step_free` and
    `meets_ramp_slope` cannot be True.
    """
    a, b = np.asarray(a_xz, float), np.asarray(b_xz, float)
    length = float(np.linalg.norm(b - a))
    count = max(2, int(np.ceil(length / (hm.grid.resolution / 2))) + 1)
    spacing = length / (count - 1)
    points = a + np.linspace(0, 1, count)[:, None] * (b - a)
    heights = hm.sample(hm.measured_elevation(), points).astype(np.float64)
    known = np.isfinite(heights)
    fraction = float(known.mean())
    result = {"length_m": round(length, 3), "known_fraction": round(fraction, 3), "rise_m": None,
              "max_level_change_m": None, "max_running_slope": None, "max_cross_slope": None,
              "step_free": None, "meets_ramp_slope": None}
    if known.sum() < 2:
        return result
    jumps = np.abs(np.diff(heights))                       # NaN wherever either sample is unknown
    max_jump = float(np.nanmax(jumps)) if np.isfinite(jumps).any() else 0.0
    window = max(1, int(round(slope_window_m / max(spacing, 1e-9))))
    running = None
    if count > window:
        bad = np.concatenate(([0], np.cumsum(~(jumps <= level_change_tol_m))))  # unknown or a level change
        clean = bad[window:] == bad[:-window]
        if clean.any():
            running = float((np.abs(heights[window:] - heights[:-window]) / (window * spacing))[clean].max())
    elif known.all() and length > 0:
        running = abs(float(heights[-1] - heights[0])) / length
    cross = None
    if length > 0:
        perpendicular = np.array([-(b - a)[1], (b - a)[0]]) / length
        across = np.abs(hm.sample(hm.slope_x, points) * perpendicular[0] + hm.sample(hm.slope_z, points) * perpendicular[1])
        across = across[np.isfinite(across)]
        cross = float(np.percentile(across, 90)) if across.size else None
    ends = heights[known]
    enough = bool(known.all())
    result.update(rise_m=round(float(ends[-1] - ends[0]), 3), max_level_change_m=round(max_jump, 3),
                  max_running_slope=None if running is None else round(running, 4),
                  max_cross_slope=None if cross is None else round(cross, 4))
    if max_jump > level_change_tol_m:
        result["step_free"] = False                         # A measured level change is conclusive.
    elif enough:
        result["step_free"] = True
    if running is not None and running > Thresholds.RAMP_MAX_SLOPE:
        result["meets_ramp_slope"] = False
    elif enough and running is not None:
        result["meets_ramp_slope"] = True
    return result
