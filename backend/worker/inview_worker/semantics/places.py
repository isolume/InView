"""Fuse every available evidence source into deduplicated, confidence-scored, provenance-tracked places.

Evidence → candidates (one per piece of evidence, each with its own confidence and source id):

- RoomPlan objects: toilets (+ nearby sinks/bathtubs) → restroom; stairs → stairs; sofa/chair
  clusters (with their tables) → seating; fireplace/television → landmark. Clusters are found on a
  top-down raster of the object footprints (`cv2.fillConvexPoly` → `cv2.dilate` →
  `cv2.connectedComponents`), so the link distance is the gap between footprints, not between centres.
- RoomPlan rooms and `regions` → room/corridor places at their polygon centroids (`cv2.moments`);
  a label that names a category ("bathroom", "Reception") makes the place that category.
- `doors` whose span sits on the floor outline with walkable floor on one side only
  (`cv2.pointPolygonTest` probes on both sides) → entrance candidates.
- `signs` (contract shape or the earlier candidate shape) → places at the sign; door-related
  categories (elevator, restroom, exit, stairs, room) snap to a door within reach.
  Directional signs (arrows) describe somewhere else and never create a place.
- OCR `text` matched against the multilingual lexicon, and room numbers ("Room 214", "301号室") →
  room places attached to the nearest door/room within a few metres.
- `hazards` stairs/ramp → stairs/ramp places.

Candidates → places: greedy, deterministic clustering with category-aware radii (shared merge keys
such as `door:<id>` merge regardless of distance; conflicting room numbers never merge),
confidence = noisy-OR of the member confidences, sources = sorted union, names per language from
the lexicon overridden by what the signs actually say. Screening evidence, not verified wayfinding.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Any, Iterable

import cv2
import numpy as np

from ..contracts import PlaceCategory, access_point_kind
from ..geometry import Grid
from . import room_numbers
from .place_lexicon import load, normalize, script

# --- tunables ---------------------------------------------------------------------------------
MERGE_RADIUS_M = {
    "restroom": 4.0, "accessible_restroom": 4.0, "elevator": 3.0, "escalator": 3.0, "stairs": 3.0,
    "ramp": 3.0, "exit": 2.5, "emergency_exit": 2.5, "entrance": 2.0, "information": 3.0,
    "reception": 3.0, "first_aid": 2.5, "fire_extinguisher": 1.5, "water_fountain": 2.0,
    "seating": 2.0, "landmark": 1.5, "room": 1.0, "corridor": 0.0, "door": 1.0,
}
DEFAULT_RADIUS_M = 1.0
# Members of a family merge; the place takes the most specific category present.
FAMILY = {"accessible_restroom": "restroom", "emergency_exit": "exit"}
SPECIFIC = {"restroom": "accessible_restroom", "exit": "emergency_exit"}
# Categories a sign/label usually marks *at a doorway*: their position snaps to that door.
DOOR_SNAP = {"elevator", "restroom", "accessible_restroom", "exit", "emergency_exit", "entrance", "stairs",
             "escalator", "room"}
DOOR_SNAP_M = 2.5
# Categories whose sign at a door means the door is not an entrance from outside.
CLAIMS_DOOR = {"elevator", "escalator", "stairs", "restroom", "accessible_restroom", "room"}
ROOM_ATTACH_DOOR_M = 3.0          # room-number text → nearest door
ROOM_TOUCH_M = 0.6                # door ↔ room polygon contact tolerance
ROOM_NEAR_M = 1.5                 # room-number text → nearest room without a door
ENTRANCE_PROBE_M = 0.45           # probe distance either side of a door span
ENTRANCE_BOUNDARY_M = 0.6         # door centre ↔ outline distance
RESTROOM_GAP_M = 2.0
SEATING_GAP_M = 0.9
MIN_CONFIDENCE = 0.15
# Scripts used by exactly one lexicon language (Han is shared by zh and ja, Latin by many).
SCRIPT_LANGUAGE = {"Jpan": "ja", "Hang": "ko", "Arab": "ar", "Deva": "hi"}
ARROWS = set("→←↑↓↗↖↘↙⇒⇐⇑⇓➔➜➝➞➡⬅⬆⬇⮕")

SEATS, TABLES = {"sofa", "chair"}, {"table"}
FIXTURES = {"sink", "bathtub"}
LANDMARK_OBJECTS = {"fireplace": "Fireplace", "television": "Television"}
# Position authority: structural anchors (doors, rooms) > objects/hazards > signs/text.
RANK_ANCHOR, RANK_OBJECT, RANK_SIGN = 3, 2, 1
# Name authority: room number > room/region label > nothing explicit (lexicon names).
NAME_NUMBER, NAME_LABEL = 3, 2


@dataclass
class Scene:
    """Plain-data view of everything places can use; every list is optional."""
    floor_id: str = "ground"
    floor_y: float = 0.0
    objects: list[dict] = field(default_factory=list)    # {id, category, center_m, footprint_xz_m}
    rooms: list[dict] = field(default_factory=list)      # roomplan.rooms
    regions: list[dict] = field(default_factory=list)
    doors: list[dict] = field(default_factory=list)      # doors product, or roomplan doors (center_m)
    outlines: list[list[list[float]]] = field(default_factory=list)  # floor_map outline polygons
    signs: list[dict] = field(default_factory=list)
    texts: list[dict] = field(default_factory=list)
    hazards: list[dict] = field(default_factory=list)


@dataclass
class Candidate:
    category: str
    position: np.ndarray                 # [x, y, z]
    confidence: float
    sources: tuple[str, ...]
    rank: int = RANK_SIGN
    names: dict[str, str] = field(default_factory=dict)   # observed per-language names
    name: str | None = None              # explicit name (room number, label)
    name_rank: int = 0
    key: str | None = None               # merge key ("door:<id>", "room:<id>", "region:<id>")
    room_number: str | None = None
    door_id: str | None = None
    region_id: str | None = None


@dataclass
class _Door:
    id: str
    center: np.ndarray                   # [x, z]
    span: np.ndarray | None              # 2×2 [[x, z], [x, z]] or None
    kind: str


@dataclass
class _Area:
    key: str
    contour: np.ndarray                  # float32 N×1×2 for cv2
    centroid: np.ndarray                 # [x, z]
    floor_y: float
    region_id: str | None


# --- geometry helpers -------------------------------------------------------------------------

def _contour(polygon: Iterable) -> np.ndarray | None:
    points = np.asarray(polygon, dtype=np.float32).reshape(-1, 2)
    return points.reshape(-1, 1, 2) if len(points) >= 3 else None


def polygon_centroid(polygon: Iterable) -> np.ndarray | None:
    contour = _contour(polygon)
    if contour is None:
        return None
    moments = cv2.moments(contour)
    if abs(moments["m00"]) < 1e-9:
        return contour.reshape(-1, 2).mean(axis=0).astype(np.float64)
    return np.array([moments["m10"] / moments["m00"], moments["m01"] / moments["m00"]])


def _signed_distance(contour: np.ndarray, point: np.ndarray) -> float:
    """Positive inside, negative outside, metres (polygon in metres)."""
    return float(cv2.pointPolygonTest(contour, (float(point[0]), float(point[1])), True))


def cluster_footprints(footprints: list[np.ndarray], gap_m: float, resolution: float = 0.05) -> list[int]:
    """Component label per footprint (N×2 x/z polygons); footprints closer than `gap_m` share one."""
    if not footprints:
        return []
    every = np.concatenate(footprints)
    grid = Grid.covering(every, resolution, margin=gap_m + 0.2)
    mask = np.zeros((grid.height, grid.width), np.uint8)
    for footprint in footprints:
        hull = cv2.convexHull(grid.int_cells(footprint))
        cv2.fillConvexPoly(mask, hull, 255)
    radius = max(1, int(round(gap_m / 2 / grid.resolution)))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * radius + 1, 2 * radius + 1))
    _, labels = cv2.connectedComponents(cv2.dilate(mask, kernel))
    out = []
    for footprint in footprints:
        col, row = grid.int_cells(footprint.mean(axis=0, keepdims=True))[0]
        out.append(int(labels[np.clip(row, 0, grid.height - 1), np.clip(col, 0, grid.width - 1)]))
    return out


def _xyz(position: Any) -> np.ndarray | None:
    if position is None:
        return None
    values = np.asarray(position, dtype=np.float64).reshape(-1)
    return values[:3] if len(values) >= 3 and np.isfinite(values[:3]).all() else None


def _language(tag: Any) -> str | None:
    if not isinstance(tag, str) or not tag.strip():
        return None
    return tag.replace("_", "-").split("-")[0].lower()


def _directional(text: str) -> bool:
    return any(char in ARROWS for char in text or "")


# --- scene indexing ---------------------------------------------------------------------------

def _doors(scene: Scene) -> list[_Door]:
    doors = []
    for index, door in enumerate(scene.doors):
        door_id = str(door.get("id", index))
        span = door.get("span_xz_m")
        if door.get("center_xz_m") is not None:
            center = np.asarray(door["center_xz_m"], dtype=np.float64)[:2]
        elif door.get("center_m") is not None:
            center = np.asarray(door["center_m"], dtype=np.float64)[[0, 2]]
        else:
            continue
        span_array = np.asarray(span, dtype=np.float64).reshape(2, 2) if span is not None else None
        doors.append(_Door(door_id, center, span_array, str(door.get("kind", "door"))))
    return doors


def _room_label(label: Any) -> str | None:
    if not isinstance(label, str) or not label.strip():
        return None
    table = load().room_labels
    if label in table:
        return table[label]
    return label.strip()


def _areas(scene: Scene) -> tuple[list[_Area], dict[str, str]]:
    """Room areas (RoomPlan rooms, then room regions not inside one) and region id → merge key."""
    areas, region_keys = [], {}
    for index, room in enumerate(scene.rooms):
        contour, centroid = _contour(room.get("polygon_xz_m") or []), polygon_centroid(room.get("polygon_xz_m") or [])
        if contour is None:
            continue
        areas.append(_Area(f"room:{room.get('id', index)}", contour, centroid,
                           float(room.get("floor_y_m", scene.floor_y)), None))
    roomplan_areas = list(areas)
    for index, region in enumerate(scene.regions):
        region_id = str(region.get("id", index))
        polygon = region.get("polygon_xz_m") or []
        centroid = (np.asarray(region["centroid_xz_m"], dtype=np.float64) if region.get("centroid_xz_m") is not None
                    else polygon_centroid(polygon))
        if centroid is None:
            continue
        owner = next((a for a in roomplan_areas if _signed_distance(a.contour, centroid) >= 0), None)
        region_keys[region_id] = owner.key if owner else f"region:{region_id}"
        contour = _contour(polygon)
        if owner is None and region.get("kind") == "room" and contour is not None:
            areas.append(_Area(f"region:{region_id}", contour, centroid, scene.floor_y, region_id))
    return areas, region_keys


def _nearest_door(doors: list[_Door], xz: np.ndarray, limit: float) -> _Door | None:
    best = None
    for door in doors:
        distance = float(np.linalg.norm(door.center - xz))
        if distance <= limit and (best is None or distance < best[0]):
            best = (distance, door)
    return best[1] if best else None


# --- candidate extractors ---------------------------------------------------------------------

def _names_for(category: str) -> dict[str, str]:
    return load().display_names(category)


def object_candidates(scene: Scene) -> list[Candidate]:
    objects = sorted(scene.objects, key=lambda o: str(o.get("id")))
    out: list[Candidate] = []

    def footprint(item: dict) -> np.ndarray:
        points = np.asarray(item.get("footprint_xz_m") or [], dtype=np.float64).reshape(-1, 2)
        if len(points) >= 3:
            return points
        center = np.asarray(item["center_m"], dtype=np.float64)[[0, 2]]
        return center + np.array([[-0.2, -0.2], [0.2, -0.2], [0.2, 0.2], [-0.2, 0.2]])

    def grouped(categories: set[str], anchors: set[str], gap: float) -> list[list[dict]]:
        members = [o for o in objects if o.get("category") in categories and _xyz(o.get("center_m")) is not None]
        labels = cluster_footprints([footprint(o) for o in members], gap)
        groups: dict[int, list[dict]] = {}
        for label, item in zip(labels, members):
            groups.setdefault(label, []).append(item)
        return [g for _, g in sorted(groups.items()) if any(o["category"] in anchors for o in g)]

    for group in grouped({"toilet"} | FIXTURES, {"toilet"}, RESTROOM_GAP_M):
        toilets = sum(o["category"] == "toilet" for o in group)
        fixtures = len(group) - toilets
        confidence = min(0.85, 0.6 + (0.1 if fixtures else 0.0) + 0.05 * (toilets - 1))
        centers = np.array([_xyz(o["center_m"]) for o in group])
        out.append(Candidate("restroom", centers.mean(axis=0), confidence,
                             tuple(f"roomplan:object:{o['id']}" for o in group), RANK_OBJECT))
    for group in grouped(SEATS | TABLES, SEATS, SEATING_GAP_M):
        seats = sum(o["category"] in SEATS for o in group)
        centers = np.array([_xyz(o["center_m"]) for o in group])
        out.append(Candidate("seating", centers.mean(axis=0), min(0.8, 0.45 + 0.1 * seats),
                             tuple(f"roomplan:object:{o['id']}" for o in group), RANK_OBJECT))
    for item in objects:
        center = _xyz(item.get("center_m"))
        if center is None:
            continue
        category = item.get("category")
        source = (f"roomplan:object:{item['id']}",)
        if category == "stairs":
            out.append(Candidate("stairs", center, 0.75, source, RANK_OBJECT))
        elif category in LANDMARK_OBJECTS:
            label = LANDMARK_OBJECTS[category]
            out.append(Candidate("landmark", center, 0.4, source, RANK_OBJECT, {"en": label}, label, NAME_LABEL))
    return out


def _label_category(label: str | None, default: str) -> tuple[str, float]:
    """Category named by a room/region label, else `default`; with the lexical weight."""
    if not label:
        return default, 0.0
    matches = [m for m in load().match(label) if m.category not in ("entrance", "exit", "emergency_exit")]
    return (matches[0].category, matches[0].weight) if matches else (default, 0.0)


def area_candidates(scene: Scene, region_keys: dict[str, str]) -> list[Candidate]:
    out, owners = [], {}
    for index, room in enumerate(scene.rooms):
        centroid = polygon_centroid(room.get("polygon_xz_m") or [])
        if centroid is None:
            continue
        label = _room_label(room.get("label"))
        category, _ = _label_category(label, "room")
        explicit = label if label and category == "room" else None
        key = f"room:{room.get('id', index)}"
        owners[key] = (category, explicit)
        out.append(Candidate(category, np.array([centroid[0], float(room.get("floor_y_m", scene.floor_y)), centroid[1]]),
                             0.7 if label else 0.45, (f"roomplan:{key}",), RANK_ANCHOR,
                             {"en": explicit} if explicit else {}, explicit, NAME_LABEL if explicit else 0, key=key))
    for index, region in enumerate(scene.regions):
        kind = region.get("kind")
        if kind not in ("room", "corridor"):
            continue
        region_id = str(region.get("id", index))
        centroid = (np.asarray(region["centroid_xz_m"], dtype=np.float64) if region.get("centroid_xz_m") is not None
                    else polygon_centroid(region.get("polygon_xz_m") or []))
        if centroid is None:
            continue
        key = region_keys.get(region_id)
        label = _room_label(region.get("label"))
        if label:
            category, _ = _label_category(label, kind)
            explicit = label if category in ("room", "corridor") else None
        elif kind == "room" and key in owners:
            category, explicit = owners[key]   # same space as a RoomPlan room: share its meaning
        else:
            category, explicit = kind, None
        base = {"room": 0.6, "corridor": 0.5}[kind] if label else {"room": 0.4, "corridor": 0.45}[kind]
        out.append(Candidate(category, np.array([centroid[0], scene.floor_y, centroid[1]]), base,
                             (f"region:{region_id}",), RANK_ANCHOR, {"en": explicit} if explicit else {},
                             explicit, NAME_LABEL if explicit else 0, key=key, region_id=region_id))
    return out


def entrance_candidates(scene: Scene, doors: list[_Door], areas: list[_Area]) -> tuple[list[Candidate], int]:
    """Doors on the outline boundary with floor on exactly one side. Returns (candidates, doors that are not entrances: interior or off the outline)."""
    contours = [c for c in (_contour(o) for o in scene.outlines) if c is not None]
    if not contours:  # fall back to the union of room polygons
        contours = [a.contour for a in areas]
    if not contours:
        return [], 0
    out, interior = [], 0
    for door in doors:
        if door.span is None:
            continue
        a, b = door.span
        along = b - a
        length = float(np.linalg.norm(along))
        if length < 1e-6:
            continue
        normal = np.array([-along[1], along[0]]) / length
        inside = [any(_signed_distance(c, door.center + s * ENTRANCE_PROBE_M * normal) >= 0 for c in contours)
                  for s in (1, -1)]
        near_edge = min(abs(_signed_distance(c, door.center)) for c in contours) <= ENTRANCE_BOUNDARY_M
        if inside[0] != inside[1] and near_edge:
            confidence = 0.6 if door.kind == "door" else 0.5
            out.append(Candidate("entrance", np.array([door.center[0], scene.floor_y, door.center[1]]), confidence,
                                 (f"door:{door.id}",), RANK_ANCHOR, key=f"door:{door.id}", door_id=door.id))
        else:
            interior += 1
    return out, interior


def _snap(candidate: Candidate, doors: list[_Door], floor_y: float) -> Candidate:
    if candidate.category not in DOOR_SNAP or candidate.key:
        return candidate
    door = _nearest_door(doors, candidate.position[[0, 2]], DOOR_SNAP_M)
    if door is None:
        return candidate
    candidate.position = np.array([door.center[0], floor_y, door.center[1]])
    candidate.rank, candidate.key, candidate.door_id = RANK_ANCHOR, f"door:{door.id}", door.id
    return candidate


def _room_candidate(number: room_numbers.RoomNumber, position: np.ndarray, confidence: float, sources: tuple[str, ...],
                    names: dict[str, str], doors: list[_Door], areas: list[_Area], floor_y: float) -> Candidate:
    """Attach a room number to the room behind the nearest door, else the room it is in or near."""
    xz = position[[0, 2]]
    name = room_numbers.display_names(number.number)["en"]
    candidate = Candidate("room", position, confidence * number.confidence, sources, RANK_SIGN, names, name, NAME_NUMBER,
                          room_number=number.number)
    door = _nearest_door(doors, xz, ROOM_ATTACH_DOOR_M)
    chosen = None
    if door is not None:
        touching = [a for a in areas if _signed_distance(a.contour, door.center) >= -ROOM_TOUCH_M]
        # Room-number plates hang outside the room they name, so prefer the room the text is not in.
        outside = [a for a in touching if _signed_distance(a.contour, xz) < 0]
        pool = outside or touching
        if pool:
            chosen = min(pool, key=lambda a: (float(np.linalg.norm(a.centroid - door.center)), a.key))
        candidate.door_id = door.id
    else:
        containing = [a for a in areas if _signed_distance(a.contour, xz) >= 0]
        near = [a for a in areas if _signed_distance(a.contour, xz) >= -ROOM_NEAR_M]
        pool = containing or near
        if pool:
            chosen = min(pool, key=lambda a: (float(np.linalg.norm(a.centroid - xz)), a.key))
    if chosen is not None:
        candidate.position = np.array([chosen.centroid[0], chosen.floor_y, chosen.centroid[1]])
        candidate.key, candidate.region_id, candidate.rank = chosen.key, chosen.region_id, RANK_ANCHOR
    elif door is not None:
        candidate.position = np.array([door.center[0], floor_y, door.center[1]])
        candidate.key, candidate.rank = f"door:{door.id}", RANK_ANCHOR
    return candidate


def _text_candidates(text: str, language: Any, position: np.ndarray, confidence: float, sources: tuple[str, ...],
                     doors: list[_Door], areas: list[_Area], floor_y: float, upgrade: str | None = None) -> list[Candidate]:
    """Lexicon and room-number candidates for one piece of placed text."""
    out = []
    number = room_numbers.parse(text)
    if number is not None:
        tag = _language(language) or number.language
        names = {tag: " ".join(text.split())} if tag and number.confidence >= room_numbers.PREFIXED_CONFIDENCE else {}
        out.append(_room_candidate(number, position.copy(), confidence, sources, names, doors, areas, floor_y))
    lexicon = load()
    for found in lexicon.match(text):
        category = SPECIFIC[found.category] if upgrade and found.category == upgrade else found.category
        score = confidence * found.weight * (1.0 if found.exact else 0.85)
        if score < MIN_CONFIDENCE:
            continue
        languages = lexicon.languages_of(found.term)
        tag = _language(language) or (found.language if len(languages) <= 1 else None) or \
            SCRIPT_LANGUAGE.get(script(text) or "")
        names = {tag: " ".join(text.split())} if tag and found.exact else {}
        out.append(_snap(Candidate(category, position.copy(), score, sources, RANK_SIGN, names), doors, floor_y))
    return out


def _pictogram_category(category: str | None, pictograms: Iterable[str]) -> str | None:
    tags = {normalize(p).replace(" ", "_") for p in pictograms or []}
    accessible = bool(tags & {"wheelchair", "isa", "accessible", "accessibility", "international_symbol_of_access"})
    if category in (None, "", "unknown", "informational"):
        for tag, mapped in (("elevator", "elevator"), ("lift", "elevator"), ("stairs", "stairs"),
                            ("escalator", "escalator"), ("running_man", "emergency_exit"),
                            ("emergency_exit", "emergency_exit"), ("exit", "exit"), ("first_aid", "first_aid"),
                            ("information", "information"), ("fire_extinguisher", "fire_extinguisher"),
                            ("water_fountain", "water_fountain"), ("ramp", "ramp")):
            if tag in tags:
                category = mapped
                break
        else:
            if tags & {"toilet", "restroom", "man", "woman", "male", "female", "toilet_male", "toilet_female",
                       "baby_change", "wc"}:
                category = "restroom"
    if category == "restroom" and accessible:
        category = "accessible_restroom"
    return category


def sign_candidates(scene: Scene, doors: list[_Door], areas: list[_Area]) -> tuple[list[Candidate], set[str], int]:
    """Returns (candidates, text ids already used by signs, directional signs skipped)."""
    texts = {str(t.get("id")): t for t in scene.texts if t.get("id") is not None}
    valid = {c.value for c in PlaceCategory} - {"unknown"}
    out, used, directional = [], set(), 0
    for index, sign in enumerate(scene.signs):
        sign_id = str(sign.get("id", index))
        source = (f"sign:{sign_id}",)
        position = _xyz(sign.get("position_m"))
        linked = [texts[str(i)] for i in sign.get("text_ids") or [] if str(i) in texts]
        if "kind" in sign and "category" not in sign:  # earlier candidate shape
            text = sign.get("text") or ""
            score = float(sign.get("score") or 0.5)
            if position is None:
                continue
            if _directional(text):
                directional += 1
                continue
            upgrade = "restroom" if sign["kind"] == "accessibility_sign_candidate" else None
            found = _text_candidates(text, None, position, min(0.85, 0.5 + 0.35 * score), source, doors, areas,
                                     scene.floor_y, upgrade) if text else []
            if not found and sign["kind"] == "exit_sign_candidate":
                found = [_snap(Candidate("exit", position.copy(), min(0.6, 0.3 + 0.3 * score), source), doors,
                               scene.floor_y)]
            out.extend(found)
            continue
        used.update(str(t.get("id")) for t in linked)
        if sign.get("arrows") or sign.get("category") == "directional" or any(_directional(t.get("text", "")) for t in linked):
            directional += 1
            continue
        if position is None:
            continue
        confidence = float(sign.get("confidence") or sign.get("score") or 0.7)
        category = _pictogram_category(sign.get("category"), sign.get("pictograms") or [])
        names: dict[str, str] = {}
        for text in sorted(linked, key=lambda t: float(t.get("confidence") or 0)):
            body = " ".join(str(text.get("text", "")).split())
            matches = load().match(body)
            tag = _language(text.get("language")) or (matches[0].language if matches else None)
            # Only text that names this sign's own category may name the place.
            if tag and body and matches and matches[0].exact and category and \
                    FAMILY.get(matches[0].category, matches[0].category) == FAMILY.get(category, category):
                names[tag] = body
        if category == "room" or category in (None, "", "unknown", "informational"):
            # Room plates and generic signs: let their text decide (room number, lexicon).
            for text in linked:
                out.extend(_text_candidates(str(text.get("text", "")), text.get("language"), position,
                                            confidence * float(text.get("confidence") or 1.0),
                                            source + (f"text:{text.get('id')}",), doors, areas, scene.floor_y))
            continue
        if category not in valid:
            continue
        sources = source + tuple(f"text:{t.get('id')}" for t in linked)
        out.append(_snap(Candidate(category, position.copy(), confidence, tuple(sorted(sources)), RANK_SIGN, names),
                         doors, scene.floor_y))
    return out, used, directional


def text_candidates(scene: Scene, used: set[str], doors: list[_Door], areas: list[_Area]) -> tuple[list[Candidate], int]:
    """Standalone OCR text. Returns (candidates, readable-but-unplaced count)."""
    out, unplaced = [], 0
    for index, item in enumerate(scene.texts):
        text_id = str(item.get("id", index))
        text = str(item.get("text") or "")
        if text_id in used or not text.strip() or _directional(text):
            continue
        position = _xyz(item.get("position_m"))
        if position is None:
            unplaced += 1
            continue
        confidence = float(item.get("confidence") if item.get("confidence") is not None else 0.5)
        out.extend(_text_candidates(text, item.get("language"), position, confidence, (f"text:{text_id}",),
                                    doors, areas, scene.floor_y))
    return out, unplaced


def hazard_candidates(scene: Scene) -> list[Candidate]:
    out = []
    for index, hazard in enumerate(scene.hazards):
        kind = hazard.get("kind")
        if kind not in ("stairs", "ramp"):
            continue
        position = _xyz(hazard.get("position_m"))
        if position is None:
            centroid = polygon_centroid(hazard.get("polygon_xz_m") or [])
            if centroid is None:
                continue
            position = np.array([centroid[0], scene.floor_y, centroid[1]])
        out.append(Candidate(kind, position, 0.7, (f"hazard:{hazard.get('id', index)}",), RANK_OBJECT))
    return out


# --- fusion -----------------------------------------------------------------------------------

@dataclass
class _Cluster:
    members: list[Candidate]

    @property
    def family(self) -> str:
        return FAMILY.get(self.members[0].category, self.members[0].category)

    def position(self) -> np.ndarray:
        """Confidence-weighted mean of the most authoritative evidence that shares the best member's
        anchor: repeated sightings of one sign average, but a door and a room centroid never blend."""
        best = max(self.members, key=lambda m: (m.rank, m.confidence))
        chosen = [m for m in self.members if m.rank == best.rank and m.key == best.key]
        weights = np.array([max(m.confidence, 1e-3) for m in chosen])
        return (np.array([m.position for m in chosen]) * weights[:, None]).sum(axis=0) / weights.sum()

    def keys(self) -> set[str]:
        return {m.key for m in self.members if m.key}

    def numbers(self) -> set[str]:
        return {m.room_number for m in self.members if m.room_number}


def _radius(category: str) -> float:
    return MERGE_RADIUS_M.get(category, DEFAULT_RADIUS_M)


def _compatible(cluster: _Cluster, candidate: Candidate) -> tuple[bool, float]:
    """(may merge, distance used for ranking)."""
    if FAMILY.get(candidate.category, candidate.category) != cluster.family:
        return False, 0.0
    numbers = cluster.numbers()
    if candidate.room_number and numbers and candidate.room_number not in numbers:
        return False, 0.0
    keys = cluster.keys()
    if candidate.key and candidate.key in keys:
        return True, 0.0
    if candidate.key and any(k.split(":", 1)[0] == candidate.key.split(":", 1)[0] for k in keys):
        return False, 0.0  # two different doors / rooms / regions are two different places
    distance = float(np.linalg.norm(cluster.position()[[0, 2]] - candidate.position[[0, 2]]))
    radius = max(_radius(candidate.category), max(_radius(m.category) for m in cluster.members))
    return distance <= radius, distance


def fuse(candidates: list[Candidate], floor_id: str) -> list[dict]:
    ordered = sorted(candidates, key=lambda c: (-c.rank, -c.confidence, c.category, c.sources))
    clusters: list[_Cluster] = []
    for candidate in ordered:
        best = None
        for index, cluster in enumerate(clusters):
            ok, distance = _compatible(cluster, candidate)
            if ok and (best is None or distance < best[0]):
                best = (distance, index)
        if best is None:
            clusters.append(_Cluster([candidate]))
        else:
            clusters[best[1]].members.append(candidate)
    places = [_place(cluster, floor_id) for cluster in clusters]
    return sorted(places, key=lambda p: (p["category"], p["name"], p["id"]))


def _place(cluster: _Cluster, floor_id: str) -> dict:
    members = cluster.members
    categories = sorted({m.category for m in members})
    # One family per cluster: with two categories present, the specific one wins (accessible restroom).
    category = categories[0] if len(categories) == 1 else next(c for c in categories if c in SPECIFIC.values())
    sources = sorted({s for m in members for s in m.sources})
    confidence = 1.0 - float(np.prod([1.0 - min(max(m.confidence, 0.0), 1.0) for m in members]))
    number = next((m.room_number for m in members if m.room_number), None)
    names = room_numbers.display_names(number) if number else _names_for(category)
    labelled = sorted((m for m in members if m.name), key=lambda m: (-m.name_rank, -m.confidence, m.sources))
    if labelled and not number and labelled[0].name_rank >= NAME_LABEL:
        names = {"en": labelled[0].name}
    for member in sorted(members, key=lambda m: (m.confidence, m.sources)):
        names.update({k: v for k, v in member.names.items() if k and v})
    name = labelled[0].name if labelled else names.get("en") or next(iter(sorted(names.values())), category)
    position = cluster.position()
    digest = hashlib.sha1("|".join(sources).encode()).hexdigest()[:10]
    place = {
        "id": f"place-{category}-{digest}",
        "category": category,
        "name": name,
        "names": dict(sorted(names.items())),
        "position_m": [round(float(v), 3) for v in position],
        "floor_id": floor_id,
        "confidence": round(min(confidence, 0.99), 3),
        "sources": sources,
        "access_point_kind": access_point_kind(category),
    }
    door_id = next((m.door_id for m in members if m.door_id), None)
    region_id = next((m.region_id for m in members if m.region_id), None)
    if door_id:
        place["door_id"] = door_id
    if region_id:
        place["region_id"] = region_id
    if number:
        place["room_number"] = number
    return place


def build(scene: Scene) -> tuple[list[dict], dict]:
    """Places and a small summary for one scene."""
    doors = _doors(scene)
    areas, region_keys = _areas(scene)
    entrances, interior = entrance_candidates(scene, doors, areas)
    signs, used, directional = sign_candidates(scene, doors, areas)
    texts, unplaced = text_candidates(scene, used, doors, areas)
    groups = {"roomplan": object_candidates(scene), "areas": area_candidates(scene, region_keys),
              "doors": entrances, "signs": signs, "text": texts, "hazards": hazard_candidates(scene)}
    candidates = [c for group in groups.values() for c in group if c.confidence >= MIN_CONFIDENCE]
    # A door claimed by an elevator/stairs/restroom/room sign leads there, not outside.
    claimed = {c.key for c in candidates if c.key and c.key.startswith("door:") and c.category in CLAIMS_DOOR}
    candidates = [c for c in candidates if not (c.category == "entrance" and c.sources[0].startswith("door:")
                                                and c.key in claimed)]
    places = fuse(candidates, scene.floor_id)
    by_category: dict[str, int] = {}
    for place in places:
        by_category[place["category"]] = by_category.get(place["category"], 0) + 1
    summary = {"places": len(places), "by_category": dict(sorted(by_category.items())),
               "candidates": {name: len(group) for name, group in groups.items()},
               "doors_not_entrances": interior, "directional_signs": directional, "unplaced_text": unplaced}
    return places, summary
