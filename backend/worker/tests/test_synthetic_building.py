"""Procedural building packages: determinism, backend-format validity, geometry and ground truth."""
import io
import json
import tarfile

import cv2
import numpy as np
import pytest

from inview_worker.geometry import matrix
from inview_worker.synthetic import building, offline
from inview_worker.synthetic.package import members


@pytest.fixture(scope="module")
def built():
    """The full default walk (every sign view) of building 0."""
    return building.build(0)


def _rigid(column_major) -> bool:
    m = np.asarray(column_major, float).reshape(4, 4, order="F")
    r = m[:3, :3]
    return (np.allclose(m[3], [0, 0, 0, 1], atol=1e-4) and np.allclose(r.T @ r, np.eye(3), atol=1e-4)
            and abs(np.linalg.det(r) - 1) < 1e-4)


def validate_package(archive: bytes) -> dict:
    """The checks of backend/src/scan_package.rs + capture.rs (decode, validate, validate_manifest)
    and the native depth/mesh layout checks of raw_lidar.rs. Returns the decoded files."""
    roots, names = set(), []
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar.getmembers():
            assert member.isfile()
            root, name = member.name.split("/")
            roots.add(root), names.append(name)
    assert len(roots) == 1 and len(names) == len(set(names)) <= 4096
    files = members(archive)
    capture = json.loads(files["capture.json"])
    assert capture["schema_version"] == 1 and capture["id"] == roots.pop()
    assert capture["coordinates"] == {"units": "meters", "up_axis": "y", "handedness": "right"}
    for kind in ("surfaces", "objects"):
        ids = [item["id"] for item in capture[kind]]
        assert len(ids) == len(set(ids)) and all(i.strip() for i in ids)
    for surface in capture["surfaces"]:
        assert _rigid(surface["map_from_surface"]) and sum(d > 0 for d in surface["dimensions_m"]) >= 2
        assert all(d >= 0 for d in surface["dimensions_m"])
    for obj in capture["objects"]:
        assert _rigid(obj["map_from_object"]) and all(d > 0 for d in obj["dimensions_m"]) and obj["category"]
    manifest = json.loads(files["package-manifest.json"])
    assert (manifest["schema_version"], manifest["capture_id"], manifest["map_id"], manifest["floor_id"]) == (
        1, capture["id"], capture["map_id"], capture["floor_id"])
    assert manifest["coordinate_frame"] == {**capture["coordinates"], "name": "shared_arkit_session"}
    assert any(a["path"] == "capture.json" and a["role"] == "portable_capture" for a in manifest["assets"])
    for asset in manifest["assets"]:
        assert len(files[asset["path"]]) == asset["bytes"] and "/" not in asset["path"]
        assert asset["role"] and asset["media_type"]
    ids = [o["id"] for o in manifest["observations"]]
    assert len(ids) == len(set(ids)) and 0 < len(ids) <= 64
    for o in manifest["observations"]:
        image, depth = o["image"], o["raw_depth"]
        assert _rigid(o["map_from_camera"]) and image["fx"] > 0 and image["fy"] > 0
        assert o["rgb_asset"] in files and depth["raw_asset"] in files and depth["confidence_asset"] in files
        assert depth["pixel_format"] == 1717855600 and depth["bytes_per_row"] >= depth["width"] * 4
        assert len(files[depth["raw_asset"]]) == depth["bytes_per_row"] * depth["height"]
        assert len(files[depth["confidence_asset"]]) == depth["confidence_bytes_per_row"] * depth["height"]
        assert depth["environment"]["recorded_at_unix_seconds"] > 0
    for anchor in manifest["mesh_anchors"]:
        assert _rigid(anchor["map_from_anchor"]) and anchor["indices_per_face"] == 3
        assert anchor["bytes_per_index"] in (2, 4) and 12 <= anchor["vertex_stride"] <= 256
        for key in ("vertices_asset", "faces_asset", "normals_asset", "classification_asset"):
            assert anchor[key] in files
        assert len(files[anchor["vertices_asset"]]) >= (anchor["vertex_count"] - 1) * anchor["vertex_stride"] + 12
        faces = np.frombuffer(files[anchor["faces_asset"]], "<u4")
        assert len(faces) == anchor["face_count"] * 3 and faces.max() < anchor["vertex_count"]
        assert len(files[anchor["classification_asset"]]) == anchor["face_count"]
    return files


def test_same_seed_gives_identical_bytes_and_truth():
    a, truth_a = building.build(5, max_observations=3)
    b, truth_b = building.build(5, max_observations=3)
    assert a == b and truth_a == truth_b
    c, truth_c = building.build(6, max_observations=3)
    assert c != a and truth_c["scan_id"] != truth_a["scan_id"]


def test_package_passes_backend_style_validation_and_decodes(built):
    archive, truth = built
    files = validate_package(archive)
    ctx = offline.context_from_archive(archive)
    assert ctx.scan_id == truth["scan_id"]
    assert len(ctx.inputs.frames) == len(truth["walk"]) >= 15
    assert all(f.color_asset and ctx.image(f.color_asset).shape == (640, 480, 3) for f in ctx.inputs.frames)
    assert len(ctx.inputs.mesh_triangles) > 1000 and ctx.inputs.sources["mesh"] == "native_arkit_mesh"
    kinds = {s.kind for s in ctx.inputs.surfaces}
    assert {"floor", "wall", "door", "opening"} <= kinds
    categories = {o.category for o in ctx.inputs.objects}
    assert {"toilet", "sink", "stairs"} <= categories
    # Every observation carries a GPS/heading sample near the true georeference.
    geo = truth["georef"]
    for observation in json.loads(files["package-manifest.json"])["observations"]:
        env = observation["raw_depth"]["environment"]
        assert abs(env["latitude"] - geo["latitude"]) < 4e-4 and abs(env["longitude"] - geo["longitude"]) < 4e-4
        assert 0 <= env["heading_degrees"] < 360


def test_roomplan_json_has_labelled_sections(built):
    rooms = json.loads(members(built[0])["roomplan.json"])
    labels = {section["label"] for room in rooms for section in room["sections"]}
    assert "bathroom" in labels and len(rooms) == len(built[1]["spaces"])
    restroom = next(r for r in rooms if r["sections"][0]["label"] == "bathroom")
    assert {"toilet", "sink"} <= {next(iter(o["category"])) for o in restroom["objects"]}
    assert all(len(s["transform"]) == 4 for room in rooms for s in room["walls"])


def test_projection_round_trips_the_ray_caster():
    b = building.layout(1)
    sc = building.scene(b)
    view = building.walk(b)[7]
    rng = np.random.default_rng(0)
    py, px = np.mgrid[20:640:90, 15:480:70]
    dirs = building._camera_dirs(view.matrix, (py + 0.5) / 640, 1 - (px + 0.5) / 480)
    t, index, _ = building.cast(sc, view.matrix[:3, 3], dirs)
    assert (index >= 0).all()
    hits = view.matrix[:3, 3] + dirs * t[..., None]
    _, pixels, depth = building.project(view.matrix, hits.reshape(-1, 3))
    assert np.allclose(pixels, np.column_stack((px.ravel() + 0.5, py.ravel() + 0.5)), atol=1e-6)
    assert np.allclose(depth, t.ravel())
    # Portrait phone: world up is image up, so a point above another is higher in the JPEG.
    _, pair, _ = building.project(view.matrix, [hits[3, 3], hits[3, 3] + [0, 0.2, 0]])
    assert pair[1, 1] < pair[0, 1] and abs(pair[1, 0] - pair[0, 0]) < 1.0
    depth_map, confidence = building.render_depth(sc, view.matrix, rng)
    assert depth_map.shape == (192, 256) and depth_map.dtype == np.float32 and confidence.max() == 2


def test_every_sign_is_visible_unoccluded_in_some_keyframe(built):
    archive, truth = built
    files = members(archive)
    observations = json.loads(files["package-manifest.json"])["observations"]
    plates = {s.id: s.plate_bgr for s in building.layout(0).signs}
    for sign in truth["signs"]:
        seen = False
        for o in observations:
            m = matrix(o["map_from_camera"])
            uv, pixel, z = building.project(m, [sign["position_m"]])
            (u, v), (px, py), z = uv[0], pixel[0], z[0]
            if not (z > 0.3 and 0.05 < u < 0.95 and 0.05 < v < 0.95):
                continue
            depth = np.frombuffer(files[o["raw_depth"]["raw_asset"]], "<f4").reshape(192, 256)
            if abs(depth[int(v * 192), int(u * 256)] - z) > 0.05:
                continue  # occluded
            image = cv2.imdecode(np.frombuffer(files[o["rgb_asset"]], np.uint8), cv2.IMREAD_COLOR)
            patch = image[int(py) - 12:int(py) + 12, int(px) - 12:int(px) + 12].reshape(-1, 3).astype(int)
            plate = np.abs(patch - np.array(plates[sign["id"]])).sum(axis=1) < 90
            white = patch.min(axis=1) > 150
            seen = seen or (plate | white).mean() > 0.6
        assert seen, sign["id"]


def test_ground_truth_semantics(built):
    _, truth = built
    doors = {d["id"]: d for d in truth["doors"]}
    assert any(not d["meets_clear_width"] for d in doors.values()) and any(d["meets_clear_width"] for d in doors.values())
    assert any(d["kind"] == "opening" for d in doors.values())
    assert doors["door-north-0"]["clear_width_m"] < 0.815 <= doors["door-north-0-north-1"]["clear_width_m"]
    assert {h["kind"] for h in truth["hazards"]} == {"stairs", "ramp"}
    assert {"restroom", "accessible_restroom"} & {p["category"] for p in truth["places"]}
    texts = {t["text"] for t in truth["text"]}
    assert {"EXIT", "SALIDA", "TOILETTES", "ELEVATOR"} <= texts and any(t.isdigit() for t in texts)
    routes = {(r["from_space"], r["to_space"], r["profile"]): r for r in truth["routes"]}
    assert all(r["reachable"] for r in truth["routes"] if r["profile"] == "ambulatory")
    for (a, b, profile), route in routes.items():
        wheel = routes[(a, b, "wheelchair")]
        if profile == "ambulatory" and wheel["reachable"]:
            assert wheel["length_m"] >= route["length_m"] - 1e-6
            if "north-0" in (a, b):  # its own door is too narrow: the detour uses the connecting door
                assert "door:door-north-0-north-1" in wheel["node_ids"]
    lobby_ok = truth["parameters"]["ramp_slope"] <= 1 / 12 + 1e-4
    assert routes[("north-1", "lobby", "wheelchair")]["reachable"] == lobby_ok
    pairs = {tuple(p) for p in truth["graph"]["room_adjacency"]}
    assert ("corridor", "lobby") in pairs and ("north-0", "north-1") in pairs


@pytest.mark.parametrize("seed", range(25))
def test_furniture_stays_inside_its_room(seed):
    b = building.layout(seed)
    for obj in b.objects:
        space = b.space(obj["space"])
        (x, _, z), (w, _, d) = obj["center"], obj["dimensions"]
        e = 1e-6
        assert space.x0 - e <= x - w / 2 and x + w / 2 <= space.x1 + e, obj["id"]
        assert space.z0 - e <= z - d / 2 and z + d / 2 <= space.z1 + e, obj["id"]
        assert "unidentified" not in space.aliases


def test_cli_writes_package_and_truth(tmp_path):
    out = tmp_path / "b.inviewscan.tar"
    assert building.main([str(out), "--seed", "2", "--max-observations", "2"]) == 0
    truth = json.loads((tmp_path / "b.inviewscan.tar.truth.json").read_text())
    assert truth["seed"] == 2 and validate_package(out.read_bytes())
