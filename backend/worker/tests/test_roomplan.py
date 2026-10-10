"""RoomPlan semantics against hand-built `[CapturedRoom]` exports in Swift's Codable layout.

The main fixture is an iOS 18-style two-story walk scanned in three sections: an L-shaped kitchen and
a living room on story 0 (sharing a door that the second section saw open), and a bedroom on story 1.
Floors use RoomPlan's convention of a local X/Y plane rotated to face up, with `polygonCorners` in
surface-local coordinates, so world polygons only come out right if the transform is applied.
"""
import json

import numpy as np
import pytest

from inview_worker import roomplan
from inview_worker.contracts import ProductName
from inview_worker.core import MemorySource, ScanContext, runner
from inview_worker.inputs import ScanInputs
from inview_worker.stages.roomplan import RoomplanStage

UP = [[1, 0, 0], [0, 0, 1], [0, -1, 0]]  # local X/Y plane -> world X/Z, local +Z -> world +Y


def columns(rotation, x=0.0, y=0.0, z=0.0):
    """simd_float4x4 as Swift's JSONEncoder writes it: four column vectors."""
    m = np.eye(4)
    m[:3, :3], m[:3, 3] = rotation, [x, y, z]
    return m.T.tolist()


def yaw(degrees):
    c, s = np.cos(np.radians(degrees)), np.sin(np.radians(degrees))
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def floor(ident, world_xz, y, story, center_xz=(0.0, 0.0)):
    cx, cz = center_xz
    local = [[x - cx, -(z - cz), 0.0] for x, z in world_xz]  # inverse of UP about the floor center
    span = np.ptp(np.asarray(world_xz), axis=0)
    return {"identifier": ident, "category": {"floor": {}}, "confidence": {"high": {}},
            "dimensions": [float(span[0]), float(span[1]), 0.0], "transform": columns(UP, cx, y, cz),
            "polygonCorners": local, "completedEdges": [], "story": story, "curve": None,
            "parentIdentifier": None}


def surface(ident, category, x, y, z, heading, width, height, story=0, parent=None, **extra):
    return {"identifier": ident, "category": category, "confidence": {"medium": {}},
            "dimensions": [width, height, 0.0], "transform": columns(yaw(heading), x, y, z),
            "polygonCorners": [], "completedEdges": [{"top": {}}, {"bottom": {}}], "story": story,
            "parentIdentifier": parent, **extra}


def obj(ident, category, x, y, z, dims, attributes=(), story=0, heading=0.0):
    return {"identifier": ident, "category": {category: {}}, "confidence": {"high": {}},
            "dimensions": dims, "transform": columns(yaw(heading), x, y, z),
            "attributes": list(attributes), "story": story, "parentIdentifier": None}


KITCHEN_FLOOR = "A0000000-0000-0000-0000-000000000001"
LIVING_FLOOR = "B0000000-0000-0000-0000-000000000001"
BED_FLOOR = "C0000000-0000-0000-0000-000000000001"
DOOR = "D0000000-0000-0000-0000-000000000001"
SHARED_WALL = "E0000000-0000-0000-0000-000000000001"


def walk() -> list[dict]:
    kitchen = {
        "identifier": "A0000000-0000-0000-0000-00000000000A", "story": 0, "version": 2,
        "floors": [floor(KITCHEN_FLOOR, [(-2, -1.5), (2, -1.5), (2, 1.5), (0, 1.5), (0, 0.5), (-2, 0.5)], 0.0, 0)],
        "walls": [surface(SHARED_WALL, {"wall": {}}, 2.0, 1.25, 0.0, 90, 3.0, 2.5),
                  surface("A0000000-0000-0000-0000-0000000000W1", {"wall": {}}, 0.0, 1.25, -1.5, 0, 4.0, 2.5)],
        "doors": [surface(DOOR, {"door": {"isOpen": False}}, 2.0, 1.0, 0.0, 90, 0.9, 2.0, parent=SHARED_WALL)],
        "windows": [surface("A0000000-0000-0000-0000-0000000000F1", {"window": {}}, -1.0, 1.5, -1.5, 0, 1.2, 1.0)],
        "openings": [],
        "objects": [obj("A0000000-0000-0000-0000-0000000000B1", "refrigerator", -1.5, 0.9, -1.1, [0.8, 1.8, 0.7]),
                    obj("A0000000-0000-0000-0000-0000000000B2", "chair", 1.0, 0.45, 0.0, [0.5, 0.9, 0.5],
                        attributes=[{"ChairType": {"dining": {}}}, "ChairArmType.missing"])],
        "sections": [{"label": {"kitchen": {}}, "center": [0.5, 0.0, -0.5], "story": 0}],
    }
    living = {
        "identifier": "B0000000-0000-0000-0000-00000000000A", "story": 0, "version": 2,
        "floors": [floor(LIVING_FLOOR, [(2, -1.5), (7, -1.5), (7, 2.5), (2, 2.5)], 0.0, 0, center_xz=(4.5, 0.5))],
        "walls": [surface(SHARED_WALL, {"wall": {}}, 2.0, 1.25, 0.0, 90, 3.0, 2.5)],
        "doors": [surface(DOOR, {"door": {"isOpen": True}}, 2.0, 1.0, 0.0, 90, 0.9, 2.0, parent=SHARED_WALL)],
        "windows": [],
        "openings": [surface("B0000000-0000-0000-0000-0000000000O1", {"opening": {}}, 7.0, 1.1, 1.0, 90, 1.5, 2.2)],
        "objects": [obj("B0000000-0000-0000-0000-0000000000B1", "sofa", 5.0, 0.4, 2.0, [2.0, 0.8, 0.9], heading=180)],
        "sections": [{"label": {"livingRoom": {}}, "center": [4.5, 0.0, 0.5], "story": 0},
                     {"label": {"unidentified": {}}, "center": [6.5, 0.0, 2.2], "story": 0}],
    }
    bedroom = {
        "identifier": "C0000000-0000-0000-0000-00000000000A", "story": 1, "version": 2,
        "floors": [floor(BED_FLOOR, [(-2, -1.5), (2, -1.5), (2, 1.5), (-2, 1.5)], 3.0, 1)],
        "walls": [], "doors": [], "windows": [], "openings": [],
        "objects": [obj("C0000000-0000-0000-0000-0000000000B1", "bed", 0.0, 3.3, 0.0, [1.6, 0.6, 2.0], story=1)],
        "sections": [{"label": {"bedroom": {}}, "center": [0.0, 3.0, 0.0], "story": 1}],
    }
    return [kitchen, living, bedroom]


def by_id(items):
    return {item["id"]: item for item in items}


@pytest.fixture
def product():
    return roomplan.build(roomplan.load(json.dumps(walk()).encode()))


def test_rooms_follow_floor_polygons_and_section_labels(product):
    rooms = by_id(product["rooms"])
    assert set(rooms) == {KITCHEN_FLOOR, LIVING_FLOOR, BED_FLOOR}
    kitchen, living, bed = rooms[KITCHEN_FLOOR], rooms[LIVING_FLOOR], rooms[BED_FLOOR]
    assert kitchen["label"] == "kitchen" and kitchen["area_m2"] == pytest.approx(10.0)
    assert kitchen["method"] == "polygon_corners" and len(kitchen["polygon_xz_m"]) == 6
    assert living["label"] == "living_room" and living["section_labels"] == ["living_room", "unidentified"]
    assert living["area_m2"] == pytest.approx(20.0) and living["centroid_xz_m"] == pytest.approx([4.5, 0.5])
    xs, zs = zip(*living["polygon_xz_m"])
    assert (min(xs), max(xs), min(zs), max(zs)) == pytest.approx((2, 7, -1.5, 2.5))
    assert bed["label"] == "bedroom" and bed["story"] == 1 and bed["floor_y_m"] == pytest.approx(3.0)
    assert kitchen["story"] == 0 and kitchen["section_id"].endswith("00A")


def test_polygons_are_counter_clockwise_in_the_map_plane(product):
    for room in product["rooms"]:
        p = np.asarray(room["polygon_xz_m"])
        area = 0.5 * (np.dot(p[:, 0], np.roll(p[:, 1], -1)) - np.dot(p[:, 1], np.roll(p[:, 0], -1)))
        assert area > 0


def test_door_takes_the_latest_state_and_connects_both_rooms(product):
    doors = by_id(product["doors"])
    assert list(doors) == [DOOR]
    door = doors[DOOR]
    assert door["is_open"] is True and door["width_m"] == pytest.approx(0.9) and door["height_m"] == pytest.approx(2.0)
    assert door["connects"] == sorted([KITCHEN_FLOOR, LIVING_FLOOR]) and not door["unmapped_side"]
    assert door["wall_id"] == SHARED_WALL and door["center_m"] == pytest.approx([2.0, 1.0, 0.0])
    assert np.allclose(sorted(door["span_xz_m"]), [[2.0, -0.45], [2.0, 0.45]])


def test_openings_windows_walls_and_objects(product):
    (opening,) = product["openings"]
    assert opening["connects"] == [LIVING_FLOOR] and opening["unmapped_side"] is True
    (window,) = product["windows"]
    assert window["sill_height_m"] == pytest.approx(1.0) and window["width_m"] == pytest.approx(1.2)
    walls = by_id(product["walls"])
    assert len(walls) == 2 and walls[SHARED_WALL]["completed_edges"] == ["bottom", "top"]
    objects = by_id(product["objects"])
    chair = objects["A0000000-0000-0000-0000-0000000000B2"]
    assert chair["attributes"] == {"chair_arm_type": "missing", "chair_type": "dining"}
    assert chair["room_id"] == KITCHEN_FLOOR and chair["bottom_y_m"] == pytest.approx(0.0)
    sofa = objects["B0000000-0000-0000-0000-0000000000B1"]
    assert sofa["room_id"] == LIVING_FLOOR and abs(sofa["yaw_deg"]) == pytest.approx(180.0)
    assert objects["C0000000-0000-0000-0000-0000000000B1"]["room_id"] == BED_FLOOR


def test_stories_and_sections(product):
    stories = by_id({"id": s["story"], **s} for s in product["stories"])
    assert stories[0]["room_ids"] == sorted([KITCHEN_FLOOR, LIVING_FLOOR]) and not stories[0]["inferred"]
    assert stories[1]["floor_y_m"] == pytest.approx(3.0)
    assert [s["room_id"] for s in product["sections"]] == [KITCHEN_FLOOR, LIVING_FLOOR, LIVING_FLOOR, BED_FLOOR]
    assert product["versions"] == [2] and product["source"] == "roomplan_native"


def test_output_is_deterministic_and_json_serialisable(product):
    again = roomplan.build(roomplan.load(walk()))
    assert json.dumps(product, sort_keys=True) == json.dumps(again, sort_keys=True)


def test_ios16_rooms_without_floors_use_the_wall_hull():
    walls = [surface(f"W{i}", "wall", x, 1.25, z, h, w, 2.5)
             for i, (x, z, h, w) in enumerate([(0, -2, 0, 4), (0, 2, 0, 4), (-2, 0, 90, 4), (2, 0, 90, 4)])]
    for wall in walls:  # iOS 16: no story, polygon corners, edges or parent
        for key in ("story", "polygonCorners", "completedEdges", "parentIdentifier"):
            wall.pop(key)
    room = {"identifier": "legacy", "walls": walls, "doors": [], "windows": [], "openings": [], "objects": []}
    product = roomplan.build(roomplan.load([room]))
    (only,) = product["rooms"]
    assert only["method"] == "wall_hull" and only["area_m2"] == pytest.approx(16.0)
    assert only["label"] is None and only["floor_y_m"] == pytest.approx(0.0)
    assert product["stories"] == [{"story": 0, "floor_y_m": 0.0, "room_ids": ["LEGACY"], "area_m2": 16.0,
                                   "inferred": True}]


def test_structure_shape_and_duplicate_floors_collapse():
    first, second = walk()[:2]
    # The living room section re-reports the kitchen under a new identifier (slightly shifted).
    again = floor("F0000000-0000-0000-0000-000000000001",
                  [(-2, -1.45), (2, -1.45), (2, 1.5), (0, 1.5), (0, 0.5), (-2, 0.5)], 0.0, 0)
    second = {**second, "floors": second["floors"] + [again]}
    structure = {"rooms": [first, second], "walls": [], "doors": [], "floors": [], "objects": [], "sections": []}
    rooms = by_id(roomplan.build(roomplan.load(structure))["rooms"])
    assert set(rooms) == {LIVING_FLOOR, "F0000000-0000-0000-0000-000000000001"}
    assert rooms["F0000000-0000-0000-0000-000000000001"]["label"] == "kitchen"


def test_upstairs_window_outside_polygons_measures_from_its_own_story():
    rooms = walk()
    rooms[2]["windows"] = [surface("C0000000-0000-0000-0000-0000000000F1", {"window": {}}, 0.0, 4.0, -2.5, 0,
                                   1.0, 1.0, story=1)]
    windows = roomplan.build(roomplan.load(rooms))["windows"]
    sills = {w["id"]: w["sill_height_m"] for w in windows}
    assert sills["C0000000-0000-0000-0000-0000000000F1"] == pytest.approx(0.5)


def test_storyless_duplicate_of_a_storied_room_collapses():
    first = walk()[0]
    legacy = {"identifier": "legacy", "walls": [  # iOS 16 re-scan of the kitchen's outer box, no story
        {k: v for k, v in surface(f"W{i}", "wall", x, 1.25, z, h, w, 2.5).items() if k != "story"}
        for i, (x, z, h, w) in enumerate([(0, -1.5, 0, 4), (0, 1.5, 0, 4), (-2, 0, 90, 3), (2, 0, 90, 3)])]}
    first = {**first, "floors": [floor(KITCHEN_FLOOR, [(-2, -1.5), (2, -1.5), (2, 1.5), (-2, 1.5)], 0.0, 0)]}
    rooms = roomplan.build(roomplan.load([first, legacy]))["rooms"]
    assert [r["id"] for r in rooms] == ["LEGACY"] and rooms[0]["story"] == 0


def test_malformed_components_are_skipped_not_fatal():
    room = walk()[0]
    room["walls"].append({"identifier": "broken", "transform": [1, 2, 3]})
    room["objects"].append("nonsense")
    room["unknownFutureKey"] = {"anything": True}
    capture = roomplan.load([room, 42, None])
    assert capture.skipped == 2 and len(roomplan.build(capture)["rooms"]) == 1


def ctx_with(assets, surfaces=()):
    inputs = ScanInputs("scan")
    inputs.surfaces = list(surfaces)
    return ScanContext("scan", inputs, MemorySource(None, assets))


def test_stage_prefers_roomplan_json_then_capture_original():
    result = runner.run(ctx_with({"roomplan.json": json.dumps(walk()).encode()}), [RoomplanStage()])
    assert result["stages"]["roomplan"]["status"] == "ok" and len(result[ProductName.ROOMPLAN]["rooms"]) == 3
    assert result["summary"]["roomplan"]["asset"] == "roomplan.json"
    assert result["summary"]["roomplan"]["labelled_rooms"] == 3

    capture = {"id": "scan", "surfaces": [], "roomplan_original": walk()[:1]}
    assets = {"roomplan.json": b"[]", "capture.json": json.dumps(capture).encode()}
    result = runner.run(ctx_with(assets), [RoomplanStage()])
    assert result["summary"]["roomplan"]["asset"] == "capture.json"
    assert [r["label"] for r in result[ProductName.ROOMPLAN]["rooms"]] == ["kitchen"]


def test_stage_falls_back_to_portable_surfaces(synthetic_ctx):
    result = runner.run(synthetic_ctx, [RoomplanStage()])
    product = result[ProductName.ROOMPLAN]
    assert product["source"] == "portable_capture"
    (room,) = product["rooms"]
    assert room["method"] == "floor_rectangle" and room["area_m2"] == pytest.approx(16.0) and room["label"] is None
    (door,) = product["doors"]
    assert door["is_open"] is None and door["width_m"] == pytest.approx(0.76) and door["connects"] == ["floor"]
    assert any("portable capture" in n for n in result["notices"])


def test_stage_without_any_evidence_reports_instead_of_failing():
    result = runner.run(ctx_with({"roomplan.json": b"not json"}), [RoomplanStage()])
    assert result["stages"]["roomplan"]["status"] == "ok" and ProductName.ROOMPLAN not in result
    assert any("could not be decoded" in n for n in result["notices"])
