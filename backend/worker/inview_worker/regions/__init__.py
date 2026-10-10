"""Region segmentation: rooms, corridors, open areas and doorways from the floor map.

`build(floor_map, doors, roomplan)` returns a `RegionMap`: the published `Region` list plus a label
raster aligned with `floor_map.grid` so the navigation graph and places can look regions up.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from ..floor_map import FloorMap
from ..geometry import Grid
from .describe import describe_regions
from .masks import Doorway, doorways_from_product, fill_polygon
from .segment import Params, Segmentation, segment

__all__ = ["Doorway", "Params", "RegionMap", "Segmentation", "build", "segment"]


@dataclass
class RegionMap:
    """In-process `regions` product data. `labels[row, col]` is a key of `ids` (0 = no region)."""
    grid: Grid
    labels: np.ndarray
    ids: dict[int, str]
    regions: list[dict]

    @property
    def index(self) -> dict[str, int]:
        return {region_id: label for label, region_id in self.ids.items()}

    def region_at(self, x: float, z: float) -> str | None:
        col, row = self.grid.int_cells(np.array([[x, z]], float))[0]
        if not (0 <= col < self.grid.width and 0 <= row < self.grid.height):
            return None
        return self.ids.get(int(self.labels[row, col]))

    def mask(self, region_id: str) -> np.ndarray:
        label = self.index.get(region_id)
        return np.zeros(self.labels.shape, bool) if label is None else self.labels == label


def _roomplan_rooms(roomplan: dict | None) -> list[dict]:
    rooms = (roomplan or {}).get("rooms") or [] if isinstance(roomplan, dict) else []
    return sorted((r for r in rooms if len(r.get("polygon_xz_m") or []) >= 3), key=lambda r: str(r.get("id")))


def build(floor_map: FloorMap, doors: list[dict] | None = None, roomplan: dict | None = None,
          params: Params = Params()) -> RegionMap:
    rooms = _roomplan_rooms(roomplan)
    room_rasters = [(str(r.get("id")), fill_polygon(floor_map.grid, np.asarray(r["polygon_xz_m"], float)))
                    for r in rooms]
    seg = segment(floor_map.walkable, floor_map.grid, doorways_from_product(doors), room_rasters, params)
    regions, ids = describe_regions(seg, floor_map.obstacle, rooms, params)
    return RegionMap(floor_map.grid, seg.labels, ids, regions)
