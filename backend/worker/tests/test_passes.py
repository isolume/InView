import base64
import math

import cv2
import numpy as np
import pytest

from inview_worker import doors, floor_map, signs
from inview_worker.geometry import jpeg_to_sensor_uv
from inview_worker.inputs import Box, Frame, ScanInputs, Surface
from inview_worker.pipeline import analyze


def pose(x=0.0, y=0.0, z=0.0, yaw_deg=0.0) -> np.ndarray:
    c, s = math.cos(math.radians(yaw_deg)), math.sin(math.radians(yaw_deg))
    m = np.eye(4)
    m[:3, :3] = [[c, 0, s], [0, 1, 0], [-s, 0, c]]
    m[:3, 3] = [x, y, z]
    return m


def room(door_width=0.9) -> ScanInputs:
    """4 m × 4 m room, floor at y = 0, a doorway in the north wall, a table, and two cabinets
    0.6 m apart forming a gap narrower than an accessible route."""
    surfaces = [
        Surface("floor", "floor", pose(), [4, 0, 4]),
        Surface("north", "wall", pose(z=-2, y=1.25), [4, 2.5, 0]),
        Surface("south", "wall", pose(z=2, y=1.25), [4, 2.5, 0]),
        Surface("east", "wall", pose(x=2, y=1.25, yaw_deg=90), [4, 2.5, 0]),
        Surface("west", "wall", pose(x=-2, y=1.25, yaw_deg=90), [4, 2.5, 0]),
        Surface("door", "door", pose(z=-2, y=1.05), [door_width, 2.1, 0]),
    ]
    objects = [
        Box("table", "table", pose(x=-0.8, y=0.37, z=0.6), [1.2, 0.74, 0.8]),
        Box("left", "storage", pose(x=0.95, y=0.45, z=1.2), [0.5, 0.9, 0.6]),
        Box("right", "storage", pose(x=1.75, y=0.45, z=1.2), [0.5, 0.9, 0.6]),  # 0.3 m gap to "left"
        Box("rug", "rug", pose(y=0.008), [2, 0.016, 2]),
    ]
    track = np.array([[x, 1.4, 0.0] for x in np.linspace(-1.5, 1.5, 12)])
    return ScanInputs("room", surfaces, objects, camera_positions=track)


def test_floor_map_uses_roomplan_structure_and_finds_obstacles():
    inputs = room()
    fm = floor_map.build(inputs)
    assert fm is not None
    assert fm.floor_height_source == "roomplan_floor"
    assert abs(fm.floor_height) < 1e-6
    # The floor polygon covers the room (16 m²), minus nothing: walls sit on its border.
    assert fm.result["outlines"][0]["area_m2"] == pytest.approx(16, rel=0.08)
    # Table, two cabinets and the walls are obstacles; the 1.6 cm rug is not.
    table = fm.grid.int_cells(np.array([[-0.8, 0.6]]))[0]
    rug_only = fm.grid.int_cells(np.array([[0.0, -0.6]]))[0]
    assert fm.obstacle[table[1], table[0]] and not fm.obstacle[rug_only[1], rug_only[0]]
    assert fm.walkable[rug_only[1], rug_only[0]]
    assert fm.result["walked_length_m"] == pytest.approx(3.0, abs=0.01)


def test_narrow_gap_between_cabinets_is_flagged():
    fm = floor_map.build(room())
    # Cabinet faces at x = 1.2 and x = 1.5: a 0.3 m gap. Another gap (0.5 m) to the east wall.
    widths = [p["min_clear_width_m"] for p in fm.result["narrow_passages"]]
    assert widths, "expected narrow passages"
    assert min(widths) == pytest.approx(0.3, abs=0.1)
    assert all(w < floor_map.ADA_PASSAGE_M for w in widths)


def test_doorway_is_carved_from_wall_and_measured():
    wide = room(door_width=0.9)
    fm = floor_map.build(wide)
    result = doors.check(wide, fm)[0]
    assert result["method"] == "obstacle_raster_span"
    assert result["measured_clear_width_m"] == pytest.approx(0.9, abs=0.12)
    assert result["meets_clear_width"] and result["meets_headroom"]

    narrow = room(door_width=0.7)
    result = doors.check(narrow, floor_map.build(narrow))[0]
    assert not result["meets_clear_width"]
    assert any("clear_width_below" in issue for issue in result["issues"])


def test_floor_height_from_mesh_ignores_a_stray_low_triangle():
    xs, zs = np.meshgrid(np.arange(-2, 2.01, 0.25), np.arange(-2, 2.01, 0.25))
    vertices = np.column_stack((xs.ravel(), np.full(xs.size, -1.2), zs.ravel()))
    n = xs.shape[1]
    triangles = []
    for r in range(xs.shape[0] - 1):
        for c in range(n - 1):
            i = r * n + c
            triangles += [[i, i + 1, i + n], [i + 1, i + n + 1, i + n]]
    stray = len(vertices)
    vertices = np.vstack((vertices, [[0, -3, 0], [0.1, -3, 0], [0, -3, 0.1]]))
    triangles.append([stray, stray + 1, stray + 2])
    inputs = ScanInputs("mesh", mesh_vertices=vertices, mesh_triangles=np.array(triangles))
    height, source = floor_map.estimate_floor_height(inputs)
    assert source == "mesh_up_facing_layer"
    assert height == pytest.approx(-1.2, abs=0.03)


def exit_sign_image() -> np.ndarray:
    image = np.full((640, 480, 3), 150, np.uint8)
    cv2.rectangle(image, (140, 200), (340, 290), (40, 160, 30), -1)  # Green plate (BGR).
    cv2.putText(image, "EXIT", (165, 265), cv2.FONT_HERSHEY_SIMPLEX, 1.6, (255, 255, 255), 4)
    cv2.rectangle(image, (60, 450), (420, 520), (245, 245, 245), -1)
    cv2.putText(image, "ROOM 214", (80, 500), cv2.FONT_HERSHEY_SIMPLEX, 1.2, (20, 20, 20), 3)
    return image


def test_sign_plate_and_text_line_are_detected():
    detections = signs.detect(exit_sign_image())
    plate = [d for d in detections if d.kind == "exit_sign_candidate"]
    assert plate and plate[0].color == "green"
    x, y, w, h = plate[0].bbox
    assert abs(x - 140) < 10 and abs(y - 200) < 10 and abs(w - 200) < 15
    texts = [d for d in detections if d.kind == "text_region"]
    assert any(d.bbox[1] > 440 and d.bbox[3] < 80 for d in texts)


def test_jpeg_mapping_inverts_the_studio_projection():
    width, height = 480, 640
    for u, v in [(0.1, 0.2), (0.5, 0.5), (0.9, 0.7)]:
        px, py = (1 - v) * width, u * height  # studio.js: upright JPEG rotated right from sensor
        assert jpeg_to_sensor_uv(px, py, width, height) == pytest.approx((u, v))


def test_detection_is_placed_with_depth_samples_under_its_box():
    # Each sample's world position encodes its own (u, v) so the median reveals the selection.
    u, v = np.meshgrid(np.linspace(0, 1, 97), np.linspace(0, 1, 97))
    points = np.column_stack((u.ravel(), v.ravel(), np.full(u.size, -2.0), u.ravel(), v.ravel()))
    frame = Frame("f", points, "f.color.jpg")
    detection = signs.Detection("exit_sign_candidate", (140, 200, 200, 90), 1.0)
    position = signs.locate(detection, frame, 480, 640)
    expected_u, expected_v = jpeg_to_sensor_uv(240, 245, 480, 640)
    assert position[0] == pytest.approx(expected_u, abs=0.02)
    assert position[1] == pytest.approx(expected_v, abs=0.02)


def test_analysis_document_is_complete_and_publishable():
    inputs = room()
    u, v = np.meshgrid(np.linspace(0, 1, 40), np.linspace(0, 1, 40))
    inputs.frames = [Frame("f", np.column_stack((u.ravel(), np.full(u.size, 1.5), v.ravel(), u.ravel(), v.ravel())), "f.color.jpg")]
    result = analyze(inputs, lambda name: exit_sign_image())
    assert result["schema_version"] == 1 and result["frame"] == "shared_arkit_session"
    assert result["summary"]["doors_checked"] == 1
    assert result["summary"]["sign_candidates"] >= 1 and result["summary"]["keyframes_examined"] == 1
    png = base64.b64decode(result["floor_map"]["image_png_base64"])
    image = cv2.imdecode(np.frombuffer(png, np.uint8), cv2.IMREAD_UNCHANGED)
    assert image.shape[2] == 4 and image.shape[:2] == (result["floor_map"]["grid"]["height"], result["floor_map"]["grid"]["width"])


def test_no_evidence_yields_no_floor_map():
    result = analyze(ScanInputs("empty"), lambda name: None)
    assert result["floor_map"] is None and result["doors"] == [] and result["signs"] == []
    assert any("No floor map" in n for n in result["notices"])
