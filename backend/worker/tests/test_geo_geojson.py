"""GeoJSON export: RFC 7946 validity, OpenCV simplification, feature mapping, and the stage."""
import json

import numpy as np
import pytest

from inview_worker.contracts import ProductName
from inview_worker.core import Product, runner
from inview_worker.geo import LocalProjection, geojson
from inview_worker.stages.geojson import GeojsonStage

GEOREF = {"latitude": 33.7756, "longitude": -84.3963, "heading_degrees": 90.0, "horizontal_accuracy_m": 6.0,
          "method": "single_fix", "samples_used": 1}
PROJECTION = LocalProjection(33.7756, -84.3963, 90.0, 6.0)

FLOOR_MAP = {"floor_height_m": 0.0, "outlines": [{"polygon_xz_m": [[-2, -2], [0, -2.01], [2, -2], [2, 2], [-2, 2]]}],
             "obstacles": [{"center_xz_m": [1.0, 1.0], "size_m": [0.5, 0.3], "angle_deg": 30.0, "area_m2": 0.15}]}
REGIONS = [{"id": "r1", "kind": "corridor", "polygon_xz_m": [[-2, 2], [2, 2], [2, 0], [-2, 0]], "label": "Hall"}]
DOORS = [{"id": "d1", "kind": "door", "span_xz_m": [[-0.4, -2.0], [0.4, -2.0]], "center_xz_m": [0, -2],
          "meets_clear_width": True, "meets_headroom": True, "measured_clear_width_m": 0.86}]
PLACES = [
    {"id": "p-exit", "category": "exit", "name": "Exit", "names": {"en": "Exit", "es": "Salida"},
     "position_m": [0.0, 1.0, -2.0], "access_point_kind": "destination"},
    {"id": "p-lift", "category": "elevator", "name": "Elevator", "position_m": [1.5, 0.0, 1.5],
     "access_point_kind": "elevator"},
]
HAZARDS = [
    {"id": "h1", "kind": "step", "position_m": [1.0, 0.0, 0.0], "severity": "barrier"},
    {"id": "h2", "kind": "drop_off", "polygon_xz_m": [[0, 0], [0.5, 0], [0.5, 0.5], [0, 0.5]], "severity": "warning"},
]
NAV_GRAPH = {"id": "s-nav", "nodes": [{"id": "n1", "x": 0.0, "y": 0.0, "z": 1.5}, {"id": "n2", "x": 0.0, "y": 0.0, "z": 0.0},
                                      {"id": "n3", "x": 0.0, "y": 0.0, "z": -2.0}], "edges": []}
ROUTES = {"profiles": ["wheelchair"], "routes": [
    {"from_place": "p-lift", "to_place": "p-exit", "profile": "wheelchair", "node_ids": ["n1", "n2", "n3"],
     "length_m": 3.5, "estimated_seconds": 4.0},
    {"from_place": "p-lift", "to_place": "p-exit", "profile": "ambulatory", "node_ids": ["n1", "missing"]},
]}


def full_collection():
    return geojson.build(PROJECTION, scan_id="s", georef=GEOREF, floor_map=FLOOR_MAP, regions=REGIONS, doors=DOORS,
                         places=PLACES, hazards=HAZARDS, nav_graph=NAV_GRAPH, routes=ROUTES,
                         signs=[{"id": "sg", "category": "exit", "position_m": [0, 2, -2], "braille": False,
                                 "languages": ["en"]}])


def by_id(collection):
    return {f["id"]: f for f in collection["features"]}


def test_full_export_is_valid_rfc7946():
    collection, notices = full_collection()
    assert geojson.validate(collection) == []
    json.dumps(collection, allow_nan=False)                                   # strict JSON
    types = sorted({f["properties"]["feature_type"] for f in collection["features"]})
    assert types == ["amenity", "level", "obstruction", "opening", "route", "sign", "unit", "venue"]
    assert any("unknown nav_graph node" in n for n in notices)
    west, south, east, north = collection["bbox"]
    for feature in collection["features"]:
        for lon, lat in geojson._positions(feature["geometry"]):
            assert west <= lon <= east and south <= lat <= north


def test_polygons_are_closed_ccw_and_simplified():
    collection, _ = full_collection()
    outline = by_id(collection)["level:ground:outline:0"]
    ring = outline["geometry"]["coordinates"][0]
    assert ring[0] == ring[-1] and len(ring) == 5                          # the 1 cm wiggle is simplified away
    assert geojson.signed_area_lonlat(ring) > 0
    assert outline["properties"]["area_m2"] == pytest.approx(16.0, abs=0.05)
    # Rings given clockwise and counterclockwise in local meters both come out counterclockwise.
    square = [[0, 0], [1, 0], [1, 1], [0, 1]]
    for local in (square, square[::-1]):
        assert geojson.signed_area_lonlat(geojson.polygon(PROJECTION, local)["coordinates"][0]) > 0
    assert geojson.polygon(PROJECTION, [[0, 0], [1, 0]]) is None
    assert geojson.polygon(PROJECTION, [[0, 0], [1e-9, 0], [0, 1e-9]]) is None       # collapses at 1 cm


def test_coordinates_round_trip_to_local_meters():
    collection, _ = full_collection()
    features = by_id(collection)
    exit_point = features["amenity:p-exit"]["geometry"]["coordinates"]
    assert np.allclose(PROJECTION.to_local(exit_point), [0.0, -2.0], atol=0.02)
    # heading 90: local -Z points east, so the exit 2 m along -Z is east of the origin.
    assert exit_point[0] > GEOREF["longitude"] and exit_point[1] == pytest.approx(GEOREF["latitude"], abs=1e-7)
    door = features["opening:d1"]["geometry"]["coordinates"]
    assert np.allclose(PROJECTION.to_local(door), [[-0.4, -2.0], [0.4, -2.0]], atol=0.02)
    route = features["route:p-lift:p-exit:wheelchair"]
    assert np.allclose(PROJECTION.to_local(route["geometry"]["coordinates"]), [[0, 1.5], [0, 0], [0, -2]], atol=0.02)
    assert route["properties"]["name"] == "Elevator to Exit" and route["properties"]["length_m"] == 3.5


def test_feature_properties():
    features = by_id(full_collection()[0])
    exit_props = features["amenity:p-exit"]["properties"]
    assert exit_props["names"] == {"en": "Exit", "es": "Salida"} and exit_props["category"] == "exit"
    assert features["amenity:p-lift"]["properties"]["accessibility"] == {"wheelchair": True}
    assert features["unit:r1"]["properties"]["category"] == "walkway"
    assert features["unit:r1"]["properties"]["name"] == "Hall"
    assert features["opening:d1"]["properties"]["accessibility"]["wheelchair"] is True
    assert features["obstruction:h1"]["geometry"]["type"] == "Point"
    assert features["obstruction:h1"]["properties"]["accessibility"] == {"barrier": True, "step_free": False}
    assert features["obstruction:h2"]["geometry"]["type"] == "Polygon"
    box = features["obstruction:floor:0"]
    assert box["geometry"]["type"] == "Polygon" and len(box["geometry"]["coordinates"][0]) == 5
    assert features["sign:sg"]["properties"]["accessibility"] == {"braille": False}
    assert features["venue:s"]["geometry"]["coordinates"] == [-84.3963, 33.7756]


def test_missing_inputs_give_a_venue_only_collection():
    collection, notices = geojson.build(PROJECTION, routes=ROUTES, doors=[{"id": "bad", "span_xz_m": None}])
    assert [f["properties"]["feature_type"] for f in collection["features"]] == ["venue"]
    assert notices == ["routes present but nav_graph has no nodes; route lines were not exported"]
    assert geojson.validate(collection) == []


def test_validate_catches_violations():
    clockwise = [[0, 0], [0, 1], [1, 1], [1, 0], [0, 0]]
    bad = {"type": "FeatureCollection", "features": [
        {"type": "Feature", "id": "a", "properties": {}, "geometry": {"type": "Polygon", "coordinates": [clockwise]}},
        {"type": "Feature", "id": "b", "properties": {}, "geometry": {"type": "Polygon", "coordinates": [clockwise[:-1]]}},
        {"type": "Feature", "id": "c", "properties": {}, "geometry": {"type": "LineString", "coordinates": [[0, 0]]}},
        {"type": "Feature", "id": "c", "properties": {}, "geometry": {"type": "Point", "coordinates": [200, 0]}},
    ]}
    errors = geojson.validate(bad)
    assert any("not counterclockwise" in e for e in errors)
    assert any("not closed" in e for e in errors)
    assert any("LineString" in e for e in errors)
    assert any("duplicate id" in e for e in errors) and any("invalid Point" in e for e in errors)
    assert geojson.validate({"type": "Feature"}) == ["not a FeatureCollection"]


def test_antimeridian_bbox_and_orientation():
    projection = LocalProjection(25, 179.99999, 0)
    collection, _ = geojson.build(projection, floor_map={"outlines": [{"polygon_xz_m": [[-5, -5], [5, -5], [5, 5], [-5, 5]]}]})
    assert geojson.validate(collection) == []
    west, _, east, _ = collection["bbox"]
    assert west > 0 > east                                                   # RFC 7946 §5.2 crossing bbox


def test_stage_with_upstream_products(synthetic_ctx):
    synthetic_ctx.products[ProductName.GEOREF] = Product(GEOREF)
    for name, value in ((ProductName.FLOOR_MAP, FLOOR_MAP), (ProductName.DOORS, DOORS), (ProductName.PLACES, PLACES),
                        (ProductName.NAV_GRAPH, NAV_GRAPH), (ProductName.ROUTES, ROUTES)):
        synthetic_ctx.products[name] = Product(value)
    result = GeojsonStage().run(synthetic_ctx)
    collection = result.products[ProductName.GEOJSON].json
    assert result.summary["valid"] and result.summary["by_type"]["route"] == 1
    assert collection["features"][1]["properties"]["level_id"] == "ground"          # manifest floor_id


def test_synthetic_pipeline_exports_outline_and_door(synthetic_ctx):
    analysis = runner.run(synthetic_ctx)
    assert analysis["stages"]["geojson"]["status"] == "ok"
    collection = analysis["geojson"]
    assert geojson.validate(collection) == []
    kinds = {f["properties"]["feature_type"] for f in collection["features"]}
    assert {"venue", "level", "opening"} <= kinds
    outline = next(f for f in collection["features"] if f["properties"]["feature_type"] == "level")
    local = PROJECTION.to_local(outline["geometry"]["coordinates"][0])
    assert np.allclose(np.abs(local), 2.0, atol=0.15)                      # the 4 m x 4 m synthetic room
