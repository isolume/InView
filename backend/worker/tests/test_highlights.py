"""Key-aspect highlights: ranking decisions, OpenCV rendering, and the stage on the synthetic scan."""
from __future__ import annotations

import base64
import math

import cv2
import numpy as np
import pytest

from inview_worker.highlights import Highlight, Options, collect, render_scene
from inview_worker.highlights.render import SEVERITY_COLORS, ascii_text
from inview_worker.pipeline import analyze

from routes_fixtures import products

GRID = {"origin_xz_m": [0.0, 0.0], "resolution_m": 0.05, "width": 400, "height": 240}


def passage(x, z, width=0.5):
    return {"center_xz_m": [x, z], "min_clear_width_m": width, "length_m": 1.0, "required_min_m": 0.915}


def hazard(kind="stairs", x=5.0, z=5.0, severity="barrier", **measure):
    return {"id": f"{kind}-0", "kind": kind, "position_m": [x, 0.0, z], "severity": severity,
            "polygon_xz_m": [[x - 1, z - 1], [x + 1, z - 1], [x + 1, z + 1], [x - 1, z + 1]], "measure": measure}


def place(category, x, z, name=None, pid=None, confidence=0.9):
    return {"id": pid or f"place-{category}", "category": category, "name": name, "position_m": [x, 0.0, z],
            "confidence": confidence}


def titles(items):
    return [h.title for h in items]


# ---- ranking ----

def test_barriers_outrank_the_things_you_want_to_find():
    items = collect(hazards=[hazard("stairs", risers=14, total_rise_m=2.4)],
                    places=[place("elevator", 9, 9), place("restroom", 3, 3)])
    assert items[0].title == "Stairs" and items[0].severity == "barrier"
    assert items[0].reason == "14 risers, 2.4 m rise"
    assert [h.id for h in items] == ["hl-barrier-1", "hl-access_feature-1", "hl-access_feature-2"]
    assert [h.rank for h in items] == [1, 2, 3]
    assert items[1].title.lower() == "elevator"  # accessible assets before ordinary amenities


def test_a_narrower_passage_matters_more():
    floor_map = {"narrow_passages": [passage(1, 1, 0.88), passage(10, 10, 0.40)]}
    items = collect(floor_map=floor_map)
    assert [h.evidence["min_clear_width_m"] for h in items] == [0.40, 0.88]
    assert items[0].importance > items[1].importance > 0.55
    # Under the 0.815 m door minimum is a barrier; between that and 0.915 m a warning.
    assert items[0].severity == "barrier" and items[1].severity == "warning"


def test_readings_of_one_squeeze_collapse_to_the_narrowest():
    floor_map = {"narrow_passages": [passage(1.0, 1.0, 0.6), passage(1.8, 1.2, 0.3), passage(2.4, 1.0, 0.5),
                                     passage(20, 20, 0.7)]}
    items = collect(floor_map=floor_map)
    assert len(items) == 2
    merged = next(h for h in items if h.evidence.get("merged"))
    assert merged.evidence["min_clear_width_m"] == 0.3 and merged.evidence["merged"] == 3
    assert "+2 more nearby" in merged.reason


def test_one_kind_cannot_crowd_out_the_rest():
    floor_map = {"narrow_passages": [passage(10 * i, 0, 0.3) for i in range(1, 11)]}
    items = collect(floor_map=floor_map, hazards=[hazard("stairs", x=-20, z=-20)],
                    places=[place("elevator", -30, 0)], options=Options(max_items=4))
    assert "Stairs" in titles(items)
    assert any(h.evidence.get("category") == "elevator" for h in items)
    assert sum(h.kind == "narrow_passage" for h in items) <= 3


def test_a_place_on_a_measured_structure_is_not_listed_twice():
    items = collect(hazards=[hazard("stairs", x=5, z=5), hazard("ramp", x=20, z=20, running_slope=0.1)],
                    places=[place("stairs", 5.5, 5.2, pid="p-stairs"), place("ramp", 20.5, 20, pid="p-ramp"),
                            place("stairs", 60, 60, pid="p-far")])
    from_places = [(h.evidence["category"], h.severity) for h in items if h.evidence.get("from_place")]
    # Only the stairs place that is NOT on a measured hazard survives, as an unmeasured warning.
    assert from_places == [("stairs", "warning")]
    assert next(h for h in items if h.title == "Steep ramp").severity == "barrier"


def test_doors_only_appear_when_something_is_wrong_with_them():
    doors = [
        {"id": "d-ok", "kind": "door", "center_xz_m": [1, 1], "measured_clear_width_m": 0.95,
         "required_min_clear_width_m": 0.815, "meets_clear_width": True, "meets_headroom": True},
        {"id": "d-narrow", "kind": "door", "center_xz_m": [2, 2], "measured_clear_width_m": 0.6,
         "required_min_clear_width_m": 0.815, "meets_clear_width": False, "span_xz_m": [[1.7, 2], [2.3, 2]]},
        {"id": "d-unknown", "kind": "door", "center_xz_m": [3, 3], "measured_clear_width_m": None,
         "meets_clear_width": None},
    ]
    items = collect(doors=doors)
    assert [h.refs["door_id"] for h in items] == ["d-narrow"] or set(h.refs["door_id"] for h in items) == {"d-narrow", "d-unknown"}
    narrow = next(h for h in items if h.refs["door_id"] == "d-narrow")
    assert narrow.severity == "barrier" and narrow.geometry["type"] == "segment"
    assert next(h for h in collect(doors=doors, options=Options(min_importance=0.0)) if h.refs["door_id"] == "d-unknown").severity == "info"
    everything = collect(doors=doors, options=Options(include_passing_doors=True, min_importance=0.0))
    assert {h.refs["door_id"] for h in everything} == {"d-ok", "d-narrow", "d-unknown"}


def test_unreachable_destinations_are_one_finding_per_origin():
    nav = {"nodes": [{"id": "a", "x": 0.0, "z": 0.0}, {"id": "b", "x": 10.0, "z": 0.0},
                     {"id": "c", "x": 20.0, "z": 0.0}, {"id": "d", "x": 30.0, "z": 0.0}]}
    routes = {"endpoints": [{"id": "e1", "node_id": "a", "name": "Entrance"}, {"id": "e2", "node_id": "b", "name": "Room 1"},
                            {"id": "e3", "node_id": "c", "name": "Room 2"}, {"id": "e4", "node_id": "d", "name": "Room 3"}],
              "unreachable": [{"from_place": "e1", "to_place": t, "profile": "wheelchair",
                               "limiting_requirements": ["maximum_slope"]} for t in ("e2", "e3", "e4")],
              "routes": []}
    items = collect(routes=routes, nav_graph=nav)
    assert len(items) == 1
    item = items[0]
    assert item.title == "No wheelchair route from Entrance"
    assert "Room 1, Room 2, Room 3" in item.reason and "maximum_slope" in item.reason
    assert item.evidence["unreachable"] == 3 and item.geometry["dashed"]


def test_filters_and_determinism():
    data = dict(floor_map={"narrow_passages": [passage(1, 1, 0.5)]}, hazards=[hazard("drop_off", rise_m=0.3)],
                places=[place("exit", 5, 5)])
    everything = collect(**data)
    assert [h.to_json() for h in everything] == [h.to_json() for h in collect(**data)]
    only = collect(**data, options=Options(kinds=("access_feature",)))
    assert [h.kind for h in only] == ["access_feature"]
    assert collect(**data, options=Options(min_importance=0.99)) == []
    assert len(collect(**data, options=Options(max_items=1))) == 1


def test_tolerates_missing_and_malformed_products():
    assert collect() == []
    junk = collect(floor_map="x", doors=[None, 3, {"center_xz_m": "bad"}], hazards=[{"kind": "stairs"}, "x"],
                   places=[{"category": "elevator", "position_m": [float("nan"), 0, 1]}], signs={"a": 1},
                   routes=[1], nav_graph=7)
    assert junk == []


def test_options_are_clamped_and_never_raise():
    o = Options.from_config({"highlights": {"max_items": 9999, "min_importance": "high", "callouts": -3,
                                            "width_px": float("nan"), "kinds": ["door", 7]}})
    assert (o.max_items, o.callouts, o.width_px) == (100, 0, 1400)
    assert o.min_importance == 0.30 and o.kinds == ("door", "7")
    assert Options.from_config(None) == Options()


def test_fixture_products_surface_the_door_and_the_drop_off():
    p = products()
    items = collect(doors=p["doors"], hazards=p["hazards"], places=p["places"], signs=p["signs"], nav_graph=p["nav_graph"])
    assert any(h.kind == "door" and h.severity == "barrier" for h in items)
    assert any(h.evidence.get("hazard_kind") == "drop_off" for h in items)
    assert items[0].severity == "barrier"


# ---- rendering ----

def base_image(width=400, height=240):
    image = np.zeros((height, width, 4), np.uint8)
    image[20:height - 20, 20:width - 20] = (246, 246, 244, 255)       # walkable
    image[:, :20] = image[:, width - 20:] = (70, 64, 60, 255)         # walls
    return image


def item(kind, severity, importance, x, z, geometry=None, title="Thing", reason="Why"):
    h = Highlight(kind, severity, importance, title, reason, [x, z], None, geometry or {"type": "point", "xz": [[x, z]]})
    return h


def numbered(items):
    for i, h in enumerate(items, start=1):
        h.id, h.rank = f"hl-{i}", i
    return items


def test_render_returns_a_png_with_the_documented_geometry():
    items = numbered([item("barrier", "barrier", 0.9, 5, 5, {"type": "polygon", "xz": [[4, 4], [6, 4], [6, 6], [4, 6]]},
                           "Stairs", "14 risers"),
                      item("access_feature", "asset", 0.8, 15, 8, title="Elevator")])
    png, meta = render_scene(base_image(), GRID, items, [[[1.0, 1.0], [10.0, 1.0]]], Options())
    image = cv2.imdecode(np.frombuffer(png, np.uint8), cv2.IMREAD_COLOR)
    assert image.shape[1] == meta["width"] and image.shape[0] == meta["height"]
    assert meta["legend"]["x"] == meta["map_width_px"] and meta["width"] == meta["map_width_px"] + meta["legend"]["width"]
    assert meta["resolution_m_per_px"] == pytest.approx(0.05 / meta["scale"], rel=1e-3)
    ax, az = meta["items"]["hl-1"]["anchor_px"]
    assert ax == pytest.approx(5 / meta["resolution_m_per_px"], abs=2) and az == pytest.approx(5 / meta["resolution_m_per_px"], abs=2)
    assert meta["items"]["hl-1"]["number"] == 1 and meta["items"]["hl-2"]["number"] == 2


def test_severity_colours_are_drawn_where_the_item_is():
    items = numbered([item("barrier", "barrier", 0.9, 10, 6, {"type": "circle", "xz": [[10, 6]], "radius_m": 1.0})])
    png, meta = render_scene(base_image(), GRID, items, None, Options())
    image = cv2.imdecode(np.frombuffer(png, np.uint8), cv2.IMREAD_COLOR)
    r = meta["resolution_m_per_px"]
    cx, cy = int(10 / r), int(6 / r)
    ring = image[cy - int(1.0 / r) - 3: cy + int(1.0 / r) + 4, cx - int(1.0 / r) - 3: cx + int(1.0 / r) + 4]
    red = np.array(SEVERITY_COLORS["barrier"])
    assert (np.abs(ring.astype(int) - red).max(axis=2) < 30).any()


def test_the_spotlight_quiets_the_plan_away_from_findings():
    plain, plain_meta = render_scene(base_image(), GRID, [], None, Options())
    items = numbered([item("barrier", "barrier", 0.9, 17, 10, title="Drop-off")])
    lit, meta = render_scene(base_image(), GRID, items, None, Options())
    decode = lambda b: cv2.imdecode(np.frombuffer(b, np.uint8), cv2.IMREAD_GRAYSCALE)
    p, l = decode(plain), decode(lit)
    r = meta["resolution_m_per_px"]
    far_wall = (int(0.5 / r), int(6 / r))            # a dark wall pixel, 16 m from the finding
    near_wall = (int(19.5 / r), int(10 / r))          # the wall right beside it
    assert int(l[far_wall[1], far_wall[0]]) > int(p[far_wall[1], far_wall[0]]) + 15
    assert abs(int(l[near_wall[1], near_wall[0]]) - int(p[near_wall[1], near_wall[0]])) < 40


def test_callouts_never_overlap_even_when_everything_is_in_one_place():
    items = numbered([item("barrier", "warning", 0.9 - i * 0.01, 10 + (i % 3) * 0.05, 6, title=f"Item {i}")
                      for i in range(18)])
    _, meta = render_scene(base_image(), GRID, items, None, Options(callouts=18))
    centres = [v["callout_px"] for v in meta["items"].values() if v["callout_px"]]
    assert len(centres) == 18
    smallest = min(math.dist(a, b) for i, a in enumerate(centres) for b in centres[i + 1:])
    assert smallest >= 2 * 11, f"badges overlap ({smallest:.1f}px apart)"


def test_text_outside_ascii_is_folded_not_dropped_or_crashed():
    assert ascii_text("Café Zürich") == "Cafe Zurich"
    assert ascii_text("出口 EXIT") == "?? EXIT"
    items = numbered([item("wayfinding", "info", 0.5, 5, 5, title="出口 / Sortie", reason="Sign à lire")])
    png, _ = render_scene(base_image(), GRID, items, None, Options())
    assert png.startswith(b"\x89PNG")


def test_degenerate_inputs_render():
    png, meta = render_scene(np.zeros((1, 1, 4), np.uint8), {"origin_xz_m": [0, 0], "resolution_m": 0.05},
                             numbered([item("barrier", "barrier", 0.9, 0, 0)]), None, Options())
    assert cv2.imdecode(np.frombuffer(png, np.uint8), cv2.IMREAD_COLOR) is not None
    assert meta["width"] >= 1


# ---- the stage ----

def test_stage_publishes_a_ranked_scene_for_the_synthetic_scan(synthetic_ctx):
    synthetic_ctx.config["highlights"] = {"max_items": 6, "callouts": 4}
    result = analyze(synthetic_ctx)
    assert result["stages"]["highlights"]["status"] == "ok", result["stages"]["highlights"]
    h = result["highlights"]
    assert h["schema_version"] == 1 and 1 <= len(h["items"]) <= 6
    assert [i["rank"] for i in h["items"]] == list(range(1, len(h["items"]) + 1))
    assert h["counts"]["total"] == len(h["items"])
    assert sum(h["counts"]["by_kind"].values()) == len(h["items"])
    # The 2.0 m door is below the 2.03 m headroom: it must be among the findings.
    assert any(i["kind"] == "door" for i in h["items"]), [i["title"] for i in h["items"]]
    image = cv2.imdecode(np.frombuffer(base64.b64decode(h["image"]["png_base64"]), np.uint8), cv2.IMREAD_COLOR)
    assert image.shape[:2] == (h["image"]["height"], h["image"]["width"])
    numbered_items = [i for i in h["items"] if i.get("number")]
    assert len(numbered_items) == min(4, len(h["items"]))
    for i in h["items"]:
        x, y = i["anchor_px"]
        assert 0 <= x < h["image"]["map_width_px"] and 0 <= y < h["image"]["map_height_px"]
    assert result["summary"]["highlights"]["items"] == len(h["items"])


def test_stage_is_skipped_without_a_floor_map():
    from inview_worker.core import ScanContext, registry, runner
    from inview_worker.inputs import ScanInputs

    ctx = ScanContext("scan", ScanInputs("scan"))
    stage = next(s for s in registry.stages() if s.name == "highlights")
    analysis = runner.run(ctx, [stage])
    assert "highlights" not in analysis and "highlights" not in ctx.products
    assert analysis["stages"]["highlights"] == {"status": "skipped", "missing": ["floor_map"]}
