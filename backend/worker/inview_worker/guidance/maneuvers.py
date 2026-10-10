"""Language-neutral turn-by-turn steps for a planned path.

Per surface leg: resample the path polyline, simplify it with `cv2.approxPolyDP` (removes skeleton
jitter), classify corners by heading change with the iOS `Maneuver` thresholds (announce >= 30 deg,
full turn >= 60 deg; u-turn >= 150 deg is an extension), merge corners separated by short pieces
into one maneuver (a jog through a doorway is not two turns), then anchor door passages, hazard
warnings and landmarks (the nearest sign / place / door around each turn), and finish with the side
of the destination on arrival.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import numpy as np

from . import geometry as geo
from .endpoints import Endpoint
from .graph import Edge, NavGraph

ANNOUNCED_TURN_DEG = 30.0   # iOS Route.announcedTurnAngle
SHARP_TURN_DEG = 60.0       # iOS Route.sharpTurnAngle
U_TURN_DEG = 150.0


@dataclass(frozen=True)
class Params:
    resample_m: float = 0.25
    simplify_m: float = 0.3
    min_segment_m: float = 1.5       # corners closer than this are merged into one maneuver
    edge_margin_m: float = 0.75      # ignore corners this close to a leg's start or end
    door_reach_m: float = 0.75
    hazard_reach_m: float = 1.25
    hazard_lead_m: float = 2.0       # warn this far before the hazard
    landmark_radius_m: float = 4.0
    arrival_ahead_m: float = 0.5     # lateral offsets below this are "ahead"
    floor_band_m: tuple[float, float] = (-1.0, 3.0)  # feature height above the path counted as same floor (signs hang high)


@dataclass(frozen=True)
class Feature:
    """A sign, place, door or hazard positioned on the map."""
    id: str
    kind: str                    # sign | place | door | hazard
    xz: tuple[float, float]
    y: float | None = None
    floor_id: str | None = None
    category: str = "unknown"
    name: str | None = None
    names: dict[str, str] = field(default_factory=dict)
    text: str | None = None
    extra: dict[str, Any] = field(default_factory=dict)

    @property
    def priority(self) -> float:
        return {"sign": 0.0, "place": 0.5, "door": 1.0}.get(self.kind, 2.0)

    def neutral(self) -> dict[str, Any]:
        out = {"id": self.id, "kind": self.kind, "category": self.category}
        for key in ("name", "text"):
            if getattr(self, key):
                out[key] = getattr(self, key)
        if self.names:
            out["names"] = dict(sorted(self.names.items()))
        return out


@dataclass
class Features:
    landmarks: list[Feature] = field(default_factory=list)   # signs, places, doors
    doors: list[Feature] = field(default_factory=list)
    hazards: list[Feature] = field(default_factory=list)


def classify(angle: float, right: bool) -> str | None:
    if angle < ANNOUNCED_TURN_DEG:
        return None
    if angle >= U_TURN_DEG:
        return "u_turn"
    side = "right" if right else "left"
    return f"slight_{side}" if angle < SHARP_TURN_DEG else side


def on_floor(feature: Feature, floor_id: str, y: float, params: Params = Params()) -> bool:
    if feature.floor_id is not None:
        return feature.floor_id == floor_id
    return feature.y is None or params.floor_band_m[0] <= feature.y - y <= params.floor_band_m[1]


@dataclass
class _Leg:
    floor_id: str
    dense: np.ndarray
    cum: np.ndarray
    vertices: np.ndarray       # indices into `dense` of the simplified polyline


def _legs(graph: NavGraph, edges: list[Edge], params: Params) -> list[_Leg | Edge]:
    """Group consecutive surface edges on one floor into polylines; transitions stay single items."""
    out: list[_Leg | Edge] = []
    points: list[tuple[float, float, float]] = []
    floor = None

    def flush() -> None:
        nonlocal points
        if len(points) >= 2:
            dense = geo.resample(geo.as_array(points), params.resample_m)
            out.append(_Leg(floor, dense, geo.cumulative(dense), geo.simplify(dense, params.simplify_m)))
        points = []

    for edge in edges:
        if edge.kind == "transition":
            flush()
            out.append(edge)
            continue
        edge_floor = graph.nodes[edge.source].floor_id
        if points and edge_floor != floor:
            flush()
        floor = edge_floor
        points.extend(edge.points if not points else edge.points[1:])
    flush()
    return out


def _corners(leg: _Leg, params: Params) -> list[dict[str, Any]]:
    v = leg.dense[leg.vertices]
    along = leg.cum[leg.vertices]
    length = leg.cum[-1]
    raw = []
    for i in range(1, len(v) - 1):
        a, b = geo.heading((v[i] - v[i - 1])[[0, 2]]), geo.heading((v[i + 1] - v[i])[[0, 2]])
        if a is None or b is None:
            continue
        angle, _ = geo.turn_angle(a, b)
        if angle >= ANNOUNCED_TURN_DEG:
            raw.append(i)
    # Merge corners separated by short pieces; the cluster's net heading change decides the maneuver.
    clusters: list[list[int]] = []
    for i in raw:
        if clusters and along[i] - along[clusters[-1][-1]] < params.min_segment_m:
            clusters[-1].append(i)
        else:
            clusters.append([i])
    corners = []
    for cluster in clusters:
        first, last = cluster[0], cluster[-1]
        incoming = geo.heading((v[first] - v[first - 1])[[0, 2]])
        outgoing = geo.heading((v[last + 1] - v[last])[[0, 2]])
        angle, right = geo.turn_angle(incoming, outgoing)
        maneuver = classify(angle, right)
        s = float((along[first] + along[last]) / 2)
        if maneuver is None or s < params.edge_margin_m or s > length - params.edge_margin_m:
            continue
        corners.append({"along": s, "maneuver": maneuver, "angle_deg": round(angle, 1),
                        "incoming": incoming, "point": geo.point_at(leg.dense, leg.cum, s)})
    return corners


def _landmark(corner: dict[str, Any], leg: _Leg, features: Features, exclude: set[str],
              params: Params) -> dict[str, Any] | None:
    point = corner["point"]
    best = None
    for feature in features.landmarks:
        if feature.id in exclude or not on_floor(feature, leg.floor_id, float(point[1]), params):
            continue
        offset = np.asarray(feature.xz) - point[[0, 2]]
        distance = float(np.linalg.norm(offset))
        if distance > params.landmark_radius_m:
            continue
        ahead = float(np.dot(offset, corner["incoming"]))   # > 0: beyond the corner, straight on
        score = distance + feature.priority + (1.5 if ahead > 1.0 else 0.0)
        key = (round(score, 6), feature.id)
        if best is None or key < best[0]:
            best = (key, feature, distance, "before" if ahead > 0.5 else "after")
    if best is None:
        return None
    _, feature, distance, relation = best
    return {**feature.neutral(), "relation": relation, "distance_m": round(distance, 2)}


def _leg_events(leg: _Leg, features: Features, exclude: set[str], params: Params) -> list[dict[str, Any]]:
    events = []
    for corner in _corners(leg, params):
        events.append({"along": corner["along"], "maneuver": corner["maneuver"], "angle_deg": corner["angle_deg"],
                       "point": corner["point"],
                       "landmark": _landmark(corner, leg, features, exclude, params)})
    length = leg.cum[-1]
    y_mid = float(leg.dense[:, 1].mean())
    for door in features.doors:
        if not on_floor(door, leg.floor_id, y_mid, params):
            continue
        hit = geo.project(leg.dense, leg.cum, door.xz)
        if hit is None or hit.distance_m > params.door_reach_m or not (0.3 < hit.along_m < length - 0.3):
            continue
        events.append({"along": hit.along_m, "maneuver": "pass_door", "point": hit.foot,
                       "door": {"id": door.id, **door.extra}, "landmark": None})
    for hazard in features.hazards:
        if not on_floor(hazard, leg.floor_id, y_mid, params):
            continue
        hit = geo.project(leg.dense, leg.cum, hazard.xz)
        # Projection clamps to the ends: skip hazards behind the start or beyond the destination.
        if hit is None or hit.distance_m > params.hazard_reach_m or not (0.3 < hit.along_m < length - 0.05):
            continue
        warn_at = max(0.0, hit.along_m - params.hazard_lead_m)
        events.append({"along": warn_at, "maneuver": "caution", "point": geo.point_at(leg.dense, leg.cum, warn_at),
                       "hazard": {"id": hazard.id, "kind": hazard.category,
                                  "severity": hazard.extra.get("severity", "warning"),
                                  "ahead_m": round(hit.along_m - warn_at, 2)},
                       "landmark": None})
    order = {"caution": 0, "pass_door": 1}
    events.sort(key=lambda e: (round(e["along"], 3), order.get(e["maneuver"], 2),
                               (e.get("door") or e.get("hazard") or {}).get("id", "")))
    return events


def _arrival_side(leg: _Leg, destination: Endpoint | None, params: Params) -> str | None:
    if destination is None or destination.position is None:
        return None
    end = leg.dense[-1]
    back = geo.point_at(leg.dense, leg.cum, leg.cum[-1] - 1.5)
    direction = geo.heading((end - back)[[0, 2]])
    target = np.array([destination.position[0], destination.position[2]])
    if direction is None or np.linalg.norm(target - end[[0, 2]]) < 0.3:
        return None
    lateral = geo.side_of(direction, end[[0, 2]], target)
    if abs(lateral) < params.arrival_ahead_m:
        return "ahead" if np.dot(target - end[[0, 2]], direction) >= 0 else None
    return "right" if lateral > 0 else "left"


def _xyz(point) -> list[float]:
    return [round(float(v), 3) for v in point]


def build_steps(graph: NavGraph, edges: list[Edge], origin: Endpoint | None, destination: Endpoint | None,
                features: Features, params: Params = Params()) -> list[dict[str, Any]]:
    """Ordered neutral steps: {maneuver, position_m, distance_m, landmark?, door?, hazard?, ...}."""
    exclude = {e.id for e in (origin, destination) if e is not None}
    steps: list[dict[str, Any]] = []
    travelled = 0.0
    start = graph.nodes[edges[0].source].position if edges else (
        graph.node(origin.node_id).position if origin else (0.0, 0.0, 0.0))
    steps.append({"maneuver": "depart", "s": 0.0, "position_m": _xyz(start), "landmark": None})
    last_leg = None
    for item in _legs(graph, edges, params):
        if isinstance(item, Edge):
            source, target = graph.nodes[item.source], graph.nodes[item.target]
            rise = target.position[1] - source.position[1]
            direction = ("up" if rise > 0.5 else "down" if rise < -0.5 else "level") \
                if source.map_id == target.map_id else "other"
            steps.append({"maneuver": item.connector or "transition", "s": travelled, "position_m": _xyz(source.position),
                          "landmark": None, "connector": {"kind": item.connector, "id": item.raw["segment"].get("connector_id"),
                                                          "direction": direction, "to_floor_id": target.floor_id,
                                                          "estimated_seconds": item.transition_seconds}})
            continue
        for event in _leg_events(item, features, exclude, params):
            step = {"maneuver": event["maneuver"], "s": travelled + event["along"], "position_m": _xyz(event["point"]),
                    "landmark": event.get("landmark")}
            for key in ("angle_deg", "door", "hazard"):
                if key in event:
                    step[key] = event[key]
            steps.append(step)
        travelled += float(item.cum[-1])
        last_leg = item
    end = graph.nodes[edges[-1].target].position if edges else start
    side = _arrival_side(last_leg, destination, params) if last_leg is not None and edges[-1].kind == "surface" else None
    steps.append({"maneuver": "arrive", "s": travelled, "position_m": _xyz(end), "landmark": None, "side": side})
    for current, following in zip(steps, steps[1:]):
        current["distance_m"] = round(max(0.0, following["s"] - current["s"]), 2)
    steps[-1]["distance_m"] = 0.0
    for step in steps:
        del step["s"]
    return steps
