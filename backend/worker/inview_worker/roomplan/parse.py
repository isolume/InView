"""RoomPlan exports -> a small, normalised model (`Capture`) that the semantics step consumes.

Accepted inputs (bytes, str, or already-decoded JSON):
- `[CapturedRoom]`, what the iPhone uploads as `roomplan.json` (one element per scanned section);
- a single `CapturedRoom`, or a `CapturedStructure` (`{"rooms": [...], walls, doors, ...}`, iOS 17+);
- the same value nested inside `capture.json` under `roomplan_original`.

Each `CapturedRoom` becomes one `RoomGroup`: its floors, walls, sections and story stay together so
room polygons and labels can be built per section. iOS 16 rooms (no floors/sections/story) and
iOS 17/18 rooms (floors with `polygonCorners`, `sections`, `story`, `version`, object `attributes`,
`parentIdentifier`, `curve`, `completedEdges`) decode through the same path; unknown keys are kept
out of the model and missing keys become `None`. Components repeated in several sections keep the
latest occurrence, matching the iPhone exporter's `identifier_latest_section_wins` rule.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from ..inputs import Box, Surface
from .codable import angle_degrees, enum_case, identifier, matrix4, number, points3, snake, vector

SURFACE_KEYS = {"walls": "wall", "doors": "door", "windows": "window", "openings": "opening", "floors": "floor"}
COMPONENT_KEYS = (*SURFACE_KEYS, "objects", "sections")


@dataclass
class RPSurface:
    id: str
    category: str                  # wall | door | window | opening | floor
    matrix: np.ndarray             # world-from-surface
    dimensions: np.ndarray         # centered box size (x, y, z), one axis ~0 for planes
    is_open: bool | None = None    # doors only
    corners: np.ndarray = field(default_factory=lambda: np.zeros((0, 3)))  # surface-local polygon
    confidence: str | None = None
    story: int | None = None
    parent_id: str | None = None   # e.g. the wall a door/window/opening sits in
    completed_edges: list[str] = field(default_factory=list)
    curve: dict[str, float] | None = None
    group: int = 0                 # index of the CapturedRoom (section scan) it came from


@dataclass
class RPObject:
    id: str
    category: str
    matrix: np.ndarray
    dimensions: np.ndarray
    attributes: dict[str, str] = field(default_factory=dict)
    confidence: str | None = None
    story: int | None = None
    parent_id: str | None = None
    group: int = 0


@dataclass
class RPSection:
    label: str                     # bedroom | bathroom | dining_room | kitchen | living_room | unidentified
    center: np.ndarray             # world [x, y, z]
    story: int | None = None
    group: int = 0


@dataclass
class RoomGroup:
    id: str                        # CapturedRoom identifier (or a positional fallback)
    story: int | None = None
    version: int | None = None


@dataclass
class Capture:
    groups: list[RoomGroup] = field(default_factory=list)
    surfaces: list[RPSurface] = field(default_factory=list)
    objects: list[RPObject] = field(default_factory=list)
    sections: list[RPSection] = field(default_factory=list)
    source: str = "roomplan_native"
    skipped: int = 0               # malformed components ignored

    @property
    def empty(self) -> bool:
        return not (self.surfaces or self.objects)

    def of(self, category: str) -> list[RPSurface]:
        return [s for s in self.surfaces if s.category == category]


def _int(value: Any) -> int | None:
    n = number(value)
    return int(n) if n is not None and n == int(n) else None


def _attributes(raw: Any) -> dict[str, str]:
    """Object attributes (iOS 17+, e.g. ChairType.dining) as {"chair_type": "dining"}.

    Seen/plausible spellings: `["ChairType.dining"]`, `[{"ChairType": {"dining": {}}}]`,
    `[{"chairType": "dining"}]`, `{"chairType": "dining"}`; anything else is ignored.
    """
    out: dict[str, str] = {}
    items = list(raw.items()) if isinstance(raw, dict) else [(None, v) for v in raw] if isinstance(raw, list) else []
    for key, value in items:
        if key is None and isinstance(value, str):
            kind, _, case = value.rpartition(".")
            out[snake(kind) if kind else f"attribute_{len(out)}"] = snake(case)
        elif key is None and isinstance(value, dict) and len(value) == 1:
            (kind, inner), = value.items()
            case, _ = enum_case(inner)
            if case:
                out[snake(kind)] = case
        elif key is not None:
            case, _ = enum_case(value)
            if case:
                out[snake(key)] = case
    return dict(sorted(out.items()))


def _curve(raw: Any) -> dict[str, float] | None:
    if not isinstance(raw, dict):
        return None
    center, radius = vector(raw.get("center"), 2), number(raw.get("radius"))
    if center is None or radius is None:
        return None
    curve = {"center_x_m": float(center[0]), "center_z_m": float(center[1]), "radius_m": radius}
    for key in ("startAngle", "endAngle"):
        degrees = angle_degrees(raw.get(key))
        if degrees is not None:
            curve[f"{snake(key)}_deg"] = degrees
    return curve


def _surface(raw: Any, default_category: str, group: int) -> RPSurface | None:
    if not isinstance(raw, dict):
        return None
    ident, m = identifier(raw.get("identifier") or raw.get("id")), matrix4(raw.get("transform"))
    dims = vector(raw.get("dimensions"), 3)
    if ident is None or m is None or dims is None:
        return None
    category, payload = enum_case(raw.get("category"))
    category = category if category in SURFACE_KEYS.values() else default_category
    is_open = payload.get("isOpen", payload.get("_0")) if category == "door" else None
    edges = raw.get("completedEdges")
    return RPSurface(
        id=ident, category=category, matrix=m, dimensions=np.abs(dims),
        is_open=is_open if isinstance(is_open, bool) else None,
        corners=points3(raw.get("polygonCorners")), confidence=enum_case(raw.get("confidence"))[0],
        story=_int(raw.get("story")), parent_id=identifier(raw.get("parentIdentifier")),
        completed_edges=sorted({c for c in (enum_case(e)[0] for e in edges) if c}) if isinstance(edges, list) else [],
        curve=_curve(raw.get("curve")), group=group)


def _object(raw: Any, group: int) -> RPObject | None:
    if not isinstance(raw, dict):
        return None
    ident, m = identifier(raw.get("identifier") or raw.get("id")), matrix4(raw.get("transform"))
    dims = vector(raw.get("dimensions"), 3)
    if ident is None or m is None or dims is None:
        return None
    return RPObject(ident, enum_case(raw.get("category"))[0] or "unknown", m, np.abs(dims),
                    _attributes(raw.get("attributes")), enum_case(raw.get("confidence"))[0],
                    _int(raw.get("story")), identifier(raw.get("parentIdentifier")), group)


def _section(raw: Any, group: int) -> RPSection | None:
    if not isinstance(raw, dict):
        return None
    center = vector(raw.get("center"), 3)
    if center is None:
        return None
    return RPSection(enum_case(raw.get("label"))[0] or "unidentified", center, _int(raw.get("story")), group)


def _list(room: dict, key: str) -> list:
    value = room.get(key)
    return value if isinstance(value, list) else []


def _is_room(value: Any) -> bool:
    return isinstance(value, dict) and any(isinstance(value.get(k), list) for k in COMPONENT_KEYS)


def _rooms(value: Any) -> list[dict]:
    """Flatten every accepted container shape into CapturedRoom-like dicts, in upload order."""
    if isinstance(value, list):
        return [room for item in value for room in _rooms(item)]
    if not isinstance(value, dict):
        return []
    if "roomplan_original" in value:          # a whole capture.json was passed
        return _rooms(value["roomplan_original"])
    nested = value.get("rooms")
    if isinstance(nested, list) and any(_is_room(r) for r in nested):
        # CapturedStructure: per-room components first, then the merged top level (latest wins).
        return [*_rooms(nested), *([value] if _is_room(value) else [])]
    return [value] if _is_room(value) else []


def load(source: bytes | str | Any) -> Capture:
    """Decode a RoomPlan export; raises ValueError only for undecodable JSON text."""
    if isinstance(source, (bytes, bytearray, str)):
        try:
            source = json.loads(source)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError(f"roomplan JSON is not decodable: {error}") from error
    capture = Capture()
    surfaces: dict[str, RPSurface] = {}
    objects: dict[str, RPObject] = {}
    for index, room in enumerate(_rooms(source)):
        group = RoomGroup(identifier(room.get("identifier")) or f"section-{index}",
                          _int(room.get("story")), _int(room.get("version")))
        capture.groups.append(group)
        for key, category in SURFACE_KEYS.items():
            for raw in _list(room, key):
                surface = _surface(raw, category, index)
                if surface is None:
                    capture.skipped += 1
                    continue
                if surface.story is None:
                    surface.story = group.story
                surfaces.pop(surface.id, None)   # re-insert so "latest" also means last in order
                surfaces[surface.id] = surface
        for raw in _list(room, "objects"):
            obj = _object(raw, index)
            if obj is None:
                capture.skipped += 1
                continue
            if obj.story is None:
                obj.story = group.story
            objects.pop(obj.id, None)
            objects[obj.id] = obj
        for raw in _list(room, "sections"):
            section = _section(raw, index)
            if section is None:
                capture.skipped += 1
                continue
            if section.story is None:
                section.story = group.story
            capture.sections.append(section)
    capture.surfaces, capture.objects = list(surfaces.values()), list(objects.values())
    return capture


def from_portable(surfaces: list[Surface], objects: list[Box]) -> Capture:
    """The portable `capture.json` records (no sections, polygons or door state) as one group."""
    capture = Capture(groups=[RoomGroup("portable")], source="portable_capture")
    for s in surfaces:
        category = s.kind if s.kind in SURFACE_KEYS.values() else None
        dims = vector(s.dimensions, 3)
        if category is None or dims is None:
            capture.skipped += 1
            continue
        capture.surfaces.append(RPSurface(s.id, category, np.asarray(s.matrix, np.float64), np.abs(dims)))
    for o in objects:
        dims = vector(o.dimensions, 3)
        if dims is None:
            capture.skipped += 1
            continue
        capture.objects.append(RPObject(o.id, o.category, np.asarray(o.matrix, np.float64), np.abs(dims),
                                        confidence=o.confidence))
    return capture
