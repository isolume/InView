"""Per-edge routing attributes: clear width, slope, step-free status, hazards, walked evidence.

`step_free` rule (unknown is `None`, never assumed):
1. `False` when a barrier hazard crosses the edge: any `step` or `stairs` hazard, or a `level_change`
   / `drop_off` hazard with severity `barrier`.
2. Otherwise, with a height map covering the edge: `False` when neighbouring samples rise more than
   `step_rise_m`, else `True`.
3. Otherwise (no height map or no finite samples): `True` only when the floor is single-level (all
   RoomPlan floors within `Thresholds.LEVEL_CHANGE_MAX_M` of each other), else `None`.

`maximum_slope` comes from the height map (rise over at least `slope_baseline_m`) and from any ramp
hazard crossing the edge (its `measure.slope` / `running_slope`); `None` when neither is known.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from ..contracts import Thresholds
from . import measure
from .topology import GEdge, PixelGraph

STEP_KINDS = frozenset({"step", "stairs"})
BARRIER_KINDS = frozenset({"level_change", "drop_off"})
SLOPE_KEYS = ("slope", "running_slope", "max_slope", "maximum_slope")


@dataclass
class EdgeAttributes:
    length_m: float
    clear_width_m: float
    step_free: bool | None
    maximum_slope: float | None
    hazards: list[str] = field(default_factory=list)
    walked_fraction: float = 0.0
    step_free_basis: str = "unknown"


def single_level(roomplan: dict | None, floor_heights: list[float]) -> bool | None:
    """True when every known floor lies within the level-change tolerance; None without evidence."""
    heights = []
    stories = set()
    for room in (roomplan or {}).get("rooms") or []:
        if room.get("floor_y_m") is not None:
            heights.append(float(room["floor_y_m"]))
        if room.get("story") is not None:
            stories.add(room["story"])
    if not heights:
        heights = [float(h) for h in floor_heights]
    if not heights:
        return None
    return len(stories) <= 1 and (max(heights) - min(heights)) <= Thresholds.LEVEL_CHANGE_MAX_M


def elevation_raster(height_map, shape: tuple[int, int]) -> np.ndarray | None:
    """Accept an ndarray or an object/dict exposing `elevation` aligned with the floor grid."""
    raster = height_map if isinstance(height_map, np.ndarray) else None
    for name in ("elevation", "elevation_m", "height", "heights", "raster"):
        if raster is not None or height_map is None:
            break
        candidate = height_map.get(name) if isinstance(height_map, dict) else getattr(height_map, name, None)
        raster = candidate if isinstance(candidate, np.ndarray) else None
    if not isinstance(raster, np.ndarray) or raster.shape[:2] != tuple(shape):
        return None
    return raster.astype(np.float64)


def _ramp_slope(hazard: dict) -> float | None:
    measure_ = hazard.get("measure") or {}
    for key in SLOPE_KEYS:
        value = measure_.get(key)
        if value is not None and np.isfinite(value):
            return abs(float(value))
    return None


def compute(graph: PixelGraph, *, dt: np.ndarray, walkable: np.ndarray, walked: np.ndarray | None,
            grid, elevation: np.ndarray | None, hazards: list[dict] | None, level: bool | None,
            slope_baseline_m: float, step_rise_m: float, hazard_radius_m: float,
            cross_section_max_m: float) -> dict[int, EdgeAttributes]:
    res = grid.resolution
    masks = []
    for hazard in hazards or []:
        mask = measure.hazard_mask(hazard, grid, walkable.shape, hazard_radius_m)
        if mask is not None:
            masks.append((hazard, mask))
    result = {}
    for edge_id, edge in sorted(graph.edges.items()):
        result[edge_id] = _edge(graph, edge, dt, walkable, walked, res, elevation, masks, level,
                                slope_baseline_m, step_rise_m, cross_section_max_m)
    return result


def _edge(graph: PixelGraph, edge: GEdge, dt, walkable, walked, res, elevation, masks, level,
          slope_baseline_m, step_rise_m, cross_section_max_m) -> EdgeAttributes:
    if edge.kind == "skeleton":
        width = measure.medial_width_m(dt, edge.path, res)
    else:
        width = measure.cross_section_width_m(walkable, dt, edge.path[0], edge.path[-1], res, cross_section_max_m)
    caps = [c for c in (edge.width_cap_m, graph.nodes[edge.u].meta.get("width_cap_m"),
                        graph.nodes[edge.v].meta.get("width_cap_m")) if c]
    width = min([width, *caps])

    crossed = [(hazard, mask) for hazard, mask in masks if measure.touches(mask, edge.path)]
    hazard_ids = sorted(str(h.get("id")) for h, _ in crossed)
    blocked = any(h.get("kind") in STEP_KINDS or (h.get("kind") in BARRIER_KINDS and h.get("severity") == "barrier")
                  for h, _ in crossed)
    slope, rise = (measure.slope_and_step(elevation, edge.path, res, slope_baseline_m)
                   if elevation is not None else (None, None))
    ramp = [s for s in (_ramp_slope(h) for h, _ in crossed if h.get("kind") == "ramp") if s is not None]
    if ramp:
        slope = max([*ramp, *([slope] if slope is not None else [])])

    if blocked:
        step_free, basis = False, "hazard"
    elif rise is not None:
        step_free, basis = (rise <= step_rise_m), "height_map"
    elif level is True:
        step_free, basis = True, "single_level_floor"
    else:
        step_free, basis = None, "unknown"

    walked_fraction = 0.0
    if walked is not None:
        rows, cols, inside = measure.cells(measure.dense(edge.path), walked.shape)
        walked_fraction = float((walked[rows, cols][inside] > 0).mean()) if inside.any() else 0.0
    return EdgeAttributes(round(edge.length_px() * res, 3), round(float(width), 3), step_free,
                          None if slope is None else round(float(slope), 4), hazard_ids,
                          round(walked_fraction, 3), basis)
