"""Hazard screening on the 2.5D height map: level changes, steps, drop-offs, stairs, ramps,
low headroom and protruding objects. Every hazard follows `contracts.Hazard`.

- Level changes are elevation discontinuities (3x3 morphological gradient of the walking surface);
  their rise is the 5x5 gradient, so a riser is measured between the two plateaus, not across one cell.
- Stairs are families of parallel risers (thinning + probabilistic Hough + `cv2.fitLine`) with a
  regular tread spacing and monotonic tread elevations, or RoomPlan `stairs` objects.
- Ramps are connected regions steeper than a walking surface (ADA 403.3: 1:20) validated by a robust
  least-squares plane; running/cross slope come from the `minAreaRect` axes.
- Overhead hazards compare cane-detectable geometry (< 0.685 m) with geometry between 0.685 m and
  2.03 m above the walking surface (ADA 307.2/307.4); a distance transform gives the protrusion depth.

Screening evidence only, never certification.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import cv2
import numpy as np

from ..contracts import Thresholds
from ..geometry import box_corners
from ..inputs import Box
from .elevation import HeightMap
from .raster import crop, disk, fill_nearest, footprint, nan_range, polygon_xz

KIND_ORDER = ("stairs", "drop_off", "step", "level_change", "ramp", "low_headroom", "protruding_object")


@dataclass(frozen=True)
class HazardParams:
    min_rise_m: float = 0.025              # sensor noise floor; ADA 303 allows <= 0.0127 m
    step_min_m: float = 0.05               # below: level_change (lip/threshold)
    step_max_m: float = 0.20               # above: drop_off
    min_edge_length_m: float = 0.25
    min_side_support: float = 0.3         # each plateau needs this many cells per edge cell
    riser_range_m: tuple[float, float] = (0.08, 0.26)
    tread_range_m: tuple[float, float] = (0.18, 0.55)
    min_risers: int = 2
    ramp_candidate_factor: float = 0.8     # candidates from 0.8 * 1:20, confirmed by the plane fit
    ramp_steep_max: float = 0.30
    min_ramp_area_m2: float = 0.3
    ramp_fit_rms_m: float = 0.03
    ramp_max_rise_m: float = 0.76          # ADA 405.6: 30 in per ramp run
    head_level_m: float = 1.5              # overhangs above this are headroom, below are protrusions
    min_overhead_area_m2: float = 0.02
    furniture: tuple[str, ...] = ("table", "bed", "sofa", "chair")


def _r(value: float, digits: int = 3) -> float:
    return round(float(value), digits)


def _unit(vector: np.ndarray) -> list[float]:
    norm = float(np.linalg.norm(vector))
    return [_r(v / norm) + 0.0 for v in vector] if norm > 1e-9 else [0.0, 0.0]  # + 0.0: no "-0.0"


def _position(hm: HeightMap, mask: np.ndarray, y: float | None = None,
              window: tuple[slice, slice] | None = None) -> list[float]:
    """Centroid of `mask` (a crop at `window`, or full-grid) as [x, y, z]; y defaults to the surface."""
    rows, cols = np.nonzero(mask)
    r0, c0 = (window[0].start, window[1].start) if window else (0, 0)
    x, z = hm.grid.world(float(cols.mean()) + c0, float(rows.mean()) + r0)
    if y is None:
        values = (hm.elevation[window] if window else hm.elevation)[rows, cols]
        y = float(np.nanmedian(values)) if np.isfinite(values).any() else hm.floor_height
    return [x, _r(y), z]


def _footprint(hm: HeightMap, box: Box) -> np.ndarray:
    return footprint(hm.grid, box_corners(box.matrix, box.dimensions))


# --- level changes --------------------------------------------------------------------------------

_SECOND_DIFFERENCES = [np.array(k, np.float32) for k in (
    [[0, 0, 0], [1, -2, 1], [0, 0, 0]], [[0, 1, 0], [0, -2, 0], [0, 1, 0]],
    [[1, 0, 0], [0, -2, 0], [0, 0, 1]], [[0, 0, 1], [0, -2, 0], [1, 0, 0]])]


def edges(hm: HeightMap, params: HazardParams) -> tuple[np.ndarray, np.ndarray]:
    """Discontinuity cells of the walking surface and the plateau-to-plateau rise at each cell.

    A cell is an edge when its 3x3 height range exceeds `min_rise_m` *and* the surface bends there
    (largest |second difference| over four directions). A plane of any slope, at any grid resolution,
    has zero second difference, so ramps never become steps; a riser of height h scores h.
    """
    known = np.isfinite(hm.elevation)
    filled = fill_nearest(hm.elevation)
    bend = np.max([np.abs(cv2.filter2D(filled, cv2.CV_32F, k, borderType=cv2.BORDER_REPLICATE))
                   for k in _SECOND_DIFFERENCES], axis=0)
    edge = known & (nan_range(hm.elevation, 3) > params.min_rise_m) & (bend > params.min_rise_m)
    return edge, nan_range(hm.elevation, 5)


def level_changes(hm: HeightMap, edge: np.ndarray, rise: np.ndarray, params: HazardParams,
                  suppress: np.ndarray) -> list[dict]:
    res = hm.grid.resolution
    count, labels, stats, _ = cv2.connectedComponentsWithStats(edge.astype(np.uint8), connectivity=8)
    hazards = []
    for label in range(1, count):
        length = stats[label, cv2.CC_STAT_AREA] * res / 2  # The band is two cells wide.
        if length < params.min_edge_length_m:
            continue
        window = crop(stats, label, edge.shape, 3)
        cells = labels[window] == label
        if (cells & (suppress[window] > 0)).sum() > 0.5 * cells.sum():
            continue
        height = float(np.median(rise[window][cells]))
        if height <= params.min_rise_m:
            continue
        kind = ("level_change" if height < params.step_min_m else "step" if height <= params.step_max_m
                else "drop_off")
        elevation = hm.elevation[window]
        around = cv2.dilate(cells.astype(np.uint8), disk(2)) > 0
        values = elevation[around & np.isfinite(elevation)]
        upper, lower = float(np.percentile(values, 90)), float(np.percentile(values, 10))
        # A real level change separates two plateaus; a stray spike has almost no upper (or lower) side.
        middle = (upper + lower) / 2
        if min((values > middle).sum(), (values < middle).sum()) < params.min_side_support * cells.sum():
            continue
        uphill = np.array([np.nanmean(hm.slope_x[window][cells]), np.nanmean(hm.slope_z[window][cells])])
        hazards.append({
            "kind": kind,
            "position_m": _position(hm, cells, middle, window),
            "polygon_xz_m": polygon_xz(hm.grid, cells, window=window),
            "measure": {"rise_m": _r(height), "length_m": _r(length, 2), "upper_y_m": _r(upper),
                        "lower_y_m": _r(lower)},
            "down_direction_xz": _unit(-uphill),
            "severity": "warning" if kind == "level_change" else "barrier",
            "issues": ["level_change_exceeds_0.5_in"] if height > Thresholds.LEVEL_CHANGE_MAX_M else [],
            "method": "elevation_discontinuity",
        })
    return hazards


def unprotected_drops(hm: HeightMap, params: HazardParams, suppress: np.ndarray) -> list[dict]:
    """Walkable edges that end at a lower level which was seen but not walked: balcony and platform
    edges, stair wells, loading docks. `level_changes` only sees surfaces connected to the floor by
    small steps, so the lower side of these never reaches it.

    Edges backed by tall geometry (a wall, railing or glass within a cell) are protected and skipped."""
    lower = hm.lower_seen
    if lower is None:
        return []
    measured = np.isfinite(hm.measured_elevation())
    seen = np.isfinite(lower)
    if not measured.any() or not seen.any():
        return []
    reach = disk(2)
    upper = cv2.dilate(np.where(measured, hm.elevation, -np.inf).astype(np.float32), reach)
    near_walk = cv2.dilate(measured.astype(np.uint8), reach) > 0
    drop = np.where(np.isfinite(upper), upper - np.where(seen, lower, np.nan), np.nan)
    below = seen & near_walk & (drop > hm.params.max_step_m)
    support = cv2.dilate(below.astype(np.uint8), reach) > 0
    guarded = cv2.dilate((hm.mid > 0).astype(np.uint8), reach) > 0
    edge = measured & support & ~guarded & (suppress == 0)
    res = hm.grid.resolution
    count, labels, stats, _ = cv2.connectedComponentsWithStats(edge.astype(np.uint8), connectivity=8)
    hazards = []
    for label in range(1, count):
        cells = labels == label
        rows, cols = np.nonzero(cells)
        length = float(max(cv2.minAreaRect(np.column_stack([cols, rows]).astype(np.float32))[1])) * res + res
        if length < params.min_edge_length_m:
            continue
        window = crop(stats, label, edge.shape, 4)
        local_lower = below[window] & (cv2.dilate(cells[window].astype(np.uint8), reach) > 0)
        if local_lower.sum() * res * res < 0.03:  # speckle: a real lower level covers a few dm2 at least
            continue
        depth = float(np.median(drop[window][local_lower]))
        top = float(np.median(hm.elevation[cells]))
        down = np.array(hm.grid.world(float(np.nonzero(local_lower)[1].mean()) + window[1].start,
                                      float(np.nonzero(local_lower)[0].mean()) + window[0].start)) \
            - np.array(hm.grid.world(float(cols.mean()), float(rows.mean())))
        hazards.append({
            "kind": "drop_off",
            "position_m": _position(hm, cells, top),
            "polygon_xz_m": polygon_xz(hm.grid, cells),
            "measure": {"rise_m": _r(depth), "length_m": _r(length, 2), "upper_y_m": _r(top),
                        "lower_y_m": _r(top - depth)},
            "down_direction_xz": _unit(down),
            "severity": "barrier",
            "issues": ["unprotected_drop"],
            "method": "unreached_lower_surface",
        })
    return hazards


# --- stairs ----------------------------------------------------------------------------------------

def _risers(mask: np.ndarray, res: float) -> list[dict]:
    """Straight riser lines: thinning, probabilistic Hough, then collinear segments merged by fitLine."""
    if not mask.any():
        return []
    thin = cv2.ximgproc.thinning(mask.astype(np.uint8) * 255)
    lines = cv2.HoughLinesP(thin, 1, np.pi / 180, threshold=max(4, int(round(0.2 / res))),
                            minLineLength=max(4, int(round(0.35 / res))), maxLineGap=2)
    if lines is None:
        return []
    groups: list[dict] = []
    for x1, y1, x2, y2 in sorted(map(tuple, lines.reshape(-1, 4).tolist())):
        p, q = np.array([x1, y1], float), np.array([x2, y2], float)
        theta = math.atan2(q[1] - p[1], q[0] - p[0]) % math.pi
        for group in groups:
            dtheta = abs(theta - group["theta"]) % math.pi
            normal = np.array([-math.sin(group["theta"]), math.cos(group["theta"])])
            if min(dtheta, math.pi - dtheta) < math.radians(10) and \
                    abs(normal @ ((p + q) / 2) - group["offset"]) < 0.1 / res:
                group["points"] += [p, q]
                break
        else:
            normal = np.array([-math.sin(theta), math.cos(theta)])
            groups.append({"theta": theta, "offset": float(normal @ ((p + q) / 2)), "points": [p, q]})
    risers = []
    for group in groups:
        points = np.array(group["points"], np.float32)
        vx, vy, x0, y0 = cv2.fitLine(points, cv2.DIST_L2, 0, 0.01, 0.01).ravel()
        if vx < 0 or (abs(vx) < 1e-9 and vy < 0):
            vx, vy = -vx, -vy
        direction, origin = np.array([vx, vy]), np.array([x0, y0])
        t = (points - origin) @ direction
        risers.append({"direction": direction, "origin": origin, "t": (float(t.min()), float(t.max()))})
    return risers


def _tread_height(hm: HeightMap, center: np.ndarray, direction: np.ndarray, half: float) -> float:
    samples = [center + direction * s for s in np.linspace(-half, half, 5)]
    values = []
    for c, r in np.round(samples).astype(int):
        if 0 <= r < hm.grid.height and 0 <= c < hm.grid.width:
            window = hm.elevation[max(r - 1, 0):r + 2, max(c - 1, 0):c + 2]
            if np.isfinite(window).any():
                values.append(float(np.nanmedian(window)))
    return float(np.median(values)) if values else math.nan


def stairs(hm: HeightMap, edge: np.ndarray, rise: np.ndarray, params: HazardParams) -> list[dict]:
    res = hm.grid.resolution
    lo, hi = params.riser_range_m
    risers = _risers(edge & (rise >= lo) & (rise <= hi), res)
    used, hazards = set(), []
    for i, base in enumerate(risers):
        if i in used:
            continue
        u = base["direction"]
        n = np.array([-u[1], u[0]])
        family = [j for j, other in enumerate(risers) if j not in used and abs(float(other["direction"] @ u)) > math.cos(math.radians(12))]
        family.sort(key=lambda j: float(n @ risers[j]["origin"]))

        def span(j: int) -> np.ndarray:  # Riser extent along the family direction `u`.
            return (risers[j]["origin"] - base["origin"]) @ u + np.array(risers[j]["t"]) * float(risers[j]["direction"] @ u)

        # Greedy chaining in offset order: a riser extends the chain whose last riser it overlaps
        # along `u` at a tread-like spacing. Parallel edges elsewhere in the map (no overlap) are
        # skipped by that chain instead of breaking it.
        chains: list[list[int]] = []
        for j in family:
            a = span(j)
            for chain in chains:
                b = span(chain[-1])
                overlap = min(a.max(), b.max()) - max(a.min(), b.min())
                spacing = float(n @ risers[j]["origin"] - n @ risers[chain[-1]]["origin"]) * res
                if overlap >= 0.5 * min(np.ptp(a), np.ptp(b)) and \
                        params.tread_range_m[0] <= spacing <= params.tread_range_m[1]:
                    chain.append(j)
                    break
            else:
                chains.append([j])
        for chain in chains:
            if len(chain) < params.min_risers:
                continue
            offsets = np.array([n @ risers[j]["origin"] for j in chain])
            spans = np.array([span(j) for j in chain])
            start, end = float(spans.min(axis=1).max()), float(spans.max(axis=1).min())
            if end <= start:
                continue
            spacing = float(np.median(np.diff(offsets)))
            mid_t = (start + end) / 2
            anchor = base["origin"] + u * mid_t
            stations = [offsets[0] - spacing / 2, *((offsets[:-1] + offsets[1:]) / 2), offsets[-1] + spacing / 2]
            heights = np.array([_tread_height(hm, anchor + n * (o - n @ anchor), u, (end - start) / 3) for o in stations])
            rises = np.diff(heights)
            if not np.isfinite(rises).all() or not (np.all(rises > 0) or np.all(rises < 0)):
                continue
            if not np.all((np.abs(rises) >= lo) & (np.abs(rises) <= hi)):
                continue
            used.update(chain)
            sign = 1.0 if rises[0] > 0 else -1.0
            low_o, high_o = stations[0], stations[-1]
            t0, t1 = float(spans.min()), float(spans.max())
            corners = [base["origin"] + u * t + n * (o - n @ base["origin"]) for t, o in
                       ((t0, low_o), (t1, low_o), (t1, high_o), (t0, high_o))]
            mask = np.zeros(edge.shape, np.uint8)
            cv2.fillPoly(mask, [np.round(np.array(corners)).astype(np.int32)], 255)
            risers_abs = np.abs(rises)
            tread = spacing * res
            issues = []
            if risers_abs.min() < 0.1016 or risers_abs.max() > 0.1778:
                issues.append("riser_height_outside_4_to_7_in")
            if tread < 0.279:
                issues.append("tread_depth_below_11_in")
            if np.ptp(risers_abs) > 0.0095:
                issues.append("riser_heights_not_uniform")
            x, z = hm.grid.world(*map(float, np.array(corners).mean(axis=0)))
            hazards.append({
                "kind": "stairs",
                "position_m": [x, _r(np.nanmean(heights)), z],
                "polygon_xz_m": [hm.grid.world(*map(float, c)) for c in corners],
                "measure": {"risers": float(len(rises)), "rise_m": _r(risers_abs.mean()),
                            "riser_min_m": _r(risers_abs.min()), "riser_max_m": _r(risers_abs.max()),
                            "tread_depth_m": _r(tread), "total_rise_m": _r(abs(heights[-1] - heights[0])),
                            "width_m": _r((t1 - t0) * res, 2)},
                "ascending_direction_xz": _unit(n * sign),
                "severity": "barrier", "issues": issues, "method": "hough_parallel_risers",
                "sources": [], "_mask": mask,
            })
    return hazards


def roomplan_stairs(hm: HeightMap, objects: list[Box], found: list[dict]) -> list[dict]:
    """Attach RoomPlan stairs objects to detected stairs, or report them on their own."""
    hazards = []
    for box in sorted((o for o in objects if o.category == "stairs"), key=lambda o: o.id):
        footprint = _footprint(hm, box)
        if not footprint.any():
            continue
        match = next((h for h in found if (h["_mask"] & footprint).any()), None)
        if match is not None:
            match["sources"].append(f"roomplan:object:{box.id}")
            continue
        corners = box_corners(box.matrix, box.dimensions)
        height = float(np.ptp(corners[:, 1]))
        hazards.append({
            "kind": "stairs",
            "position_m": [_r(v) for v in box.matrix[:3, 3]],
            "polygon_xz_m": polygon_xz(hm.grid, footprint > 0),
            "measure": {"total_rise_m": _r(height), "risers_estimated": float(max(1, round(height / 0.17))),
                        "width_m": _r(min(box.dimensions[0], box.dimensions[2]), 2)},
            "severity": "barrier", "issues": [], "method": "roomplan_object",
            "sources": [f"roomplan:object:{box.id}"], "_mask": footprint,
        })
    return hazards


# --- ramps -----------------------------------------------------------------------------------------

def ramps(hm: HeightMap, edge: np.ndarray, params: HazardParams) -> list[dict]:
    res = hm.grid.resolution
    known = np.isfinite(hm.slope)
    slope = np.where(known, hm.slope, 0)
    candidate = (known & (slope >= params.ramp_candidate_factor * Thresholds.RUNNING_SLOPE_MAX)
                 & (slope <= params.ramp_steep_max) & ~(cv2.dilate(edge.astype(np.uint8), disk(2)) > 0))
    candidate = cv2.morphologyEx(candidate.astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    count, labels, stats, _ = cv2.connectedComponentsWithStats(candidate, connectivity=8)
    hazards = []
    for label in range(1, count):
        if stats[label, cv2.CC_STAT_AREA] * res ** 2 < params.min_ramp_area_m2:
            continue
        window = crop(stats, label, candidate.shape, 1)
        cells = labels[window] == label
        rows, cols = np.nonzero(cells)
        rows, cols = rows + window[0].start, cols + window[1].start
        x, z = hm.grid.x0 + cols * res, hm.grid.z0 + rows * res
        y = hm.elevation[rows, cols].astype(np.float64)
        design = np.column_stack((x - x.mean(), z - z.mean(), np.ones_like(x)))
        inliers = np.isfinite(y)
        for _ in range(2):  # Least squares, then refit on inliers (robust to edge cells).
            coef, *_ = np.linalg.lstsq(design[inliers], y[inliers], rcond=None)
            residual = y - design @ coef
            inliers = np.isfinite(y) & (np.abs(residual) < max(0.02, 2.5 * float(np.nanstd(residual[inliers]))))
        rms = float(np.sqrt(np.mean(residual[inliers] ** 2)))
        grad = coef[:2]
        steepness = float(np.linalg.norm(grad))
        if rms > params.ramp_fit_rms_m or not (Thresholds.RUNNING_SLOPE_MAX < steepness <= params.ramp_steep_max):
            continue
        box = cv2.boxPoints(cv2.minAreaRect(np.column_stack((cols, rows)).astype(np.float32)))
        axes = [box[1] - box[0], box[2] - box[1]]
        lengths = [float(np.linalg.norm(a)) for a in axes]
        units = [a / max(l, 1e-9) for a, l in zip(axes, lengths)]
        along = int(np.argmax([abs(float(grad @ unit)) for unit in units]))
        running, cross = abs(float(grad @ units[along])), abs(float(grad @ units[1 - along]))
        run = (lengths[along] + 1) * res
        rise = running * run
        issues = []
        if running > Thresholds.RAMP_MAX_SLOPE:
            issues.append("running_slope_exceeds_1_12")
        if cross > Thresholds.CROSS_SLOPE_MAX:
            issues.append("cross_slope_exceeds_1_48")
        if rise > params.ramp_max_rise_m:
            issues.append("rise_exceeds_30_in_per_run")
        hazards.append({
            "kind": "ramp",
            "position_m": _position(hm, cells, window=window),
            "polygon_xz_m": polygon_xz(hm.grid, cells, window=window),
            "measure": {"running_slope": _r(running, 4), "cross_slope": _r(cross, 4), "run_per_rise": _r(1 / running, 1),
                        "rise_m": _r(rise), "run_m": _r(run, 2), "width_m": _r((lengths[1 - along] + 1) * res, 2),
                        "fit_rms_m": _r(rms, 4)},
            "ascending_direction_xz": _unit(grad),
            "severity": "barrier" if running > Thresholds.RAMP_MAX_SLOPE else "warning",
            "issues": issues, "method": "sobel_slope_plane_fit",
        })
    return hazards


# --- overhead --------------------------------------------------------------------------------------

def overhead(hm: HeightMap, objects: list[Box], params: HazardParams) -> list[dict]:
    """Low headroom (ADA 307.4) and protruding objects (ADA 307.2) over the walking surface."""
    if not hm.measured or not hm.mid.any():
        return []
    res = hm.grid.resolution
    clearance = np.where(np.isfinite(hm.clearance), hm.clearance, np.inf)
    overhang = (hm.walking > 0) & (hm.mid > 0) & (hm.low == 0) & (clearance < Thresholds.HEADROOM_MIN_M)
    if not overhang.any():
        return []
    # Distance from each cell to the nearest cane-detectable footprint (walls, posts, object bases).
    solid = _solid_footprints(hm, clearance, params)
    overhang &= ~solid
    beyond = cv2.distanceTransform(np.where(solid, 0, 255).astype(np.uint8), cv2.DIST_L2, 5) * res \
        if solid.any() else np.full(overhang.shape, np.inf, np.float32)
    furniture = np.zeros(overhang.shape, np.uint8)
    for box in objects:
        if box.category in params.furniture:
            furniture |= _footprint(hm, box)
    min_cells = max(2, int(math.ceil(params.min_overhead_area_m2 / res ** 2)))
    hazards = []
    layers = (("protruding_object", overhang & (clearance < params.head_level_m)),
              ("low_headroom", overhang & (clearance >= params.head_level_m)
               & (beyond > Thresholds.PROTRUSION_MAX_DEPTH_M)))
    for kind, layer in layers:
        count, labels, stats, _ = cv2.connectedComponentsWithStats(layer.astype(np.uint8), connectivity=8)
        for label in range(1, count):
            area = int(stats[label, cv2.CC_STAT_AREA])
            if area < min_cells:
                continue
            window = crop(stats, label, layer.shape, 1)
            cells = labels[window] == label
            if (cells & (furniture[window] > 0)).sum() > 0.5 * area:
                continue
            reach, height = beyond[window][cells], clearance[window][cells]
            depth = float(reach.max())
            if kind == "protruding_object" and depth <= Thresholds.PROTRUSION_MAX_DEPTH_M:
                continue
            # The underside height is read where the object overhangs past the allowance, so
            # wall samples spilling into the cells right next to a wall do not lower it.
            core = reach > Thresholds.PROTRUSION_MAX_DEPTH_M
            edge_height = float(np.percentile(height[core] if core.any() else height, 10))
            surface = float(np.nanmedian(hm.elevation[window][cells]))
            if kind == "protruding_object":
                measure = {"protrusion_m": _r(min(depth, 99.0)), "leading_edge_height_m": _r(edge_height),
                           "area_m2": _r(area * res ** 2)}
                issues = ["protrudes_more_than_4_in_between_27_and_80_in"]
            else:
                measure = {"clearance_min_m": _r(height.min()), "clearance_median_m": _r(np.median(height)),
                           "area_m2": _r(area * res ** 2)}
                issues = ["headroom_below_80_in"]
            hazards.append({
                "kind": kind,
                "position_m": _position(hm, cells, surface + edge_height, window),
                "polygon_xz_m": polygon_xz(hm.grid, cells, window=window),
                "measure": measure,
                "severity": "warning", "issues": issues, "method": "overhang_occupancy_distance",
            })
    return hazards


def _solid_footprints(hm: HeightMap, clearance: np.ndarray, params: HazardParams) -> np.ndarray:
    """Cane-detectable geometry plus the closed outlines it encloses when those are capped below head
    level (a solid cabinet or box: sides are measured, its top covers the inside). Rooms are enclosed
    by walls too, but their interior is not mostly covered by low overhead geometry, so they stay open.
    Tables on legs are not enclosed; RoomPlan furniture footprints cover those."""
    low = hm.low > 0
    solid = low.copy()
    count, labels, stats, _ = cv2.connectedComponentsWithStats((~low).astype(np.uint8), connectivity=4)
    h, w = low.shape
    for label in range(1, count):
        x, y, bw, bh, _ = stats[label]
        if x == 0 or y == 0 or x + bw >= w or y + bh >= h:
            continue
        window = crop(stats, label, low.shape, 0)
        cells = labels[window] == label
        covered = float((hm.mid[window][cells] > 0).mean())
        if covered >= 0.7 and float(np.median(clearance[window][cells])) < params.head_level_m:
            solid[window] |= cells
    return solid


# --- orchestration ---------------------------------------------------------------------------------

def detect(hm: HeightMap, objects: list[Box] = (), params: HazardParams = HazardParams()) -> list[dict]:
    """All hazards, sorted deterministically with stable ids (`<kind>-<n>` in map order)."""
    objects = list(objects)
    hazards: list[dict] = []
    if hm.measured:
        edge, rise = edges(hm, params)
        found = stairs(hm, edge, rise, params)
    else:
        edge, rise, found = np.zeros(hm.elevation.shape, bool), None, []
    found += roomplan_stairs(hm, objects, found)
    suppress = np.zeros(hm.elevation.shape, np.uint8)
    for item in found:
        suppress |= cv2.dilate(item.pop("_mask"), disk(2))
        if not item["sources"]:
            item.pop("sources")
    hazards += found
    if hm.measured:
        hazards += level_changes(hm, edge, rise, params, suppress)
        hazards += unprotected_drops(hm, params, suppress)
        hazards += ramps(hm, edge, params)
        hazards += overhead(hm, objects, params)
    hazards.sort(key=lambda h: (KIND_ORDER.index(h["kind"]), h["position_m"][0], h["position_m"][2], h["position_m"][1]))
    counters: dict[str, int] = {}
    for hazard in hazards:
        counters[hazard["kind"]] = counters.get(hazard["kind"], 0) + 1
        hazard["id"] = f"{hazard['kind']}-{counters[hazard['kind']]}"
    return [{"id": h.pop("id"), **h} for h in hazards]
