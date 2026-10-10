"""Tunable parameters of the navigation-graph builder (all lengths in meters)."""
from __future__ import annotations

from dataclasses import asdict, dataclass, fields
from typing import Any, Mapping


@dataclass(frozen=True)
class NavGraphConfig:
    # A body needs this much clearance from every non-walkable cell for the skeleton to pass:
    # the free space is the walkable raster eroded by this radius (0.25 m -> passages >= ~0.5 m).
    clearance_radius_m: float = 0.25
    # Morphological opening of the free space before thinning; removes boundary noise spurs.
    smooth_radius_m: float = 0.05
    # OpenCV ximgproc thinning: "zhang_suen" or "guo_hall".
    thinning: str = "zhang_suen"
    # Spur pruning: a dead-end branch is removed when it is shorter than `spur_min_m`, or when it
    # only reaches into a corner, i.e. its clearance shrinks towards the tip and its length is
    # explained by that shrinkage (length < spur_ratio * clearance drop + spur_min_m).
    spur_min_m: float = 0.3
    spur_ratio: float = 1.6
    # Free-space components at least this large always keep a node (an empty convex room thins
    # to a point); smaller specks behind furniture are ignored.
    min_component_m2: float = 0.5
    # Junctions closer than this (along the skeleton) are merged into one.
    merge_junction_m: float = 0.4
    # approxPolyDP tolerance for exported polylines (collision-checked afterwards).
    simplify_epsilon_m: float = 0.04
    # Anchors (doors, regions, places) connect to the skeleton within this straight-line distance.
    max_snap_m: float = 4.0
    # Edges leaving a door node are split this far from it; only those short crossing edges carry
    # the door's clear width.
    door_approach_m: float = 0.5
    # A place inside an obstacle (wall-mounted sign, sofa) gets an access point this close.
    max_access_m: float = 1.5
    # Slope from the height map: rise over at least this run.
    slope_baseline_m: float = 0.5
    # A rise above this between neighbouring height-map samples is treated as a step.
    step_rise_m: float = 0.02
    # Point hazards without a polygon cover a disc of this radius.
    hazard_radius_m: float = 0.3
    # Perpendicular cross-section rays used for connector clear widths stop after this distance.
    cross_section_max_m: float = 3.0
    # Backend map/floor identifiers; default to the package manifest, then scan id / "ground".
    map_id: str | None = None
    floor_id: str | None = None

    @classmethod
    def from_mapping(cls, mapping: Mapping[str, Any] | None) -> "NavGraphConfig":
        if not mapping:
            return cls()
        known = {f.name for f in fields(cls)}
        unknown = set(mapping) - known
        if unknown:
            raise ValueError(f"Unknown nav_graph config keys: {sorted(unknown)}")
        return cls(**dict(mapping))

    def describe(self) -> dict[str, Any]:
        return {key: value for key, value in asdict(self).items() if key not in ("map_id", "floor_id")}
