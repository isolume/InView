"""Door and opening clearance screening against the floor map.

RoomPlan reports each door/opening's nominal width. The measured clear width is the free span
across the doorway in the obstacle raster (walls, ARKit mesh, LiDAR depth, furniture), which
catches jambs, door leaves, or furniture that narrow the usable opening. Screening only.
"""
from __future__ import annotations

import numpy as np

from .floor_map import FloorMap, _segment
from .geometry import box_corners
from .inputs import ScanInputs

DOOR_MIN_CLEAR_M = 0.815  # 32 in (2010 ADA §404.2.3).
OPENING_MIN_CLEAR_M = 0.915  # 36 in accessible-route width (§403.5.1).
HEADROOM_MIN_M = 2.03  # 80 in (§307.4).
PROBE_OFFSETS_M = np.linspace(-0.15, 0.15, 7)


def _free_run(floor_map: FloorMap, start: np.ndarray, direction: np.ndarray, limit: float) -> float | None:
    grid, step = floor_map.grid, floor_map.grid.resolution / 2
    for distance in np.arange(0, limit + step, step):
        col, row = grid.int_cells((start + direction * distance)[None])[0]
        if not (0 <= col < grid.width and 0 <= row < grid.height):
            return None
        if floor_map.obstacle[row, col]:
            return float(distance)
    return None


def measure_clear_width(floor_map: FloorMap, a: np.ndarray, b: np.ndarray) -> tuple[float | None, bool]:
    """Narrowest free span across the doorway; also reports a blocked doorway centre."""
    width = float(np.linalg.norm(b - a))
    along = (b - a) / max(width, 1e-9)
    normal = np.array([-along[1], along[0]])
    centre = (a + b) / 2
    spans, blocked = [], False
    for offset in PROBE_OFFSETS_M:
        start = centre + normal * offset
        col, row = floor_map.grid.int_cells(start[None])[0]
        if 0 <= col < floor_map.grid.width and 0 <= row < floor_map.grid.height and floor_map.obstacle[row, col]:
            blocked = True
            continue
        left = _free_run(floor_map, start, -along, width / 2 + 0.6)
        right = _free_run(floor_map, start, along, width / 2 + 0.6)
        if left is not None and right is not None:
            # Each probe stops inside the first obstacle cell: remove that half-cell per side.
            spans.append(max(0.0, left + right - floor_map.grid.resolution))
    return (min(spans) if spans else None), blocked


def check(inputs: ScanInputs, floor_map: FloorMap | None) -> list[dict]:
    results = []
    for surface in inputs.surfaces:
        if surface.kind not in ("door", "opening"):
            continue
        corners = box_corners(surface.matrix, surface.dimensions)
        a, b = _segment(corners)
        nominal = float(np.linalg.norm(b - a))
        height = float(corners[:, 1].max() - corners[:, 1].min())
        required = DOOR_MIN_CLEAR_M if surface.kind == "door" else OPENING_MIN_CLEAR_M
        measured, blocked = measure_clear_width(floor_map, a, b) if floor_map else (None, False)
        governing = measured if measured is not None else nominal
        issues = []
        if blocked:
            issues.append("obstacle_at_doorway_centre (door leaf closed or object during capture?)")
        if governing < required:
            issues.append(f"clear_width_below_{required:.3f}_m")
        if height < HEADROOM_MIN_M:
            issues.append(f"headroom_below_{HEADROOM_MIN_M:.2f}_m")
        results.append({
            "id": surface.id,
            "kind": surface.kind,
            "center_xz_m": [round(float(v), 3) for v in (a + b) / 2],
            "span_xz_m": [[round(float(v), 3) for v in a], [round(float(v), 3) for v in b]],
            "nominal_width_m": round(nominal, 3),
            "height_m": round(height, 3),
            "measured_clear_width_m": None if measured is None else round(measured, 3),
            "required_min_clear_width_m": required,
            "meets_clear_width": governing >= required,
            "meets_headroom": height >= HEADROOM_MIN_M,
            "issues": issues,
            "method": "obstacle_raster_span" if measured is not None else "roomplan_nominal_width",
        })
    return results
