"""Navigation graph (U3): skeleton topology, anchors, attributes and the backend Graph v1 contract."""
import copy
import heapq
import json
import math

import cv2
import numpy as np
import pytest

from inview_worker import doors, floor_map, navgraph
from inview_worker.core import ScanContext
from inview_worker.inputs import Box, ScanInputs, Surface
from inview_worker.navgraph import skeleton
from inview_worker.navgraph.validate import GraphValidationError, validate_graph
from inview_worker.pipeline import analyze


def pose(x=0.0, y=0.0, z=0.0, yaw_deg=0.0) -> np.ndarray:
    c, s = math.cos(math.radians(yaw_deg)), math.sin(math.radians(yaw_deg))
    m = np.eye(4)
    m[:3, :3] = [[c, 0, s], [0, 1, 0], [-s, 0, c]]
    m[:3, 3] = [x, y, z]
    return m


def wall(name, x, z, length, along_z=False):
    return Surface(name, "wall", pose(x=x, y=1.25, z=z, yaw_deg=90 if along_z else 0), [length, 2.5, 0])


def single_room(door_width=0.9) -> ScanInputs:
    """4 m x 4 m room with a north doorway, a table and two cabinets (as in test_passes.room)."""
    surfaces = [
        Surface("floor", "floor", pose(), [4, 0, 4]),
        wall("north", 0, -2, 4), wall("south", 0, 2, 4),
        wall("east", 2, 0, 4, along_z=True), wall("west", -2, 0, 4, along_z=True),
        Surface("door", "door", pose(z=-2, y=1.05), [door_width, 2.1, 0]),
    ]
    objects = [
        Box("table", "table", pose(x=-0.8, y=0.37, z=0.6), [1.2, 0.74, 0.8]),
        Box("left", "storage", pose(x=0.95, y=0.45, z=1.2), [0.5, 0.9, 0.6]),
        Box("right", "storage", pose(x=1.75, y=0.45, z=1.2), [0.5, 0.9, 0.6]),
    ]
    return ScanInputs("room", surfaces, objects)


def suite(door_a=0.9, door_b=0.7) -> ScanInputs:
    """Room A (x -4..0) -- door A -- corridor (x 0..4, 1.6 m wide) -- door B -- room B (x 4..8)."""
    surfaces = [
        Surface("floor-a", "floor", pose(x=-2), [4, 0, 4]),
        Surface("floor-corridor", "floor", pose(x=2), [4, 0, 1.6]),
        Surface("floor-b", "floor", pose(x=6), [4, 0, 4]),
        wall("a-north", -2, -2, 4), wall("a-south", -2, 2, 4),
        wall("a-west", -4, 0, 4, along_z=True), wall("a-east", 0, 0, 4, along_z=True),
        wall("c-north", 2, -0.8, 4), wall("c-south", 2, 0.8, 4),
        wall("b-north", 6, -2, 4), wall("b-south", 6, 2, 4),
        wall("b-west", 4, 0, 4, along_z=True), wall("b-east", 8, 0, 4, along_z=True),
        Surface("door-a", "door", pose(x=0, y=1.05, yaw_deg=90), [door_a, 2.1, 0]),
        Surface("door-b", "door", pose(x=4, y=1.05, yaw_deg=90), [door_b, 2.1, 0]),
    ]
    objects = [
        Box("table-a", "table", pose(x=-2, y=0.37, z=0.0), [1.2, 0.74, 0.8]),
        Box("desk-b", "table", pose(x=6.8, y=0.37, z=-1.3), [1.0, 0.74, 0.6]),
    ]
    return ScanInputs("suite", surfaces, objects)


def build(inputs, **kwargs):
    fm = floor_map.build(inputs)
    kwargs.setdefault("doors", doors.check(inputs, fm))
    kwargs.setdefault("level", True)
    return fm, navgraph.build(fm, scan_id=inputs.scan_id, map_id="map", floor_id="ground", **kwargs)


def route(nav, start, goal, min_width=None, step_free=False):
    """Dijkstra over the adjacency product with the backend's eligibility rules."""
    best, queue = {start: 0.0}, [(0.0, start, [start])]
    while queue:
        cost, node, path = heapq.heappop(queue)
        if node == goal:
            return path, cost
        if cost > best.get(node, math.inf):
            continue
        for edge in nav.adjacency[node]:
            if min_width is not None and not edge.minimum_clear_width_m >= min_width:
                continue
            if step_free and edge.step_free is not True:
                continue
            nxt = cost + edge.length_m
            if nxt < best.get(edge.target, math.inf):
                best[edge.target] = nxt
                heapq.heappush(queue, (nxt, edge.target, path + [edge.target]))
    return None


def world_samples(graph, step=0.01):
    for edge in graph["edges"]:
        pts = np.array([[p["x"], p["z"]] for p in edge["segment"]["path_points"]])
        for a, b in zip(pts[:-1], pts[1:]):
            n = max(1, int(np.ceil(np.linalg.norm(b - a) / step)))
            for t in np.linspace(0, 1, n + 1):
                yield edge["id"], a + (b - a) * t


# --- skeleton primitives -----------------------------------------------------------------------

def test_classify_finds_endpoints_and_one_junction_on_a_plus():
    image = np.zeros((41, 41), np.uint8)
    image[20, 5:36] = 255
    image[5:36, 20] = 255
    _, endpoints, junctions = skeleton.classify(image)
    assert endpoints.sum() == 4
    n, _ = cv2.connectedComponents(junctions.astype(np.uint8))
    assert n - 1 == 1


def test_y_junction_with_touching_branch_pixels_keeps_all_three_branches():
    sk = np.zeros((30, 30), np.uint8)
    sk[2:16, 15] = 255                       # up, through N of the junction
    sk[15, 15:28] = 255                      # right, through E (touches N diagonally)
    for k in range(1, 12):
        sk[15 + k, 15 - k] = 255             # south-west
    graph = skeleton.to_graph(skeleton.minimal(sk), np.ones(sk.shape, np.float32))
    assert len(graph.nodes) == 4 and len(graph.edges) == 3
    junction = next(n for n, node in graph.nodes.items() if node.kind == "junction")
    assert tuple(graph.nodes[junction].pos) == (15.0, 15.0) and graph.degree(junction) == 3


@pytest.mark.parametrize("angle", range(0, 360, 15))
def test_y_corridors_at_any_angle_stay_connected(angle):
    image = np.zeros((161, 161), np.uint8)
    centre = (80, 80)
    for a in (angle, angle + 120, angle + 235):
        end = (int(80 + 70 * math.cos(math.radians(a))), int(80 + 70 * math.sin(math.radians(a))))
        cv2.line(image, centre, end, 255, 12)
    graph = skeleton.to_graph(skeleton.thin(image), np.ones(image.shape, np.float32))
    assert len(graph.components()) == 1
    assert sum(node.kind == "endpoint" for node in graph.nodes.values()) == 3


def test_ring_skeleton_becomes_two_nodes_and_two_edges():
    image = np.zeros((60, 60), np.uint8)
    cv2.circle(image, (30, 30), 20, 255, 1)
    graph = skeleton.to_graph(cv2.ximgproc.thinning(image), np.ones(image.shape, np.float32))
    graph.break_loops()
    assert len(graph.nodes) == 2 and len(graph.edges) == 2
    assert all(e.u != e.v for e in graph.edges.values())


def test_thinning_methods_are_selectable():
    free = np.zeros((30, 60), np.uint8)
    free[10:20, 5:55] = 255
    assert skeleton.thin(free, "guo_hall").any() and skeleton.thin(free, "zhang_suen").any()
    with pytest.raises(ValueError):
        skeleton.thin(free, "medial")


# --- graph on synthetic rooms ------------------------------------------------------------------

def test_single_room_graph_is_valid_connected_and_has_the_door():
    fm, result = build(single_room())
    graph = result.graph
    validate_graph(graph)
    assert graph["id"] == "room-nav" and graph["schema_version"] == 1
    assert result.summary["components"] == 1 and result.summary["nodes"] >= 3
    assert graph["metadata"]["door_nodes"] == {"door": "door-door"}
    door = next(n for n in graph["nodes"] if n["id"] == "door-door")
    assert door["label"] == "Door" and door["z"] == pytest.approx(-2.0, abs=0.15) and abs(door["x"]) < 0.3
    assert all(n["y"] == 0.0 for n in graph["nodes"])
    # Every connection is bidirectional with reversed geometry.
    by_id = {e["id"]: e for e in graph["edges"]}
    for edge_id, edge in by_id.items():
        twin = by_id[edge_id[:-1] + ("r" if edge_id.endswith("f") else "f")]
        assert (twin["from"], twin["to"]) == (edge["to"], edge["from"])
        assert twin["segment"]["path_points"] == edge["segment"]["path_points"][::-1]
        assert edge["availability"] == "available" and edge["minimum_clear_width_m"] > 0


def test_multi_room_graph_connects_across_doors():
    fm, result = build(suite())
    graph, nav = result.graph, result.adjacency
    assert result.summary["components"] == 1
    assert set(graph["metadata"]["door_nodes"]) == {"door-a", "door-b"}
    xs = [n["x"] for n in graph["nodes"]]
    assert min(xs) < -1.0 and max(xs) > 5.0, "graph must reach into both rooms"
    west = min(graph["nodes"], key=lambda n: n["x"])["id"]
    east = max(graph["nodes"], key=lambda n: n["x"])["id"]
    path, length = route(nav, west, east)
    assert "door-door-a" in path and "door-door-b" in path
    assert 6.0 < length < 16.0


def test_narrow_door_edges_carry_its_width_and_block_wide_routes():
    fm, result = build(suite(door_b=0.7))
    graph, nav = result.graph, result.adjacency
    door_b = graph["metadata"]["door_nodes"]["door-b"]
    info = graph["metadata"]["doors"]["door-b"]
    assert info["meets_clear_width"] is False and info["clear_width_m"] == pytest.approx(0.7, abs=0.12)
    incident = [e for e in graph["edges"] if door_b in (e["from"], e["to"])]
    assert incident and all(e["minimum_clear_width_m"] <= info["clear_width_m"] + 1e-6 for e in incident)
    assert all(e["minimum_clear_width_m"] == pytest.approx(0.7, abs=0.15) for e in incident)
    west = min(graph["nodes"], key=lambda n: n["x"])["id"]
    east = max(graph["nodes"], key=lambda n: n["x"])["id"]
    assert route(nav, west, east) is not None
    assert route(nav, west, east, min_width=0.9) is None          # requirement is never relaxed
    assert route(nav, west, door_b, min_width=0.6) is not None
    # Only the short crossing edges carry the door width: the corridor keeps its own.
    corridor = [e for e in graph["edges"] if all(0.3 < p["x"] < 3.7 for p in e["segment"]["path_points"])]
    assert corridor and all(e["minimum_clear_width_m"] > 1.0 for e in corridor)
    for edge in incident:
        length = sum(math.dist((a["x"], a["z"]), (b["x"], b["z"])) for a, b in
                     zip(edge["segment"]["path_points"], edge["segment"]["path_points"][1:]))
        assert length <= 0.51


def test_door_narrower_than_the_body_skeleton_is_connected_by_connectors():
    # 0.45 m: the 0.25 m clearance skeleton cannot pass, so the door centre gets connectors.
    fm, result = build(suite(door_b=0.45))
    graph = result.graph
    assert graph["metadata"]["doors"]["door-b"]["connection"] == "connectors"
    assert result.summary["components"] == 1
    door_b = graph["metadata"]["door_nodes"]["door-b"]
    widths = [e["minimum_clear_width_m"] for e in graph["edges"] if door_b in (e["from"], e["to"])]
    assert widths and max(widths) < 0.6


def test_empty_convex_room_keeps_a_centre_node_and_connects_its_door():
    surfaces = [Surface("floor", "floor", pose(), [4, 0, 4]),
                wall("north", 0, -2, 4), wall("south", 0, 2, 4),
                wall("east", 2, 0, 4, along_z=True), wall("west", -2, 0, 4, along_z=True),
                Surface("door", "door", pose(z=2, y=1.05, x=1.0), [0.9, 2.1, 0])]
    fm, result = build(ScanInputs("square", surfaces),
                       places=[{"id": "seat", "category": "seating", "name": "Seat", "position_m": [-1.2, 0.4, -1.2]}])
    graph = result.graph
    kinds = graph["metadata"]["node_kinds"]
    centre = [n for n in graph["nodes"] if kinds[n["id"]] == "centre"]
    assert len(centre) == 1 and abs(centre[0]["x"]) < 0.15 and abs(centre[0]["z"]) < 0.15
    assert result.summary["components"] == 1
    assert route(result.adjacency, "place-seat", "door-door") is not None


def test_closed_door_leaf_still_connects_and_is_noted():
    inputs = suite()
    # A thin closed leaf across door A, as the ARKit mesh records it.
    inputs.objects.append(Box("leaf", "door_leaf", pose(x=0, y=1.0, yaw_deg=90), [0.9, 2.0, 0.04]))
    fm, result = build(inputs)
    info = result.graph["metadata"]["doors"]["door-a"]
    assert info["connection"] == "connectors" and info["notes"]
    assert result.summary["components"] == 1


def test_no_edge_crosses_obstacles():
    for inputs in (single_room(), suite(), suite(door_b=0.45)):
        fm, result = build(inputs)
        cells = fm.grid.int_cells(np.array([p for _, p in world_samples(result.graph)]))
        assert not fm.obstacle[cells[:, 1], cells[:, 0]].any()


def test_places_snap_to_reachable_skeleton_points():
    places = [
        {"id": "info", "category": "information", "name": "Info desk", "position_m": [-3.0, 1.0, -1.2]},
        # Wall-mounted on room A's north wall: its access point must stay inside room A.
        {"id": "extinguisher", "category": "fire_extinguisher", "name": "Fire extinguisher",
         "position_m": [-3.0, 1.2, -2.0]},
        # Inside the table: moved to the nearest free cell beside it.
        {"id": "table", "category": "landmark", "name": "Table", "position_m": [-2.0, 0.7, 0.0]},
        {"id": "far", "category": "exit", "name": "Far away", "position_m": [100.0, 0.0, 100.0]},
    ]
    fm, result = build(suite(), places=places)
    graph, nav = result.graph, result.adjacency
    nodes = {n["id"]: n for n in graph["nodes"]}
    snapped = graph["metadata"]["place_nodes"]
    assert set(snapped) == {"info", "extinguisher", "table"}
    assert [u["id"] for u in graph["metadata"]["unattached"]] == ["far"]
    info = nodes[snapped["info"]]
    assert (info["x"], info["z"]) == pytest.approx((-3.0, -1.2), abs=0.06) and info["label"] == "Info desk"
    ext = nodes[snapped["extinguisher"]]
    assert -2.0 < ext["z"] < -1.4 and -4 < ext["x"] < 0
    table = nodes[snapped["table"]]
    assert abs(table["x"] + 2.0) > 0.6 - 1e-6 or abs(table["z"]) > 0.4 - 1e-6
    # Every place connector is collision free and every place is routable to room B.
    east = max(graph["nodes"], key=lambda n: n["x"])["id"]
    for node in snapped.values():
        assert route(nav, node, east) is not None
    assert result.summary["places_connected"] == 3 and result.summary["components"] == 1


def test_region_nodes_and_doorway_regions():
    regions = [
        {"id": "room-a", "kind": "room", "label": "Lobby", "centroid_xz_m": [-2.0, 0.0],
         "polygon_xz_m": [[-4, -2], [0, -2], [0, 2], [-4, 2]], "area_m2": 16.0},
        {"id": "corridor", "kind": "corridor", "centroid_xz_m": [2.0, 0.0],
         "polygon_xz_m": [[0, -0.8], [4, -0.8], [4, 0.8], [0, 0.8]], "area_m2": 6.4},
        {"id": "doorway-a", "kind": "doorway", "centroid_xz_m": [0.0, 0.0]},
    ]
    fm, result = build(suite(), regions=regions)
    graph = result.graph
    region_nodes = graph["metadata"]["region_nodes"]
    assert set(region_nodes) == {"room-a", "corridor"}               # the doorway is the door node
    nodes = {n["id"]: n for n in graph["nodes"]}
    lobby = nodes[region_nodes["room-a"]]
    assert lobby["label"] == "Lobby" and -4 < lobby["x"] < 0       # centroid is in the table: moved, same room
    assert nodes[region_nodes["corridor"]]["label"] == "Corridor"
    assert graph["metadata"]["anchors"][region_nodes["room-a"]]["moved_m"] > 0.3
    assert route(result.adjacency, region_nodes["room-a"], region_nodes["corridor"]) is not None


def test_step_free_and_slope_rules():
    fm, flat = build(suite())
    assert all(e["step_free"] is None for e in flat.graph["edges"])
    assert all("maximum_slope" not in e for e in flat.graph["edges"])

    measured_flat = {"measured": True, "elevation": np.zeros(fm.walkable.shape)}
    _, measured = build(suite(), height_map=measured_flat)
    assert all(e["step_free"] is True and e["maximum_slope"] == 0 for e in measured.graph["edges"])

    _, unknown = build(suite(), level=None)
    assert all(e["step_free"] is None for e in unknown.graph["edges"])

    # A step across the corridor: corridor edges are no longer step-free, rooms still are.
    step = {"id": "step-1", "kind": "step", "position_m": [2.0, 0.0, 0.0], "severity": "barrier",
            "polygon_xz_m": [[1.8, -0.8], [2.2, -0.8], [2.2, 0.8], [1.8, 0.8]], "measure": {"rise_m": 0.15}}
    _, stepped = build(suite(), hazards=[step], height_map=measured_flat)
    blocked = [e for e in stepped.graph["edges"] if e["step_free"] is False]
    assert blocked and all(any(p["x"] > 1.7 for p in e["segment"]["path_points"]) for e in blocked)
    nav = stepped.adjacency
    west = min(stepped.graph["nodes"], key=lambda n: n["x"])["id"]
    east = max(stepped.graph["nodes"], key=lambda n: n["x"])["id"]
    assert route(nav, west, east, step_free=True) is None and route(nav, west, east) is not None
    details = stepped.graph["metadata"]["edges"]
    assert any(d["hazards"] == ["step-1"] for d in details.values())

    # A 1:16 ramp along the corridor in the height map; flat elsewhere.
    xs = fm.grid.x0 + np.arange(fm.grid.width) * fm.grid.resolution
    elevation = np.zeros((fm.grid.height, fm.grid.width))
    elevation[:, :] = np.clip(xs - 0.5, 0, 3.0)[None, :] / 16
    _, ramped = build(suite(), height_map={"elevation": elevation, "measured": True})
    slopes = [e.get("maximum_slope") for e in ramped.graph["edges"]]
    assert all(s is not None for s in slopes)
    assert max(slopes) == pytest.approx(1 / 16, abs=0.01)
    assert all(e["step_free"] is True for e in ramped.graph["edges"])
    points = [p for e in ramped.graph["edges"] for p in e["segment"]["path_points"]]
    assert max(p["y"] for p in points) - min(p["y"] for p in points) > 0.15
    assert all(abs(p["y"] - np.clip(p["x"] - 0.5, 0, 3.0) / 16) < 0.005 for p in points)
    # A raster without measurement provenance is useful geometry, not eligibility evidence.
    _, wrapped = build(suite(), height_map={"elevation": elevation})
    assert all(e["step_free"] is None and "maximum_slope" not in e for e in wrapped.graph["edges"])


def test_output_is_deterministic():
    _, a = build(suite())
    _, b = build(suite())
    assert json.dumps(a.graph, sort_keys=True) == json.dumps(b.graph, sort_keys=True)


def test_single_level_rule():
    assert navgraph.single_level(None, [0.0, 0.005]) is True
    assert navgraph.single_level(None, [0.0, 0.2]) is False
    assert navgraph.single_level(None, []) is None
    assert navgraph.single_level({"rooms": [{"floor_y_m": 0, "story": 0}, {"floor_y_m": 0, "story": 1}]}, []) is False


def test_config_overrides_and_rejects_unknown_keys():
    cfg = navgraph.NavGraphConfig.from_mapping({"clearance_radius_m": 0.4, "thinning": "guo_hall"})
    assert cfg.clearance_radius_m == 0.4 and cfg.thinning == "guo_hall"
    with pytest.raises(ValueError):
        navgraph.NavGraphConfig.from_mapping({"clearance": 1})
    # A wider body clearance cannot pass the 0.7 m door on the skeleton, connectors keep it routable.
    fm = floor_map.build(suite())
    result = navgraph.build(fm, scan_id="suite", map_id="m", floor_id="f", doors=doors.check(suite(), fm),
                            level=True, config=cfg)
    assert result.graph["metadata"]["doors"]["door-b"]["connection"] == "connectors"
    assert result.summary["components"] == 1


# --- backend contract ----------------------------------------------------------------------------

def test_local_validator_mirrors_backend_rules():
    _, result = build(single_room())
    good = result.graph
    validate_graph(good)

    def broken(mutate):
        graph = copy.deepcopy(good)
        mutate(graph)
        with pytest.raises(GraphValidationError):
            validate_graph(graph)

    broken(lambda g: g.update(extra=1))
    broken(lambda g: g["nodes"][0].update(kind="junction"))
    broken(lambda g: g["edges"][0].update(length_m=1.0))
    broken(lambda g: g["edges"][0]["segment"].update(width=1.0))
    broken(lambda g: g.update(schema_version=2))
    broken(lambda g: g["nodes"].append(dict(g["nodes"][0])))
    broken(lambda g: g["edges"].append(dict(g["edges"][0])))
    broken(lambda g: g["edges"][0].update(minimum_clear_width_m=0))
    broken(lambda g: g["edges"][0].update(maximum_slope=-0.1))
    broken(lambda g: g["edges"][0].update(to="missing"))
    broken(lambda g: g["edges"][0]["segment"]["path_points"][0].update(x=999.0))
    broken(lambda g: g["edges"][0]["segment"].update(floor_id="other"))
    broken(lambda g: g["edges"][0]["segment"].update(path_points=g["edges"][0]["segment"]["path_points"][:1]))
    broken(lambda g: g["nodes"][0].update(map_id=" "))
    broken(lambda g: g["edges"][0].update(availability="open"))


def test_endpoints_meet_nodes_within_tolerance():
    _, result = build(suite(), places=[{"id": "p", "category": "seating", "name": "Bench",
                                        "position_m": [6.0, 0.5, 1.0]}])
    nodes = {n["id"]: n for n in result.graph["nodes"]}
    for edge in result.graph["edges"]:
        first, last = edge["segment"]["path_points"][0], edge["segment"]["path_points"][-1]
        for point, node in ((first, nodes[edge["from"]]), (last, nodes[edge["to"]])):
            assert math.dist((point["x"], point["y"], point["z"]), (node["x"], node["y"], node["z"])) <= 0.05


# --- pipeline integration --------------------------------------------------------------------------

def test_stage_runs_in_the_pipeline_and_publishes_a_valid_graph():
    analysis = analyze(ScanContext("suite", suite()))
    assert analysis["stages"]["nav_graph"]["status"] == "ok"
    graph = analysis["nav_graph"]
    validate_graph(graph)
    assert graph["id"] == "suite-nav" and graph["nodes"][0]["floor_id"] == "unassigned"
    assert set(graph["metadata"]["door_nodes"]) == {"door-a", "door-b"}
    assert analysis["summary"]["nav_graph"]["components"] == 1
    assert graph["metadata"]["review_status"] == "draft"
    assert analysis["height_map"]["measured"] is False
    assert all(e["step_free"] is None and "maximum_slope" not in e for e in graph["edges"])
    assert not any(r["profile"] == "wheelchair" for r in analysis["routes"]["routes"])
    json.dumps(analysis, allow_nan=False)


def test_stage_on_synthetic_package_uses_manifest_ids(synthetic_ctx):
    analysis = analyze(synthetic_ctx)
    assert analysis["stages"]["nav_graph"]["status"] == "ok"
    graph = analysis["nav_graph"]
    validate_graph(graph)
    assert graph["id"] == "synthetic-walk-nav"
    assert {n["map_id"] for n in graph["nodes"]} == {"synthetic-map"}
    assert analysis["summary"]["nav_graph"]["nodes"] > 0


def test_stage_is_skipped_without_floor_map():
    analysis = analyze(ScanContext("empty", ScanInputs("empty")))
    assert analysis["stages"]["nav_graph"]["status"] == "skipped"
