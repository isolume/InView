"""Shared-ARKit-frame helpers. Meters, right-handed, Y up; the 2D map is the X/Z plane."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


def matrix(column_major: list[float]) -> np.ndarray:
    return np.asarray(column_major, dtype=np.float64).reshape(4, 4, order="F")


def transform(m: np.ndarray, points: np.ndarray) -> np.ndarray:
    return points @ m[:3, :3].T + m[:3, 3]


def box_corners(m: np.ndarray, dimensions: list[float]) -> np.ndarray:
    """World corners of a centered box (RoomPlan surfaces/objects); planar boxes repeat corners."""
    half = np.asarray(dimensions, dtype=np.float64) / 2
    signs = np.array([[x, y, z] for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)], dtype=np.float64)
    return transform(m, signs * half)


@dataclass(frozen=True)
class Grid:
    """Top-down raster: column = (x - x0) / resolution, row = (z - z0) / resolution (+Z down)."""
    x0: float
    z0: float
    resolution: float
    width: int
    height: int

    @staticmethod
    def covering(xz: np.ndarray, resolution: float = 0.05, margin: float = 0.5,
                 max_cells: int = 2400) -> "Grid":
        low, high = xz.min(axis=0) - margin, xz.max(axis=0) + margin
        extent = float((high - low).max())
        resolution = max(resolution, extent / max_cells)
        width, height = (np.ceil((high - low) / resolution).astype(int) + 1).tolist()
        return Grid(float(low[0]), float(low[1]), resolution, width, height)

    def cells(self, xz: np.ndarray) -> np.ndarray:
        """Float pixel coordinates (col, row) for cv2 drawing."""
        return np.column_stack(((xz[:, 0] - self.x0) / self.resolution, (xz[:, 1] - self.z0) / self.resolution))

    def int_cells(self, xz: np.ndarray) -> np.ndarray:
        return np.round(self.cells(xz)).astype(np.int32)

    def world(self, col: float, row: float) -> list[float]:
        return [round(self.x0 + col * self.resolution, 3), round(self.z0 + row * self.resolution, 3)]

    def inside(self, cells: np.ndarray) -> np.ndarray:
        return (cells[:, 0] >= 0) & (cells[:, 1] >= 0) & (cells[:, 0] < self.width) & (cells[:, 1] < self.height)

    def describe(self) -> dict:
        return {"origin_xz_m": [round(self.x0, 4), round(self.z0, 4)], "resolution_m": round(self.resolution, 4),
                "width": self.width, "height": self.height,
                "axes": "column = +X, row = +Z (top-down, +Z points down the image)"}


def jpeg_to_sensor_uv(px: float, py: float, width: int, height: int) -> tuple[float, float]:
    """Inverse of the iPhone's upright JPEG: it is sensor-native landscape rotated right."""
    return py / height, 1.0 - px / width
