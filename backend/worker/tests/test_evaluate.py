"""Evaluation harness: metric math, scorers fed with ground-truth-perfect products, and a smoke run."""
import json
import math

import pytest

from inview_worker import cli, evaluate
from inview_worker.synthetic import building


@pytest.fixture(scope="module")
def truth():
    return building.ground_truth(building.layout(3), [])


def perfect_nav_graph(truth: dict) -> dict:
    """The truth waypoint graph in backend Graph v1 shape (what an ideal nav_graph stage emits)."""
    nodes = [{"id": n["id"], "map_id": "m", "floor_id": "f", "x": n["position_m"][0], "y": n["position_m"][1],
              "z": n["position_m"][2]} for n in truth["graph"]["nodes"]]
    points = {n["id"]: {k: n[k] for k in ("x", "y", "z")} for n in nodes}
    edges = []
    for i, e in enumerate(truth["graph"]["edges"]):
        for a, b, suffix in ((e["from"], e["to"], "f"), (e["to"], e["from"], "r")):
            edge = {"id": f"e{i}{suffix}", "from": a, "to": b, "step_free": not e.get("stairs", False),
                    "availability": "available", "minimum_clear_width_m": e.get("clear_width_m", 1.8),
                    "maximum_slope": e.get("slope", 0.0),
                    "segment": {"type": "surface", "map_id": "m", "floor_id": "f",
                                "path_points": [points[a], points[b]]}}
            edges.append(edge)
    return {"schema_version": 1, "id": "x-nav", "nodes": nodes, "edges": edges}


def test_text_metrics():
    assert evaluate.levenshtein("kitten", "sitting") == 3
    assert evaluate.normalize_text(" exit-> salida! ") == "EXIT SALIDA"
    assert evaluate.cer("EXlT", "EXIT") == 0.25
    assert evaluate.cer(None, "214") == 1.0 and evaluate.cer("", "") == 0.0
    assert evaluate.cer("a much longer wrong string", "AB") == 1.0


def test_geometry_metrics():
    square = [[0, 0], [2, 0], [2, 2], [0, 2]]
    shifted = [[1, 0], [3, 0], [3, 2], [1, 2]]
    assert evaluate.iou([square], [square]) == 1.0
    assert evaluate.iou([square], [shifted]) == pytest.approx(1 / 3, abs=0.03)
    assert evaluate.iou([], [square]) == 0.0
    assert evaluate.polygon_area(square) == 4.0
    assert evaluate.point_in_polygon([1, 1], square) and not evaluate.point_in_polygon([3, 1], square)
    assert evaluate.haversine_m(33.0, -84.0, 34.0, -84.0) == pytest.approx(111_195, rel=1e-3)
    assert evaluate.angle_difference_deg(350, 10) == 20 and evaluate.angle_difference_deg(90, 90) == 0
    matches = evaluate.greedy_match([[0, 0], [5, 5], [0.2, 0]], [[0.1, 0], [9, 9]], 1.0)
    assert [(i, j) for i, j, _ in matches] == [(0, 0)]
    assert evaluate.mean([]) is None and evaluate.median([1, 3, 10]) == 3 and evaluate.ratio(1, 0) is None


def test_category_and_label_matching():
    assert evaluate.category_matches("accessible_restroom", "restroom")
    assert evaluate.category_matches("exit_sign_candidate", "exit")
    assert evaluate.category_matches("exit", "directional") and not evaluate.category_matches("elevator", "exit")
    assert evaluate.label_matches("Room 214", ["214", "office"]) and evaluate.label_matches("Bathroom", ["bathroom"])
    assert not evaluate.label_matches(None, ["x"]) and not evaluate.label_matches("kitchen", ["214", "office"])
    assert not evaluate.label_matches("unidentified", ["unidentified", "214"])


def test_scorers_give_perfect_scores_to_ground_truth_products(truth):
    floor = {"outlines": [{"polygon_xz_m": p, "area_m2": evaluate.polygon_area(p)} for p in truth["floor"]["footprint_polygons_xz_m"]],
             "floor_height_m": 0.0}
    assert evaluate.score_floor_map(floor, truth)["outline_iou"] == 1.0
    doors = [{"id": d["id"], "center_xz_m": d["center_xz_m"], "nominal_width_m": d["nominal_width_m"],
              "measured_clear_width_m": d["clear_width_m"], "meets_clear_width": d["meets_clear_width"]} for d in truth["doors"]]
    scored = evaluate.score_doors(doors, truth)
    assert scored["recall"] == scored["pass_fail_accuracy"] == scored["below_min_recall"] == 1.0
    assert scored["clear_width_mae_m"] == 0.0
    signs = [{"category": s["category"], "position_m": s["position_m"], "text": s["text"]} for s in truth["signs"]]
    scored = evaluate.score_signs(signs, truth)
    assert scored["recall"] == scored["category_accuracy"] == scored["read_rate"] == 1.0 and scored["ocr_cer"] == 0.0
    scored = evaluate.score_text([dict(t) for t in truth["text"]], truth)
    assert scored["line_recall"] == 1.0 and scored["mean_cer"] == 0.0
    regions = [{"kind": "room" if s["kind"] != "corridor" else "corridor", "polygon_xz_m": s["polygon_xz_m"],
                "label": s["name"]} for s in truth["spaces"]]
    scored = evaluate.score_regions(regions, truth)
    assert scored["recall"] == scored["label_accuracy"] == scored["kind_accuracy"] == 1.0 and scored["count_error"] == 0
    scored = evaluate.score_places([dict(p) for p in truth["places"]], truth)
    assert scored["recall"] == scored["precision"] == scored["room_number_recall"] == 1.0
    hazards = [{"kind": h["kind"], "position_m": h["position_m"], "measure": h["measure"]} for h in truth["hazards"]]
    scored = evaluate.score_hazards(hazards, truth)
    assert scored["recall"] == scored["precision"] == 1.0 and scored["ramp_slope_error"] == 0.0
    geo = evaluate.score_georef(truth["georef"], truth)
    assert geo == {"distance_m": 0.0, "heading_error_deg": 0.0}


def test_nav_graph_and_routes_scoring(truth):
    graph = perfect_nav_graph(truth)
    scored = evaluate.score_nav_graph(graph, truth)
    assert scored["space_coverage"] == 1.0
    assert scored["adjacency_f1"] == 1.0
    assert scored["ambulatory_reachability_agreement"] == scored["wheelchair_reachability_agreement"] == 1.0
    assert scored["ambulatory_route_length_ratio"] == pytest.approx(1.0, abs=1e-3)
    # A graph that ignores door widths and stairs disagrees on wheelchair reachability.
    careless = {**graph, "edges": [dict(e, step_free=True, minimum_clear_width_m=2.0, maximum_slope=0.0)
                                   for e in graph["edges"]]}
    wheel = [r for r in truth["routes"] if r["profile"] == "wheelchair"]
    if not all(r["reachable"] for r in wheel):
        assert evaluate.score_nav_graph(careless, truth)["wheelchair_reachability_agreement"] < 1.0
    # A routes product that follows the truth exactly scores a length ratio of 1.
    places = [{"id": f"p-{s['id']}", "position_m": s["center_m"]} for s in truth["spaces"]]
    routes = {"routes": [{"from_place": f"p-{r['from_space']}", "to_place": f"p-{r['to_space']}", "profile": r["profile"],
                          "length_m": r["length_m"] or 10.0} for r in truth["routes"]]}
    scored = evaluate.score_routes(routes, truth, places, None)
    assert scored["resolved"] == len(truth["routes"]) and scored["length_ratio_median"] == 1.0
    assert scored["wheelchair_impossible_routes"] == sum(not r["reachable"] for r in wheel)


def test_score_reports_missing_unscored_and_scorer_errors(truth):
    result = evaluate.score({"scan_id": "x", "stages": {}, "doors": [], "weird": 1, "signs": 5}, truth)
    assert "doors" in result["products"] and "signs" in result["errors"]
    assert "floor_map" in result["missing"] and "routes" in result["missing"] and result["unscored"] == ["weird"]


def test_smoke_evaluation_on_base_products(tmp_path):
    """The full offline pipeline on a building: products present in the base meet sane thresholds."""
    report = evaluate.run(seed=0, scenarios=1, max_observations=32, keep=tmp_path)
    scenario = report["scenarios"][0]
    assert all(status == "ok" for status in scenario["stages"].values())
    products = scenario["products"]
    floor = products["floor_map"]
    assert floor["outline_iou"] > 0.85 and floor["area_rel_error"] < 0.1 and floor["floor_height_error_m"] < 0.05
    doors = products["doors"]
    assert doors["recall"] == 1.0 and doors["nominal_width_mae_m"] < 0.03 and doors["clear_width_mae_m"] < 0.2
    assert doors["below_min_recall"] == 1.0  # every truly narrow door is flagged
    signs = products["signs"]
    assert signs["recall"] >= 0.3 and signs["localization_error_median_m"] < 0.3 and signs["precision_near_any"] >= 0.5
    assert report["aggregate"]["floor_map"]["outline_iou"] == floor["outline_iou"]
    assert (tmp_path / f"{scenario['scan_id']}.analysis.json").is_file()
    text = evaluate.table(report)
    assert "floor_map.outline_iou" in text and "seed 0" in text


def test_cli_evaluate_writes_report(tmp_path, capsys):
    out = tmp_path / "report.json"
    assert cli.main(["evaluate", "--seed", "4", "--scenarios", "1", "--max-observations", "3", "--out", str(out)]) == 0
    report = json.loads(out.read_text())
    assert report["scenarios"][0]["seed"] == 4 and "doors" in report["aggregate"]
    assert "doors.recall" in capsys.readouterr().out
    assert not math.isnan(report["aggregate"]["doors"]["recall"])


def one_way_graph(**properties):
    path = [{"x": x, "y": 0.0, "z": z} for x, z in [(0, 0), (0, 1), (1, 1), (1, 0)]]
    edge = {"id": "e", "from": "a", "to": "b", "availability": "available", "step_free": True,
            "minimum_clear_width_m": 1.0, "maximum_slope": 0.0,
            "segment": {"type": "surface", "map_id": "m", "floor_id": "f", "path_points": path}}
    edge.update(properties)
    return {"schema_version": 1, "id": "one-way", "nodes": [{"id": key, "map_id": "m", "floor_id": "f", **point}
                                        for key, point in (("a", path[0]), ("b", path[-1]))], "edges": [edge]}


@pytest.mark.parametrize("change", [{"step_free": None}, {"availability": "closed"},
                                    {"availability": "unknown"}, {"minimum_clear_width_m": None},
                                    {"minimum_clear_width_m": 0.85}, {"maximum_slope": None}])
def test_graph_scoring_uses_the_routing_profiles_hard_requirements(change):
    _, adjacency = evaluate._graph(one_way_graph(**change), "wheelchair")
    assert adjacency == {}


def test_graph_scores_directed_reachability_and_actual_surface_path_length():
    graph = one_way_graph()
    _, adjacency = evaluate._graph(graph, "wheelchair")
    assert adjacency == {"a": [("b", 3.0)]}
    truth = {"spaces": [{"id": key, "kind": "room", "center_m": [x, 0, 0],
                          "polygon_xz_m": [[x - 0.2, -0.2], [x + 0.2, -0.2], [x + 0.2, 0.2], [x - 0.2, 0.2]]}
                         for key, x in (("a", 0), ("b", 1))],
             "graph": {"room_adjacency": [["a", "b"]]},
             "routes": [{"profile": profile, "from_space": "a", "to_space": "b", "reachable": True, "length_m": 3}
                        for profile in ("ambulatory", "wheelchair")]}
    result = evaluate.score_nav_graph(graph, truth)
    for profile in ("ambulatory", "wheelchair"):
        assert result[f"{profile}_reachability_agreement"] == 0.5
        assert result[f"{profile}_route_length_ratio"] == 1.0
