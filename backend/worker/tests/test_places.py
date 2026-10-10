"""Places: evidence fusion from hand-built fixtures that follow the product contract."""
import copy
import json
import random

import numpy as np
import pytest

from inview_worker.contracts import PlaceCategory, ProductName
from inview_worker.core import Product, runner
from inview_worker.semantics import places
from inview_worker.stages.places import PlacesStage


def square(x0, z0, x1, z1):
    return [[x0, z0], [x1, z0], [x1, z1], [x0, z1]]


def obj(id, category, x, z, y=0.4, half=0.25):
    return {"id": id, "category": category, "center_m": [x, y, z],
            "footprint_xz_m": square(x - half, z - half, x + half, z + half)}


def door(id, a, b, kind="door"):
    return {"id": id, "kind": kind, "center_xz_m": [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], "span_xz_m": [a, b],
            "nominal_width_m": float(np.hypot(b[0] - a[0], b[1] - a[1])), "meets_clear_width": True}


def text(id, body, x, y, z, language=None, confidence=0.9):
    item = {"id": id, "text": body, "confidence": confidence, "engine": "test", "frame_id": "f0",
            "bbox_px": [0, 0, 10, 10], "position_m": [x, y, z]}
    if language:
        item["language"] = language
    return item


def building() -> places.Scene:
    """Corridor (z −1..1, x −6..6) with room A (x −6..−2) and a bathroom (x 2..6) to its south.

    Doors: exterior west door, room A door, bathroom door, elevator door on the north edge.
    """
    return places.Scene(
        floor_id="level-2",
        floor_y=0.0,
        outlines=[square(-6, -1, 6, 5)],
        rooms=[{"id": "rb", "label": "bathroom", "story": 0, "polygon_xz_m": square(2, 1, 6, 5), "floor_y_m": 0.0}],
        regions=[
            {"id": "corridor", "kind": "corridor", "polygon_xz_m": square(-6, -1, 6, 1), "centroid_xz_m": [0, 0],
             "area_m2": 24.0, "label": None, "adjacent": ["ra", "rb-region"]},
            {"id": "ra", "kind": "room", "polygon_xz_m": square(-6, 1, -2, 5), "centroid_xz_m": [-4, 3],
             "area_m2": 16.0, "label": None, "adjacent": ["corridor"]},
            {"id": "rb-region", "kind": "room", "polygon_xz_m": square(2, 1, 6, 5), "centroid_xz_m": [4, 3],
             "area_m2": 16.0, "label": None, "adjacent": ["corridor"]},
        ],
        doors=[
            door("west", [-6, -0.45], [-6, 0.45]),
            door("door-a", [-4.45, 1], [-3.55, 1]),
            door("door-b", [3.05, 1], [3.95, 1]),
            door("elevator", [-0.5, -1], [0.5, -1]),
        ],
        objects=[
            obj("toilet-1", "toilet", 5.0, 4.0), obj("toilet-2", "toilet", 5.0, 3.0), obj("sink-1", "sink", 3.0, 4.5),
            obj("sofa", "sofa", -1.0, 0.0, half=0.4), obj("chair", "chair", 0.1, 0.0),
            obj("stairs-obj", "stairs", 5.3, -0.4, y=0.5, half=0.5),
        ],
        texts=[
            text("t-room", "Room 214", -4.0, 1.6, 0.9, "en"),
            text("t-banos", "Aseos", 3.5, 1.8, 0.9, "es"),
            text("t-exit", "出口", -5.9, 2.1, 0.2, "zh"),
            text("t-asc", "Ascenseur", 0.0, 1.5, -0.95, "fr"),
            text("t-not", "NOT AN EXIT", 1.0, 1.5, 0.95, "en"),
            text("t-arrow", "Restrooms →", -2.0, 1.8, -0.95, "en"),
            {"id": "t-noplace", "text": "Information", "confidence": 0.9, "engine": "test", "frame_id": "f0",
             "bbox_px": [0, 0, 1, 1], "position_m": None},
        ],
        signs=[
            {"id": "s-elev", "category": "elevator", "pictograms": ["elevator"], "text_ids": ["t-asc"], "arrows": [],
             "languages": ["fr"], "position_m": [0.05, 1.6, -0.95], "confidence": 0.8},
            {"id": "s-wc", "category": "restroom", "pictograms": ["toilet", "wheelchair"], "text_ids": [], "arrows": [],
             "languages": [], "position_m": [3.6, 1.5, 0.95]},
            {"id": "s-dir", "category": "restroom", "pictograms": ["toilet"], "text_ids": [],
             "arrows": [{"direction_xz": [1, 0]}], "languages": [], "position_m": [-3.0, 1.8, -0.95]},
        ],
        hazards=[
            {"id": "h-stairs", "kind": "stairs", "position_m": [5.0, 0.0, -0.5], "severity": "barrier", "measure": {}},
            {"id": "h-ramp", "kind": "ramp", "position_m": [-2.0, 0.0, 4.0], "severity": "warning",
             "measure": {"slope": 0.07}},
        ],
    )


def by_category(result, category):
    return [p for p in result if p["category"] == category]


@pytest.fixture(scope="module")
def built():
    return places.build(building())


def test_every_place_follows_the_contract(built):
    result, _ = built
    assert result
    for place in result:
        assert PlaceCategory(place["category"])
        assert place["id"].startswith(f"place-{place['category']}-")
        assert place["floor_id"] == "level-2"
        assert 0 < place["confidence"] < 1
        assert len(place["position_m"]) == 3 and place["sources"] == sorted(set(place["sources"]))
        assert place["access_point_kind"] in ("elevator", "ramp", "destination")
        assert place["name"] and place["names"]["en"]
    json.dumps(result)  # serialisable
    assert len({p["id"] for p in result}) == len(result)


def test_exterior_door_is_an_entrance_and_interior_doors_are_not(built):
    result, summary = built
    entrances = by_category(result, "entrance")
    assert [p["door_id"] for p in entrances] == ["west"]
    assert entrances[0]["position_m"] == [-6.0, 0.0, 0.0]
    # door-a and door-b open onto floor on both sides; the elevator door is claimed by its sign.
    assert summary["doors_not_entrances"] == 2
    assert not any("door:elevator" in p["sources"] and p["category"] == "entrance" for p in result)


def test_room_number_names_the_room_behind_the_nearest_door(built):
    result, _ = built
    room = next(p for p in result if p.get("room_number") == "214")
    assert room["category"] == "room" and room["name"] == "Room 214"
    assert room["names"]["fr"] == "Salle 214" and room["names"]["ja"] == "214号室"
    assert room["position_m"] == [-4.0, 0.0, 3.0]            # region ra centroid, not the plate
    assert room["region_id"] == "ra" and room["door_id"] == "door-a"
    assert room["sources"] == ["region:ra", "text:t-room"]   # merged with the region's room place


def test_restroom_fuses_objects_room_label_text_and_accessible_sign(built):
    result, _ = built
    restrooms = [p for p in result if p["category"] in ("restroom", "accessible_restroom")]
    assert len(restrooms) == 1
    place = restrooms[0]
    assert place["category"] == "accessible_restroom"          # wheelchair pictogram upgrades the family
    assert set(place["sources"]) == {"roomplan:object:toilet-1", "roomplan:object:toilet-2", "roomplan:object:sink-1",
                                     "roomplan:room:rb", "region:rb-region", "sign:s-wc", "text:t-banos"}
    assert place["names"]["es"] == "Aseos"                       # what the sign says beats the lexicon name
    assert place["names"]["en"] == "Accessible restroom"
    assert place["door_id"] == "door-b"
    assert place["position_m"] == [3.5, 0.0, 1.0]                # the doorway the signs mark
    assert place["confidence"] > 0.95                            # noisy-OR of seven sources


def test_elevator_sign_snaps_to_its_door_and_uses_linked_text(built):
    result, _ = built
    (elevator,) = by_category(result, "elevator")
    assert elevator["access_point_kind"] == "elevator"
    assert elevator["position_m"] == [0.0, 0.0, -1.0]
    assert elevator["sources"] == ["sign:s-elev", "text:t-asc"]
    assert elevator["names"]["fr"] == "Ascenseur" and elevator["confidence"] == 0.8


def test_exit_text_in_chinese_snaps_to_the_exterior_door(built):
    result, _ = built
    (exit_place,) = by_category(result, "exit")
    assert exit_place["door_id"] == "west" and exit_place["names"]["zh"] == "出口"
    assert exit_place["position_m"] == [-6.0, 0.0, 0.0]


def test_negated_directional_and_unplaced_text_create_no_places(built):
    result, summary = built
    every_source = {s for p in result for s in p["sources"]}
    assert not {"text:t-not", "text:t-arrow", "text:t-noplace", "sign:s-dir"} & every_source
    assert summary["directional_signs"] == 1 and summary["unplaced_text"] == 1
    assert not by_category(result, "information")


def test_stairs_object_and_hazard_merge_and_ramp_maps_to_ios_ramp(built):
    result, _ = built
    (stairs,) = by_category(result, "stairs")
    assert stairs["sources"] == ["hazard:h-stairs", "roomplan:object:stairs-obj"]
    assert stairs["confidence"] == pytest.approx(1 - 0.25 * 0.3, abs=1e-3)
    (ramp,) = by_category(result, "ramp")
    assert ramp["access_point_kind"] == "ramp" and ramp["sources"] == ["hazard:h-ramp"]


def test_seating_and_corridor(built):
    result, _ = built
    (seating,) = by_category(result, "seating")
    assert seating["sources"] == ["roomplan:object:chair", "roomplan:object:sofa"]
    assert seating["names"]["de"] == "Sitzbereich"
    (corridor,) = by_category(result, "corridor")
    assert corridor["position_m"] == [0.0, 0.0, 0.0] and corridor["name"] == "Corridor"


def test_output_is_deterministic_under_input_reordering(built):
    result, _ = built
    shuffled = copy.deepcopy(building())
    rng = random.Random(7)
    for name in ("objects", "regions", "doors", "texts", "signs", "hazards"):
        rng.shuffle(getattr(shuffled, name))
    again, _ = places.build(shuffled)
    assert again == result


def test_place_ids_derive_from_sources():
    scene = places.Scene(texts=[text("a", "EXIT", 0, 2, 0)])
    first, _ = places.build(scene)
    moved, _ = places.build(places.Scene(texts=[text("a", "EXIT", 0.3, 2, 0)]))
    renamed, _ = places.build(places.Scene(texts=[text("b", "EXIT", 0, 2, 0)]))
    assert first[0]["id"] == moved[0]["id"] != renamed[0]["id"]


# --- dedupe -----------------------------------------------------------------------------------

def test_nearby_sightings_merge_with_noisy_or_and_distant_ones_do_not():
    near, _ = places.build(places.Scene(texts=[text("a", "EXIT", 0, 2, 0, confidence=0.6),
                                               text("b", "Salida", 1.0, 2, 0, "es", confidence=0.5)]))
    assert len(near) == 1
    assert near[0]["confidence"] == pytest.approx(1 - 0.4 * 0.5)
    assert near[0]["names"]["es"] == "Salida" and near[0]["position_m"][0] == pytest.approx(0.5 / 1.1, abs=1e-3)
    far, _ = places.build(places.Scene(texts=[text("a", "EXIT", 0, 2, 0), text("b", "EXIT", 6, 2, 0)]))
    assert len(far) == 2


def test_radius_is_category_aware():
    # 3 m apart: one restroom (radius 4 m) but two fire extinguishers (radius 1.5 m).
    wc, _ = places.build(places.Scene(texts=[text("a", "WC", 0, 2, 0), text("b", "Toilets", 3, 2, 0)]))
    fx, _ = places.build(places.Scene(texts=[text("a", "Fire extinguisher", 0, 1, 0),
                                             text("b", "Extintor", 3, 1, 0, "es")]))
    assert len(wc) == 1 and len(fx) == 2


def test_different_room_numbers_never_merge():
    scene = places.Scene(texts=[text("a", "Room 214", 0, 1.5, 0), text("b", "Room 216", 0.5, 1.5, 0)])
    result, _ = places.build(scene)
    assert sorted(p["room_number"] for p in result) == ["214", "216"]


def test_emergency_exit_absorbs_a_plain_exit_sign():
    result, _ = places.build(places.Scene(texts=[text("a", "EXIT", 0, 2, 0), text("b", "Notausgang", 1, 2, 0, "de")]))
    assert [p["category"] for p in result] == ["emergency_exit"]
    assert result[0]["names"]["de"] == "Notausgang"


# --- individual sources -------------------------------------------------------------------------

def test_object_clusters():
    scene = places.Scene(objects=[
        obj("t", "toilet", 0, 0), obj("s", "sink", 1.5, 0),                # 1 m gap: one restroom
        obj("k-sink", "sink", 10, 0),                                      # kitchen sink alone: nothing
        obj("c1", "chair", 0, 6), obj("c2", "chair", 0.8, 6), obj("tb", "table", 0.4, 6.8),
        obj("c3", "chair", 8, 6),                                          # isolated chair: its own seating
        obj("lonely-table", "table", -8, 6),                               # table without seats: nothing
        obj("fp", "fireplace", 5, -5),
    ])
    result, _ = places.build(scene)
    (restroom,) = by_category(result, "restroom")
    assert restroom["confidence"] == 0.7 and restroom["sources"] == ["roomplan:object:s", "roomplan:object:t"]
    seating = by_category(result, "seating")
    assert sorted(p["sources"] for p in seating) == [
        ["roomplan:object:c1", "roomplan:object:c2", "roomplan:object:tb"], ["roomplan:object:c3"]]
    (landmark,) = by_category(result, "landmark")
    assert landmark["name"] == "Fireplace"


def test_cluster_footprints_links_by_gap_not_centre_distance():
    long_sofa = np.array(square(0, 0, 3, 0.8))
    chair = np.array(square(3.5, 0, 4.0, 0.5))         # 0.5 m gap, 2.25 m between centres
    far_chair = np.array(square(5.5, 0, 6.0, 0.5))     # 1.5 m gap
    assert places.cluster_footprints([long_sofa, chair, far_chair], 0.9) == [1, 1, 2]


def test_entrances_fall_back_to_room_polygons_without_a_floor_map():
    scene = places.Scene(rooms=[{"id": "r", "label": "livingRoom", "polygon_xz_m": square(0, 0, 4, 4), "floor_y_m": 0.0}],
                         doors=[door("out", [1, 4], [2, 4]), door("far", [10, 10], [11, 10])])
    result, summary = places.build(scene)
    (entrance,) = by_category(result, "entrance")
    assert entrance["door_id"] == "out"
    (room,) = by_category(result, "room")
    assert room["name"] == "Living room" and room["position_m"] == [2.0, 0.0, 2.0]
    assert summary["doors_not_entrances"] == 1      # the far door touches no outline


def test_earlier_sign_shape_is_supported():
    signs = [
        {"kind": "exit_sign_candidate", "color": "green", "text": None, "score": 1.0, "position_m": [0, 2, -2],
         "observations": [], "observation_count": 1},
        {"kind": "exit_sign_candidate", "color": "red", "text": "SALIDA", "score": 0.8, "position_m": [8, 2, -2],
         "observations": [], "observation_count": 1},
        {"kind": "accessibility_sign_candidate", "color": "blue", "text": "Toilets", "score": 0.9,
         "position_m": [0, 1.5, 8], "observations": [], "observation_count": 1},
        {"kind": "accessibility_sign_candidate", "color": "blue", "text": None, "score": 0.9,
         "position_m": [8, 1.5, 8], "observations": [], "observation_count": 1},
        {"kind": "text_region", "color": None, "text": "Rm 12", "score": 0.7, "position_m": [-8, 1.5, 0],
         "observations": [], "observation_count": 1},
        {"kind": "text_region", "color": None, "text": "Exit →", "score": 0.7, "position_m": [-8, 1.5, 8],
         "observations": [], "observation_count": 1},
    ]
    result, summary = places.build(places.Scene(signs=signs))
    got = {(p["category"], tuple(p["sources"])) for p in result}
    assert got == {("exit", ("sign:0",)), ("exit", ("sign:1",)), ("accessible_restroom", ("sign:2",)),
                   ("room", ("sign:4",))}
    plain = next(p for p in result if p["sources"] == ["sign:0"])
    assert plain["position_m"] == [0.0, 2.0, -2.0] and plain["confidence"] == 0.6
    assert summary["directional_signs"] == 1


def test_contract_sign_with_room_category_reads_its_text():
    scene = places.Scene(
        texts=[text("t1", "Salle 12", 0, 1.5, 0, "fr")],
        signs=[{"id": "plate", "category": "room", "pictograms": [], "text_ids": ["t1"], "arrows": [],
                "position_m": [0, 1.5, 0], "confidence": 0.9}])
    (room,) = places.build(scene)[0]
    assert room["room_number"] == "12" and room["names"]["fr"] == "Salle 12" and room["name"] == "Room 12"
    assert room["sources"] == ["sign:plate", "text:t1"]


def test_labelled_regions_become_their_category():
    scene = places.Scene(regions=[
        {"id": "r1", "kind": "room", "polygon_xz_m": square(0, 0, 4, 4), "centroid_xz_m": [2, 2], "label": "Reception"},
        {"id": "r2", "kind": "room", "polygon_xz_m": square(5, 0, 9, 4), "centroid_xz_m": [7, 2], "label": "Studio B"},
        {"id": "r3", "kind": "doorway", "polygon_xz_m": square(4, 1, 5, 2), "centroid_xz_m": [4.5, 1.5]},
    ])
    result, _ = places.build(scene)
    assert {(p["category"], p["name"]) for p in result} == {("reception", "Reception"), ("room", "Studio B")}


# --- stage --------------------------------------------------------------------------------------

def test_stage_on_the_synthetic_package(synthetic_ctx):
    analysis = runner.run(synthetic_ctx)
    assert analysis["stages"]["places"]["status"] == "ok"
    result = analysis["places"]
    (exit_place,) = by_category(result, "exit")
    assert exit_place["position_m"] == pytest.approx([0.0, 2.0, -2.0], abs=0.1)
    assert exit_place["sources"] == ["sign:0"] and exit_place["floor_id"] == "ground"
    (entrance,) = by_category(result, "entrance")           # the door in the south wall leads outside
    assert entrance["door_id"] == "door"
    assert entrance["position_m"] == pytest.approx([1.2, 0.0, 2.0], abs=0.05)
    assert analysis["summary"]["places"]["places"] == 2


def test_stage_reads_every_optional_product(synthetic_ctx):
    synthetic_ctx.products[ProductName.TEXT] = Product([text("t", "Aufzug", -1.9, 1.5, 0.0, "de")])
    synthetic_ctx.products[ProductName.ROOMPLAN] = Product({
        "rooms": [{"id": "main", "label": "kitchen", "polygon_xz_m": square(-2, -2, 2, 2), "floor_y_m": 0.0}],
        "objects": [{"id": "rp-toilet", "category": "toilet", "center_m": [1.5, 0.4, -1.5], "dimensions_m": [0.4, 0.8, 0.7]}],
    })
    synthetic_ctx.products[ProductName.HAZARDS] = Product([{"id": "h", "kind": "ramp", "position_m": [0, 0, 1]}])
    synthetic_ctx.config["floor_id"] = "L3"
    result = PlacesStage().run(synthetic_ctx).products[ProductName.PLACES].json
    categories = {p["category"] for p in result}
    assert {"elevator", "room", "restroom", "ramp"} <= categories
    assert {p["floor_id"] for p in result} == {"L3"}
    kitchen = next(p for p in result if p["category"] == "room")
    assert kitchen["name"] == "Kitchen"


def test_stage_with_no_evidence_returns_an_empty_list():
    from inview_worker.core import ScanContext
    from inview_worker.inputs import ScanInputs
    result = PlacesStage().run(ScanContext("empty", ScanInputs("empty")))
    assert result.products[ProductName.PLACES].json == []
    assert result.notices and result.summary["places"] == 0


def test_sign_names_come_only_from_text_naming_its_category():
    scene = places.Scene(
        texts=[text("a", "Elevator", 0, 1.5, 0, "en", 0.7), text("b", "Floors 1-3", 0, 1.4, 0, "en", 0.95),
               text("c", "Exit", 0, 1.3, 0, "en", 0.99)],
        signs=[{"id": "s", "category": "elevator", "pictograms": [], "text_ids": ["a", "b", "c"], "arrows": [],
                "position_m": [0, 1.5, 0], "confidence": 0.8}])
    (place,) = places.build(scene)[0]
    assert place["name"] == "Elevator" and place["names"]["en"] == "Elevator"


# --- malformed upstream products: drop the bad component, keep every valid place -------------

NAN, INF = float("nan"), float("inf")


def _signature(result):
    places_list = result[0] if isinstance(result, tuple) else result
    return sorted((p["category"], p.get("name"), tuple(p["position_m"])) for p in places_list)


def _with_garbage(scene: places.Scene) -> places.Scene:
    bad = copy.deepcopy(scene)
    bad.rooms += [
        {"id": "odd", "label": "kitchen", "polygon_xz_m": [[0, 0], [1, 0], [1]]},          # odd-length polygon
        {"id": "nan-room", "label": "office", "polygon_xz_m": [[NAN, 0], [1, 0], [1, 1]]},
        {"id": "text-room", "label": "lab", "polygon_xz_m": "not a polygon"},
        {"id": "bad-floor", "label": "store", "polygon_xz_m": square(20, 20, 22, 22), "floor_y_m": "high"},
    ]
    bad.regions += [
        {"id": "nan-region", "kind": "room", "polygon_xz_m": [[0, 0], [1, 0]], "centroid_xz_m": [NAN, INF]},
        {"id": "short-centroid", "kind": "corridor", "polygon_xz_m": [], "centroid_xz_m": [1]},
    ]
    bad.doors += [
        {"id": "bad-span", "kind": "door", "center_xz_m": [30, 30], "span_xz_m": [[1, 2, 3]]},
        {"id": "nan-span", "kind": "door", "span_xz_m": [[NAN, 0], [1, 0]]},
        {"id": "no-geometry", "kind": "door"},
        {"id": "inf-center", "kind": "door", "center_xz_m": [INF, 0]},
    ]
    bad.objects += [
        {"id": "nan-toilet", "category": "toilet", "center_m": [NAN, 0, 0]},
        {"id": "short-toilet", "category": "toilet", "center_m": [1, 2]},
        {"id": "odd-chair", "category": "chair", "center_m": [40, 0.4, 40], "footprint_xz_m": [[0, 0], [1]]},
    ]
    bad.texts += [text("t-nan", "Exit", NAN, 1.5, 0), {"id": "t-str", "text": "Lift", "position_m": "here",
                                                      "confidence": "high"}]
    bad.signs += [{"id": "s-nan", "category": "exit", "position_m": [0, INF, 0], "score": NAN}]
    bad.hazards += [{"id": "h-bad", "kind": "ramp", "position_m": [None, 0, 0]}]
    bad.outlines += [[[0, 0], [1, 1], [2]]]
    return bad


def test_malformed_components_are_skipped_without_losing_valid_places():
    clean = places.build(building())
    noisy = places.build(_with_garbage(building()))
    garbage_names = {"kitchen", "office", "lab"}
    survivors = [p for p in _signature(noisy) if p[1] not in garbage_names]
    # The one well-formed extra room (finite polygon, unreadable floor height) is still a place,
    # placed at the scene floor height instead of failing.
    store = [p for p in survivors if p[1] == "store"]
    assert len(store) == 1 and store[0][2][1] == 0.0
    # A chair with a valid centre but a malformed footprint keeps a default footprint (seating).
    chair = [p for p in survivors if p[2] == (40.0, 0.4, 40.0)]
    assert [p[0] for p in chair] == ["seating"]
    assert [p for p in survivors if p not in store + chair] == _signature(clean)


@pytest.mark.parametrize("polygon", [[[0, 0], [1, 0], [1]], [[0, 0, 0]], [[NAN, 1], [2, 2], [3, 0]], "x", None, []])
def test_contour_rejects_malformed_polygons(polygon):
    assert places._contour(polygon) is None
    assert places.polygon_centroid(polygon) is None


def test_stage_survives_malformed_products(synthetic_ctx):
    from inview_worker.core import Product
    synthetic_ctx.products[ProductName.FLOOR_MAP] = Product({"floor_height_m": NAN, "outlines": [{"polygon_xz_m": [[1]]}, 7]})
    synthetic_ctx.products[ProductName.DOORS] = Product([{"id": "d", "span_xz_m": [[0, 0], [NAN, 1]]}, "junk", None])
    synthetic_ctx.products[ProductName.ROOMPLAN] = Product({"rooms": [None, {"id": "r", "polygon_xz_m": [[0, 1, 2]]}],
                                                            "objects": [{"id": "o", "center_m": [INF, 0, 0]}, 3]})
    synthetic_ctx.products[ProductName.REGIONS] = Product("not a list")
    synthetic_ctx.products[ProductName.SIGNS] = Product([{"kind": "exit_sign_candidate", "position_m": [0, 2, -2],
                                                          "score": "n/a"}])
    result = PlacesStage().run(synthetic_ctx)
    assert any(p["category"] in ("exit", "emergency_exit") for p in result.products[ProductName.PLACES].json)
