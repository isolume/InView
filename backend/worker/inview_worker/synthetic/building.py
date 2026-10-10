"""Procedural multi-room building scans in the iPhone `.inviewscan.tar` format, with ground truth.

`build(seed)` returns `(archive_bytes, truth)`. The same seed always produces identical bytes.

The building (meters, shared ARKit frame, +Y up) is a corridor along +X with rooms on both sides,
a sunken lobby at its east end reached by a stair lane and a ramp lane separated by a guard rail,
doors of varied widths (some below the 0.815 m ADA clear width), a room with a doorless opening,
a connecting door between two rooms, furniture (RoomPlan objects, including a restroom's toilet and
sink), and wall signs: room-number plates ("214"), an accessible-restroom plate (pictograms,
"RESTROOM"/"TOILETTES"), exit signs ("EXIT"/"SALIDA", running man, arrow), an elevator sign
("ELEVATOR"/"ASCENSOR") and a ramp sign.

The package mirrors `CaptureStore.makeArchive`: `capture.json` (RoomPlan surfaces/objects, portable
frames omitted), `roomplan.json` (CapturedRoom-like sections), `package-manifest.json` with calibrated
observations (landscape 1920×1440 sensor intrinsics, binary float32 depth + confidence, GPS/heading
environment samples) and native mesh anchors (vertices/faces/normals/classification sidecars), and
upright 480×640 JPEG keyframes (sensor image rotated right; the phone is held in portrait). Depth and
keyframes are ray-cast against the same geometry (walls, floors, steps, ramp, door leaves, furniture).

Ground truth (never inside the archive): spaces (polygons, labels), doors (nominal/clear widths),
signs and text lines (3D positions, strings), hazards, places, a waypoint graph with room adjacency
and per-profile shortest paths (wheelchair avoids stairs, doors under 0.815 m clear and ramps steeper
than 1:12), and the georeference used to synthesize the GPS samples.

    python -m inview_worker.synthetic.building out.inviewscan.tar [--seed N] [--truth truth.json]
"""
from __future__ import annotations

import argparse
import heapq
import io
import json
import math
import tarfile
from dataclasses import dataclass, field

import cv2
import numpy as np

from .package import CX, CY, FOCAL, IMAGE_H, IMAGE_W

GENERATOR = "inview_worker.synthetic.building"
TRUTH_SCHEMA_VERSION = 1
DEPTH_W, DEPTH_H = 256, 192
JPEG_W, JPEG_H = 480, 640
WALL_T = 0.10
CEILING_Y = 2.7
DOOR_H = 2.1
OPENING_H = 2.2
LANE_OPENING_TOP_Y = 2.4
EYE_M = 1.45
LEAF_T = 0.04
RAIL_T = 0.10
RAIL_TOP_Y = 1.0
STAIR_RISERS, STAIR_RUN_M = 2, 0.3
DOOR_MIN_CLEAR_M = 0.815
OPENING_MIN_CLEAR_M = 0.915
RAMP_MAX_SLOPE = 1 / 12
TEXTURE_PPM = 1000.0          # sign texture pixels per meter
JPEG_FOCAL = FOCAL * JPEG_W / IMAGE_H
SEGMENT_M = 2.0               # long boxes are split for ray-cast culling
MESH_CELL_M = 0.5
TILE = 32
T0_UNIX = 1_791_000_000.0
METERS_PER_DEG_LAT = 111_320.0

# ARMeshClassification: 0 none, 1 wall, 2 floor, 3 ceiling, 4 table, 5 seat, 6 window, 7 door.
MATERIALS = {
    # name: (BGR color, mesh classification)
    "wall": ((204, 209, 213), 1), "floor": ((118, 132, 146), 2), "ceiling": ((236, 236, 234), 3),
    "door_leaf": ((60, 100, 150), 7), "rail": ((60, 60, 66), 0), "stairs": ((150, 150, 146), 2),
    "ramp": ((128, 138, 140), 2), "table": ((90, 130, 172), 4), "chair": ((72, 70, 80), 5),
    "sofa": ((140, 92, 62), 5), "storage": ((152, 160, 170), 0), "toilet": ((242, 242, 240), 0),
    "sink": ((236, 238, 238), 0), "refrigerator": ((222, 222, 226), 0), "stove": ((70, 72, 76), 0),
}
MATERIAL_IDS = {name: i for i, name in enumerate(MATERIALS)}
OBJECT_MATERIAL = {"table": "table", "chair": "chair", "sofa": "sofa", "storage": "storage", "toilet": "toilet",
                   "sink": "sink", "refrigerator": "refrigerator", "stove": "stove", "stairs": "stairs"}
# RoomPlan CapturedRoom.Section.Label values.
ROOM_KINDS = {
    "office": ("OFFICE", "unidentified"), "conference": ("CONFERENCE", "unidentified"),
    "storage": ("STORAGE", "unidentified"), "lounge": ("LOUNGE", "livingRoom"),
    "kitchenette": ("KITCHEN", "kitchen"),
}


# --- Building description ---------------------------------------------------------------------

@dataclass
class Space:
    id: str
    kind: str                  # room | corridor | lobby
    x0: float
    x1: float
    z0: float
    z1: float
    floor_y: float = 0.0
    room_kind: str = ""        # office | conference | ... | restroom
    number: str | None = None
    name: str = ""
    section_label: str = "unidentified"
    aliases: list[str] = field(default_factory=list)

    @property
    def polygon(self) -> list[list[float]]:
        return [[self.x0, self.z0], [self.x1, self.z0], [self.x1, self.z1], [self.x0, self.z1]]

    @property
    def center(self) -> np.ndarray:
        return np.array([(self.x0 + self.x1) / 2, self.floor_y, (self.z0 + self.z1) / 2])

    def contains(self, x: float, z: float, margin: float = 0.0) -> bool:
        return self.x0 - margin <= x <= self.x1 + margin and self.z0 - margin <= z <= self.z1 + margin


@dataclass
class Door:
    id: str
    kind: str                  # door | opening
    spaces: tuple[str, str | None]
    axis: str                  # "x": the wall runs along X (constant z); "z": constant x
    line: float                # the wall's constant coordinate
    center: float              # the door centre along the wall
    width: float
    floor_y: float = 0.0
    height: float = DOOR_H
    leaf: str | None = None    # "open" (swung 90° into spaces[0]), "closed", None (opening)
    hinge: int = -1            # -1: hinge at the low end along the wall, +1: high end
    into: int = 1              # direction (+1/−1 along the wall normal axis) into spaces[0]

    @property
    def center_xz(self) -> np.ndarray:
        return np.array([self.center, self.line]) if self.axis == "x" else np.array([self.line, self.center])

    @property
    def clear_width(self) -> float:
        return round(self.width - LEAF_T, 3) if self.leaf else self.width

    @property
    def required(self) -> float:
        return DOOR_MIN_CLEAR_M if self.kind == "door" else OPENING_MIN_CLEAR_M


@dataclass
class Wall:
    id: str
    axis: str                  # "x": runs along X at z = line; "z": runs along Z at x = line
    line: float
    a0: float
    a1: float
    y0: float
    y1: float
    holes: list[tuple[float, float, float]] = field(default_factory=list)  # (b0, b1, top_y)


@dataclass
class SignSpec:
    id: str
    category: str              # exit | directional | restroom | accessible_restroom | elevator | ramp | room
    center: np.ndarray         # on the wall face, world
    normal: np.ndarray         # unit, into the viewer's space
    size: tuple[float, float]  # width, height (m)
    plate_bgr: tuple[int, int, int]
    lines: list[dict]          # {text, language, box: (x0, y0, x1, y1) in relative units, color}
    pictograms: list[dict]     # {kind, box, color, direction?}
    arrows: list[list[float]] = field(default_factory=list)
    space: str = ""
    texture: np.ndarray | None = None

    @property
    def right(self) -> np.ndarray:
        return np.cross([0.0, 1.0, 0.0], self.normal)


@dataclass
class Decal:
    center: np.ndarray
    normal: np.ndarray
    size: tuple[float, float]
    texture: np.ndarray

    @property
    def right(self) -> np.ndarray:
        return np.cross([0.0, 1.0, 0.0], self.normal)


@dataclass
class Scene:
    lo: np.ndarray             # (B, 3) axis-aligned boxes
    hi: np.ndarray
    material: np.ndarray       # (B,) material ids
    owner: list[str]           # box -> space id (mesh anchor grouping)
    triangles: np.ndarray      # (T, 3, 3) sloped surfaces (ramp)
    tri_material: np.ndarray
    tri_owner: list[str]
    decals: list[Decal]

    def __post_init__(self) -> None:
        self.centers = (self.lo + self.hi) / 2
        self.radii = np.linalg.norm(self.hi - self.lo, axis=1) / 2


@dataclass
class Building:
    seed: int
    scan_id: str
    floor_number: int
    corridor_width: float
    lobby_drop: float
    ramp_run: float
    ramp_slope: float
    stair_lane: tuple[float, float]
    ramp_lane: tuple[float, float]
    level_end_x: float         # Lc: corridor floor ends, lanes begin
    lanes_end_x: float         # X1: lobby west wall
    spaces: list[Space]
    doors: list[Door]
    walls: list[Wall]
    objects: list[dict]        # {id, category, space, center, dimensions, yaw}
    signs: list[SignSpec]
    decals: list[Decal]
    georef: dict

    def space(self, space_id: str) -> Space:
        return next(s for s in self.spaces if s.id == space_id)


# --- Helpers ------------------------------------------------------------------------------------

def _r(value: float, digits: int = 3) -> float:
    return round(float(value), digits)


def _rot_y(yaw: float) -> np.ndarray:
    c, s = math.cos(yaw), math.sin(yaw)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def _rot_x(pitch: float) -> np.ndarray:
    c, s = math.cos(pitch), math.sin(pitch)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


PORTRAIT = np.array([[0.0, 1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, 1.0]])  # Rz(−90°): sensor u points down


def camera_matrix(position, yaw: float, pitch: float = 0.0) -> np.ndarray:
    """map_from_camera for a phone held in portrait: camera −Z forward, +X down, +Y right."""
    m = np.eye(4)
    m[:3, :3] = _rot_y(yaw) @ _rot_x(pitch) @ PORTRAIT
    m[:3, 3] = position
    return m


def _yaw_towards(direction_xz) -> float:
    """Yaw whose camera −Z axis points along the horizontal direction (x, z)."""
    return math.atan2(-direction_xz[0], -direction_xz[1])


def _column_major(m: np.ndarray) -> list[float]:
    return [round(float(v), 6) for v in m.reshape(-1, order="F")]


def _pose(x=0.0, y=0.0, z=0.0, yaw_deg=0.0) -> np.ndarray:
    m = np.eye(4)
    m[:3, :3] = _rot_y(math.radians(yaw_deg))
    m[:3, 3] = [x, y, z]
    return m


# --- Layout -------------------------------------------------------------------------------------

def _partition(rng: np.random.Generator, count: int) -> list[float]:
    return [round(float(rng.uniform(3.0, 4.2)), 1) for _ in range(count)]


def layout(seed: int = 0, rooms_per_side: tuple[int, int] | None = None) -> Building:
    """Seeded building description (geometry and semantics, no rendering)."""
    rng = np.random.default_rng(seed)
    n_north, n_south = rooms_per_side or (int(rng.integers(2, 4)), int(rng.integers(2, 4)))
    n_north, n_south = max(2, n_north), max(1, n_south)
    cw = float(rng.choice([2.0, 2.2, 2.4]))
    depth_n, depth_s = (round(float(rng.uniform(3.4, 4.6)), 1) for _ in range(2))
    drop = 0.30
    slope = float(rng.choice([1 / 12, 1 / 14, 1 / 10], p=[0.5, 0.25, 0.25]))
    ramp_run = round(drop / slope, 2)
    lobby_w = round(float(rng.uniform(4.0, 5.0)), 1)
    floor_number = int(rng.integers(1, 5))
    widths_n, widths_s = _partition(rng, n_north), _partition(rng, n_south)
    lc = max(sum(widths_n), sum(widths_s))
    x1 = round(lc + ramp_run, 3)
    xe = round(x1 + lobby_w, 3)
    zc = cw / 2
    zn, zs = -zc - depth_n, zc + depth_s
    stair_lane, ramp_lane = (-zc, -RAIL_T / 2), (RAIL_T / 2, zc)

    def rooms(widths: list[float], z0: float, z1: float, side: str) -> list[Space]:
        result, x = [], 0.0
        for i, w in enumerate(widths):
            end = x1 if i == len(widths) - 1 else round(x + w, 3)
            result.append(Space(f"{side}-{i}", "room", round(x, 3), end, z0, z1))
            x = end
        return result

    north, south = rooms(widths_n, zn, -zc, "north"), rooms(widths_s, zc, zs, "south")
    corridor = Space("corridor", "corridor", 0.0, x1, -zc, zc, name="Corridor",
                     aliases=["corridor", "hallway", "hall"])
    lobby = Space("lobby", "lobby", x1, xe, zn, zs, floor_y=-drop, name="Lobby",
                  aliases=["lobby", "entrance", "foyer"])

    # Room semantics: one restroom on the south side; other kinds sampled.
    restroom = south[int(rng.integers(0, len(south)))]
    kinds = list(ROOM_KINDS)
    numbers = iter(range(floor_number * 100 + 1, floor_number * 100 + 99))
    for room in sorted(north + south, key=lambda r: (r.x0, r.z0)):
        room.number = str(next(numbers))
        if room is restroom:
            room.room_kind, room.name, room.section_label = "restroom", "Restroom", "bathroom"
            room.aliases = ["restroom", "bathroom", "toilet", "toilets", "toilettes", "wc", room.number]
        else:
            kind = kinds[int(rng.integers(0, len(kinds)))]
            label, section = ROOM_KINDS[kind]
            room.room_kind, room.name, room.section_label = kind, label.title(), section
            # RoomPlan's "unidentified" fallback is not a label, so it is never an alias.
            room.aliases = [room.number, kind, label.lower()] + ([section.lower()] if section != "unidentified" else [])

    # Doors on the corridor walls.
    doors: list[Door] = []
    opening_candidates = [r for r in south + north[2:] if r is not restroom]
    opening_room = opening_candidates[int(rng.integers(0, len(opening_candidates)))] if opening_candidates else None
    for room in north + south:
        side_n = room.z1 <= 0
        level_x1 = min(room.x1, lc)
        if room is north[0]:
            width = float(rng.choice([0.71, 0.76]))
        elif room is north[1]:
            width = float(rng.choice([0.91, 0.97, 1.07]))
        elif room is restroom:
            width = float(rng.choice([0.91, 0.97, 1.07, 0.76], p=[0.3, 0.3, 0.2, 0.2]))
        else:
            width = float(rng.choice([0.76, 0.86, 0.91, 0.97]))
        kind = "door"
        if room is opening_room:
            kind, width = "opening", 1.2
        near_low = bool(rng.integers(0, 2))
        center = room.x0 + 0.5 + width / 2 if near_low else level_x1 - 0.5 - width / 2
        doors.append(Door(f"door-{room.id}", kind, (room.id, "corridor"), "x", -zc if side_n else zc,
                          round(center, 3), width, height=OPENING_H if kind == "opening" else DOOR_H,
                          leaf="open" if kind == "door" else None, hinge=-1 if near_low else 1,
                          into=-1 if side_n else 1))
    # Connecting door between the first two north rooms (a step-free detour around a narrow door).
    zmid = round(-zc - 0.5 - 0.455, 3)
    doors.append(Door("door-north-0-north-1", "door", ("north-1", "north-0"), "z", north[0].x1, zmid, 0.91,
                      leaf="open", hinge=-1, into=1))
    # Lobby: two lane openings in its west wall, and a closed exterior exit door.
    lane_w_s, lane_w_r = stair_lane[1] - stair_lane[0], ramp_lane[1] - ramp_lane[0]
    doors.append(Door("opening-stair-lane", "opening", ("lobby", "corridor"), "z", x1,
                      round(sum(stair_lane) / 2, 3), round(lane_w_s, 3), floor_y=-drop, height=LANE_OPENING_TOP_Y + drop))
    doors.append(Door("opening-ramp-lane", "opening", ("lobby", "corridor"), "z", x1,
                      round(sum(ramp_lane) / 2, 3), round(lane_w_r, 3), floor_y=-drop, height=LANE_OPENING_TOP_Y + drop))
    doors.append(Door("door-exit", "door", ("lobby", None), "z", xe, 0.0, 0.97, floor_y=-drop, leaf="closed"))

    # Walls (RoomPlan walls span their doorways; geometry holes are cut from them).
    walls = [
        Wall("wall-north-exterior", "x", zn, 0.0, x1, 0.0, CEILING_Y),
        Wall("wall-south-exterior", "x", zs, 0.0, x1, 0.0, CEILING_Y),
        Wall("wall-west-exterior", "z", 0.0, zn, zs, 0.0, CEILING_Y),
        # Corridor walls reach the lobby level: the lanes beside them drop towards the lobby.
        Wall("wall-corridor-north", "x", -zc, 0.0, x1, -drop, CEILING_Y),
        Wall("wall-corridor-south", "x", zc, 0.0, x1, -drop, CEILING_Y),
        Wall("wall-lobby-north", "x", zn, x1, xe, -drop, CEILING_Y),
        Wall("wall-lobby-south", "x", zs, x1, xe, -drop, CEILING_Y),
        Wall("wall-lobby-east", "z", xe, zn, zs, -drop, CEILING_Y),
        Wall("wall-lobby-west", "z", x1, zn, zs, -drop, CEILING_Y),
    ]
    for side, z0, z1 in ((north, zn, -zc), (south, zc, zs)):
        for room in side[:-1]:
            walls.append(Wall(f"wall-{room.id}-east", "z", room.x1, z0, z1, 0.0, CEILING_Y))
    by_id = {w.id: w for w in walls}
    for door in doors:
        if door.leaf == "closed":
            continue  # A closed leaf fills its doorway; geometry keeps the wall.
        if door.axis == "x":
            wall = by_id["wall-corridor-north" if door.line < 0 else "wall-corridor-south"]
        elif door.line == x1:
            wall = by_id["wall-lobby-west"]
        else:
            wall = next(w for w in walls if w.axis == "z" and abs(w.line - door.line) < 1e-9 and w.a0 < door.center < w.a1)
        top = LANE_OPENING_TOP_Y if wall.id == "wall-lobby-west" else door.floor_y + door.height
        wall.holes.append((door.center - door.width / 2, door.center + door.width / 2, top))

    spaces = [*north, *south, corridor, lobby]
    building = Building(seed, f"synthetic-building-{seed}", floor_number, cw, drop, ramp_run, drop / ramp_run,
                        stair_lane, ramp_lane, round(lc, 3), x1, spaces, doors, walls, [], [], [],
                        _georef(rng))
    building.objects = _furnish(building, rng, restroom)
    building.signs, building.decals = _signage(building, restroom)
    return building


def _georef(rng: np.random.Generator) -> dict:
    return {"latitude": round(33.7756 + float(rng.uniform(-0.004, 0.004)), 7),
            "longitude": round(-84.3963 + float(rng.uniform(-0.004, 0.004)), 7),
            "heading_degrees": round(float(rng.uniform(0, 360)), 2),
            "altitude_m": round(float(rng.uniform(280, 320)), 1)}


def _furnish(b: Building, rng: np.random.Generator, restroom: Space) -> list[dict]:
    objects: list[dict] = []

    def add(space: Space, category: str, x: float, z: float, dims, yaw=0.0) -> None:
        if space.kind == "room":  # keep every object inside the room's walls
            x = float(np.clip(x, space.x0 + WALL_T / 2 + 0.05 + dims[0] / 2, space.x1 - WALL_T / 2 - 0.05 - dims[0] / 2))
        objects.append({"id": f"obj-{space.id}-{sum(o['space'] == space.id for o in objects)}", "category": category,
                        "space": space.id, "center": [round(x, 3), round(space.floor_y + dims[1] / 2, 3), round(z, 3)],
                        "dimensions": [float(d) for d in dims], "yaw": yaw})

    for room in (s for s in b.spaces if s.kind == "room"):
        north = room.z1 <= 0
        far = room.z0 + WALL_T / 2 if north else room.z1 - WALL_T / 2  # wall face opposite the door
        inward = 1 if north else -1                                       # +Z away from the far wall
        door = next(d for d in b.doors if d.spaces[0] == room.id and d.axis == "x")
        # Keep furniture out of the doorway approach: use the half of the room away from the door.
        lo, hi = room.x0 + 0.35, min(room.x1, b.level_end_x + 2.5) - 0.35
        mid_x = (room.x0 + min(room.x1, b.level_end_x)) / 2
        away = (mid_x, hi) if door.center < mid_x else (lo, mid_x)
        if room is restroom:
            add(room, "toilet", lo + 0.3, far + inward * 0.38, (0.4, 0.76, 0.7))
            add(room, "sink", hi - 0.35, far + inward * 0.25, (0.6, 0.86, 0.5))
            add(room, "toilet", lo + 1.25, far + inward * 0.38, (0.4, 0.76, 0.7))
        elif room.room_kind == "office":
            x = (away[0] + away[1]) / 2
            add(room, "table", x, far + inward * 0.4, (1.4, 0.74, 0.7))
            add(room, "chair", x, far + inward * 1.05, (0.5, 0.9, 0.5))
            add(room, "storage", room.x0 + 0.35 if door.center >= mid_x else hi - 0.1, far + inward * 0.25,
                (0.5, 1.8, 0.45))
        elif room.room_kind == "conference":
            cz = (room.z0 + room.z1) / 2 - inward * 0.25
            add(room, "table", mid_x, cz, (1.8, 0.75, 0.9))
            add(room, "chair", mid_x - 0.5, cz - inward * 0.75, (0.5, 0.9, 0.5))
            add(room, "chair", mid_x + 0.5, cz - inward * 0.75, (0.5, 0.9, 0.5))
        elif room.room_kind == "storage":
            add(room, "storage", away[0] + 0.5, far + inward * 0.25, (0.9, 1.8, 0.45))
            add(room, "storage", away[1] - 0.5, far + inward * 0.25, (0.9, 1.8, 0.45))
        elif room.room_kind == "lounge":
            x = (away[0] + away[1]) / 2
            add(room, "sofa", x, far + inward * 0.45, (1.9, 0.85, 0.85))
            add(room, "table", x, far + inward * 1.45, (1.0, 0.45, 0.6))
        else:  # kitchenette: a run of appliances along the far wall, from the end away from the door
            items = (("refrigerator", (0.7, 1.8, 0.7)), ("sink", (0.8, 0.9, 0.6)), ("stove", (0.7, 0.9, 0.6)))
            step = 1 if door.center >= mid_x else -1
            edge = room.x0 + WALL_T / 2 + 0.05 if step > 0 else min(room.x1, b.level_end_x + 2.5) - WALL_T / 2 - 0.05
            for category, dims in items:
                add(room, category, edge + step * dims[0] / 2, far + inward * dims[2] / 2, dims)
                edge += step * (dims[0] + 0.05)
    lobby = b.space("lobby")
    add(lobby, "sofa", (lobby.x0 + lobby.x1) / 2, lobby.z1 - WALL_T / 2 - 0.45, (1.9, 0.85, 0.85))
    # The stair as RoomPlan reports it: a box over the stepped part of the stair lane.
    stair_x0 = b.lanes_end_x - (STAIR_RISERS - 1) * STAIR_RUN_M
    lane = b.stair_lane
    objects.append({"id": "obj-stairs-0", "category": "stairs", "space": "corridor",
                    "center": [round((stair_x0 + b.lanes_end_x) / 2, 3), round(-b.lobby_drop / 2, 3), round(sum(lane) / 2, 3)],
                    "dimensions": [round(b.lanes_end_x - stair_x0, 3), b.lobby_drop, round(lane[1] - lane[0], 3)], "yaw": 0.0})
    _ = rng  # reserved for future furniture variation
    return objects


# --- Signs ----------------------------------------------------------------------------------------

def _wall_point(b: Building, door: Door, along: float, height: float, side_space: str) -> tuple[np.ndarray, np.ndarray]:
    """Point on the wall face of `door`'s wall at `along` (wall coordinate), facing `side_space`."""
    space = b.space(side_space)
    if door.axis == "x":
        sign = 1.0 if space.center[2] > door.line else -1.0
        normal = np.array([0.0, 0.0, sign])
        point = np.array([along, space.floor_y + height, door.line + sign * WALL_T / 2])
    else:
        sign = 1.0 if space.center[0] > door.line else -1.0
        normal = np.array([sign, 0.0, 0.0])
        point = np.array([door.line + sign * WALL_T / 2, space.floor_y + height, along])
    return point, normal


def _clear_along(b: Building, signs: list[SignSpec], line: float, preferred: float, half: float,
                 lo: float, hi: float) -> float:
    """Position along a corridor wall (constant z = `line`) near `preferred` that keeps a sign of
    half-width `half` clear of doorways and of signs already on that wall face."""
    taken = [(d.center, d.width / 2 + 0.12) for d in b.doors if d.axis == "x" and abs(d.line - line) < 1e-6]
    taken += [(s.center[0], s.size[0] / 2 + 0.08) for s in signs if abs(abs(s.center[2]) - abs(line) + WALL_T / 2) < 1e-6
              and np.sign(s.center[2]) == np.sign(line)]
    for candidate in sorted(np.arange(lo, hi + 1e-9, 0.05), key=lambda c: (abs(c - preferred), c)):
        if all(abs(candidate - c) >= r + half for c, r in taken):
            return round(float(candidate), 3)
    return round(preferred, 3)


def _signage(b: Building, restroom: Space) -> tuple[list[SignSpec], list[Decal]]:
    signs: list[SignSpec] = []
    white, black = (255, 255, 255), (20, 20, 20)
    for door in (d for d in b.doors if d.axis == "x"):
        room = b.space(door.spaces[0])
        latch = -door.hinge  # plates sit on the latch side of the door
        if room is restroom:
            accessible = door.clear_width >= DOOR_MIN_CLEAR_M
            w, h = 0.30, 0.36
            along = door.center + latch * (door.width / 2 + 0.12 + w / 2)
            center, normal = _wall_point(b, door, along, 1.5, "corridor")
            pictos = [{"kind": "man", "box": (0.08, 0.05, 0.46, 0.5), "color": white},
                      {"kind": "woman", "box": (0.54, 0.05, 0.92, 0.5), "color": white}]
            if accessible:
                pictos = [{"kind": "man", "box": (0.02, 0.05, 0.34, 0.5), "color": white},
                          {"kind": "woman", "box": (0.34, 0.05, 0.66, 0.5), "color": white},
                          {"kind": "wheelchair", "box": (0.66, 0.08, 0.98, 0.48), "color": white}]
            signs.append(SignSpec(f"sign-{room.id}", "accessible_restroom" if accessible else "restroom", center, normal,
                                  (w, h), (170, 80, 10),
                                  [{"text": "RESTROOM", "language": "en", "box": (0.06, 0.56, 0.94, 0.74), "color": white},
                                   {"text": "TOILETTES", "language": "fr", "box": (0.06, 0.78, 0.94, 0.94), "color": white}],
                                  pictos, space="corridor"))
        else:
            w, h = 0.26, 0.20
            along = door.center + latch * (door.width / 2 + 0.12 + w / 2)
            center, normal = _wall_point(b, door, along, 1.5, "corridor")
            signs.append(SignSpec(f"sign-{room.id}", "room", center, normal, (w, h), (70, 45, 30),
                                  [{"text": room.number, "language": None, "box": (0.12, 0.08, 0.88, 0.6), "color": white},
                                   {"text": room.name.upper(), "language": "en", "box": (0.08, 0.68, 0.92, 0.9), "color": white}],
                                  [], space="corridor"))
    lobby = b.space("lobby")
    exit_door = next(d for d in b.doors if d.id == "door-exit")
    center, normal = _wall_point(b, exit_door, 0.0, DOOR_H + 0.26, "lobby")
    signs.append(SignSpec("sign-exit", "exit", center, normal, (0.44, 0.26), (40, 150, 20),
                          [{"text": "EXIT", "language": "en", "box": (0.36, 0.08, 0.95, 0.56), "color": white},
                           {"text": "SALIDA", "language": "es", "box": (0.36, 0.62, 0.95, 0.92), "color": white}],
                          [{"kind": "running_man", "box": (0.04, 0.1, 0.32, 0.9), "color": white}], space="lobby"))
    # Directional exit sign on the corridor's north wall near its west end, pointing east (+X).
    wall_door = Door("_", "door", ("corridor", None), "x", -b.corridor_width / 2, 0.0, 1.0)
    along = _clear_along(b, signs, wall_door.line, 1.1, 0.21, 0.4, b.level_end_x - 0.4)
    center, normal = _wall_point(b, wall_door, along, 1.75, "corridor")
    signs.append(SignSpec("sign-exit-direction", "directional", center, normal, (0.42, 0.18), (40, 150, 20),
                          [{"text": "EXIT", "language": "en", "box": (0.06, 0.15, 0.52, 0.85), "color": white}],
                          [{"kind": "arrow", "box": (0.58, 0.15, 0.95, 0.85), "color": white,
                            "direction": "right" if normal[2] > 0 else "left"}],
                          arrows=[[1.0, 0.0]], space="corridor"))
    # Elevator sign and doors on the lobby's north wall.
    north_wall_door = Door("_", "door", ("lobby", None), "x", lobby.z0, 0.0, 1.0)
    ex = round(lobby.x0 + 0.45 * (lobby.x1 - lobby.x0), 3)
    center, normal = _wall_point(b, north_wall_door, ex + 1.0, 1.55, "lobby")
    signs.append(SignSpec("sign-elevator", "elevator", center, normal, (0.30, 0.30), (120, 60, 20),
                          [{"text": "ELEVATOR", "language": "en", "box": (0.06, 0.56, 0.94, 0.74), "color": white},
                           {"text": "ASCENSOR", "language": "es", "box": (0.06, 0.78, 0.94, 0.94), "color": white}],
                          [{"kind": "elevator", "box": (0.25, 0.06, 0.75, 0.5), "color": white}], space="lobby"))
    door_center, door_normal = _wall_point(b, north_wall_door, ex, 1.05, "lobby")
    decals = [Decal(door_center, door_normal, (1.1, 2.1), _elevator_doors())]
    # Exit door panel (closed leaf) on the lobby's east wall.
    panel_center, panel_normal = _wall_point(b, exit_door, 0.0, DOOR_H / 2, "lobby")
    decals.append(Decal(panel_center, panel_normal, (exit_door.width, DOOR_H), _door_panel()))
    # Ramp sign on the corridor's south wall where the ramp lane begins.
    south_wall_door = Door("_", "door", ("corridor", None), "x", b.corridor_width / 2, 0.0, 1.0)
    along = _clear_along(b, signs, south_wall_door.line, b.level_end_x - 0.4, 0.18, 0.4, b.level_end_x - 0.2)
    center, normal = _wall_point(b, south_wall_door, along, 1.5, "corridor")
    signs.append(SignSpec("sign-ramp", "ramp", center, normal, (0.36, 0.20), (170, 80, 10),
                          [{"text": "RAMP", "language": "en", "box": (0.36, 0.2, 0.74, 0.8), "color": white}],
                          [{"kind": "wheelchair", "box": (0.04, 0.1, 0.32, 0.9), "color": white},
                           {"kind": "arrow", "box": (0.76, 0.2, 0.97, 0.8), "color": white,
                            "direction": "left" if normal[2] < 0 else "right"}],
                          arrows=[[1.0, 0.0]], space="corridor"))
    for sign in signs:
        sign.texture = _sign_texture(sign)
    _ = black
    return signs, decals


def _fit_text(image: np.ndarray, text: str, box_px, color) -> None:
    x0, y0, x1, y1 = box_px
    font = cv2.FONT_HERSHEY_DUPLEX
    (tw, th), _ = cv2.getTextSize(text, font, 1.0, 1)
    scale = min(0.92 * (x1 - x0) / tw, 0.78 * (y1 - y0) / th)
    thickness = max(2, int(round(scale * 1.9)))
    (tw, th), _ = cv2.getTextSize(text, font, scale, thickness)
    origin = (int(round((x0 + x1 - tw) / 2)), int(round((y0 + y1 + th) / 2)))
    cv2.putText(image, text, origin, font, scale, color, thickness, cv2.LINE_AA)


def _pictogram(image: np.ndarray, kind: str, box_px, color, direction: str | None = None) -> None:
    x0, y0, x1, y1 = box_px
    w, h = x1 - x0, y1 - y0
    cx = (x0 + x1) // 2
    t = max(3, int(min(w, h) * 0.08))
    if kind in ("man", "woman"):
        head = int(min(w, h) * 0.13)
        cv2.circle(image, (cx, y0 + head + 2), head, color, -1, cv2.LINE_AA)
        top = y0 + 2 * head + 8
        if kind == "man":
            cv2.rectangle(image, (cx - int(w * 0.17), top), (cx + int(w * 0.17), y0 + int(h * 0.62)), color, -1)
        else:
            dress = np.array([[cx, top], [cx - int(w * 0.25), y0 + int(h * 0.68)], [cx + int(w * 0.25), y0 + int(h * 0.68)]])
            cv2.fillPoly(image, [dress], color, cv2.LINE_AA)
        for dx in (-0.08, 0.08):
            cv2.line(image, (cx + int(w * dx), y0 + int(h * 0.6)), (cx + int(w * dx), y1 - 2), color, t, cv2.LINE_AA)
    elif kind == "wheelchair":  # International Symbol of Access, simplified
        r = int(min(w, h) * 0.1)
        cv2.circle(image, (x0 + int(w * 0.42), y0 + r + 2), r, color, -1, cv2.LINE_AA)
        cv2.line(image, (x0 + int(w * 0.42), y0 + 2 * r + 4), (x0 + int(w * 0.42), y0 + int(h * 0.58)), color, t, cv2.LINE_AA)
        cv2.line(image, (x0 + int(w * 0.42), y0 + int(h * 0.58)), (x0 + int(w * 0.72), y0 + int(h * 0.58)), color, t, cv2.LINE_AA)
        cv2.line(image, (x0 + int(w * 0.72), y0 + int(h * 0.58)), (x0 + int(w * 0.85), y0 + int(h * 0.88)), color, t, cv2.LINE_AA)
        cv2.ellipse(image, (x0 + int(w * 0.42), y0 + int(h * 0.68)), (int(w * 0.28), int(h * 0.26)), 0, 60, 330, color, t, cv2.LINE_AA)
    elif kind == "running_man":
        cv2.rectangle(image, (x0 + int(w * 0.55), y0), (x1, y1), color, max(2, t // 2))
        r = int(min(w, h) * 0.11)
        hx, hy = x0 + int(w * 0.45), y0 + r + 4
        cv2.circle(image, (hx, hy), r, color, -1, cv2.LINE_AA)
        hip = (x0 + int(w * 0.32), y0 + int(h * 0.6))
        neck = (hx - int(w * 0.04), hy + r + 4)
        for a, b_ in ((neck, hip), (neck, (x0 + int(w * 0.68), y0 + int(h * 0.38))), (neck, (x0 + int(w * 0.08), y0 + int(h * 0.45))),
                      (hip, (x0 + int(w * 0.6), y1 - 4)), (hip, (x0 + int(w * 0.05), y0 + int(h * 0.82)))):
            cv2.line(image, a, b_, color, t, cv2.LINE_AA)
    elif kind == "arrow":
        y = (y0 + y1) // 2
        start, end = ((x0 + 4, y), (x1 - 4, y)) if direction != "left" else ((x1 - 4, y), (x0 + 4, y))
        cv2.arrowedLine(image, start, end, color, max(4, int(h * 0.16)), cv2.LINE_AA, tipLength=0.45)
    elif kind == "elevator":
        mx = (x0 + x1) // 2
        up = np.array([[mx - int(w * 0.42), y0 + int(h * 0.46)], [mx - int(w * 0.06), y0 + int(h * 0.46)], [mx - int(w * 0.24), y0 + 4]])
        down = np.array([[mx + int(w * 0.06), y1 - int(h * 0.46)], [mx + int(w * 0.42), y1 - int(h * 0.46)], [mx + int(w * 0.24), y1 - 4]])
        cv2.fillPoly(image, [up, down], color, cv2.LINE_AA)


def _sign_texture(sign: SignSpec) -> np.ndarray:
    w, h = int(round(sign.size[0] * TEXTURE_PPM)), int(round(sign.size[1] * TEXTURE_PPM))
    image = np.zeros((h, w, 3), np.uint8)
    image[:] = sign.plate_bgr
    border = max(4, int(0.012 * TEXTURE_PPM))
    cv2.rectangle(image, (border, border), (w - border - 1, h - border - 1), (235, 235, 235), max(2, border // 2))
    px = lambda box: (int(box[0] * w), int(box[1] * h), int(box[2] * w), int(box[3] * h))  # noqa: E731
    for picto in sign.pictograms:
        _pictogram(image, picto["kind"], px(picto["box"]), picto["color"], picto.get("direction"))
    for line in sign.lines:
        _fit_text(image, line["text"], px(line["box"]), line["color"])
    return image


def _elevator_doors() -> np.ndarray:
    w, h = int(1.1 * 400), int(2.1 * 400)
    image = np.full((h, w, 3), (175, 172, 168), np.uint8)
    cv2.rectangle(image, (0, 0), (w - 1, h - 1), (95, 95, 95), 18)
    cv2.line(image, (w // 2, 0), (w // 2, h), (90, 90, 90), 5)
    return image


def _door_panel() -> np.ndarray:
    w, h = int(0.97 * 400), int(2.1 * 400)
    image = np.full((h, w, 3), (80, 110, 150), np.uint8)
    cv2.rectangle(image, (0, 0), (w - 1, h - 1), (60, 60, 60), 14)
    cv2.rectangle(image, (int(w * 0.1), int(h * 0.47)), (int(w * 0.9), int(h * 0.5)), (190, 190, 190), -1)
    return image


def _line_position(sign: SignSpec, box) -> np.ndarray:
    sx, sy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    return sign.center + sign.right * (sx - 0.5) * sign.size[0] + np.array([0.0, 1.0, 0.0]) * (0.5 - sy) * sign.size[1]


# --- Geometry -------------------------------------------------------------------------------------

def _split(lo: np.ndarray, hi: np.ndarray, limit: float | None = None) -> list[tuple[np.ndarray, np.ndarray]]:
    limit = limit or SEGMENT_M
    counts = [max(1, int(math.ceil((hi[k] - lo[k]) / limit))) for k in range(3)]
    pieces = []
    for index in np.ndindex(*counts):
        a = lo + (hi - lo) * np.asarray(index) / counts
        c = lo + (hi - lo) * (np.asarray(index) + 1) / counts
        pieces.append((a, c))
    return pieces


def _wall_boxes(wall: Wall) -> list[tuple[np.ndarray, np.ndarray]]:
    half = WALL_T / 2

    def box(a0: float, a1: float, y0: float, y1: float):
        if wall.axis == "x":
            return np.array([a0, y0, wall.line - half]), np.array([a1, y1, wall.line + half])
        return np.array([wall.line - half, y0, a0]), np.array([wall.line + half, y1, a1])

    boxes, start = [], wall.a0 - half
    for b0, b1, top in sorted(wall.holes):
        if b0 > start:
            boxes.append(box(start, b0, wall.y0, wall.y1))
        boxes.append(box(b0, b1, top, wall.y1))
        start = b1
    if start < wall.a1 + half:
        boxes.append(box(start, wall.a1 + half, wall.y0, wall.y1))
    return boxes


def scene(b: Building) -> Scene:
    lo, hi, material, owner = [], [], [], []

    def add(a, c, name: str, space: str, split: bool = True) -> None:
        for p, q in (_split(np.asarray(a, float), np.asarray(c, float)) if split else [(np.asarray(a, float), np.asarray(c, float))]):
            lo.append(p), hi.append(q), material.append(MATERIAL_IDS[name]), owner.append(space)

    def owner_of(x: float, z: float) -> str:
        return next((s.id for s in b.spaces if s.contains(x, z)), "corridor")

    for wall in b.walls:
        for a, c in _wall_boxes(wall):
            add(a, c, "wall", owner_of(*(((a + c) / 2)[[0, 2]])))
    lc, x1, drop = b.level_end_x, b.lanes_end_x, b.lobby_drop
    for space in b.spaces:
        if space.kind == "room":
            add((space.x0, -0.05, space.z0), (space.x1, 0.0, space.z1), "floor", space.id)
    corridor = b.space("corridor")
    add((0.0, -0.05, corridor.z0), (lc, 0.0, corridor.z1), "floor", "corridor")
    stair_x0 = x1 - (STAIR_RISERS - 1) * STAIR_RUN_M
    add((lc, -drop - 0.05, b.stair_lane[0]), (stair_x0, 0.0, b.stair_lane[1] + RAIL_T / 2), "floor", "corridor")
    for k in range(1, STAIR_RISERS):
        add((x1 - (STAIR_RISERS - k) * STAIR_RUN_M, -drop - 0.05, b.stair_lane[0]),
            (x1 - (STAIR_RISERS - k - 1) * STAIR_RUN_M, -k * drop / STAIR_RISERS, b.stair_lane[1] + RAIL_T / 2), "stairs", "corridor")
    lobby = b.space("lobby")
    add((lobby.x0, -drop - 0.05, lobby.z0), (lobby.x1, -drop, lobby.z1), "floor", "lobby")
    add((lc, -drop, -RAIL_T / 2), (x1, RAIL_TOP_Y, RAIL_T / 2), "rail", "corridor")
    for space in b.spaces:
        add((space.x0, CEILING_Y, space.z0), (space.x1, CEILING_Y + 0.05, space.z1), "ceiling", space.id)
    for door in b.doors:
        if door.leaf != "open":
            continue
        hinge = door.center + door.hinge * door.width / 2
        leaf_lo, leaf_hi = sorted((hinge, hinge - door.hinge * LEAF_T))
        face = door.line + door.into * WALL_T / 2
        depth_lo, depth_hi = sorted((face, face + door.into * door.width))
        if door.axis == "x":
            add((leaf_lo, door.floor_y + 0.01, depth_lo), (leaf_hi, door.floor_y + door.height - 0.01, depth_hi), "door_leaf", door.spaces[0], False)
        else:
            add((depth_lo, door.floor_y + 0.01, leaf_lo), (depth_hi, door.floor_y + door.height - 0.01, leaf_hi), "door_leaf", door.spaces[0], False)
    for obj in b.objects:
        if obj["category"] == "stairs":
            continue  # stairs are drawn as steps above
        center, dims = np.asarray(obj["center"]), np.asarray(obj["dimensions"])
        if abs(obj["yaw"]) > 1e-9:
            dims = dims[[2, 1, 0]]
        add(center - dims / 2, center + dims / 2, OBJECT_MATERIAL[obj["category"]], obj["space"], False)
    # The ramp lane surface: from the corridor level at Lc down to the lobby at X1.
    r0, r1 = b.ramp_lane[0] - RAIL_T / 2, b.ramp_lane[1]
    a, bq, c, d = (np.array(p, float) for p in ((lc, 0.0, r0), (lc, 0.0, r1), (x1, -drop, r1), (x1, -drop, r0)))
    triangles = np.array([[a, bq, c], [a, c, d]])
    return Scene(np.array(lo), np.array(hi), np.array(material, np.int32), owner, triangles,
                 np.full(2, MATERIAL_IDS["ramp"], np.int32), ["corridor", "corridor"],
                 [Decal(s.center, s.normal, s.size, s.texture) for s in b.signs] + list(b.decals))


# --- Ray casting ----------------------------------------------------------------------------------

def cast(sc: Scene, origin: np.ndarray, dirs: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Nearest hit of each ray (H, W, 3) from `origin`: parameter t (z-depth for camera rays with
    z = −1), primitive index (boxes first, then triangles; −1 for none) and surface normal."""
    height, width, _ = dirs.shape
    t_best = np.full((height, width), np.inf)
    index = np.full((height, width), -1, np.int64)
    axis = np.zeros((height, width), np.int64)
    safe = np.where(np.abs(dirs) < 1e-12, 1e-12, dirs)
    inv = 1.0 / safe
    unit = dirs / np.linalg.norm(dirs, axis=-1, keepdims=True)
    offset = sc.centers - origin
    distance = np.linalg.norm(offset, axis=1)
    inside = distance <= sc.radii + 1e-6
    toward = offset / np.maximum(distance, 1e-9)[:, None]
    spread = np.arcsin(np.clip(sc.radii / np.maximum(distance, 1e-9), 0, 1))
    for r0 in range(0, height, TILE):
        for c0 in range(0, width, TILE):
            u = unit[r0:r0 + TILE, c0:c0 + TILE].reshape(-1, 3)
            centre = u.mean(axis=0)
            centre /= np.linalg.norm(centre)
            half = float(np.arccos(np.clip(u @ centre, -1, 1)).max())
            angle = np.arccos(np.clip(toward @ centre, -1, 1))
            candidates = np.nonzero(inside | (angle <= half + spread + 1e-3))[0]
            if not len(candidates):
                continue
            tile_inv = inv[r0:r0 + TILE, c0:c0 + TILE].reshape(-1, 3)
            t1 = (sc.lo[candidates][None] - origin) * tile_inv[:, None]
            t2 = (sc.hi[candidates][None] - origin) * tile_inv[:, None]
            near = np.minimum(t1, t2)
            t_near, t_far = near.max(-1), np.maximum(t1, t2).min(-1)
            t = np.where((t_far >= t_near) & (t_near > 1e-3), t_near, np.inf)
            pick = t.argmin(axis=1)
            rows = np.arange(len(pick))
            shape = t_best[r0:r0 + TILE, c0:c0 + TILE].shape
            t_best[r0:r0 + TILE, c0:c0 + TILE] = t[rows, pick].reshape(shape)
            hit_axis = near[rows, pick].argmax(-1)
            index[r0:r0 + TILE, c0:c0 + TILE] = np.where(np.isfinite(t[rows, pick]), candidates[pick], -1).reshape(shape)
            axis[r0:r0 + TILE, c0:c0 + TILE] = hit_axis.reshape(shape)
    normal = np.zeros_like(dirs)
    np.put_along_axis(normal, axis[..., None], -np.sign(np.take_along_axis(dirs, axis[..., None], -1)), -1)
    boxes = len(sc.lo)
    for k, (a, bq, c) in enumerate(sc.triangles):  # Möller–Trumbore
        e1, e2 = bq - a, c - a
        p = np.cross(dirs, e2)
        det = p @ e1
        with np.errstate(divide="ignore", invalid="ignore"):
            inv_det = 1.0 / det
            s = origin - a
            u = (p @ s) * inv_det
            q = np.cross(s, e1)
            v = (dirs @ q) * inv_det
            t = (q @ e2) * inv_det
        hit = (np.abs(det) > 1e-12) & (u >= 0) & (v >= 0) & (u + v <= 1) & (t > 1e-3) & (t < t_best)
        t_best = np.where(hit, t, t_best)
        index = np.where(hit, boxes + k, index)
        n = np.cross(e1, e2)
        n /= np.linalg.norm(n)
        oriented = np.where((dirs @ n)[..., None] > 0, -n, n)
        normal = np.where(hit[..., None], oriented, normal)
    return t_best, index, normal


def _camera_dirs(m: np.ndarray, u: np.ndarray, v: np.ndarray) -> np.ndarray:
    local = np.stack(((u * IMAGE_W - CX) / FOCAL, -(v * IMAGE_H - CY) / FOCAL, -np.ones_like(u)), -1)
    return local @ m[:3, :3].T


def project(m: np.ndarray, points) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """World points -> (sensor-native u/v in [0, 1], upright-JPEG pixel x/y, z-depth) for camera `m`."""
    local = (np.asarray(points, float).reshape(-1, 3) - m[:3, 3]) @ m[:3, :3]
    depth = -local[:, 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        u = (FOCAL * local[:, 0] / depth + CX) / IMAGE_W
        v = (CY - FOCAL * local[:, 1] / depth) / IMAGE_H
    return np.column_stack((u, v)), np.column_stack(((1.0 - v) * JPEG_W, u * JPEG_H)), depth


def render_depth(sc: Scene, m: np.ndarray, rng: np.random.Generator, noise: bool = True) -> tuple[np.ndarray, np.ndarray]:
    """Sensor-native float32 depth (z-distance) and ARKit-style confidence (2 near, 1 mid, 0 far)."""
    v, u = np.mgrid[0:DEPTH_H, 0:DEPTH_W]
    depth, _, _ = cast(sc, m[:3, 3], _camera_dirs(m, (u + 0.5) / DEPTH_W, (v + 0.5) / DEPTH_H))
    finite = np.isfinite(depth)
    if noise:
        depth = depth + rng.normal(0.0, 1.0, depth.shape) * (0.003 + 0.002 * np.where(finite, depth, 0))
    confidence = np.where(depth < 3.5, 2, np.where(depth < 5.0, 1, 0)).astype(np.uint8)
    confidence[~finite] = 0
    depth = np.where(finite, depth, 0.0)
    return depth.astype("<f4"), confidence


def render_keyframe(sc: Scene, m: np.ndarray, rng: np.random.Generator) -> bytes:
    """Upright 480×640 JPEG (landscape sensor image rotated right), shaded, with sign decals."""
    py, px = np.mgrid[0:JPEG_H, 0:JPEG_W]
    dirs = _camera_dirs(m, (py + 0.5) / JPEG_H, 1.0 - (px + 0.5) / JPEG_W)
    origin = m[:3, 3]
    t, index, normal = cast(sc, origin, dirs)
    colors = np.array([c for c, _ in MATERIALS.values()], np.float64)
    material = np.concatenate([sc.material, sc.tri_material])
    base = np.where((index >= 0)[..., None], colors[material[np.maximum(index, 0)]], 30.0)
    hit = origin + dirs * np.where(np.isfinite(t), t, 0)[..., None]
    for decal in sc.decals:
        rel = hit - decal.center
        s = rel @ decal.right / decal.size[0] + 0.5
        r = 0.5 - rel[..., 1] / decal.size[1]
        mask = (np.abs(rel @ decal.normal) < 0.01) & (s >= 0) & (s <= 1) & (r >= 0) & (r <= 1) & np.isfinite(t)
        if not mask.any():
            continue
        th, tw = decal.texture.shape[:2]
        distance = float(np.median(t[mask]))
        scale = min(1.0, 2.0 * JPEG_FOCAL / max(distance, 0.3) * decal.size[0] / tw)
        texture = cv2.resize(decal.texture, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA) if scale < 1 else decal.texture
        th, tw = texture.shape[:2]
        map_x = (s * tw - 0.5).astype(np.float32)
        map_y = (r * th - 0.5).astype(np.float32)
        sampled = cv2.remap(texture, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        base[mask] = sampled[mask]
    light = np.array([0.3, 1.0, 0.5]) / np.linalg.norm([0.3, 1.0, 0.5])
    shade = 0.62 + 0.38 * np.abs(normal @ light)
    falloff = np.clip(1.08 - 0.035 * np.where(np.isfinite(t), t, 10), 0.65, 1.0)
    image = base * (shade * falloff)[..., None] + rng.normal(0.0, 2.0, base.shape)
    image = np.clip(image, 0, 255).astype(np.uint8)
    return cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 90])[1].tobytes()


# --- Native mesh ----------------------------------------------------------------------------------

def _quad_grid(a, b, c, d, normal, out_v, out_n, out_f, classification, out_c) -> None:
    a, b, c, d = (np.asarray(p, float) for p in (a, b, c, d))
    nu = max(1, int(math.ceil(np.linalg.norm(b - a) / MESH_CELL_M)))
    nv = max(1, int(math.ceil(np.linalg.norm(d - a) / MESH_CELL_M)))
    base = len(out_v)
    for i in range(nv + 1):
        for j in range(nu + 1):
            s, t = j / nu, i / nv
            out_v.append((1 - t) * ((1 - s) * a + s * b) + t * ((1 - s) * d + s * c))
            out_n.append(normal)
    for i in range(nv):
        for j in range(nu):
            k = base + i * (nu + 1) + j
            for tri in ((k, k + 1, k + nu + 2), (k, k + nu + 2, k + nu + 1)):
                p0, p1, p2 = (out_v[x] for x in tri)
                out_f.append(tri if np.dot(np.cross(p1 - p0, p2 - p0), normal) >= 0 else (tri[0], tri[2], tri[1]))
                out_c.append(classification)


def mesh_anchors(sc: Scene, b: Building) -> list[dict]:
    """ARKit-style mesh anchors (one per space), vertices local to `map_from_anchor`."""
    classes = [cls for _, cls in MATERIALS.values()]
    groups: dict[str, tuple[list, list, list, list]] = {s.id: ([], [], [], []) for s in b.spaces}
    for (lo, hi, mat, owner) in zip(sc.lo, sc.hi, sc.material, sc.owner):
        v, n, f, c = groups[owner]
        x0, y0, z0 = lo
        x1, y1, z1 = hi
        cls = classes[mat]
        faces = [
            ((x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1), (0, 1, 0)),
            ((x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1), (0, 0, 1)),
            ((x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (0, 0, -1)),
            ((x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (1, 0, 0)),
            ((x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0), (-1, 0, 0)),
        ]
        if mat == MATERIAL_IDS["ceiling"]:
            faces = [((x0, y0, z0), (x0, y0, z1), (x1, y0, z1), (x1, y0, z0), (0, -1, 0))]
        for a, bq, cq, d, normal in faces:
            _quad_grid(a, bq, cq, d, np.asarray(normal, float), v, n, f, cls, c)
    for tri, mat, owner in zip(sc.triangles, sc.tri_material, sc.tri_owner):
        v, n, f, c = groups[owner]
        normal = np.cross(tri[1] - tri[0], tri[2] - tri[0])
        normal = normal / np.linalg.norm(normal)
        if normal[1] < 0:
            normal = -normal
        base = len(v)
        v.extend(tri), n.extend([normal] * 3)
        f.append((base, base + 1, base + 2) if np.dot(np.cross(tri[1] - tri[0], tri[2] - tri[0]), normal) > 0 else (base, base + 2, base + 1))
        c.append(classes[mat])
    anchors = []
    for i, space in enumerate(b.spaces):
        v, n, f, c = groups[space.id]
        if not f:
            continue
        origin = np.round(space.center, 3)
        anchors.append({"id": f"m{i}", "space": space.id, "matrix": _pose(*origin),
                        "vertices": (np.asarray(v) - origin).astype("<f4"), "normals": np.asarray(n, "<f4"),
                        "faces": np.asarray(f, "<u4"), "classification": np.asarray(c, np.uint8)})
    return anchors


# --- Walk -----------------------------------------------------------------------------------------

@dataclass
class View:
    id: str
    matrix: np.ndarray
    space: str
    purpose: str


def _sign_view(sign: SignSpec, floor_y: float, distance: float, lateral: float = 0.0) -> tuple[np.ndarray, float, float]:
    position = sign.center + sign.normal * distance + sign.right * lateral
    position[1] = floor_y + EYE_M
    look = sign.center - position
    yaw = _yaw_towards(look[[0, 2]])
    pitch = math.atan2(look[1], float(np.linalg.norm(look[[0, 2]])))
    return position, yaw, pitch


def walk(b: Building, max_observations: int = 32) -> list[View]:
    """Camera poses visiting the lobby, the ramp/stair lanes, the corridor and every room."""
    views: list[tuple[np.ndarray, float, float, str, str]] = []
    lobby, corridor = b.space("lobby"), b.space("corridor")
    signs = {s.id: s for s in b.signs}
    lc, x1, drop, cw = b.level_end_x, b.lanes_end_x, b.lobby_drop, b.corridor_width
    lobby_eye = -drop + EYE_M
    lobby_c = np.array([(lobby.x0 + lobby.x1) / 2, lobby_eye, 0.0])
    views.append((*_sign_view(signs["sign-exit"], -drop, 2.2), "lobby", "exit sign"))
    views.append((*_sign_view(signs["sign-elevator"], -drop, 1.9, -0.5), "lobby", "elevator sign"))
    views.append((lobby_c + np.array([0.8, 0, 0]), _yaw_towards((-1, 0)), math.radians(-12), "lobby", "stairs and ramp"))
    ramp_z = sum(b.ramp_lane) / 2
    views.append((np.array([x1 - b.ramp_run / 2, -drop / 2 + EYE_M, ramp_z]), _yaw_towards((-1, 0)), math.radians(-6), "corridor", "ramp"))
    views.append((np.array([lc - 0.8, EYE_M, 0.25]), _yaw_towards((1, 0)), math.radians(-14), "corridor", "lanes from corridor"))
    near = min(cw - 0.45, 1.3)
    views.append((*_sign_view(signs["sign-ramp"], 0.0, near, 0.2), "corridor", "ramp sign"))
    views.append((*_sign_view(signs["sign-exit-direction"], 0.0, near, 0.3), "corridor", "exit direction sign"))
    views.append((np.array([0.6, EYE_M, 0.0]), _yaw_towards((1, 0)), 0.0, "corridor", "corridor"))
    for door in sorted((d for d in b.doors if d.axis == "x"), key=lambda d: (d.center, d.line)):
        room = b.space(door.spaces[0])
        sign = signs[f"sign-{room.id}"]
        views.append((*_sign_view(sign, 0.0, 1.15, 0.15 * door.hinge), "corridor", f"{room.id} sign"))
        inward = np.array([0.0, 0.0, door.into])
        inside = np.array([door.center, EYE_M, door.line]) + inward * 1.0
        views.append((inside, _yaw_towards(inward[[0, 2]]), math.radians(-12), room.id, f"{room.id} interior"))
        if room.room_kind == "restroom":
            views.append((inside, _yaw_towards((-door.hinge * 0.7, door.into)), math.radians(-20), room.id, "restroom fixtures"))
    connecting = next(d for d in b.doors if d.id == "door-north-0-north-1")
    views.append((np.array([connecting.line + 1.0, EYE_M, connecting.center]), _yaw_towards((-1, 0)), math.radians(-8),
                  "north-1", "connecting door"))
    views.append((np.array([lc - 1.0, EYE_M, 0.0]), _yaw_towards((-1, 0)), 0.0, "corridor", "corridor west"))
    if len(views) > max_observations:
        keep = np.unique(np.linspace(0, len(views) - 1, max_observations).round().astype(int))
        views = [views[i] for i in keep]
    return [View(f"f{i:02d}", camera_matrix(p, yaw, pitch), space, purpose)
            for i, (p, yaw, pitch, space, purpose) in enumerate(views)]


def _environment(b: Building, m: np.ndarray, timestamp: float, rng: np.random.Generator) -> dict:
    geo = b.georef
    heading = math.radians(geo["heading_degrees"])
    x, y, z = m[:3, 3]
    east = math.sin(heading) * -z + math.cos(heading) * x + rng.normal(0, 3.5)
    north = math.cos(heading) * -z - math.sin(heading) * x + rng.normal(0, 3.5)
    forward = -m[:3, 2]
    local_bearing = math.degrees(math.atan2(forward[0], -forward[2]))
    altitude = geo["altitude_m"] + y + rng.normal(0, 1.5)
    return {
        "recorded_at_unix_seconds": round(T0_UNIX + timestamp, 3),
        "latitude": round(geo["latitude"] + north / METERS_PER_DEG_LAT, 7),
        "longitude": round(geo["longitude"] + east / (METERS_PER_DEG_LAT * math.cos(math.radians(geo["latitude"]))), 7),
        "horizontal_accuracy_m": round(float(rng.uniform(5.0, 9.0)), 1),
        "altitude_m": round(altitude, 2), "vertical_accuracy_m": 4.0,
        "heading_degrees": round((geo["heading_degrees"] + local_bearing + rng.normal(0, 4.0)) % 360, 2),
        "heading_accuracy_degrees": round(float(rng.uniform(8.0, 15.0)), 1),
        "relative_altitude_m": round(y - EYE_M + rng.normal(0, 0.05), 3),
        "pressure_kpa": round(101.325 * math.exp(-altitude / 8434.0), 4),
    }


# --- Ground truth ---------------------------------------------------------------------------------

def _dijkstra(edges: dict[str, list[tuple[str, float]]], source: str) -> tuple[dict[str, float], dict[str, str]]:
    distance, previous, queue = {source: 0.0}, {}, [(0.0, source)]
    while queue:
        d, node = heapq.heappop(queue)
        if d > distance.get(node, math.inf):
            continue
        for other, length in edges.get(node, []):
            if d + length < distance.get(other, math.inf) - 1e-12:
                distance[other], previous[other] = d + length, node
                heapq.heappush(queue, (d + length, other))
    return distance, previous


def ground_graph(b: Building) -> dict:
    """Waypoint graph: space centres, door centres, corridor centreline and the two lanes."""
    nodes: dict[str, dict] = {}
    edges: list[dict] = []

    def node(node_id: str, position, kind: str, space: str | None) -> str:
        nodes.setdefault(node_id, {"id": node_id, "position_m": [_r(v) for v in position], "kind": kind, "space": space})
        return node_id

    def edge(a: str, c: str, kind: str = "walk", **extra) -> None:
        pa, pc = np.asarray(nodes[a]["position_m"]), np.asarray(nodes[c]["position_m"])
        edges.append({"from": a, "to": c, "kind": kind, "length_m": _r(np.linalg.norm(pa - pc)), **extra})

    lc, x1, drop = b.level_end_x, b.lanes_end_x, b.lobby_drop
    for space in b.spaces:
        if space.kind != "corridor":
            node(f"space:{space.id}", space.center, "space", space.id)
    corridor_xs = {0.6, round(lc - 0.3, 3)}
    for door in b.doors:
        y = door.floor_y
        x, z = door.center_xz
        door_node = node(f"door:{door.id}", (x, y, z), door.kind, None)
        attrs = {"door_id": door.id, "clear_width_m": door.clear_width}
        if door.axis == "x":  # room <-> corridor
            corridor_xs.add(round(door.center, 3))
            edge(f"space:{door.spaces[0]}", door_node, "door", **attrs)
            edge(door_node, node(f"corridor:{door.center:.3f}", (door.center, 0.0, 0.0), "corridor", "corridor"), "door", **attrs)
        elif door.id.startswith("opening-") or door.spaces[1] is None:
            edge("space:lobby", door_node, "door", **attrs)
        else:
            edge(f"space:{door.spaces[0]}", door_node, "door", **attrs)
            edge(door_node, f"space:{door.spaces[1]}", "door", **attrs)
    xs = sorted(corridor_xs)
    for x in xs:
        node(f"corridor:{x:.3f}", (x, 0.0, 0.0), "corridor", "corridor")
    for a, c in zip(xs, xs[1:]):
        edge(f"corridor:{a:.3f}", f"corridor:{c:.3f}")
    junction = f"corridor:{lc - 0.3:.3f}"
    stair_z, ramp_z = sum(b.stair_lane) / 2, sum(b.ramp_lane) / 2
    edge(junction, node("lane:stair_top", (lc, 0.0, stair_z), "lane", "corridor"))
    edge(junction, node("lane:ramp_top", (lc, 0.0, ramp_z), "lane", "corridor"))
    edge("lane:stair_top", "door:opening-stair-lane", "stairs", stairs=True, rise_m=drop)
    edge("lane:ramp_top", "door:opening-ramp-lane", "ramp", slope=_r(b.ramp_slope, 4), rise_m=drop)
    _ = x1
    adjacency = sorted({tuple(sorted((d.spaces[0], d.spaces[1]))) for d in b.doors if d.spaces[1] is not None})
    return {"nodes": sorted(nodes.values(), key=lambda n: n["id"]), "edges": edges,
            "room_adjacency": [list(p) for p in adjacency]}


def _usable(edge: dict, profile: str) -> bool:
    if profile != "wheelchair":
        return True
    if edge.get("stairs"):
        return False
    if edge.get("slope", 0.0) > RAMP_MAX_SLOPE + 1e-6:
        return False
    return edge.get("clear_width_m", math.inf) >= DOOR_MIN_CLEAR_M


def ground_routes(b: Building, graph: dict) -> list[dict]:
    routes = []
    targets = [s for s in b.spaces if s.kind != "corridor"]
    for profile in ("wheelchair", "ambulatory"):
        adjacency: dict[str, list[tuple[str, float]]] = {}
        for e in graph["edges"]:
            if _usable(e, profile):
                adjacency.setdefault(e["from"], []).append((e["to"], e["length_m"]))
                adjacency.setdefault(e["to"], []).append((e["from"], e["length_m"]))
        for i, a in enumerate(targets):
            distance, previous = _dijkstra(adjacency, f"space:{a.id}")
            for c in targets[i + 1:]:
                goal = f"space:{c.id}"
                path = None
                if goal in distance:
                    path, cursor = [goal], goal
                    while cursor != f"space:{a.id}":
                        cursor = previous[cursor]
                        path.append(cursor)
                    path.reverse()
                routes.append({"from_space": a.id, "to_space": c.id, "profile": profile,
                               "length_m": _r(distance[goal]) if goal in distance else None,
                               "reachable": goal in distance, "node_ids": path})
    return routes


def ground_truth(b: Building, views: list[View]) -> dict:
    graph = ground_graph(b)
    footprint = [s.polygon for s in b.spaces]
    signs, texts = [], []
    for sign in b.signs:
        lines = []
        for line in sign.lines:
            position = [_r(v) for v in _line_position(sign, line["box"])]
            lines.append({"text": line["text"], "language": line["language"], "position_m": position})
            texts.append({"text": line["text"], "language": line["language"], "position_m": position, "sign_id": sign.id})
        signs.append({"id": sign.id, "category": sign.category, "position_m": [_r(v) for v in sign.center],
                      "normal_m": [_r(v) for v in sign.normal], "size_m": list(sign.size),
                      "mounting_height_m": _r(sign.center[1] - b.space(sign.space).floor_y),
                      "pictograms": [p["kind"] for p in sign.pictograms], "arrows": sign.arrows,
                      "text": " ".join(line["text"] for line in sign.lines), "lines": lines, "space": sign.space})
    x1, drop = b.lanes_end_x, b.lobby_drop
    stair_x0 = x1 - (STAIR_RISERS - 1) * STAIR_RUN_M
    s0, s1 = b.stair_lane
    r0, r1 = b.ramp_lane
    hazards = [
        {"id": "hazard-stairs", "kind": "stairs", "severity": "barrier",
         "position_m": [_r((stair_x0 + x1) / 2), _r(-drop / 2), _r((s0 + s1) / 2)],
         "polygon_xz_m": [[_r(stair_x0 - 0.05), s0], [x1, s0], [x1, s1], [_r(stair_x0 - 0.05), s1]],
         "measure": {"rise_m": drop, "riser_height_m": _r(drop / STAIR_RISERS), "step_count": STAIR_RISERS,
                     "tread_depth_m": STAIR_RUN_M}},
        {"id": "hazard-ramp", "kind": "ramp", "severity": "warning" if b.ramp_slope <= RAMP_MAX_SLOPE + 1e-6 else "barrier",
         "position_m": [_r(b.level_end_x + b.ramp_run / 2), _r(-drop / 2), _r((r0 + r1) / 2)],
         "polygon_xz_m": [[b.level_end_x, r0], [x1, r0], [x1, r1], [b.level_end_x, r1]],
         "measure": {"slope": _r(b.ramp_slope, 4), "rise_m": drop, "run_m": b.ramp_run,
                     "length_m": _r(math.hypot(b.ramp_run, drop))}},
    ]
    places = []
    for space in b.spaces:
        if space.kind == "room":
            category = space.room_kind == "restroom" and "restroom" or "room"
            door = next(d for d in b.doors if d.spaces[0] == space.id and d.axis == "x")
            if category == "restroom" and door.clear_width >= DOOR_MIN_CLEAR_M:
                category = "accessible_restroom"
            names = {"en": f"{space.name} {space.number}" if category == "room" else space.name}
            if category != "room":
                names["fr"] = "Toilettes"
            places.append({"id": f"place-{space.id}", "category": category, "name": names["en"], "names": names,
                           "number": space.number, "space": space.id, "position_m": [_r(v) for v in space.center]})
    exit_door = next(d for d in b.doors if d.id == "door-exit")
    elevator = next(s for s in b.signs if s.id == "sign-elevator")
    places += [
        {"id": "place-exit", "category": "exit", "name": "Exit", "names": {"en": "Exit", "es": "Salida"}, "space": "lobby",
         "position_m": [_r(exit_door.line), -drop, _r(exit_door.center)]},
        {"id": "place-elevator", "category": "elevator", "name": "Elevator", "names": {"en": "Elevator", "es": "Ascensor"},
         "space": "lobby", "position_m": [_r(elevator.center[0] - 1.0), -drop, _r(elevator.center[2])]},
        {"id": "place-stairs", "category": "stairs", "name": "Stairs", "names": {"en": "Stairs"}, "space": "corridor",
         "position_m": hazards[0]["position_m"]},
        {"id": "place-ramp", "category": "ramp", "name": "Ramp", "names": {"en": "Ramp"}, "space": "corridor",
         "position_m": hazards[1]["position_m"]},
    ]
    return {
        "schema_version": TRUTH_SCHEMA_VERSION, "generator": GENERATOR, "seed": b.seed, "scan_id": b.scan_id,
        "frame": "shared_arkit_session",
        "notes": "Route lengths are waypoint-graph geodesics (space centre -> door -> corridor centreline) that ignore "
                 "furniture. Door clear width = nominal - 0.04 m leaf thickness for hinged doors.",
        "parameters": {"corridor_width_m": b.corridor_width, "lobby_drop_m": drop, "ramp_slope": _r(b.ramp_slope, 4),
                       "ramp_run_m": b.ramp_run, "floor_number": b.floor_number},
        "georef": dict(b.georef),
        "floor": {"floor_height_m": 0.0, "footprint_polygons_xz_m": footprint,
                  "footprint_area_m2": _r(sum((s.x1 - s.x0) * (s.z1 - s.z0) for s in b.spaces), 2)},
        "spaces": [{"id": s.id, "kind": s.kind, "room_kind": s.room_kind or s.kind, "number": s.number, "name": s.name,
                    "label": s.section_label if s.kind == "room" else s.kind, "aliases": s.aliases,
                    "polygon_xz_m": s.polygon, "area_m2": _r((s.x1 - s.x0) * (s.z1 - s.z0), 2),
                    "floor_y_m": s.floor_y, "center_m": [_r(v) for v in s.center]} for s in b.spaces],
        "doors": [{"id": d.id, "kind": d.kind, "spaces": list(d.spaces), "center_xz_m": [_r(v) for v in d.center_xz],
                   "nominal_width_m": d.width, "clear_width_m": d.clear_width, "height_m": d.height,
                   "required_min_clear_width_m": d.required, "meets_clear_width": d.clear_width >= d.required,
                   "leaf": d.leaf} for d in b.doors],
        "objects": [{k: o[k] for k in ("id", "category", "space", "center", "dimensions")} for o in b.objects],
        "signs": signs,
        "text": texts,
        "hazards": hazards,
        "places": places,
        "graph": graph,
        "routes": ground_routes(b, graph),
        "walk": [{"id": v.id, "space": v.space, "purpose": v.purpose,
                  "position_m": [_r(x) for x in v.matrix[:3, 3]]} for v in views],
    }


# --- Package --------------------------------------------------------------------------------------

def _measured(rng: np.random.Generator, sigma: float, m: np.ndarray, dims: list[float]) -> tuple[np.ndarray, list[float]]:
    """RoomPlan-style measurement error: a few centimetres on the centre and the non-zero extents."""
    if sigma <= 0:
        return m, dims
    m = m.copy()
    m[[0, 2], 3] += rng.normal(0.0, sigma, 2)
    m[1, 3] += rng.normal(0.0, sigma / 3)
    return m, [_r(d + rng.normal(0.0, sigma)) if d > 0 else d for d in dims]


def _surface_records(b: Building, rng: np.random.Generator, sigma: float) -> list[dict]:
    records = []
    for space in b.spaces:
        m, dims = _measured(rng, sigma, _pose((space.x0 + space.x1) / 2, space.floor_y, (space.z0 + space.z1) / 2),
                            [_r(space.x1 - space.x0), 0.0, _r(space.z1 - space.z0)])
        records.append({"id": f"floor-{space.id}", "kind": "floor", "space": space.id, "matrix": m, "dimensions": dims})
    for wall in b.walls:
        mid = (wall.a0 + wall.a1) / 2
        y = (wall.y0 + wall.y1) / 2
        matrix = _pose(mid, y, wall.line) if wall.axis == "x" else _pose(wall.line, y, mid, 90)
        m, dims = _measured(rng, sigma, matrix, [_r(wall.a1 - wall.a0), _r(wall.y1 - wall.y0), 0.0])
        records.append({"id": wall.id, "kind": "wall", "matrix": m, "dimensions": dims})
    for door in b.doors:
        y = door.floor_y + door.height / 2
        x, z = door.center_xz
        matrix = _pose(x, y, z) if door.axis == "x" else _pose(x, y, z, 90)
        m, dims = _measured(rng, sigma / 2, matrix, [door.width, _r(door.height), 0.0])
        records.append({"id": door.id, "kind": door.kind, "matrix": m, "dimensions": dims, "is_open": door.leaf != "closed"})
    return records


def _object_records(b: Building, rng: np.random.Generator, sigma: float) -> list[dict]:
    records = []
    for o in b.objects:
        m, dims = _measured(rng, sigma, _pose(*o["center"], math.degrees(o["yaw"])), list(o["dimensions"]))
        records.append({"id": o["id"], "category": o["category"], "space": o["space"], "matrix": m, "dimensions": dims})
    return records


def capture_json(b: Building, surfaces: list[dict], objects: list[dict], colors: list[str]) -> dict:
    return {
        "schema_version": 1, "id": b.scan_id, "map_id": f"{b.scan_id}-map", "floor_id": f"level-{b.floor_number}",
        "coordinates": {"units": "meters", "up_axis": "y", "handedness": "right"},
        "metadata": {"source": "synthetic_building", "generator": GENERATOR, "seed": b.seed,
                     "coordinate_space": "shared_arkit_session",
                     "roomplan_section_ids": [f"section-{s.id}" for s in b.spaces],
                     "section_count": len(b.spaces),
                     "raw_upload_omissions": ["depth_frames_exceed_upload_limit; full_selected_frames_preserved_locally"],
                     "assets": {"roomplan": "roomplan.json", "world_map": "worldmap.archive", "color_keyframes": colors}},
        "surfaces": [{"id": s["id"], "kind": s["kind"], "map_from_surface": _column_major(s["matrix"]),
                      "dimensions_m": s["dimensions"]} for s in surfaces],
        "objects": [{"id": o["id"], "category": o["category"], "confidence": "high",
                     "map_from_object": _column_major(o["matrix"]), "dimensions_m": o["dimensions"]} for o in objects],
        "meshes": [], "frames": [],
    }


def _nested(m: np.ndarray) -> list[list[float]]:
    return [[round(float(v), 6) for v in m[:, k]] for k in range(4)]


def roomplan_json(b: Building, surfaces: list[dict], objects: list[dict]) -> list[dict]:
    """CapturedRoom-like sections: one entry per space, shared walls/doors listed by both neighbours."""
    rooms = []
    for space in b.spaces:
        def near(record: dict) -> bool:
            x, z = record["matrix"][0, 3], record["matrix"][2, 3]
            half = np.asarray(record["dimensions"]) / 2
            span = half[0]
            if record["kind"] == "floor":
                return record.get("space") == space.id
            along_x = abs(record["matrix"][0, 0]) > 0.5
            xs, zs = ((x - span, x + span), (z, z)) if along_x else ((x, x), (z - span, z + span))
            return (space.x0 - 0.06 <= xs[1] and xs[0] <= space.x1 + 0.06 and space.z0 - 0.06 <= zs[1] and zs[0] <= space.z1 + 0.06
                    and (abs(x - space.x0) < 0.06 or abs(x - space.x1) < 0.06 or abs(z - space.z0) < 0.06 or abs(z - space.z1) < 0.06))

        def surface(record: dict) -> dict:
            category = {"door": {"door": {"isOpen": bool(record.get("is_open", True))}}}.get(record["kind"], {record["kind"]: {}})
            corners = []
            if record["kind"] == "floor":
                w, d = record["dimensions"][0] / 2, record["dimensions"][2] / 2
                corners = [[-w, 0.0, -d], [w, 0.0, -d], [w, 0.0, d], [-w, 0.0, d]]
            return {"identifier": record["id"], "category": category, "confidence": {"high": {}},
                    "dimensions": record["dimensions"], "transform": _nested(record["matrix"]),
                    "polygonCorners": corners, "completedEdges": [], "curve": None, "story": 0,
                    "parentIdentifier": None}

        mine = [r for r in surfaces if near(r)]
        rooms.append({
            "identifier": f"section-{space.id}", "story": 0, "version": 2,
            "sections": [{"label": space.section_label if space.kind == "room" else "unidentified",
                          "center": [_r(v) for v in space.center], "story": 0}],
            "floors": [surface(r) for r in mine if r["kind"] == "floor"],
            "walls": [surface(r) for r in mine if r["kind"] == "wall"],
            "doors": [surface(r) for r in mine if r["kind"] == "door"],
            "openings": [surface(r) for r in mine if r["kind"] == "opening"],
            "windows": [],
            "objects": [{"identifier": o["id"], "category": {o["category"]: {}}, "confidence": {"high": {}},
                         "dimensions": o["dimensions"], "transform": _nested(o["matrix"]),
                         "story": 0, "attributes": [], "parentIdentifier": None}
                        for o in objects if o["space"] == space.id],
        })
    return rooms


def _role(name: str) -> str:
    for suffix, role in ((".color.jpg", "rgb_keyframe"), (".depth-f32le", "raw_depth_float32"),
                         (".confidence-u8", "depth_confidence"), (".mesh-vertices", "mesh_vertices"),
                         (".mesh-faces", "mesh_indices"), (".mesh-normals", "mesh_normals"),
                         (".mesh-classification-u8", "mesh_classification")):
        if name.endswith(suffix):
            return role
    return {"capture.json": "portable_capture", "roomplan.json": "roomplan_original",
            "worldmap.archive": "arkit_world_map"}.get(name, "opaque_sidecar")


def _media(name: str) -> str:
    return "application/json" if name.endswith(".json") else "image/jpeg" if name.endswith(".jpg") else "application/octet-stream"


def build(seed: int = 0, max_observations: int = 32, rooms_per_side: tuple[int, int] | None = None,
          depth_noise: bool = True, roomplan_noise_m: float = 0.015) -> tuple[bytes, dict]:
    """Deterministic `.inviewscan.tar` bytes and its ground truth for `seed`.

    Depth carries LiDAR-like noise and RoomPlan surfaces/objects carry centimetre measurement error
    (`roomplan_noise_m`, σ); the ground truth is always the exact generated geometry."""
    b = layout(seed, rooms_per_side)
    sc = scene(b)
    views = walk(b, max_observations)
    rng = np.random.default_rng([seed, 7])
    files: dict[str, bytes] = {}
    observations = []
    for i, view in enumerate(views):
        depth, confidence = render_depth(sc, view.matrix, rng, depth_noise)
        files[f"{view.id}.depth-f32le"] = depth.tobytes()
        files[f"{view.id}.confidence-u8"] = confidence.tobytes()
        files[f"{view.id}.color.jpg"] = render_keyframe(sc, view.matrix, rng)
        timestamp = round(1.0 + 2.5 * i, 3)
        observations.append({
            "id": view.id, "timestamp_seconds": timestamp, "rgb_asset": f"{view.id}.color.jpg",
            "map_from_camera": _column_major(view.matrix),
            "image": {"width": IMAGE_W, "height": IMAGE_H, "fx": FOCAL, "fy": FOCAL, "cx": CX, "cy": CY},
            "raw_depth": {"raw_asset": f"{view.id}.depth-f32le", "confidence_asset": f"{view.id}.confidence-u8",
                          "smoothed_asset": None, "width": DEPTH_W, "height": DEPTH_H, "bytes_per_row": DEPTH_W * 4,
                          "pixel_format": 1717855600, "confidence_bytes_per_row": DEPTH_W,
                          "environment": _environment(b, view.matrix, timestamp, rng)},
        })
    anchors = []
    for anchor in mesh_anchors(sc, b):
        name = anchor["id"]
        files[f"{name}.mesh-vertices"] = anchor["vertices"].tobytes()
        files[f"{name}.mesh-faces"] = anchor["faces"].tobytes()
        files[f"{name}.mesh-normals"] = anchor["normals"].tobytes()
        files[f"{name}.mesh-classification-u8"] = anchor["classification"].tobytes()
        anchors.append({
            "id": name, "map_from_anchor": _column_major(anchor["matrix"]), "vertices_asset": f"{name}.mesh-vertices",
            "faces_asset": f"{name}.mesh-faces", "normals_asset": f"{name}.mesh-normals",
            "classification_asset": f"{name}.mesh-classification-u8", "vertex_offset": 0, "vertex_stride": 12,
            "vertex_format": 30, "vertex_count": len(anchor["vertices"]), "bytes_per_index": 4,
            "face_count": len(anchor["faces"]), "indices_per_face": 3, "normal_offset": 0, "normal_stride": 12,
            "normal_format": 30,
        })
    measurement = np.random.default_rng([seed, 11])
    surfaces = _surface_records(b, measurement, roomplan_noise_m)
    objects = _object_records(b, measurement, roomplan_noise_m)
    colors = [o["rgb_asset"] for o in observations]
    files["capture.json"] = json.dumps(capture_json(b, surfaces, objects, colors), sort_keys=True).encode()
    files["roomplan.json"] = json.dumps(roomplan_json(b, surfaces, objects), sort_keys=True).encode()
    files["worldmap.archive"] = b"\x00"
    capture = json.loads(files["capture.json"])
    manifest = {
        "schema_version": 1, "capture_id": b.scan_id, "map_id": capture["map_id"], "floor_id": capture["floor_id"],
        "coordinate_frame": {"units": "meters", "up_axis": "y", "handedness": "right", "name": "shared_arkit_session"},
        "assets": [{"path": name, "role": _role(name), "media_type": _media(name), "bytes": len(data)}
                   for name, data in sorted(files.items())],
        "observations": observations,
        "mesh_anchors": anchors,
    }
    files["package-manifest.json"] = json.dumps(manifest, sort_keys=True).encode()
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name in sorted(files):
            info = tarfile.TarInfo(f"{b.scan_id}/{name}")
            info.size, info.mtime, info.mode = len(files[name]), 0, 0o644
            tar.addfile(info, io.BytesIO(files[name]))
    return buffer.getvalue(), ground_truth(b, views)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out", help="output .inviewscan.tar path")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--truth", help="ground-truth JSON path (default: <out>.truth.json)")
    parser.add_argument("--max-observations", type=int, default=32)
    args = parser.parse_args(argv)
    archive, truth = build(args.seed, args.max_observations)
    with open(args.out, "wb") as output:
        output.write(archive)
    truth_path = args.truth or f"{args.out}.truth.json"
    with open(truth_path, "w") as output:
        json.dump(truth, output, indent=2)
    print(f"{truth['scan_id']}: {len(archive) / 1e6:.1f} MB, {len(truth['walk'])} observations -> {args.out}, {truth_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
