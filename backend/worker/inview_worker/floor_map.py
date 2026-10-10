"""Top-down floor products: floor/obstacle/walkable rasters, outline, obstacles, narrow passages.

RoomPlan supplies structure (floors, walls, objects); ARKit mesh and LiDAR depth add measured
evidence. Everything stays in the shared ARKit frame. These are review candidates, not
certified accessible routes.
"""
from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from .geometry import Grid, box_corners
from .inputs import ScanInputs

WALL_THICKNESS_M = 0.12
BODY_BAND_M = (0.12, 1.9)  # Above floor: obstacles a walking or seated person would hit.
FLOOR_TOLERANCE_M = 0.08
ADA_PASSAGE_M = 0.915  # 36 in accessible-route clear width (2010 ADA §403.5.1).
MIN_REPORTED_GAP_M = 0.25
NON_OBSTACLE_SURFACES = {"floor", "window"}


@dataclass
class FloorMap:
    grid: Grid
    floor_height: float
    floor_height_source: str
    floor: np.ndarray
    obstacle: np.ndarray
    walked: np.ndarray
    walkable: np.ndarray
    narrow: np.ndarray
    result: dict


def _segment(corners: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Farthest pair of XZ corners: the horizontal span of a vertical planar surface."""
    xz = corners[:, [0, 2]]
    distances = np.linalg.norm(xz[:, None] - xz[None], axis=2)
    a, b = np.unravel_index(np.argmax(distances), distances.shape)
    return xz[a], xz[b]


def _triangle_normals(vertices: np.ndarray, triangles: np.ndarray) -> np.ndarray:
    v = vertices[triangles]
    normals = np.cross(v[:, 1] - v[:, 0], v[:, 2] - v[:, 0])
    length = np.linalg.norm(normals, axis=1, keepdims=True)
    return np.divide(normals, length, out=np.zeros_like(normals), where=length > 1e-12)


def estimate_floor_height(inputs: ScanInputs) -> tuple[float, str] | None:
    floors = [box_corners(s.matrix, s.dimensions)[:, 1].mean() for s in inputs.surfaces if s.kind == "floor"]
    if floors:
        return float(np.median(floors)), "roomplan_floor"
    if len(inputs.mesh_triangles):
        normals = _triangle_normals(inputs.mesh_vertices, inputs.mesh_triangles)
        up = np.abs(normals[:, 1]) > 0.9
        heights = inputs.mesh_vertices[inputs.mesh_triangles[up]].mean(axis=1)[:, 1]
        if len(heights) >= 10:
            # The lowest well-populated horizontal layer, not a stray low triangle.
            counts, edges = np.histogram(heights, bins=np.arange(heights.min(), heights.max() + 0.1, 0.05))
            layer = int(np.argmax(counts >= 0.25 * counts.max()))
            near = heights[(heights >= edges[layer] - 0.05) & (heights <= edges[layer + 1] + 0.05)]
            return float(np.median(near)), "mesh_up_facing_layer"
    if len(inputs.points) >= 50:
        return float(np.percentile(inputs.points[:, 1], 2)), "depth_low_percentile"
    if len(inputs.camera_positions):
        return float(np.median(inputs.camera_positions[:, 1]) - 1.35), "camera_height_prior"
    return None


def _evidence_xz(inputs: ScanInputs) -> np.ndarray:
    parts = [inputs.mesh_vertices[:, [0, 2]], inputs.points[:, [0, 2]], inputs.camera_positions[:, [0, 2]]]
    for item in [*inputs.surfaces, *inputs.objects]:
        parts.append(box_corners(item.matrix, item.dimensions)[:, [0, 2]])
    xz = np.concatenate([p for p in parts if len(p)]) if any(len(p) for p in parts) else np.zeros((0, 2))
    return xz[np.isfinite(xz).all(axis=1)]


def _mark_points(mask: np.ndarray, grid: Grid, xz: np.ndarray, minimum: int) -> None:
    if not len(xz):
        return
    cells = grid.int_cells(xz)
    cells = cells[grid.inside(cells)]
    counts = np.zeros(mask.shape, dtype=np.int32)
    np.add.at(counts, (cells[:, 1], cells[:, 0]), 1)
    mask[counts >= minimum] = 255


def build(inputs: ScanInputs, resolution: float = 0.05) -> FloorMap | None:
    estimate = estimate_floor_height(inputs)
    xz = _evidence_xz(inputs)
    if estimate is None or len(xz) < 3:
        return None
    floor_y, floor_source = estimate
    grid = Grid.covering(xz, resolution)
    shape = (grid.height, grid.width)
    floor, obstacle, walls, walked = (np.zeros(shape, np.uint8) for _ in range(4))
    wall_px = max(1, int(round(WALL_THICKNESS_M / grid.resolution)))
    low, high = floor_y + BODY_BAND_M[0], floor_y + BODY_BAND_M[1]

    # RoomPlan structure.
    for surface in inputs.surfaces:
        corners = box_corners(surface.matrix, surface.dimensions)
        if surface.kind == "floor":
            hull = cv2.convexHull(grid.cells(corners[:, [0, 2]]).astype(np.float32)).astype(np.int32)
            cv2.fillPoly(floor, [hull], 255)
        elif surface.kind not in NON_OBSTACLE_SURFACES and surface.kind not in ("door", "opening"):
            a, b = grid.int_cells(np.array(_segment(corners)))
            cv2.line(walls, tuple(map(int, a)), tuple(map(int, b)), 255, wall_px)
    # RoomPlan walls span their doorways; carve doors/openings out of the wall layer only. A
    # rectangle (not a round-capped line) keeps the carved width equal to the opening width.
    for surface in inputs.surfaces:
        if surface.kind in ("door", "opening"):
            a, b = _segment(box_corners(surface.matrix, surface.dimensions))
            along = (b - a) / max(float(np.linalg.norm(b - a)), 1e-9)
            across = np.array([-along[1], along[0]]) * (WALL_THICKNESS_M + 2 * grid.resolution)
            band = np.array([a + across, b + across, b - across, a - across])
            cv2.fillPoly(walls, [np.round(grid.cells(band)).astype(np.int32)], 0)
    obstacle |= walls
    for item in inputs.objects:
        corners = box_corners(item.matrix, item.dimensions)
        if corners[:, 1].max() > low and corners[:, 1].min() < high:  # Rugs never block.
            hull = cv2.convexHull(grid.cells(corners[:, [0, 2]]).astype(np.float32)).astype(np.int32)
            cv2.fillPoly(obstacle, [hull], 255)

    # Measured ARKit mesh evidence.
    if len(inputs.mesh_triangles):
        tris = inputs.mesh_vertices[inputs.mesh_triangles]
        normals = _triangle_normals(inputs.mesh_vertices, inputs.mesh_triangles)
        ys = tris[:, :, 1]
        on_floor = (np.abs(normals[:, 1]) > 0.85) & (np.abs(ys.mean(axis=1) - floor_y) < FLOOR_TOLERANCE_M)
        blocking = ~on_floor & (ys.max(axis=1) > low) & (ys.min(axis=1) < high)
        for mask, chosen in ((floor, on_floor), (obstacle, blocking)):
            if chosen.any():
                polygons = np.round(grid.cells(tris[chosen][:, :, [0, 2]].reshape(-1, 2))).astype(np.int32).reshape(-1, 3, 2)
                cv2.fillPoly(mask, list(polygons), 255)
                cv2.polylines(mask, list(polygons), True, 255, 1)  # Vertical faces project to lines.

    # LiDAR depth evidence.
    if len(inputs.points):
        y = inputs.points[:, 1]
        _mark_points(floor, grid, inputs.points[np.abs(y - floor_y) < FLOOR_TOLERANCE_M][:, [0, 2]], 1)
        _mark_points(obstacle, grid, inputs.points[(y > low) & (y < high)][:, [0, 2]], 2)

    # Where the phone travelled is walked evidence (the person stood there).
    track = inputs.camera_positions
    if len(track):
        cells = grid.int_cells(track[:, [0, 2]])
        radius = max(1, int(round(0.25 / grid.resolution)))
        for i, cell in enumerate(cells):
            cv2.circle(walked, tuple(map(int, cell)), radius, 255, -1)
            if i and np.linalg.norm(track[i, [0, 2]] - track[i - 1, [0, 2]]) < 1.5:
                cv2.line(walked, tuple(map(int, cells[i - 1])), tuple(map(int, cell)), 255, radius * 2)

    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    floor = cv2.morphologyEx(floor, cv2.MORPH_CLOSE, kernel, iterations=2)
    walkable = cv2.bitwise_and(cv2.bitwise_or(floor, walked), cv2.bitwise_not(obstacle))

    # Gaps between real obstacles (unknown space is not treated as a wall).
    gap = cv2.distanceTransform(cv2.bitwise_not(obstacle), cv2.DIST_L2, 5) * grid.resolution
    ridge = (gap >= cv2.dilate(gap, np.ones((3, 3), np.uint8))) & (walkable > 0)
    width = 2 * gap
    narrow = (ridge & (width < ADA_PASSAGE_M) & (width >= MIN_REPORTED_GAP_M)).astype(np.uint8) * 255
    passages = []
    count, labels, stats, centroids = cv2.connectedComponentsWithStats(narrow, connectivity=8)
    for label in range(1, count):
        cells = labels == label
        if stats[label, cv2.CC_STAT_AREA] < 2:
            continue
        passages.append({"center_xz_m": grid.world(*centroids[label]),
                         "min_clear_width_m": round(float(width[cells].min()), 3),
                         "length_m": round(float(stats[label, cv2.CC_STAT_AREA] * grid.resolution), 2),
                         "required_min_m": ADA_PASSAGE_M})
    passages.sort(key=lambda p: p["min_clear_width_m"])

    region = cv2.morphologyEx(cv2.bitwise_or(floor, walked), cv2.MORPH_CLOSE, kernel, iterations=2)
    contours, _ = cv2.findContours(region, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    cell_area = grid.resolution ** 2
    outlines = []
    for contour in sorted(contours, key=cv2.contourArea, reverse=True):
        if cv2.contourArea(contour) * cell_area < 1.0:
            continue
        poly = cv2.approxPolyDP(contour, max(1.0, 0.05 / grid.resolution), True).reshape(-1, 2)
        outlines.append({"polygon_xz_m": [grid.world(*p) for p in poly],
                         "area_m2": round(float(cv2.contourArea(contour) * cell_area), 2)})

    near_floor = cv2.dilate(region, kernel, iterations=3)
    obstacles = []
    # Walls bound the space; list the free-standing obstacles inside it separately.
    standing = cv2.bitwise_and(cv2.bitwise_and(obstacle, near_floor), cv2.bitwise_not(walls))
    contours, _ = cv2.findContours(standing, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    for contour in sorted(contours, key=cv2.contourArea, reverse=True)[:200]:
        area = cv2.contourArea(contour) * cell_area
        if area < 0.02:
            continue
        (cx, cz), (w, d), angle = cv2.minAreaRect(contour)
        obstacles.append({"center_xz_m": grid.world(cx, cz), "size_m": [round(w * grid.resolution, 2), round(d * grid.resolution, 2)],
                          "angle_deg": round(float(angle), 1), "area_m2": round(float(area), 3)})

    walked_length = float(np.linalg.norm(np.diff(track[:, [0, 2]], axis=0), axis=1).sum()) if len(track) > 1 else 0.0
    result = {
        "grid": grid.describe(),
        "floor_height_m": round(floor_y, 3),
        "floor_height_source": floor_source,
        "body_band_m": [round(low, 3), round(high, 3)],
        "outlines": outlines,
        "obstacles": obstacles,
        "narrow_passages": passages[:50],
        "walkable_area_m2": round(float((walkable > 0).sum() * cell_area), 2),
        "floor_area_m2": round(float((floor > 0).sum() * cell_area), 2),
        "walked_length_m": round(walked_length, 2),
    }
    return FloorMap(grid, floor_y, floor_source, floor, obstacle, walked, walkable, narrow, result)


def render(floor_map: FloorMap, doors: list[dict]) -> bytes:
    """Transparent-background PNG for review overlays. Not a navigation product."""
    image = np.zeros((floor_map.grid.height, floor_map.grid.width, 4), np.uint8)
    image[floor_map.floor > 0] = (214, 214, 210, 255)
    image[floor_map.walkable > 0] = (246, 246, 244, 255)
    image[floor_map.walked > 0] = (240, 220, 196, 255)
    image[floor_map.obstacle > 0] = (70, 64, 60, 255)
    image[cv2.dilate(floor_map.narrow, np.ones((3, 3), np.uint8)) > 0] = (40, 60, 225, 255)
    grid = floor_map.grid
    for door in doors:
        a, b = grid.int_cells(np.array(door["span_xz_m"]))
        color = (60, 170, 70, 255) if door["meets_clear_width"] else (30, 140, 245, 255)
        cv2.line(image, tuple(map(int, a)), tuple(map(int, b)), color, max(2, int(0.08 / grid.resolution)))
    ok, png = cv2.imencode(".png", image)
    if not ok:
        raise RuntimeError("Could not encode the floor map image")
    return png.tobytes()
