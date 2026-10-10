"""`Capture` -> the `roomplan` product: labelled room polygons, doors, openings, objects, stories.

Geometry is done in the map plane (X/Z) with OpenCV:
- room polygons come from floor `polygonCorners` (surface-local, so they are transformed by the
  floor's `transform`), or the floor's centered rectangle when corners are absent (iOS 16 and the
  portable capture), or the convex hull of the section's wall segments when there is no floor at all;
- polygons are cleaned with `approxPolyDP` (drops duplicate/collinear corners), oriented
  counter-clockwise in (x, z), and near-duplicates of the same room reported by two sections are
  collapsed by raster IoU (`fillPoly`), keeping the later section's measurement;
- section labels, object rooms and door sides use `pointPolygonTest` (signed distance in meters).
"""
from __future__ import annotations

from itertools import combinations
from typing import Any

import cv2
import numpy as np

from ..geometry import transform
from .parse import Capture, RPObject, RPSection, RPSurface

MIN_ROOM_AREA_M2 = 0.5          # smaller floor patches are RoomPlan fragments, not rooms
SECTION_TOLERANCE_M = 0.3       # a section center this far outside a floor still labels it
DOOR_PROBE_M = 0.4              # probe distance either side of a door/opening to find its rooms
DUPLICATE_IOU = 0.6             # overlap above which two floors are one room seen twice
STORY_GAP_M = 1.0               # floor heights further apart than this are different stories
RASTER_M = 0.05


def _r(value: float, digits: int = 3) -> float:
    return round(float(value), digits)


def _xz(points: np.ndarray) -> list[list[float]]:
    return [[_r(p[0]), _r(p[-1])] for p in points]


def _contour(polygon: np.ndarray) -> np.ndarray:
    return np.asarray(polygon, np.float32).reshape(-1, 1, 2)


def _signed_area(polygon: np.ndarray) -> float:
    x, z = polygon[:, 0], polygon[:, 1]
    return 0.5 * float(np.dot(x, np.roll(z, -1)) - np.dot(z, np.roll(x, -1)))


def _clean(polygon: np.ndarray) -> np.ndarray | None:
    """Simplified, counter-clockwise (x, z) polygon, or None if it is degenerate."""
    if len(polygon) < 3 or not np.isfinite(polygon).all():
        return None
    simplified = cv2.approxPolyDP(_contour(polygon), 0.01, True).reshape(-1, 2).astype(np.float64)
    if len(simplified) < 3:
        return None
    if _signed_area(simplified) < 0:
        simplified = simplified[::-1]
    return simplified


def _plane_axes(dimensions: np.ndarray) -> tuple[int, int]:
    """Local axes spanning a planar surface: the two largest dimensions, in axis order."""
    i, j = sorted(np.argsort(dimensions)[-2:].tolist())
    return i, j


def _rectangle(surface: RPSurface) -> np.ndarray:
    i, j = _plane_axes(surface.dimensions)
    half = surface.dimensions / 2
    local = np.zeros((4, 3))
    for k, (si, sj) in enumerate(((-1, -1), (1, -1), (1, 1), (-1, 1))):
        local[k, i], local[k, j] = si * half[i], sj * half[j]
    return transform(surface.matrix, local)


def _floor_outline(floor: RPSurface) -> tuple[np.ndarray, str]:
    if len(floor.corners) >= 3:
        return transform(floor.matrix, floor.corners), "polygon_corners"
    return _rectangle(floor), "floor_rectangle"


def _segment(surface: RPSurface) -> np.ndarray:
    """World endpoints of a wall/door/opening along its local X (width) axis."""
    axis = surface.matrix[:3, 0] / max(np.linalg.norm(surface.matrix[:3, 0]), 1e-9)
    center = surface.matrix[:3, 3]
    return np.stack((center - axis * surface.dimensions[0] / 2, center + axis * surface.dimensions[0] / 2))


def _normal_xz(surface: RPSurface) -> np.ndarray:
    n = surface.matrix[:3, 2][[0, 2]]
    length = np.linalg.norm(n)
    return n / length if length > 1e-6 else np.zeros(2)


def _yaw_degrees(m: np.ndarray) -> float:
    """Heading of the local +X axis in the map plane, degrees counter-clockwise from +X toward −Z."""
    return float(np.degrees(np.arctan2(-m[2, 0], m[0, 0])))


class _Room:
    def __init__(self, rid: str, polygon: np.ndarray, floor_y: float, story: int | None, group: int,
                 method: str, confidence: str | None):
        self.id, self.polygon, self.floor_y, self.story = rid, polygon, floor_y, story
        self.group, self.method, self.confidence = group, method, confidence
        self.contour = _contour(polygon)
        self.area = abs(_signed_area(polygon))
        self.labels: list[str] = []
        self.label: str | None = None

    def distance(self, xz: np.ndarray) -> float:
        """Signed distance in meters (positive inside)."""
        return float(cv2.pointPolygonTest(self.contour, (float(xz[0]), float(xz[1])), True))


def _wall_hull_rooms(capture: Capture, groups_with_floor: set[int]) -> list[_Room]:
    rooms = []
    for index, group in enumerate(capture.groups):
        walls = [w for w in capture.of("wall") if w.group == index]
        if index in groups_with_floor or len(walls) < 3:
            continue
        ends = np.concatenate([_segment(w) for w in walls])
        hull = cv2.convexHull(_contour(ends[:, [0, 2]])).reshape(-1, 2).astype(np.float64)
        polygon = _clean(hull)
        if polygon is None:
            continue
        floor_y = min(float(w.matrix[1, 3] - w.dimensions[1] / 2) for w in walls)
        rooms.append(_Room(group.id, polygon, floor_y, group.story, index, "wall_hull", None))
    return rooms


def _drop_duplicates(rooms: list[_Room]) -> list[_Room]:
    """Collapse floors that overlap heavily on the same story; the later section wins."""
    dropped: set[int] = set()
    for a, b in combinations(range(len(rooms)), 2):
        if a in dropped or b in dropped or not _same_story(rooms[a].story, rooms[b].story):
            continue
        if _iou(rooms[a].polygon, rooms[b].polygon) > DUPLICATE_IOU:
            dropped.add(a if rooms[a].group <= rooms[b].group else b)
    return [r for i, r in enumerate(rooms) if i not in dropped]


def _iou(p: np.ndarray, q: np.ndarray) -> float:
    """Raster intersection-over-union of two polygons, on their joint bounding box only."""
    low = np.maximum(p.min(axis=0), q.min(axis=0))
    high = np.minimum(p.max(axis=0), q.max(axis=0))
    if (high <= low).any():
        return 0.0
    origin = np.minimum(p.min(axis=0), q.min(axis=0)) - RASTER_M
    size = (np.ceil((np.maximum(p.max(axis=0), q.max(axis=0)) - origin) / RASTER_M).astype(int) + 2).tolist()
    masks = []
    for polygon in (p, q):
        mask = np.zeros((size[1], size[0]), np.uint8)
        cv2.fillPoly(mask, [np.round((polygon - origin) / RASTER_M).astype(np.int32)], 1)
        masks.append(mask.astype(bool))
    union = np.count_nonzero(masks[0] | masks[1])
    return np.count_nonzero(masks[0] & masks[1]) / union if union else 0.0


def _assign_stories(rooms: list[_Room]) -> set[str]:
    """Fill missing stories: nearest known story by floor height, else cluster heights. Returns ids."""
    known = [r for r in rooms if r.story is not None]
    unknown = sorted((r for r in rooms if r.story is None), key=lambda r: (r.floor_y, r.id))
    if known:
        for room in unknown:
            nearest = min(known, key=lambda k: (abs(k.floor_y - room.floor_y), k.story))
            rise = room.floor_y - nearest.floor_y
            levels = 0 if abs(rise) <= STORY_GAP_M else int(np.sign(rise)) * max(1, round(abs(rise) / 3.0))
            room.story = nearest.story + levels
    else:
        story, previous = 0, None
        for room in unknown:
            if previous is not None and room.floor_y - previous > STORY_GAP_M:
                story += 1
            room.story, previous = story, room.floor_y
    return {r.id for r in unknown}


def _same_story(a: int | None, b: int | None) -> bool:
    return a is None or b is None or a == b


def _label(rooms: list[_Room], sections: list[RPSection]) -> None:
    for room in rooms:
        hits = [(s, room.distance(s.center[[0, 2]])) for s in sections if _same_story(s.story, room.story)]
        inside = [(s, d) for s, d in hits if d >= -SECTION_TOLERANCE_M]
        if not inside:
            # A section scan with exactly one floor labels it even if the center sits outside it.
            own = [s for s in sections if s.group == room.group]
            if len(own) == 1 and sum(r.group == room.group for r in rooms) == 1:
                inside = [(own[0], -np.inf)]
        inside.sort(key=lambda h: (h[0].label == "unidentified", -h[1], h[0].label))
        room.labels = sorted({s.label for s, _ in inside})
        room.label = next((s.label for s, _ in inside if s.label != "unidentified"), None)


def _room_at(rooms: list[_Room], xz: np.ndarray, story: int | None, tolerance: float = 0.0) -> _Room | None:
    best = max(((r.distance(xz), r.id, r) for r in rooms if _same_story(r.story, story)),
               default=None, key=lambda t: (t[0], t[1]))
    return best[2] if best and best[0] >= -tolerance else None


def _passage(surface: RPSurface, rooms: list[_Room], story: int | None) -> dict[str, Any]:
    center, normal = surface.matrix[:3, 3], _normal_xz(surface)
    sides = [_room_at(rooms, center[[0, 2]] + sign * DOOR_PROBE_M * normal, story) for sign in (1, -1)]
    if not normal.any():
        sides = [None, None]
    connects = sorted({s.id for s in sides if s is not None})
    return {
        "id": surface.id,
        "center_m": [_r(v) for v in center],
        "width_m": _r(surface.dimensions[0]),
        "height_m": _r(surface.dimensions[1]),
        "span_xz_m": _xz(_segment(surface)[:, [0, 2]]),
        "normal_xz": [_r(v, 4) for v in normal],
        "story": story,
        "wall_id": surface.parent_id,
        "confidence": surface.confidence,
        "connects": connects,
        # A side with no mapped room is unscanned space or the outside; never assume which.
        "unmapped_side": bool(normal.any() and any(s is None for s in sides)),
    }


def _story_of(surface: RPSurface | RPObject, rooms: list[_Room]) -> int | None:
    if surface.story is not None:
        return surface.story
    room = _room_at(rooms, surface.matrix[:3, 3][[0, 2]], None, tolerance=DOOR_PROBE_M)
    return room.story if room else None


def _object(obj: RPObject, rooms: list[_Room]) -> dict[str, Any]:
    story = _story_of(obj, rooms)
    center = obj.matrix[:3, 3]
    half = obj.dimensions / 2
    local = np.array([[sx * half[0], 0.0, sz * half[2]] for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1))])
    room = _room_at(rooms, center[[0, 2]], story)
    return {
        "id": obj.id, "category": obj.category, "attributes": obj.attributes,
        "center_m": [_r(v) for v in center], "dimensions_m": [_r(v) for v in obj.dimensions],
        "yaw_deg": _r(_yaw_degrees(obj.matrix), 1),
        "footprint_xz_m": _xz(transform(obj.matrix, local)[:, [0, 2]]),
        "bottom_y_m": _r(center[1] - half[1]), "top_y_m": _r(center[1] + half[1]),
        "confidence": obj.confidence, "story": story, "room_id": room.id if room else None,
        "parent_id": obj.parent_id,
    }


def build(capture: Capture) -> dict[str, Any]:
    """The `roomplan` product (contracts.RoomplanProduct plus walls/windows/sections extras)."""
    rooms: list[_Room] = []
    for floor in capture.of("floor"):
        outline, method = _floor_outline(floor)
        polygon = _clean(outline[:, [0, 2]])
        if polygon is None or abs(_signed_area(polygon)) < MIN_ROOM_AREA_M2:
            continue
        rooms.append(_Room(floor.id, polygon, float(outline[:, 1].mean()), floor.story, floor.group,
                           method, floor.confidence))
    rooms += _wall_hull_rooms(capture, {r.group for r in rooms})
    rooms = sorted(_drop_duplicates(rooms), key=lambda r: r.id)
    inferred = _assign_stories(rooms)
    _label(rooms, capture.sections)

    room_json = []
    for room in rooms:
        m = cv2.moments(room.contour)
        centroid = [m["m10"] / m["m00"], m["m01"] / m["m00"]] if m["m00"] else room.polygon.mean(axis=0)
        room_json.append({
            "id": room.id, "label": room.label, "section_labels": room.labels, "story": room.story,
            "polygon_xz_m": _xz(room.polygon), "floor_y_m": _r(room.floor_y), "area_m2": _r(room.area, 2),
            "centroid_xz_m": [_r(v) for v in centroid], "method": room.method, "confidence": room.confidence,
            "section_id": capture.groups[room.group].id if room.group < len(capture.groups) else None,
        })

    doors = []
    for door in sorted(capture.of("door"), key=lambda s: s.id):
        doors.append({**_passage(door, rooms, _story_of(door, rooms)), "is_open": door.is_open})
    openings = [_passage(o, rooms, _story_of(o, rooms)) for o in sorted(capture.of("opening"), key=lambda s: s.id)]

    windows = []
    for window in sorted(capture.of("window"), key=lambda s: s.id):
        story = _story_of(window, rooms)
        center = window.matrix[:3, 3]
        bottom = center[1] - window.dimensions[1] / 2
        room = _room_at(rooms, center[[0, 2]], story, tolerance=DOOR_PROBE_M)
        # Outside every polygon: measure from the highest floor of its story that lies below the sill.
        below = [r.floor_y for r in rooms if _same_story(r.story, story) and r.floor_y <= bottom + 0.05]
        floor_y = room.floor_y if room else (max(below) if below else None)
        windows.append({"id": window.id, "center_m": [_r(v) for v in center], "width_m": _r(window.dimensions[0]),
                        "height_m": _r(window.dimensions[1]), "span_xz_m": _xz(_segment(window)[:, [0, 2]]),
                        "sill_height_m": _r(bottom - floor_y) if floor_y is not None else None,
                        "story": story, "wall_id": window.parent_id})

    walls = []
    for wall in sorted(capture.of("wall"), key=lambda s: s.id):
        entry = {"id": wall.id, "span_xz_m": _xz(_segment(wall)[:, [0, 2]]), "height_m": _r(wall.dimensions[1]),
                 "base_y_m": _r(wall.matrix[1, 3] - wall.dimensions[1] / 2), "story": _story_of(wall, rooms),
                 "completed_edges": wall.completed_edges}
        if wall.curve:
            entry["curve"] = {k: _r(v) for k, v in wall.curve.items()}
        walls.append(entry)

    objects = [_object(o, rooms) for o in sorted(capture.objects, key=lambda o: o.id)]

    sections = []
    for index, section in enumerate(capture.sections):
        room = _room_at(rooms, section.center[[0, 2]], section.story, tolerance=SECTION_TOLERANCE_M)
        sections.append({"label": section.label, "center_m": [_r(v) for v in section.center],
                         "story": section.story, "room_id": room.id if room else None, "index": index})

    stories = []
    for story in sorted({r.story for r in rooms if r.story is not None}):
        members = [r for r in rooms if r.story == story]
        stories.append({"story": story, "floor_y_m": _r(float(np.median([r.floor_y for r in members]))),
                        "room_ids": [r.id for r in members], "area_m2": _r(sum(r.area for r in members), 2),
                        "inferred": all(r.id in inferred for r in members)})

    return {"source": capture.source, "rooms": room_json, "doors": doors, "openings": openings,
            "windows": windows, "walls": walls, "objects": objects, "sections": sections, "stories": stories,
            "versions": sorted({g.version for g in capture.groups if g.version is not None})}


def summarize(product: dict[str, Any], capture: Capture) -> dict[str, Any]:
    doors = product["doors"]
    return {"source": product["source"], "captured_rooms": len(capture.groups), "rooms": len(product["rooms"]),
            "labelled_rooms": sum(r["label"] is not None for r in product["rooms"]),
            "doors": len(doors), "open_doors": sum(d["is_open"] is True for d in doors),
            "closed_doors": sum(d["is_open"] is False for d in doors), "openings": len(product["openings"]),
            "windows": len(product["windows"]), "objects": len(product["objects"]),
            "stories": len(product["stories"]), "skipped_components": capture.skipped}
