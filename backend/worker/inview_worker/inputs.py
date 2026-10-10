"""Scan evidence in the shared ARKit frame, gathered from the backend or built by tests."""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np


@dataclass
class Surface:
    """RoomPlan wall/door/opening/window/floor: centered box `dimensions` under `matrix`."""
    id: str
    kind: str
    matrix: np.ndarray
    dimensions: list[float]


@dataclass
class Box:
    """RoomPlan object bounds (furniture, storage, stairs...)."""
    id: str
    category: str
    matrix: np.ndarray
    dimensions: list[float]
    confidence: str = "unknown"


@dataclass
class Frame:
    """One calibrated depth observation with an optional RGB keyframe.

    `points` rows are world x, y, z plus *sensor-native* normalized u, v of each depth sample.
    """
    id: str
    points: np.ndarray
    color_asset: str | None = None


@dataclass
class ScanInputs:
    scan_id: str
    surfaces: list[Surface] = field(default_factory=list)
    objects: list[Box] = field(default_factory=list)
    mesh_vertices: np.ndarray = field(default_factory=lambda: np.zeros((0, 3)))
    mesh_triangles: np.ndarray = field(default_factory=lambda: np.zeros((0, 3), dtype=np.int64))
    points: np.ndarray = field(default_factory=lambda: np.zeros((0, 3)))
    camera_positions: np.ndarray = field(default_factory=lambda: np.zeros((0, 3)))
    frames: list[Frame] = field(default_factory=list)
    sources: dict[str, str] = field(default_factory=dict)
