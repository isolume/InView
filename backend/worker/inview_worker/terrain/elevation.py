"""2.5D walking-surface model on the floor-map grid: elevation, slope, overhead clearance, occupancy.

Pipeline (all rasters aligned exactly with `floor_map.grid`):
1. Up-facing mesh triangles are sampled on a barycentric lattice and reduced to the *lowest* surface
   per cell (`np.minimum.at`). Depth points fill cells the mesh missed, but only where the lowest
   points of the cell form a horizontal cluster (wall and furniture sides do not).
2. An edge-preserving median removes single-cell spikes.
3. Walkable surfaces are the cells reachable from the floor and from under the camera track by
   steps no taller than `max_step_m` (`cv2.floodFill` in floating-range mode). Table tops, seats and
   counters are therefore not walking surfaces, while platforms, stairs and ramps are.
4. Small enclosed holes are filled with `cv2.inpaint` (Navier-Stokes, clamped to the hole's rim);
   larger unknown areas stay NaN.
5. Slope comes from a Gaussian-smoothed 5x5 Sobel; overhead clearance and cane-detectable/overhang
   occupancy come from all geometry measured relative to the walking surface.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np

from ..contracts import Thresholds
from ..floor_map import _triangle_normals
from ..geometry import Grid, box_corners
from ..inputs import ScanInputs
from .raster import cell_count, cell_index, cell_min, fill_nearest, footprint, gradient, nan_median, sample_triangles


@dataclass(frozen=True)
class TerrainParams:
    walk_normal_min: float = 0.866        # cos 30 deg: steeper triangles are not walking surfaces
    min_surface_samples: int = 3          # lattice samples a cell needs (stray tilted wall facets have few)
    search_m: float = 3.5                 # walking surfaces within +- this of the floor estimate
    deep_search_m: float = 30.0           # lower levels (atria, stairwells, balconies) seen below the floor
    max_step_m: float = 0.25              # largest riser a person steps up while staying "connected"
    seed_tolerance_m: float = 0.05        # floor-level seed band
    camera_height_m: tuple[float, float] = (0.9, 2.0)  # phone above the surface the person stands on
    camera_seed_radius_m: float = 0.3
    point_cluster_m: float = 0.03         # depth points within this of the cell minimum are "surface"
    point_cluster_fraction: float = 0.5   # ...and must be this share of points in the lowest 0.3 m
    point_min_count: int = 2
    hole_max_area_m2: float = 0.12        # enclosed gaps up to this size are inpainted
    surface_eps_m: float = 0.05           # geometry this close above the surface is the surface
    slope_sigma_cells: float = 1.0


@dataclass
class HeightMap:
    grid: Grid
    floor_height: float
    source: str                      # mesh | depth | mesh+depth | roomplan_floor
    measured: bool                   # False when only RoomPlan planes were available
    elevation: np.ndarray            # float32 world Y of the walking surface, NaN = unknown
    slope: np.ndarray                # float32 |grad| rise/run, NaN = unknown
    slope_x: np.ndarray              # float32 dY/dX
    slope_z: np.ndarray              # float32 dY/dZ
    ceiling: np.ndarray              # float32 world Y of the lowest overhead geometry, NaN = none seen
    clearance: np.ndarray            # float32 ceiling - elevation, NaN = none seen / unknown floor
    walking: np.ndarray              # uint8 255 where the elevation is known
    low: np.ndarray                  # uint8 255: geometry a cane detects (surface_eps .. 0.685 m up)
    mid: np.ndarray                  # uint8 255: geometry 0.685 .. 2.03 m above the surface
    params: TerrainParams = field(default_factory=TerrainParams)
    measured_mask: np.ndarray | None = None  # excludes inpainted cells; None for explicitly supplied rasters
    lower_seen: np.ndarray | None = None     # float32 Y of a lower surface seen but not walkable from here

    def relative(self) -> np.ndarray:
        return self.elevation - np.float32(self.floor_height)

    def measured_elevation(self) -> np.ndarray:
        """Walking-surface evidence, excluding floor-plane estimates and interpolated holes."""
        known = np.isfinite(self.elevation) if self.measured else np.zeros(self.elevation.shape, bool)
        if self.measured_mask is not None:
            known &= self.measured_mask
        return np.where(known, self.elevation, np.nan).astype(np.float32)

    def sample(self, raster: np.ndarray, xz: np.ndarray) -> np.ndarray:
        """Nearest-cell values of `raster` at X/Z points (NaN outside the grid)."""
        cells = self.grid.int_cells(np.asarray(xz, dtype=np.float64).reshape(-1, 2))
        inside = self.grid.inside(cells)
        out = np.full(len(cells), np.nan, np.float32)
        out[inside] = raster[cells[inside, 1], cells[inside, 0]]
        return out


def _point_surface(grid: Grid, points: np.ndarray, floor_y: float, params: TerrainParams) -> np.ndarray:
    """Per-cell lowest depth point, kept only where it belongs to a horizontal cluster."""
    if not len(points):
        return np.full((grid.height, grid.width), np.nan, np.float32)
    y = points[:, 1]
    keep = np.isfinite(points).all(axis=1) & (np.abs(y - floor_y) < params.search_m)
    flat, inside = cell_index(grid, points[keep][:, [0, 2]])
    flat, y = flat[inside], y[keep][inside]
    lowest = cell_min(grid, flat, y)
    above = y - lowest.ravel()[flat]
    near = cell_count(grid, flat[above <= params.point_cluster_m])
    band = cell_count(grid, flat[above <= 0.3])
    ok = (near >= params.point_min_count) & (near >= params.point_cluster_fraction * np.maximum(band, 1))
    return np.where(ok, lowest, np.nan).astype(np.float32)


def _seeds(grid: Grid, surface: np.ndarray, floor_y: float, cameras: np.ndarray, params: TerrainParams) -> np.ndarray:
    known = np.isfinite(surface)
    seeds = (known & (np.abs(np.where(known, surface, 1e6) - floor_y) <= params.seed_tolerance_m)).astype(np.uint8)
    if len(cameras):
        radius = max(1, int(round(params.camera_seed_radius_m / grid.resolution)))
        lo, hi = params.camera_height_m
        disk_mask = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * radius + 1, 2 * radius + 1)) > 0
        below_ok = np.zeros_like(seeds, dtype=bool)
        for (_, y, _), (c, r) in zip(cameras, grid.int_cells(cameras[:, [0, 2]])):
            r0, r1, c0, c1 = r - radius, r + radius + 1, c - radius, c + radius + 1
            if r1 <= 0 or c1 <= 0 or r0 >= grid.height or c0 >= grid.width:
                continue
            window = surface[max(r0, 0):r1, max(c0, 0):c1]
            local = disk_mask[max(r0, 0) - r0:window.shape[0] + max(r0, 0) - r0,
                              max(c0, 0) - c0:window.shape[1] + max(c0, 0) - c0]
            with np.errstate(invalid="ignore"):
                below = y - window
                candidate = local & (below >= lo) & (below <= hi)
            if candidate.any():
                # Only the lowest surface under the phone: the person stands on it, not on a table.
                lowest = float(window[candidate].min())
                below_ok[max(r0, 0):r1, max(c0, 0):c1] |= candidate & (window <= lowest + params.seed_tolerance_m)
        seeds |= below_ok.astype(np.uint8)
    return seeds


def reachable(surface: np.ndarray, seeds: np.ndarray, max_step: float) -> np.ndarray:
    """Cells connected to a seed through 8-neighbours whose heights differ by <= `max_step`."""
    known = np.isfinite(surface)
    image = np.where(known, surface, 1e6).astype(np.float32)
    mask = np.zeros((surface.shape[0] + 2, surface.shape[1] + 2), np.uint8)
    mask[1:-1, 1:-1][~known] = 1  # Unknown cells block the fill.
    flags = 8 | cv2.FLOODFILL_MASK_ONLY | (255 << 8)
    # Every seed cell not yet reached starts its own fill: adjacent seeds may differ by > max_step.
    for r, c in zip(*np.nonzero((seeds > 0) & known)):
        if mask[r + 1, c + 1] == 0:
            cv2.floodFill(image, mask, (int(c), int(r)), 0, max_step, max_step, flags)
    return mask[1:-1, 1:-1] == 255


def fill_small_holes(elevation: np.ndarray, max_cells: int, evidence: np.ndarray | None = None) -> np.ndarray:
    """Inpaint unknown components enclosed by known cells (not touching the border, <= `max_cells`).

    Components containing any `evidence` cell (a measured but unreachable surface such as the top of
    a pedestal or bin) are obstacles, not gaps, and stay unknown.

    Navier-Stokes inpainting (Telea extrapolates gradients and overshoots on float rasters), clamped
    to the range of each hole's own boundary ring so a fill never invents a step. Returns the mask of
    filled cells; `elevation` is updated in place.
    """
    known = np.isfinite(elevation)
    count, labels, stats, _ = cv2.connectedComponentsWithStats((~known).astype(np.uint8), connectivity=4)
    h, w = known.shape
    holes = [label for label in range(1, count)
             if stats[label, cv2.CC_STAT_AREA] <= max_cells and stats[label, 0] > 0 and stats[label, 1] > 0
             and stats[label, 0] + stats[label, 2] < w and stats[label, 1] + stats[label, 3] < h]
    if evidence is not None and holes:
        has_evidence = np.zeros(count, bool)
        has_evidence[np.unique(labels[evidence & ~known])] = True
        holes = [label for label in holes if not has_evidence[label]]
    filled_mask = np.zeros(known.shape, bool)
    if not holes or not known.any():
        return filled_mask
    keep = np.zeros(count, bool)
    keep[holes] = True
    filled_mask = keep[labels]
    painted = cv2.inpaint(fill_nearest(elevation), filled_mask.astype(np.uint8) * 255, 2.0, cv2.INPAINT_NS)
    ring_kernel = np.ones((3, 3), np.uint8)
    for label in holes:
        x, y, bw, bh, _ = stats[label]
        window = (slice(y - 1, y + bh + 1), slice(x - 1, x + bw + 1))
        hole = labels[window] == label
        ring = (cv2.dilate(hole.astype(np.uint8), ring_kernel) > 0) & ~hole & known[window]
        values = elevation[window][ring]
        elevation[window][hole] = np.clip(painted[window][hole], values.min(), values.max())
    return filled_mask


def _roomplan_floor(grid: Grid, inputs: ScanInputs) -> np.ndarray:
    elevation = np.full((grid.height, grid.width), np.nan, np.float32)
    for surface in sorted((s for s in inputs.surfaces if s.kind == "floor"), key=lambda s: s.id):
        corners = box_corners(surface.matrix, surface.dimensions)
        layer = footprint(grid, corners)
        y = np.float32(corners[:, 1].mean())
        elevation[layer > 0] = np.fmin(elevation[layer > 0], y)
    return elevation


def _lower_levels(grid: Grid, vertices: np.ndarray, triangles: np.ndarray, samples: np.ndarray, owners: np.ndarray,
                  flat: np.ndarray, inside: np.ndarray, elevation: np.ndarray, floor_y: float,
                  params: TerrainParams) -> np.ndarray:
    """Up-facing surfaces well below the walking floor where there is no walking surface: the lower
    level of an atrium, stairwell, balcony or platform edge. They are not reachable (so they never enter
    `elevation`), but the walkable cells next to them are an unprotected drop.

    The nearest surface below wins (a per-cell maximum), so a basement seen through a gap does not
    hide the floor just under the edge."""
    up = np.abs(_triangle_normals(vertices, triangles)[:, 1]) >= params.walk_normal_min
    y = samples[:, 1]
    chosen = inside & up[owners] & (y < floor_y - params.max_step_m) & (y > floor_y - params.deep_search_m)
    if not chosen.any():
        return np.full((grid.height, grid.width), np.nan, np.float32)
    nearest = -cell_min(grid, flat[chosen], -y[chosen])
    nearest[cell_count(grid, flat[chosen]) < params.min_surface_samples] = np.nan
    return np.where(np.isnan(elevation), nearest, np.nan).astype(np.float32)


def build(inputs: ScanInputs, grid: Grid, floor_y: float, params: TerrainParams = TerrainParams()) -> HeightMap:
    res = grid.resolution
    shape = (grid.height, grid.width)
    vertices, triangles = inputs.mesh_vertices, inputs.mesh_triangles
    has_mesh = len(triangles) > 0
    samples, owners = sample_triangles(vertices, triangles, res / 2)
    flat, inside = cell_index(grid, samples[:, [0, 2]])
    sources = []

    surface = np.full(shape, np.nan, np.float32)
    if has_mesh:
        up = np.abs(_triangle_normals(vertices, triangles)[:, 1]) >= params.walk_normal_min
        y = samples[:, 1]
        chosen = inside & up[owners] & (np.abs(y - floor_y) < params.search_m)
        surface = cell_min(grid, flat[chosen], y[chosen])
        surface[cell_count(grid, flat[chosen]) < params.min_surface_samples] = np.nan
        if np.isfinite(surface).any():
            sources.append("mesh")
    from_points = _point_surface(grid, inputs.points, floor_y, params)
    gaps = np.isnan(surface) & np.isfinite(from_points)
    if gaps.any():
        surface[gaps] = from_points[gaps]
        sources.append("depth")

    if not sources:
        elevation = _roomplan_floor(grid, inputs)
        walking = np.isfinite(elevation)
        nan = np.where(walking, 0, np.nan).astype(np.float32)
        empty = np.full(shape, np.nan, np.float32)
        zeros = np.zeros(shape, np.uint8)
        return HeightMap(grid, floor_y, "roomplan_floor", False, elevation, nan.copy(), nan.copy(), nan.copy(),
                         empty, empty.copy(), walking.astype(np.uint8) * 255, zeros, zeros.copy(), params)

    surface = nan_median(surface, 3)
    walking = reachable(surface, _seeds(grid, surface, floor_y, inputs.camera_positions, params), params.max_step_m)
    elevation = np.where(walking, surface, np.nan).astype(np.float32)
    measured_mask = np.isfinite(elevation)
    lower_seen = _lower_levels(grid, vertices, triangles, samples, owners, flat, inside, elevation, floor_y, params) \
        if has_mesh else None
    walking |= fill_small_holes(elevation, int(params.hole_max_area_m2 / res ** 2), np.isfinite(surface))
    known = np.isfinite(elevation)

    reference = fill_nearest(elevation) if known.any() else np.full(shape, floor_y, np.float32)
    slope_x, slope_z = gradient(reference, res, params.slope_sigma_cells)
    slope = np.where(known, np.hypot(slope_x, slope_z), np.nan).astype(np.float32)
    slope_x = np.where(known, slope_x, np.nan).astype(np.float32)
    slope_z = np.where(known, slope_z, np.nan).astype(np.float32)

    # Everything measured relative to the walking surface below it: mesh when present, else points.
    if has_mesh:
        g_flat, g_y, min_count = flat[inside], samples[inside, 1], 1
    else:
        pts = inputs.points[np.isfinite(inputs.points).all(axis=1)]
        p_flat, p_inside = cell_index(grid, pts[:, [0, 2]])
        g_flat, g_y, min_count = p_flat[p_inside], pts[p_inside, 1], params.point_min_count
    height = g_y - reference.ravel()[g_flat]
    overhead = height > params.max_step_m
    clearance = cell_min(grid, g_flat[overhead], height[overhead]) if overhead.any() else np.full(shape, np.nan, np.float32)
    clearance = np.where(known, clearance, np.nan).astype(np.float32)
    ceiling = (elevation + clearance).astype(np.float32)
    low_band = (height > params.surface_eps_m) & (height < Thresholds.PROTRUSION_LOW_M)
    mid_band = (height >= Thresholds.PROTRUSION_LOW_M) & (height < Thresholds.PROTRUSION_HIGH_M)
    low = ((cell_count(grid, g_flat[low_band]) >= min_count) * 255).astype(np.uint8)
    mid = ((cell_count(grid, g_flat[mid_band]) >= min_count) * 255).astype(np.uint8)
    return HeightMap(grid, floor_y, "+".join(sources), True, elevation, slope, slope_x, slope_z, ceiling, clearance,
                     walking.astype(np.uint8) * 255, low, mid, params, measured_mask, lower_seen)


def summary(hm: HeightMap, region: np.ndarray | None = None) -> dict:
    """Small JSON description of the rasters (the rasters themselves stay in `Product.data`)."""
    known = np.isfinite(hm.elevation)
    measured = np.isfinite(hm.measured_elevation())
    cell_area = hm.grid.resolution ** 2
    result = {
        "grid": hm.grid.describe(),
        "floor_height_m": round(float(hm.floor_height), 3),
        "source": hm.source,
        "measured": hm.measured,
        "known_area_m2": round(float(known.sum() * cell_area), 2),
        "measured_area_m2": round(float(measured.sum() * cell_area), 2),
        "measured_coverage": None,
        "coverage": None,
        "min_elevation_m": None, "max_elevation_m": None,
        "min_relative_m": None, "max_relative_m": None,
        "slope_p95": None,
        "rasters": {
            "elevation": "float32 world Y of the walking surface (NaN unknown)",
            "slope": "float32 rise/run magnitude", "slope_x": "float32 dY/dX", "slope_z": "float32 dY/dZ",
            "ceiling": "float32 world Y of the lowest overhead geometry", "clearance": "float32 ceiling - elevation",
        },
    }
    if region is not None and region.any():
        result["coverage"] = round(float((known & (region > 0)).sum() / (region > 0).sum()), 3)
        result["measured_coverage"] = round(float((measured & (region > 0)).sum() / (region > 0).sum()), 3)
    if known.any():
        values = hm.elevation[known]
        low, high = float(values.min()), float(values.max())
        result.update(min_elevation_m=round(low, 3), max_elevation_m=round(high, 3),
                      min_relative_m=round(low - hm.floor_height, 3), max_relative_m=round(high - hm.floor_height, 3))
        slopes = hm.slope[known & np.isfinite(hm.slope)]
        if slopes.size:
            result["slope_p95"] = round(float(np.percentile(slopes, 95)), 3)
    return result
