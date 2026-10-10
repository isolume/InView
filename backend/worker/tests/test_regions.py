"""Region segmentation: rooms, corridors and doorways from the floor map (U2)."""
import math

import cv2
import numpy as np
import pytest

from inview_worker import doors, floor_map, regions
from inview_worker.contracts import ProductName
from inview_worker.core import Product, ScanContext, runner
from inview_worker.geometry import Grid
from inview_worker.inputs import Box, ScanInputs, Surface
from inview_worker.pipeline import analyze
from inview_worker.regions import describe
from inview_worker.regions.seeds import persistent_markers
from inview_worker.synthetic import package
from inview_worker.stages.doors import DoorsStage
from inview_worker.stages.floor_map import FloorMapStage
from inview_worker.stages.regions import RegionsStage

RES = 0.05


def pose(x=0.0, y=0.0, z=0.0, yaw_deg=0.0) -> np.ndarray:
    c, s = math.cos(math.radians(yaw_deg)), math.sin(math.radians(yaw_deg))
    m = np.eye(4)
    m[:3, :3] = [[c, 0, s], [0, 1, 0], [-s, 0, c]]
    m[:3, 3] = [x, y, z]
    return m


def wall(name, x, z, length, along_x=True):
    return Surface(name, "wall", pose(x=x, y=1.4, z=z, yaw_deg=0 if along_x else 90), [length, 2.8, 0])


def building(furniture=True, kind="opening") -> ScanInputs:
    """Living room (6 × 5 m, z -2.5..2.5) and meeting room (6 × 5 m, z -13.5..-8.5) joined by a
    2.4 m × 6 m hallway (x 0.55..2.95) through two 1.1 m openings at x = 1.75."""
    surfaces = [
        Surface("living-floor", "floor", pose(), [6, 0, 5]),
        wall("living-back", 0, 2.5, 6), wall("living-front", 0, -2.5, 6),
        wall("living-left", -3, 0, 5, False), wall("living-right", 3, 0, 5, False),
        Surface("entry", kind, pose(x=1.75, y=1.07, z=-2.5), [1.1, 2.15, 0]),
        Surface("hall-floor", "floor", pose(x=1.75, z=-5.5), [2.4, 0, 6]),
        wall("hall-left", 0.55, -5.5, 6, False), wall("hall-right", 2.95, -5.5, 6, False),
        Surface("meeting-floor", "floor", pose(z=-11), [6, 0, 5]),
        wall("meeting-front", 0, -8.5, 6), wall("meeting-back", 0, -13.5, 6),
        wall("meeting-left", -3, -11, 5, False), wall("meeting-right", 3, -11, 5, False),
        Surface("meeting-entry", kind, pose(x=1.75, y=1.07, z=-8.5), [1.1, 2.15, 0]),
    ]
    objects = []
    if furniture:
        objects = [
            Box("sofa", "sofa", pose(x=-0.65, y=0.5, z=1.78), [2.9, 1.0, 1.0]),
            Box("table", "table", pose(x=-0.6, y=0.2, z=0.15), [1.45, 0.43, 0.85]),
            Box("console", "storage", pose(x=-2.7, y=0.4, z=-0.75, yaw_deg=90), [1.7, 0.82, 0.43]),
            Box("meeting-table", "table", pose(x=0.85, y=0.37, z=-11.6), [1.65, 0.74, 0.8]),
            Box("chair", "chair", pose(x=0.34, y=0.45, z=-10.82), [0.52, 0.9, 0.54]),
        ]
    return ScanInputs("building", surfaces, objects)


LIVING = [[-3, -2.5], [3, -2.5], [3, 2.5], [-3, 2.5]]
MEETING = [[-3, -13.5], [3, -13.5], [3, -8.5], [-3, -8.5]]
HALL = [[0.55, -8.5], [2.95, -8.5], [2.95, -2.5], [0.55, -2.5]]
ROOMPLAN = {"rooms": [{"id": "rp-living", "label": "living_room", "story": 0, "polygon_xz_m": LIVING, "floor_y_m": 0.0},
                      {"id": "rp-meeting", "label": "meeting_room", "story": 0, "polygon_xz_m": MEETING, "floor_y_m": 0.0},
                      {"id": "rp-hall", "label": None, "story": 0, "polygon_xz_m": HALL, "floor_y_m": 0.0}],
            "doors": [], "openings": [], "objects": [], "stories": []}


def segmented(inputs=None, use_doors=True, roomplan=None):
    inputs = inputs or building()
    fm = floor_map.build(inputs)
    return fm, regions.build(fm, doors.check(inputs, fm) if use_doors else None, roomplan)


def by_kind(region_map, kind):
    return [r for r in region_map.regions if r["kind"] == kind]


def at(region_map, x, z):
    region_id = region_map.region_at(x, z)
    return next(r for r in region_map.regions if r["id"] == region_id)


def test_two_rooms_and_a_hallway_with_doors():
    _, rm = segmented()
    rooms, corridors, doorways = by_kind(rm, "room"), by_kind(rm, "corridor"), by_kind(rm, "doorway")
    assert (len(rooms), len(corridors), len(doorways)) == (2, 1, 2)
    assert not by_kind(rm, "open_area")
    living, meeting, hall = at(rm, 0, 0), at(rm, 0, -11), at(rm, 1.75, -5.5)
    assert living["kind"] == meeting["kind"] == "room" and hall["kind"] == "corridor"
    # Free floor inside the walls: 5.88 × 4.88 m rooms; furniture islands belong to the room.
    assert living["area_m2"] == pytest.approx(28.7, rel=0.06)
    assert meeting["area_m2"] == pytest.approx(28.7, rel=0.06)
    assert hall["area_m2"] == pytest.approx(2.28 * 5.88, rel=0.08)
    assert hall["metrics"]["clear_width_m"] == pytest.approx(2.28, abs=0.15)
    # Adjacency only through the doorways: room - doorway - hallway - doorway - room.
    entry, meeting_entry = (next(d for d in doorways if d["door_id"] == i) for i in ("entry", "meeting-entry"))
    assert entry["connects"] == sorted([living["id"], hall["id"]])
    assert meeting_entry["connects"] == sorted([meeting["id"], hall["id"]])
    assert living["adjacent"] == [entry["id"]] and meeting["adjacent"] == [meeting_entry["id"]]
    assert hall["adjacent"] == sorted([entry["id"], meeting_entry["id"]])
    assert entry["clear_width_m"] == pytest.approx(1.1, abs=0.1) and entry["evidence"] == "doors"
    assert entry["centroid_xz_m"] == pytest.approx([1.75, -2.5], abs=0.01)


def test_constrictions_become_doorways_without_door_evidence():
    _, rm = segmented(use_doors=False)
    assert len(by_kind(rm, "room")) == 2 and len(by_kind(rm, "corridor")) == 1
    doorways = sorted(by_kind(rm, "doorway"), key=lambda d: d["centroid_xz_m"][1])
    assert len(doorways) == 2 and all(d["evidence"] == "constriction" for d in doorways)
    assert doorways[0]["centroid_xz_m"] == pytest.approx([1.75, -8.5], abs=0.15)
    assert doorways[1]["centroid_xz_m"] == pytest.approx([1.75, -2.5], abs=0.15)
    assert all(d["clear_width_m"] == pytest.approx(1.1, abs=0.2) for d in doorways)
    hall = at(rm, 1.75, -5.5)
    assert hall["kind"] == "corridor" and hall["adjacent"] == sorted(d["id"] for d in doorways)


def test_a_door_and_an_opening_on_one_span_keep_the_first():
    inputs = building()
    fm = floor_map.build(inputs)
    found = doors.check(inputs, fm)
    duplicate = dict(found[0], id="zz-duplicate")
    rm = regions.build(fm, [*found, duplicate])
    assert sorted(r["door_id"] for r in by_kind(rm, "doorway")) == ["entry", "meeting-entry"]
    assert len(by_kind(rm, "room")) == 2 and len(by_kind(rm, "corridor")) == 1


def test_labels_come_from_roomplan_rooms():
    _, rm = segmented(roomplan=ROOMPLAN)
    living, meeting, hall = at(rm, 0, 0), at(rm, 0, -11), at(rm, 1.75, -5.5)
    assert (living["label"], living["roomplan_room_id"]) == ("living_room", "rp-living")
    assert (meeting["label"], meeting["roomplan_room_id"]) == ("meeting_room", "rp-meeting")
    assert hall["label"] is None and hall["roomplan_room_id"] == "rp-hall"
    assert living["roomplan_overlap"] > 0.9 and living["story"] == 0


def test_furniture_does_not_split_rooms_and_output_is_deterministic():
    _, bare = segmented(building(furniture=False))
    _, furnished = segmented(building(furniture=True))
    assert [r["kind"] for r in bare.regions] == [r["kind"] for r in furnished.regions]
    assert segmented()[1].regions == furnished.regions
    assert [r["id"] for r in furnished.regions] == ["room-1", "room-2", "corridor-1",
                                                     "doorway-entry", "doorway-meeting-entry"]


def test_label_raster_is_aligned_with_the_floor_grid():
    fm, rm = segmented()
    assert rm.labels.shape == fm.walkable.shape and rm.grid == fm.grid
    assert set(np.unique(rm.labels)) - {0} == set(rm.ids)
    # Every walkable cell inside the building belongs to a region; walls never do.
    inside = fm.walkable > 0
    assert (rm.labels[inside] > 0).mean() > 0.97
    for x, z in ((0.55, -5.5), (2.95, -4.0), (0.0, -2.5), (-3.0, 0.0)):   # Wall centrelines.
        assert rm.region_at(x, z) is None
    assert at(rm, -0.6, 0.15)["id"] == at(rm, 0, 0)["id"]                 # The table's footprint.
    hall = rm.mask(at(rm, 1.75, -5.5)["id"])
    assert hall.sum() * fm.grid.resolution ** 2 == pytest.approx(at(rm, 1.75, -5.5)["area_m2"], abs=0.01)
    assert rm.region_at(100, 100) is None


def test_polygons_centroids_and_corridor_axis():
    _, rm = segmented()
    for region in rm.regions:
        poly = np.asarray(region["polygon_xz_m"], np.float32)
        assert len(poly) >= 4
        assert cv2.pointPolygonTest(poly, tuple(map(float, region["anchor_xz_m"])), False) >= 0
    living = at(rm, 0, 0)
    assert abs(cv2.contourArea(np.asarray(living["polygon_xz_m"], np.float32)) - living["area_m2"]) < 1.5
    axis = np.asarray(at(rm, 1.75, -5.5)["axis_xz_m"])
    assert abs(axis[0, 0] - axis[1, 0]) < 0.2 and abs(axis[0, 1] - axis[1, 1]) > 5.0


def test_open_plan_rooms_are_split_by_roomplan_sections():
    """A 10 × 5 m floor with no wall between two RoomPlan rooms."""
    surfaces = [Surface("floor", "floor", pose(), [10, 0, 5]),
                wall("n", 0, -2.5, 10), wall("s", 0, 2.5, 10), wall("w", -5, 0, 5, False), wall("e", 5, 0, 5, False)]
    inputs = ScanInputs("open-plan", surfaces)
    _, alone = segmented(inputs)
    assert len(alone.regions) == 1 and alone.regions[0]["kind"] in ("room", "open_area")
    sections = {"rooms": [{"id": "kitchen", "label": "kitchen", "polygon_xz_m": [[-5, -2.5], [0, -2.5], [0, 2.5], [-5, 2.5]]},
                          {"id": "dining", "label": "dining", "polygon_xz_m": [[0, -2.5], [5, -2.5], [5, 2.5], [0, 2.5]]}]}
    _, split = segmented(inputs, roomplan=sections)
    assert sorted(r["label"] for r in split.regions) == ["dining", "kitchen"]
    kitchen = next(r for r in split.regions if r["label"] == "kitchen")
    assert kitchen["centroid_xz_m"][0] < -1.5 and kitchen["adjacent"]


def test_unwalled_walked_space_is_an_open_area():
    xs = np.linspace(-6, 6, 60)
    track = np.array([[x, 1.4, z] for z in np.linspace(-6, 6, 25) for x in xs])
    _, rm = segmented(ScanInputs("plaza", camera_positions=track), use_doors=False)
    assert [r["kind"] for r in rm.regions] == ["open_area"]
    assert rm.regions[0]["metrics"]["enclosure"] < 0.5


def disk_mask(shape, parts):
    mask = np.zeros(shape, np.uint8)
    for x0, y0, x1, y1 in parts:
        mask[y0:y1, x0:x1] = 255
    return mask


@pytest.mark.parametrize("parts,expected", [
    # Two 4 m squares joined by a 0.9 m neck: two spaces.
    ([(10, 10, 90, 90), (110, 10, 190, 90), (90, 41, 110, 59)], 2),
    # One 4 m square with a 1 m notch bitten out of its side: one space.
    ([(10, 10, 90, 90)], 1),
    # A 10 m hall and a 2 m corridor behind a 1 m door: both survive (scale-free markers).
    ([(10, 10, 210, 210), (230, 90, 390, 130), (210, 100, 230, 120)], 2),
])
def test_persistent_markers(parts, expected):
    mask = disk_mask((230, 400), parts)
    if expected == 1:
        mask[10:30, 40:60] = 0
    dt = cv2.distanceTransform(mask, cv2.DIST_L2, 5) * RES
    markers = persistent_markers(dt, RES, 0.25, 0.3, 0.75, 4)
    assert markers.max() == expected


def test_segment_on_raw_rasters_without_floor_map():
    grid = Grid(0.0, 0.0, RES, 400, 230)
    walkable = disk_mask((230, 400), [(10, 10, 210, 210), (230, 90, 390, 130), (210, 100, 230, 120)])
    seg = regions.segment(walkable, grid)
    kinds = {}
    for label in np.unique(seg.labels[seg.labels > 0]):
        kinds.setdefault("doorway" if label in seg.doorways else "space", []).append(label)
    assert len(kinds["space"]) == 2 and len(kinds["doorway"]) == 1


def test_stage_publishes_regions_and_uses_upstream_products():
    inputs = building()
    ctx = ScanContext("building", inputs, products={ProductName.ROOMPLAN: Product(ROOMPLAN)})
    result = runner.run(ctx, [FloorMapStage(), DoorsStage(), RegionsStage()])
    assert result["stages"]["regions"]["status"] == "ok"
    assert result["summary"]["regions"] == {"room": 2, "corridor": 1, "open_area": 0, "doorway": 2,
                                            "links": 4, "labelled": 2}
    assert {r["label"] for r in result["regions"] if r["kind"] == "room"} == {"living_room", "meeting_room"}
    data = ctx.data(ProductName.REGIONS)
    assert isinstance(data, regions.RegionMap) and data.region_at(0, 0) == at(data, 0, 0)["id"]
    for region in result["regions"]:
        assert {"id", "kind", "polygon_xz_m", "centroid_xz_m", "area_m2", "label", "adjacent"} <= set(region)


@pytest.mark.parametrize("area,width,axis,elongation,enclosure,expected", [
    (28.0, 4.5, 2.3, 1.2, 1.0, "room"),
    (13.0, 2.2, 4.7, 2.6, 1.0, "corridor"),
    (240.0, 2.0, 115.0, 55.0, 1.0, "corridor"),      # Long corridors are never "open" by area.
    (400.0, 18.0, 4.0, 1.1, 1.0, "open_area"),       # A large hall.
    (20.0, 4.0, 2.0, 1.2, 0.2, "open_area"),         # Not bounded by walls.
])
def test_classification(area, width, axis, elongation, enclosure, expected):
    shape = describe.Shape(area, width, width, axis, elongation, enclosure, ((0, 0), (1, 1), 0))
    assert describe.classify(shape, regions.Params()) == expected


def test_synthetic_iphone_package_has_one_room_and_its_door(synthetic_ctx):
    result = analyze(synthetic_ctx)
    assert result["stages"]["regions"]["status"] == "ok"
    rooms = [r for r in result["regions"] if r["kind"] == "room"]
    doorway = next(r for r in result["regions"] if r["kind"] == "doorway")
    assert len(rooms) == 1 and rooms[0]["area_m2"] == pytest.approx(package.TRUTH["room_area_m2"], rel=0.12)
    assert doorway["door_id"] == package.TRUTH["door"]["id"] and doorway["connects"] == [rooms[0]["id"]]


def test_stage_is_skipped_without_a_floor_map():
    result = runner.run(ScanContext("empty", ScanInputs("empty")), [FloorMapStage(), RegionsStage()])
    assert result["stages"]["regions"] == {"status": "skipped", "missing": ["floor_map"]}
