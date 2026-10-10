"""Raster preparation for region segmentation: the free-space domain and doorway geometry.

Everything here works on the floor map grid (column = +X, row = +Z) and returns uint8 masks
(0 / 255) or boolean masks with the grid's shape.
"""
from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from ..geometry import Grid


def fill_holes(mask: np.ndarray, max_hole_px: int) -> np.ndarray:
    """Fill enclosed non-free islands (free-standing furniture, columns) up to `max_hole_px`.

    An island is a connected non-free component that does not touch the raster border. Walls are
    connected to the unknown space outside the building, so they are never filled.
    """
    free = mask > 0
    count, labels, stats, _ = cv2.connectedComponentsWithStats((~free).astype(np.uint8), connectivity=4)
    out = free.copy()
    height, width = mask.shape
    for label in range(1, count):
        x, y, w, h, area = stats[label]
        touches_border = x == 0 or y == 0 or x + w >= width or y + h >= height
        if not touches_border and area <= max_hole_px:
            out[labels == label] = True
    return out.astype(np.uint8) * 255


def drop_specks(mask: np.ndarray, min_px: int) -> np.ndarray:
    """Remove free-space components smaller than `min_px` (noise, slivers behind furniture)."""
    count, labels, stats, _ = cv2.connectedComponentsWithStats((mask > 0).astype(np.uint8), connectivity=8)
    keep = np.zeros(count, bool)
    keep[1:] = stats[1:, cv2.CC_STAT_AREA] >= min_px
    return keep[labels].astype(np.uint8) * 255


@dataclass(frozen=True)
class Doorway:
    """A door/opening span from the `doors` product, in world X/Z."""
    id: str
    kind: str
    a: np.ndarray
    b: np.ndarray
    clear_width_m: float | None = None    # Measured clear width when known.

    @property
    def width(self) -> float:
        return float(np.linalg.norm(self.b - self.a))

    @property
    def along(self) -> np.ndarray:
        return (self.b - self.a) / max(self.width, 1e-9)

    @property
    def normal(self) -> np.ndarray:
        return np.array([-self.along[1], self.along[0]])

    def rectangle(self, extend_m: float, half_depth_m: float) -> np.ndarray:
        """World corners of the span widened by `extend_m` at both ends and `half_depth_m` across."""
        a, b = self.a - self.along * extend_m, self.b + self.along * extend_m
        across = self.normal * half_depth_m
        return np.array([a + across, b + across, b - across, a - across])


def doorways_from_product(doors: list[dict] | None) -> list[Doorway]:
    result = []
    for index, door in enumerate(doors or []):
        span = door.get("span_xz_m")
        if not span or len(span) != 2:
            continue
        a, b = np.asarray(span[0], float), np.asarray(span[1], float)
        if not (np.isfinite(a).all() and np.isfinite(b).all()) or np.linalg.norm(b - a) < 0.2:
            continue
        clear = door.get("measured_clear_width_m")
        clear = door.get("nominal_width_m") if clear is None else clear
        door_id = door.get("id")
        result.append(Doorway(f"door-{index + 1}" if door_id in (None, "") else str(door_id), str(door.get("kind", "door")), a, b,
                              None if clear is None else float(clear)))
    return sorted(result, key=lambda d: d.id)


def fill_polygon(grid: Grid, polygon_xz: np.ndarray) -> np.ndarray:
    """Boolean raster of a world X/Z polygon."""
    mask = np.zeros((grid.height, grid.width), np.uint8)
    if len(polygon_xz) >= 3:
        cv2.fillPoly(mask, [np.round(grid.cells(np.asarray(polygon_xz, float))).astype(np.int32)], 255)
    return mask > 0


def cut_doorways(seg: np.ndarray, grid: Grid, doorways: list[Doorway], extend_m: float) -> np.ndarray:
    """Draw every door span as a thin barrier so free space on each side separates there."""
    out = seg.copy()
    thickness = max(2, int(round(0.1 / grid.resolution)))
    for door in doorways:
        a, b = grid.int_cells(np.array([door.a - door.along * extend_m, door.b + door.along * extend_m]))
        cv2.line(out, tuple(map(int, a)), tuple(map(int, b)), 0, thickness, cv2.LINE_8)
    return out
