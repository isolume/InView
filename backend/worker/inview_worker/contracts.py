"""Shared contract for pipeline products. See PIPELINE.md for the full description.

Conventions for every product:
- Positions are in the scan's shared ARKit frame: meters, right-handed, +Y up. The 2D map is the X/Z
  plane (`*_xz_m` = [x, z]); 3D positions are `[x, y, z]` (`*_m`).
- Slopes are rise/run (unitless), widths and heights meters, angles degrees unless named `_rad`.
- IDs are stable for identical inputs (derive from source IDs or deterministic order, never random).
- Output is screening evidence, never certification of accessibility.
"""
from __future__ import annotations

from enum import Enum
from typing import Any, TypedDict

ANALYSIS_SCHEMA_VERSION = 1
FRAME = "shared_arkit_session"
NOTICE = ("Automated OpenCV screening of measured evidence. Floor maps, places, routes, sign/text "
          "readings and clearance checks are NOT verified accessible routes or ADA certification; "
          "review before use.")
# Top-level analysis keys owned by the runner; no product may use them.
RESERVED_KEYS = frozenset({"schema_version", "scan_id", "frame", "generated_at", "worker", "sources",
                           "stages", "summary", "notices"})


class ProductName:
    FLOOR_MAP = "floor_map"
    DOORS = "doors"
    SIGNS = "signs"
    ROOMPLAN = "roomplan"
    REGIONS = "regions"
    HEIGHT_MAP = "height_map"
    HAZARDS = "hazards"
    TEXT = "text"
    PLACES = "places"
    NAV_GRAPH = "nav_graph"
    ROUTES = "routes"
    GEOREF = "georef"
    GEOJSON = "geojson"


class PlaceCategory(str, Enum):
    ENTRANCE = "entrance"
    EXIT = "exit"
    EMERGENCY_EXIT = "emergency_exit"
    RESTROOM = "restroom"
    ACCESSIBLE_RESTROOM = "accessible_restroom"
    ELEVATOR = "elevator"
    STAIRS = "stairs"
    ESCALATOR = "escalator"
    RAMP = "ramp"
    DOOR = "door"
    ROOM = "room"
    CORRIDOR = "corridor"
    INFORMATION = "information"
    RECEPTION = "reception"
    SEATING = "seating"
    WATER_FOUNTAIN = "water_fountain"
    FIRE_EXTINGUISHER = "fire_extinguisher"
    FIRST_AID = "first_aid"
    LANDMARK = "landmark"
    UNKNOWN = "unknown"


# iOS `AccessPoint.Kind` is closed: map every place onto one of its cases.
ACCESS_POINT_KIND = {PlaceCategory.ELEVATOR: "elevator", PlaceCategory.RAMP: "ramp"}


def access_point_kind(category: PlaceCategory | str) -> str:
    return ACCESS_POINT_KIND.get(PlaceCategory(category), "destination")


# Accessibility screening thresholds (2010 ADA Standards), shared so stages agree.
class Thresholds:
    DOOR_MIN_CLEAR_M = 0.815          # §404.2.3
    ROUTE_MIN_CLEAR_M = 0.915         # §403.5.1
    HEADROOM_MIN_M = 2.03             # §307.4
    RAMP_MAX_SLOPE = 1 / 12           # §405.2 (rise/run)
    RUNNING_SLOPE_MAX = 1 / 20        # §403.3: steeper walking surfaces are ramps
    CROSS_SLOPE_MAX = 1 / 48          # §403.3
    PROTRUSION_LOW_M = 0.685          # §307.2 (27 in)
    PROTRUSION_HIGH_M = 2.03          # §307.2 (80 in)
    PROTRUSION_MAX_DEPTH_M = 0.10     # §307.2 (4 in)
    LEVEL_CHANGE_MAX_M = 0.0127       # §303.2 (1/2 in, beveled up to 6.4 mm vertical)
    TACTILE_SIGN_BASELINE_M = (1.22, 1.52)  # §703.4.1 (48–60 in, raised characters baseline)


# --- Product JSON shapes (documentation + static typing; stages may add fields) ---------------

class RoomplanRoom(TypedDict, total=False):
    id: str
    label: str | None           # RoomPlan section label: kitchen, bathroom, bedroom, ...
    story: int | None
    polygon_xz_m: list[list[float]]
    floor_y_m: float


class RoomplanProduct(TypedDict, total=False):
    rooms: list[RoomplanRoom]
    doors: list[dict[str, Any]]      # {id, is_open, center_m, width_m, height_m}
    openings: list[dict[str, Any]]
    objects: list[dict[str, Any]]    # {id, category, attributes, center_m, dimensions_m}
    stories: list[dict[str, Any]]


class Region(TypedDict, total=False):
    id: str
    kind: str                         # room | corridor | open_area | doorway
    polygon_xz_m: list[list[float]]
    centroid_xz_m: list[float]
    area_m2: float
    label: str | None
    adjacent: list[str]


class Hazard(TypedDict, total=False):
    id: str
    kind: str      # step | stairs | ramp | level_change | drop_off | low_headroom | protruding_object
    position_m: list[float]
    polygon_xz_m: list[list[float]]
    measure: dict[str, float]
    severity: str  # barrier | warning


class TextObservation(TypedDict, total=False):
    id: str
    text: str
    confidence: float
    language: str | None
    script: str | None
    engine: str                  # opencv_dnn | tesseract | apple_vision
    frame_id: str
    bbox_px: list[int]           # x, y, w, h in the source image
    quad_px: list[list[float]]
    position_m: list[float] | None
    normal_m: list[float] | None


class Sign(TypedDict, total=False):
    id: str
    category: str                # PlaceCategory value or "directional" / "informational"
    category_confidence: float   # semantic confidence, distinct from rectangle detector score
    excluded_categories: list[str]
    review_status: str           # candidate; a sign reading is not a verified destination
    pictograms: list[str]
    text_ids: list[str]
    arrows: list[dict[str, Any]]  # {direction_xz: [dx, dz]} unit vector in the map frame
    braille: bool
    contrast_ratio: float | None
    mounting_height_m: float | None
    languages: list[str]
    issues: list[str]
    position_m: list[float] | None
    observations: list[dict[str, Any]]


class Place(TypedDict, total=False):
    id: str
    category: str                # PlaceCategory value
    name: str
    names: dict[str, str]        # BCP-47 language -> name
    position_m: list[float]
    floor_id: str
    confidence: float
    sources: list[str]           # e.g. "roomplan:object:<id>", "text:<id>", "sign:<id>"
    access_point_kind: str       # elevator | ramp | destination (iOS AccessPoint.Kind)
    review_status: str           # candidate, including fused evidence from an existing phone point
    source: str                  # manual | detected (original phone source when present)
    source_access_point_id: str  # original phone UUID; do not create a duplicate map point
    slope_degrees: float         # measured incline; missing means unknown, not zero
    requires_assistance: bool    # supplied by the phone; absent when unknown
    provenance: dict[str, Any]   # original phone evidence and optional observation timestamp


class RouteStep(TypedDict, total=False):
    text: str
    distance_m: float
    maneuver: str                # depart | straight | left | right | slight_left | ... | arrive
    position_m: list[float]
    landmark: str | None


class Route(TypedDict, total=False):
    from_place: str
    to_place: str
    profile: str                 # wheelchair | ambulatory | low_vision | ...
    node_ids: list[str]
    length_m: float
    estimated_seconds: float
    instructions: dict[str, list[RouteStep]]   # language -> steps


class GeoReference(TypedDict, total=False):
    latitude: float
    longitude: float
    heading_degrees: float       # clockwise from true north to the scan's local -Z axis
    horizontal_accuracy_m: float | None
    method: str
    samples_used: int


# `nav_graph` is the backend Graph v1 JSON (backend/src/graph.rs): nodes {id,map_id,floor_id,x,y,z,
# label?}, directed edges {id,from,to,step_free?,availability,minimum_clear_width_m?,maximum_slope?,
# segment}; extra data only under `metadata` (the backend rejects unknown fields).
