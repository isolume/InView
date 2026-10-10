"""Hand-built products following the PIPELINE.md contract (no other unit's code).

Ground floor (map "scan", y = 0), plan view (x right, z down):

    entrance(0,0) ── 10 m ── j(10,0) ── 6 m ── k(16,0)
        │                     │ 0.78 m door at z=6     │
     4 m│                     │ (drop-off hazard       │ 8 m
        │                     │  beside it at z=4)     │
    stairs-bottom(0,-4)    restroom(10,8) ── 6 m ── m(16,8)

stairs-bottom ──stairs (12 s)──▶ stairs-top (floor "upper", y = 3) ── 5 m ── office(5,-4).
Every surface edge exists in both directions. The EXIT sign hangs just before the j corner.
"""
from __future__ import annotations

import copy

NODES = {
    "entrance": ("ground", 0.0, 0.0, 0.0),
    "j": ("ground", 10.0, 0.0, 0.0),
    "k": ("ground", 16.0, 0.0, 0.0),
    "m": ("ground", 16.0, 0.0, 8.0),
    "restroom": ("ground", 10.0, 0.0, 8.0),
    "stairs-bottom": ("ground", 0.0, 0.0, -4.0),
    "stairs-top": ("upper", 0.0, 3.0, -4.0),
    "office": ("upper", 5.0, 3.0, -4.0),
}
SURFACES = [  # (a, b, clear width, slope, step_free)
    ("entrance", "j", 1.8, 0.0, True),
    ("j", "k", 1.6, 0.0, True),
    ("k", "m", 1.6, 0.02, True),
    ("m", "restroom", 1.6, 0.0, True),
    ("j", "restroom", 0.78, 0.0, True),   # direct, through a narrow door
    ("entrance", "stairs-bottom", 1.5, 0.0, True),
    ("stairs-top", "office", 1.5, 0.0, True),
]


def _point(node: str) -> dict:
    _, x, y, z = NODES[node]
    return {"x": x, "y": y, "z": z}


def nav_graph() -> dict:
    nodes = [{"id": n, "map_id": "scan", "floor_id": f, "x": x, "y": y, "z": z, "label": n.replace("-", " ").title()}
             for n, (f, x, y, z) in NODES.items()]
    edges = []
    for a, b, width, slope, step_free in SURFACES:
        for source, target in ((a, b), (b, a)):
            edges.append({"id": f"{source}__{target}", "from": source, "to": target, "step_free": step_free,
                          "availability": "available", "minimum_clear_width_m": width, "maximum_slope": slope,
                          "segment": {"type": "surface", "map_id": "scan", "floor_id": NODES[source][0],
                                      "path_points": [_point(source), _point(target)]}})
    for source, target in (("stairs-bottom", "stairs-top"), ("stairs-top", "stairs-bottom")):
        edges.append({"id": f"{source}__{target}", "from": source, "to": target, "step_free": False,
                      "availability": "available", "minimum_clear_width_m": 1.2, "maximum_slope": 0.0,
                      "segment": {"type": "transition", "connector_id": "stairs-a", "kind": "stairs",
                                  "estimated_seconds": 12.0}})
    return {"schema_version": 1, "id": "fixture-nav", "nodes": nodes, "edges": edges,
            "metadata": {"node_kinds": {"stairs-bottom": "stairs", "stairs-top": "stairs"},
                         "place_nodes": {"place-entrance": "entrance"}, "generator": "test-fixture"}}


PLACES = [
    {"id": "place-entrance", "category": "entrance", "name": "Main Entrance",
     "names": {"en": "Main Entrance", "es": "Entrada principal", "ar": "المدخل الرئيسي"},
     "position_m": [-0.4, 0.0, 0.0], "floor_id": "ground", "confidence": 0.9, "sources": ["sign:s-entrance"],
     "access_point_kind": "destination"},
    {"id": "place-restroom", "category": "restroom", "name": None, "names": {},
     "position_m": [10.0, 0.0, 8.8], "floor_id": "ground", "confidence": 0.8, "sources": ["roomplan:object:t1"],
     "access_point_kind": "destination"},
    {"id": "place-office", "category": "room", "name": "Office 204", "names": {},
     "position_m": [5.0, 3.0, -4.6], "floor_id": "upper", "confidence": 0.7, "sources": ["text:t2"],
     "access_point_kind": "destination"},
]
SIGNS = [{"id": "sign-exit", "category": "exit", "pictograms": ["running_person"], "text_ids": ["t-exit"],
          "arrows": [], "position_m": [9.4, 2.1, -0.6]}]
TEXT = [{"id": "t-exit", "text": "EXIT", "confidence": 0.95}]
DOORS = [{"id": "door-0", "kind": "door", "center_xz_m": [10.0, 6.0], "span_xz_m": [[9.6, 6.0], [10.4, 6.0]],
          "nominal_width_m": 0.8, "measured_clear_width_m": 0.78, "meets_clear_width": False}]
HAZARDS = [{"id": "hz-0", "kind": "drop_off", "position_m": [10.6, 0.0, 4.0], "severity": "barrier"}]


def products() -> dict:
    return copy.deepcopy({"nav_graph": nav_graph(), "places": PLACES, "signs": SIGNS, "text": TEXT,
                          "doors": DOORS, "hazards": HAZARDS})
