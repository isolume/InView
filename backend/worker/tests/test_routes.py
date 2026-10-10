import json
from dataclasses import replace

import numpy as np
import pytest

from inview_worker.core import Product, ScanContext, registry, runner
from inview_worker.guidance import (AMBULATORY, LOW_VISION, WHEELCHAIR, NavGraph, Requirements, build_routes,
                                    find_route)
from inview_worker.guidance import geometry as geo
from inview_worker.guidance import i18n, maneuvers
from inview_worker.guidance.endpoints import Endpoint, select_pairs
from inview_worker.guidance.graph import eligible
from inview_worker.inputs import ScanInputs
from routes_fixtures import NODES, PLACES, nav_graph, products

RLM, FSI, PDI = "‏", "⁨", "⁩"
# Only "office" is a dead end, so the farthest same-floor pair (m, stairs-bottom) is added.
EXTREMITIES = ["m", "office", "stairs-bottom"]


def routes_for(**overrides):
    args = {**products(), **overrides}
    product, summary = build_routes(**args, languages=("en", "es", "ar"))
    return {route["id"]: route for route in product["routes"]}, product, summary


# --- backend semantics and profiles -----------------------------------------------------------

def test_eligibility_mirrors_backend_rules():
    graph = NavGraph.from_json(nav_graph())
    stairs = next(e for e in graph.edges if e.kind == "transition")
    narrow = next(e for e in graph.edges if e.id == "j__restroom")
    assert not eligible(stairs, Requirements(requires_step_free=True))
    assert eligible(stairs, Requirements())
    assert not eligible(narrow, WHEELCHAIR.requirements) and eligible(narrow, AMBULATORY.requirements)
    doc = nav_graph()
    doc["edges"][0].pop("availability")                      # missing availability is "unknown"
    doc["edges"][1]["minimum_clear_width_m"] = None          # unknown width never satisfies a minimum
    doc["edges"][2]["availability"] = "closed"
    graph = NavGraph.from_json(doc)
    assert not eligible(graph.edges[0], Requirements())
    assert not eligible(graph.edges[1], Requirements(minimum_clear_width_m=0.5))
    assert not eligible(graph.edges[2], Requirements())


def test_profiles_filter_narrow_door_and_stairs():
    routes, product, _ = routes_for()
    wheelchair = routes["wheelchair:place-entrance->place-restroom"]
    walking = routes["ambulatory:place-entrance->place-restroom"]
    assert wheelchair["node_ids"] == ["entrance", "j", "k", "m", "restroom"]
    assert walking["node_ids"] == ["entrance", "j", "restroom"]
    assert wheelchair["estimated_seconds"] == pytest.approx(30 / 0.8)
    assert walking["estimated_seconds"] == pytest.approx(18 / 1.2)
    assert wheelchair["detour_ratio"] == pytest.approx(30 / 18, abs=1e-3)
    assert routes["ambulatory:place-entrance->place-office"]["node_ids"] == [
        "entrance", "stairs-bottom", "stairs-top", "office"]
    assert routes["ambulatory:place-entrance->place-office"]["estimated_seconds"] == pytest.approx(9 / 1.2 + 12)
    assert "wheelchair:place-entrance->place-office" not in routes
    blocked = [u for u in product["unreachable"] if u["profile"] == "wheelchair"]
    assert {(u["from_place"], u["to_place"]) for u in blocked} == {("place-entrance", "place-office"),
                                                                  ("place-restroom", "place-office")}
    assert all(u["limiting_requirements"] == ["requires_step_free"] for u in blocked)
    assert product["reachability"]["wheelchair"] == {"pairs": 3, "routed": 1, "unreachable": 2, "fraction": 0.333}
    assert product["reachability"]["ambulatory"]["fraction"] == 1.0


def test_low_vision_avoids_hazards_but_reports_true_seconds():
    routes, _, _ = routes_for()
    low_vision = routes["low_vision:place-entrance->place-restroom"]
    assert low_vision["node_ids"] == ["entrance", "j", "k", "m", "restroom"]
    assert low_vision["estimated_seconds"] == pytest.approx(30.0) and low_vision["cost"] > 30.0
    routes, _, _ = routes_for(hazards=[])
    assert routes["low_vision:place-entrance->place-restroom"]["node_ids"] == ["entrance", "j", "restroom"]


def test_requirements_are_never_relaxed():
    graph = NavGraph.from_json(nav_graph())
    assert find_route(graph, WHEELCHAIR, "entrance", "office") is None
    strict = replace(WHEELCHAIR, requirements=replace(WHEELCHAIR.requirements, minimum_clear_width_m=1.7))
    assert find_route(graph, strict, "entrance", "restroom") is None  # 1.6 m detour no longer qualifies
    with pytest.raises(KeyError):
        find_route(graph, AMBULATORY, "entrance", "nowhere")


def test_equal_cost_ties_follow_backend_queue_order():
    # Two identical 2-edge paths a->b->d and a->c->d: the backend pops lower node indices first and
    # relaxes strictly, so the path through the earlier-indexed node wins.
    doc = {"schema_version": 1, "id": "tie", "nodes": [], "edges": []}
    for i, (name, x, z) in enumerate([("a", 0, 0), ("b", 1, 1), ("c", 1, -1), ("d", 2, 0)]):
        doc["nodes"].append({"id": name, "map_id": "m", "floor_id": "f", "x": x, "y": 0, "z": z})
    for source, target in [("a", "c"), ("a", "b"), ("c", "d"), ("b", "d")]:
        a, b = (next(n for n in doc["nodes"] if n["id"] == k) for k in (source, target))
        doc["edges"].append({"id": f"{source}{target}", "from": source, "to": target, "availability": "available",
                             "segment": {"type": "surface", "map_id": "m", "floor_id": "f",
                                         "path_points": [{k: a[k] for k in "xyz"}, {k: b[k] for k in "xyz"}]}})
    assert find_route(NavGraph.from_json(doc), AMBULATORY, "a", "d").node_ids == ["a", "b", "d"]


# --- guidance ---------------------------------------------------------------------------------

def test_english_instructions_are_deterministic():
    routes, _, _ = routes_for()
    steps = routes["ambulatory:place-entrance->place-restroom"]["instructions"]["en"]
    assert [s["text"] for s in steps] == [
        "Start at Main Entrance, then continue for 10 meters.",
        "Turn right after the EXIT sign, then continue for 2 meters.",
        "Caution: a drop-off in 2 meters.",
        "Go through the narrow door (0.78 m clear), then continue for 2 meters.",
        "Arrive at the restroom, straight ahead.",
    ]
    assert [s["maneuver"] for s in steps] == ["depart", "right", "caution", "pass_door", "arrive"]
    assert [s["distance_m"] for s in steps] == [10.0, 2.0, 4.0, 2.0, 0.0]
    assert steps[1]["position_m"] == [10.0, 0.0, 0.0] and steps[1]["landmark"] == "the EXIT sign"
    wheelchair = routes["wheelchair:place-entrance->place-restroom"]["instructions"]["en"]
    assert wheelchair[-1]["text"] == "Arrive at the restroom, on your left."
    office = routes["ambulatory:place-entrance->place-office"]["instructions"]["en"]
    assert office[1]["text"] == "Take the stairs up to floor upper, then continue for 5 meters."
    assert office[1]["maneuver"] == "stairs"


def test_spanish_instructions():
    routes, _, _ = routes_for()
    steps = routes["ambulatory:place-entrance->place-restroom"]["instructions"]["es"]
    assert [s["text"] for s in steps] == [
        "Sal desde Entrada principal y continúa 10 metros.",
        "Gira a la derecha tras el letrero «EXIT» y continúa 2 metros.",
        "Precaución: un borde con caída a 2 metros.",
        "Atraviesa la puerta estrecha (0,78 m de paso libre) y continúa 2 metros.",
        "Destino alcanzado: los aseos, justo delante.",
    ]


def test_arabic_instructions_are_rtl_with_isolated_names_and_native_digits():
    routes, product, _ = routes_for()
    steps = routes["ambulatory:place-entrance->place-restroom"]["instructions"]["ar"]
    assert [s["text"] for s in steps] == [
        f"{RLM}ابدأ من {FSI}المدخل الرئيسي{PDI}، ثم تابع لمسافة ١٠ أمتار.",
        f"{RLM}انعطف يمينًا بعد لافتة {FSI}EXIT{PDI}، ثم تابع لمسافة مترين.",
        f"{RLM}تنبيه: حافة منحدرة على بُعد مترين.",
        f"{RLM}اعبر الباب الضيق (عرضه الصافي ٠٫٧٨ م)، ثم تابع لمسافة مترين.",
        f"{RLM}وصلت إلى دورة المياه، أمامك مباشرةً.",
    ]
    assert {"code": "ar", "direction": "rtl"} in product["languages"]


def test_landmark_anchoring_relation_and_radius():
    routes, _, _ = routes_for()
    turn = routes["ambulatory:place-entrance->place-restroom"]["steps"][1]
    assert turn["landmark"]["id"] == "sign-exit" and turn["landmark"]["relation"] == "after"
    beyond = [{**products()["signs"][0], "position_m": [11.5, 2.2, -0.5]}]  # past the corner, straight on
    routes, _, _ = routes_for(signs=beyond)
    step = routes["ambulatory:place-entrance->place-restroom"]["instructions"]["en"][1]
    assert step["text"].startswith("Turn right before the EXIT sign")
    far = [{**products()["signs"][0], "position_m": [3.0, 2.2, -0.5]}]
    routes, _, _ = routes_for(signs=far)
    assert routes["ambulatory:place-entrance->place-restroom"]["steps"][1]["landmark"] is None
    upstairs = [{**products()["signs"][0], "position_m": [9.4, 6.5, -0.6]}]  # another storey
    routes, _, _ = routes_for(signs=upstairs)
    assert routes["ambulatory:place-entrance->place-restroom"]["steps"][1]["landmark"] is None


def test_unread_sign_falls_back_to_category():
    routes, _, _ = routes_for(text=[])
    step = routes["ambulatory:place-entrance->place-restroom"]["instructions"]["en"][1]
    assert step["landmark"] == "the exit sign"


def test_output_is_deterministic():
    first = build_routes(**products())
    second = build_routes(**products())
    assert json.dumps(first, sort_keys=True, ensure_ascii=False) == json.dumps(second, sort_keys=True, ensure_ascii=False)


def test_turn_thresholds_match_ios():
    assert maneuvers.classify(29.9, True) is None
    assert maneuvers.classify(30.0, False) == "slight_left"
    assert maneuvers.classify(59.9, True) == "slight_right"
    assert maneuvers.classify(60.0, True) == "right"
    assert maneuvers.classify(150.0, False) == "u_turn"
    # +X then +Z is a right turn (positive cross product), as in iOS Maneuver.
    angle, right = geo.turn_angle(np.array([1.0, 0.0]), np.array([0.0, 1.0]))
    assert angle == pytest.approx(90.0) and right


def _steps_for(points):
    nodes = [{"id": f"n{i}", "map_id": "m", "floor_id": "f", "x": p[0], "y": 0.0, "z": p[1]} for i, p in
             enumerate([points[0], points[-1]])]
    edge = {"id": "e", "from": "n0", "to": "n1", "availability": "available",
            "segment": {"type": "surface", "map_id": "m", "floor_id": "f",
                        "path_points": [{"x": x, "y": 0.0, "z": z} for x, z in points]}}
    graph = NavGraph.from_json({"schema_version": 1, "id": "g", "nodes": nodes, "edges": [edge]})
    return maneuvers.build_steps(graph, graph.edges, None, None, maneuvers.Features())


def test_jitter_is_simplified_away_and_short_jogs_merge():
    rng = np.random.default_rng(7)
    xs = np.linspace(0, 12, 61)
    noisy = [(float(x), float(z)) for x, z in zip(xs, rng.normal(0, 0.05, xs.size))]
    assert [s["maneuver"] for s in _steps_for(noisy)] == ["depart", "arrive"]
    jog = [(0, 0), (5, 0), (5.5, 0.6), (11, 0.6)]          # sidestep through a doorway: no turn
    assert [s["maneuver"] for s in _steps_for(jog)] == ["depart", "arrive"]
    corner = [(0, 0), (5, 0), (5.7, 0.7), (5.7, 6)]         # two 45 deg bends 1 m apart: one right turn
    steps = _steps_for(corner)
    assert [s["maneuver"] for s in steps] == ["depart", "right", "arrive"]
    assert sum(s["distance_m"] for s in steps) == pytest.approx(5 + 0.99 + 5.3, abs=0.05)


# --- i18n -------------------------------------------------------------------------------------

def test_plural_rules_and_number_formatting():
    ar, es, fr, en = (i18n.load(code) for code in ("ar", "es", "fr", "en"))
    assert [i18n.plural_category("ar", n) for n in (0, 1, 2, 3, 10, 11, 99, 100, 102)] == [
        "zero", "one", "two", "few", "few", "many", "many", "other", "other"]
    assert i18n.plural_category("fr", 0) == "one" and i18n.plural_category("en", 0) == "other"
    assert i18n.plural_category("en", 1, 1) == "other"   # "1.0 meters"
    assert es.format_number(1234) == "1234" and es.format_number(12345) == "12.345"
    assert en.format_number(12345.678, 2) == "12,345.68"
    assert ar.format_number(1.5, 1) == "١٫٥"
    assert ar.message("distance", n=i18n.Number(1)) == "متر واحد"
    assert ar.message("distance", n=i18n.Number(11)) == "١١ مترًا"
    assert fr.message("distance", n=i18n.Number(1)) == "1 mètre"


def test_message_parser_supports_select_plural_and_exact_matches():
    locale = i18n.Locale("en", "ltr", {}, {"m": "{n, plural, =0 {none} one {# item} other {# items}} {k, select, a {A} other {?}}"})
    assert locale.message("m", n=0, k="a") == "none A"
    assert locale.message("m", n=1, k="b") == "1 item ?"
    assert locale.message("m", n=i18n.Number(2.5, 1), k="a") == "2.5 items A"
    for bad in ("{n, plural, one {x}}", "{n", "{n, date}"):
        with pytest.raises(ValueError):
            i18n.parse(bad)


def test_every_locale_has_the_english_keys():
    reference = i18n.load("en")
    assert set(i18n.available_languages()) >= {"en", "es", "fr", "de", "zh", "ar", "hi"}
    for code in i18n.available_languages():
        locale = i18n.load(code)
        assert set(locale.messages) == set(reference.messages), code
        for table in ("place_phrases", "sign_categories", "hazards"):
            assert set(locale.tables[table]) == set(reference.tables[table]), (code, table)


# --- endpoints and the stage ------------------------------------------------------------------

def test_endpoint_fallbacks_without_places():
    regions = [{"id": "r-hall", "kind": "corridor", "centroid_xz_m": [8.0, 0.2], "label": "Hall"},
               {"id": "r-wc", "kind": "room", "centroid_xz_m": [10.0, 9.0], "label": None},
               {"id": "r-door", "kind": "doorway", "centroid_xz_m": [10.0, 6.0]}]
    _, product, summary = routes_for(places=[], regions=regions)
    assert summary["endpoint_source"] == "regions"
    assert [e["id"] for e in product["endpoints"]] == ["region:r-hall", "region:r-wc"]
    _, product, summary = routes_for(places=[], regions=[])
    assert summary["endpoint_source"] == "graph_extremities"
    assert [e["node_id"] for e in product["endpoints"]] == EXTREMITIES
    assert all(r["from_place"].startswith("node:") for r in product["routes"])


def test_pair_selection_prioritises_entrances_and_caps():
    endpoints = [Endpoint(f"p{i}", "place", f"n{i}", 0.0, category) for i, category in
                 enumerate(["room", "entrance", "restroom", "room", "elevator"])]
    pairs, dropped = select_pairs(endpoints, 5)
    assert [(a.id, b.id) for a, b in pairs[:4]] == [("p1", "p2"), ("p1", "p4"), ("p1", "p0"), ("p1", "p3")]
    assert (pairs[4][0].id, pairs[4][1].id) == ("p2", "p4") and dropped == 5


def test_unmapped_places_are_reported():
    far = [*PLACES, {"id": "place-far", "category": "seating", "position_m": [60.0, 0.0, 60.0], "floor_id": "ground"}]
    _, product, _ = routes_for(places=far)
    assert product["unmapped_places"] == [{"id": "place-far", "reason": "no graph node within snap distance"}]


def test_stage_runs_in_pipeline_and_skips_without_graph():
    registry.discover()
    stage = next(s for s in registry.stages() if s.name == "routes")
    ctx = ScanContext("scan", ScanInputs("scan"))
    assert runner.run(ctx, [stage])["stages"]["routes"] == {"status": "skipped", "missing": ["nav_graph"]}
    ctx = ScanContext("scan", ScanInputs("scan"), config={"routes_languages": ["en"], "routes_max_pairs": 2})
    for name, value in products().items():
        ctx.products[name] = Product(value)
    analysis = runner.run(ctx, [stage])
    assert analysis["stages"]["routes"]["status"] == "ok"
    assert analysis["summary"]["routes"]["pairs"] == 2 and analysis["summary"]["routes"]["pairs_truncated"] == 1
    assert set(analysis["routes"]["routes"][0]["instructions"]) == {"en"}
    json.dumps(analysis)  # publishable
