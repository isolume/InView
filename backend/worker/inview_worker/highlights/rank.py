"""Turns the worker's products into a ranked list of the aspects a wheelchair user, or a person
who can't see the space, most needs to know about. Pure data in, plain dataclasses out."""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

from ..contracts import Thresholds

# Severities, most urgent first. `asset` and `info` are things to find, not to avoid.
SEVERITIES = ("barrier", "warning", "asset", "info")

# Importance of finding each kind of place (0..1).
ASSET_WEIGHTS = {
    "elevator": 0.85, "accessible_restroom": 0.82, "ramp": 0.80, "entrance": 0.76, "exit": 0.70,
    "emergency_exit": 0.72, "restroom": 0.58, "information": 0.52, "reception": 0.50, "first_aid": 0.60,
    "water_fountain": 0.40, "escalator": 0.45, "seating": 0.32, "fire_extinguisher": 0.35,
}
# Places that are barriers to a wheelchair user rather than something to find. A sign or label
# without a measured hazard still deserves a warning: "stairs here" is exactly what they need to know.
BARRIER_PLACES = {"stairs": 0.74, "escalator": 0.5}
HAZARD_TITLES = {
    "stairs": "Stairs", "drop_off": "Drop-off", "step": "Step", "level_change": "Level change",
    "ramp": "Ramp", "low_headroom": "Low headroom", "protruding_object": "Protruding object",
}


@dataclass
class Options:
    max_items: int = 24
    min_importance: float = 0.30
    callouts: int = 12
    kinds: tuple[str, ...] | None = None
    include_passing_doors: bool = False
    width_px: int = 1400

    @staticmethod
    def from_config(config: dict[str, Any] | None) -> "Options":
        raw = (config or {}).get("highlights") or {}
        defaults = Options()

        def number(key, low, high, fallback):
            try:
                value = float(raw.get(key, fallback))
            except (TypeError, ValueError):
                return fallback
            return min(high, max(low, value)) if math.isfinite(value) else fallback

        kinds = raw.get("kinds")
        return Options(
            max_items=int(number("max_items", 1, 100, defaults.max_items)),
            min_importance=number("min_importance", 0.0, 1.0, defaults.min_importance),
            callouts=int(number("callouts", 0, 30, defaults.callouts)),
            kinds=tuple(str(k) for k in kinds) if isinstance(kinds, (list, tuple)) and kinds else None,
            include_passing_doors=bool(raw.get("include_passing_doors", False)),
            width_px=int(number("width_px", 400, 2400, defaults.width_px)),
        )


@dataclass
class Highlight:
    kind: str                 # barrier | narrow_passage | door | access_feature | wayfinding | route
    severity: str             # one of SEVERITIES
    importance: float         # 0..1, what the ranking sorts by
    title: str
    reason: str
    position_xz_m: list[float]
    position_m: list[float] | None = None
    # How to draw it, in meters: {"type": "polygon"|"segment"|"point"|"circle", "xz": [[x, z], ...], "radius_m"?}
    geometry: dict[str, Any] = field(default_factory=dict)
    refs: dict[str, Any] = field(default_factory=dict)
    evidence: dict[str, Any] = field(default_factory=dict)
    id: str = ""
    rank: int = 0

    def to_json(self) -> dict[str, Any]:
        out = {"id": self.id, "rank": self.rank, "kind": self.kind, "severity": self.severity,
               "importance": round(self.importance, 3), "title": self.title, "reason": self.reason,
               "position_xz_m": [round(v, 3) for v in self.position_xz_m], "geometry": self.geometry,
               "refs": self.refs, "evidence": self.evidence}
        if self.position_m is not None:
            out["position_m"] = [round(v, 3) for v in self.position_m]
        return out


def _dicts(value: Any) -> list[dict]:
    return [v for v in value if isinstance(v, dict)] if isinstance(value, list) else []


def _xz(value: Any) -> list[float] | None:
    try:
        x, z = float(value[0]), float(value[1])
    except (TypeError, ValueError, IndexError, KeyError):
        return None
    return [x, z] if math.isfinite(x) and math.isfinite(z) else None


def _xyz_to_xz(value: Any) -> list[float] | None:
    try:
        return _xz([value[0], value[2]]) if len(value) >= 3 else None
    except TypeError:
        return None


def _clamp(value: float) -> float:
    return max(0.0, min(1.0, value))


def _hazards(items: list[dict]) -> list[Highlight]:
    out = []
    for hazard in items:
        kind = str(hazard.get("kind") or "hazard")
        measure = hazard.get("measure") if isinstance(hazard.get("measure"), dict) else {}
        severity = "barrier" if hazard.get("severity") == "barrier" else "warning"
        position = hazard.get("position_m")
        xz = _xyz_to_xz(position)
        polygon = [p for p in (_xz(v) for v in hazard.get("polygon_xz_m") or []) if p]
        if xz is None and polygon:
            xz = [sum(p[0] for p in polygon) / len(polygon), sum(p[1] for p in polygon) / len(polygon)]
        if xz is None:
            continue
        title, reason, importance = HAZARD_TITLES.get(kind, kind.replace("_", " ").capitalize()), "", 0.9 if severity == "barrier" else 0.62
        if kind == "stairs":
            risers = measure.get("risers") or measure.get("risers_estimated")
            rise = measure.get("total_rise_m") or measure.get("rise_m")
            parts = [f"{risers} risers" if risers else None, f"{rise:.1f} m rise" if isinstance(rise, (int, float)) else None]
            reason = ", ".join(p for p in parts if p) or "Not step-free"
            importance = 0.96
        elif kind in ("drop_off", "step", "level_change"):
            rise = measure.get("rise_m")
            reason = f"{rise * 100:.0f} cm drop" if isinstance(rise, (int, float)) else "Change in floor height"
            importance = 0.93 if kind == "drop_off" else importance
        elif kind == "ramp":
            slope = measure.get("running_slope")
            if isinstance(slope, (int, float)):
                reason = f"Slope 1:{1 / slope:.0f}" if slope > 0 else "Level"
                importance = 0.9 if slope > Thresholds.RAMP_MAX_SLOPE else 0.6
                title = "Steep ramp" if slope > Thresholds.RAMP_MAX_SLOPE else "Ramp"
                severity = "barrier" if slope > Thresholds.RAMP_MAX_SLOPE else "warning"
            else:
                reason = "Slope not measured"
        elif kind == "low_headroom":
            clearance = measure.get("clearance_min_m")
            reason = (f"{clearance:.2f} m clear, needs {Thresholds.HEADROOM_MIN_M:.2f} m"
                      if isinstance(clearance, (int, float)) else "Headroom below the minimum")
            importance = 0.7
        elif kind == "protruding_object":
            protrusion = measure.get("protrusion_m")
            reason = (f"Sticks out {protrusion * 100:.0f} cm at cane height"
                      if isinstance(protrusion, (int, float)) else "Protrudes into the walkway")
            importance = 0.74
        else:
            reason = "; ".join(str(i) for i in (hazard.get("issues") or [])[:2]) or title
        geometry = ({"type": "polygon", "xz": polygon} if len(polygon) >= 3
                    else {"type": "circle", "xz": [xz], "radius_m": 0.7})
        out.append(Highlight("barrier", severity, importance, title, reason, xz,
                             position if isinstance(position, list) and len(position) == 3 else None,
                             geometry, {"hazard_id": hazard.get("id")}, {"hazard_kind": kind, "measure": measure}))
    return out


CLUSTER_M = 1.6


def _clusters(points: list[list[float]], radius: float) -> list[list[int]]:
    """Connected groups of points closer than `radius` (single-linkage, small inputs only)."""
    parent = list(range(len(points)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(len(points)):
        for j in range(i + 1, len(points)):
            if math.dist(points[i], points[j]) <= radius:
                parent[find(i)] = find(j)
    groups: dict[int, list[int]] = {}
    for i in range(len(points)):
        groups.setdefault(find(i), []).append(i)
    return list(groups.values())


def _narrow(floor_map: dict | None) -> list[Highlight]:
    out = []
    for passage in _dicts((floor_map or {}).get("narrow_passages")):
        center = _xz(passage.get("center_xz_m"))
        width = passage.get("min_clear_width_m")
        if center is None or not isinstance(width, (int, float)):
            continue
        required = float(passage.get("required_min_m") or Thresholds.ROUTE_MIN_CLEAR_M)
        deficit = _clamp((required - width) / required)
        length = float(passage.get("length_m") or 1.0)
        out.append(Highlight(
            "narrow_passage", "barrier" if width < Thresholds.DOOR_MIN_CLEAR_M else "warning",
            0.55 + 0.33 * _clamp(deficit / 0.4), f"Narrow passage {width:.2f} m",
            f"{width:.2f} m clear; routes need {required:.3f} m", center, None,
            {"type": "circle", "xz": [center], "radius_m": max(0.45, min(0.9, length / 2))},
            {}, {"min_clear_width_m": width, "required_min_m": required, "length_m": length}))
    # Furniture clutter makes many readings of one squeeze: keep the narrowest of each group.
    merged = []
    for group in _clusters([h.position_xz_m for h in out], CLUSTER_M):
        members = sorted((out[i] for i in group), key=lambda h: h.evidence["min_clear_width_m"])
        keep = members[0]
        if len(members) > 1:
            keep.reason += f" (+{len(members) - 1} more nearby)"
            keep.evidence["merged"] = len(members)
            keep.geometry["radius_m"] = min(1.2, keep.geometry["radius_m"] + 0.1 * (len(members) - 1))
        merged.append(keep)
    return merged


def _doors(items: list[dict], include_passing: bool) -> list[Highlight]:
    out = []
    for door in items:
        center = _xz(door.get("center_xz_m"))
        if center is None:
            continue
        measured = door.get("measured_clear_width_m")
        required = float(door.get("required_min_clear_width_m") or Thresholds.DOOR_MIN_CLEAR_M)
        fails_width = door.get("meets_clear_width") is False
        fails_head = door.get("meets_headroom") is False
        unknown = measured is None and door.get("meets_clear_width") is not True
        if not (fails_width or fails_head or unknown or include_passing):
            continue
        span = [p for p in (_xz(v) for v in door.get("span_xz_m") or []) if p]
        kind = "door" if door.get("kind") != "opening" else "opening"
        if fails_width and isinstance(measured, (int, float)):
            importance = 0.72 + 0.2 * _clamp((required - measured) / required / 0.3)
            title, reason, severity = f"Narrow {kind} {measured:.2f} m", f"Needs {required:.3f} m clear", "barrier"
        elif fails_head:
            importance, title, reason, severity = 0.7, f"Low {kind}", "; ".join(door.get("issues") or ["Headroom below the minimum"]), "warning"
        elif unknown:
            importance, title, reason, severity = 0.45, f"{kind.capitalize()} width not measured", "Check it on site", "info"
        else:
            importance, title, severity = 0.35, f"{kind.capitalize()} {measured:.2f} m clear" if isinstance(measured, (int, float)) else kind.capitalize(), "asset"
            reason = "Passes the minimum clear width"
        out.append(Highlight(
            "door", severity, importance, title, reason, center, None,
            {"type": "segment", "xz": span} if len(span) == 2 else {"type": "circle", "xz": [center], "radius_m": 0.5},
            {"door_id": door.get("id")},
            {"measured_clear_width_m": measured, "required_min_clear_width_m": required, "issues": door.get("issues") or []}))
    return out


def _places(items: list[dict]) -> list[Highlight]:
    out = []
    for place in items:
        category = str(place.get("category") or "unknown")
        weight = ASSET_WEIGHTS.get(category)
        xz = _xyz_to_xz(place.get("position_m"))
        if xz is None or (weight is None and category not in BARRIER_PLACES):
            continue
        confidence = place.get("confidence")
        confidence = float(confidence) if isinstance(confidence, (int, float)) else 0.5
        name = str(place.get("name") or "").strip() or category.replace("_", " ").capitalize()
        if weight is None:
            out.append(Highlight(
                "barrier", "warning", BARRIER_PLACES[category] * (0.85 + 0.15 * _clamp(confidence)), name,
                f"{category.capitalize()} (not step-free; not measured)", xz, place.get("position_m"),
                {"type": "circle", "xz": [xz], "radius_m": 0.7}, {"place_id": place.get("id")},
                {"category": category, "confidence": confidence, "from_place": True}))
            continue
        out.append(Highlight(
            "access_feature", "asset", weight * (0.8 + 0.2 * _clamp(confidence)), name,
            category.replace("_", " ").capitalize(), xz, place.get("position_m"),
            {"type": "point", "xz": [xz]}, {"place_id": place.get("id")},
            {"category": category, "confidence": confidence, "from_place": True}))
    return out


def _signs(items: list[dict]) -> list[Highlight]:
    out = []
    for sign in items:
        if sign.get("kind") == "text_region":
            continue
        xz = _xyz_to_xz(sign.get("position_m"))
        if xz is None:
            continue
        issues = [str(i) for i in (sign.get("issues") or [])]
        text = str(sign.get("text") or "").strip()
        category = str(sign.get("category") or "sign")
        out.append(Highlight(
            "wayfinding", "warning" if issues else "info", 0.5 if issues else 0.42,
            text or category.replace("_", " ").capitalize(),
            issues[0] if issues else f"{category.replace('_', ' ').capitalize()} sign",
            xz, sign.get("position_m"), {"type": "point", "xz": [xz]}, {"sign_id": sign.get("id")},
            {"category": category, "issues": issues, "mounting_height_m": sign.get("mounting_height_m")}))
    return out


def _routes(routes: dict | None, nav_graph: dict | None) -> list[Highlight]:
    out = []
    nodes = {n.get("id"): n for n in _dicts((nav_graph or {}).get("nodes"))}
    endpoints = {e.get("id"): e for e in _dicts((routes or {}).get("endpoints"))}

    def point(endpoint_id):
        node = nodes.get((endpoints.get(endpoint_id) or {}).get("node_id"))
        return [float(node["x"]), float(node["z"])] if node and "x" in node and "z" in node else None

    def name(endpoint_id):
        endpoint = endpoints.get(endpoint_id) or {}
        return str(endpoint.get("name") or endpoint.get("category") or endpoint_id or "?")

    # One finding per origin and profile, not one per destination.
    groups: dict[tuple, list[dict]] = {}
    for gap in _dicts((routes or {}).get("unreachable")):
        groups.setdefault((gap.get("from_place"), gap.get("profile")), []).append(gap)
    for (origin, profile), gaps in groups.items():
        a = point(origin)
        targets = [(g, point(g.get("to_place"))) for g in gaps]
        targets = [(g, b) for g, b in targets if b is not None]
        if a is None or not targets:
            continue
        nearest = min(targets, key=lambda t: math.dist(a, t[1]))
        limits: list[str] = []
        for gap, _ in targets:
            for limit in gap.get("limiting_requirements") or []:
                if str(limit) not in limits:
                    limits.append(str(limit))
        names = [name(g.get("to_place")) for g, _ in targets]
        shown = ", ".join(names[:3]) + (f" and {len(names) - 3} more" if len(names) > 3 else "")
        label = str(profile or "route").replace("_", " ")
        b = nearest[1]
        out.append(Highlight(
            "route", "barrier", 0.88 + 0.06 * _clamp((len(targets) - 1) / 5),
            f"No {label} route from {name(origin)}", f"Cannot reach {shown}" + (f" ({'; '.join(limits[:2])})" if limits else ""),
            [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], None, {"type": "segment", "xz": [a, b], "dashed": True},
            {"from_place": origin, "to_places": [g.get("to_place") for g, _ in targets]},
            {"profile": profile, "limiting_requirements": limits, "unreachable": len(targets)}))
    for route in _dicts((routes or {}).get("routes")):
        ratio = route.get("detour_ratio")
        if not isinstance(ratio, (int, float)) or ratio < 1.6:
            continue
        path = [p for p in (point_for_node(nodes, n) for n in route.get("node_ids") or []) if p]
        if len(path) < 2:
            continue
        mid = path[len(path) // 2]
        out.append(Highlight(
            "route", "warning", 0.5 + 0.2 * _clamp((ratio - 1.6) / 1.4),
            f"Long detour: {name(route.get('from_place'))} to {name(route.get('to_place'))}",
            f"{ratio:.1f}x longer than the straight line", mid, None, {"type": "polyline", "xz": path},
            {"route_id": route.get("id")}, {"detour_ratio": ratio, "length_m": route.get("length_m")}))
    return out


def point_for_node(nodes: dict, node_id: Any) -> list[float] | None:
    node = nodes.get(node_id)
    try:
        return [float(node["x"]), float(node["z"])]
    except (TypeError, KeyError, ValueError):
        return None


def route_polylines(routes: dict | None, nav_graph: dict | None, limit: int = 8) -> list[list[list[float]]]:
    """The walked paths of the first routes, for drawing under the highlights."""
    nodes = {n.get("id"): n for n in _dicts((nav_graph or {}).get("nodes"))}
    paths = []
    for route in _dicts((routes or {}).get("routes"))[:limit]:
        path = [p for p in (point_for_node(nodes, n) for n in route.get("node_ids") or []) if p]
        if len(path) >= 2:
            paths.append(path)
    return paths


DIVERSITY = 0.88


def _diversify(items: list[Highlight]) -> list[Highlight]:
    """Greedy re-ranking: each kind's next item counts a little less, so a dozen readings of one
    kind can't push the elevator, the stairs and the failing door off the list. An item's own
    `importance` is unchanged; only the order and the cut are affected."""
    def tie(h: Highlight):
        return (SEVERITIES.index(h.severity) if h.severity in SEVERITIES else 9, h.kind, h.title, h.position_xz_m)

    pool = sorted(items, key=lambda h: (-h.importance, *tie(h)))
    chosen: list[Highlight] = []
    taken: dict[str, int] = {}
    while pool:
        best = max(pool, key=lambda h: (h.importance * DIVERSITY ** taken.get(h.kind, 0), -pool.index(h)))
        pool.remove(best)
        taken[best.kind] = taken.get(best.kind, 0) + 1
        chosen.append(best)
    return chosen


def collect(*, floor_map=None, doors=None, hazards=None, places=None, signs=None, routes=None,
            nav_graph=None, options: Options | None = None) -> list[Highlight]:
    """Every highlight above the importance floor, most important first, with stable ids."""
    options = options or Options()
    found = (_hazards(_dicts(hazards)) + _narrow(floor_map if isinstance(floor_map, dict) else None)
             + _doors(_dicts(doors), options.include_passing_doors) + _places(_dicts(places))
             + _signs(_dicts(signs)) + _routes(routes if isinstance(routes, dict) else None,
                                               nav_graph if isinstance(nav_graph, dict) else None))
    # A stairs (or ramp) place sitting on a measured stairs (or ramp) hazard is the same structure:
    # keep the measurement, which carries the numbers and the severity.
    measured = {kind: [h.position_xz_m for h in found
                       if h.kind == "barrier" and h.evidence.get("hazard_kind") == kind]
                for kind in ("stairs", "ramp")}
    found = [h for h in found
             if not (h.evidence.get("from_place") and h.evidence.get("category") in measured
                     and any(math.dist(h.position_xz_m, s) < 2.5 for s in measured[h.evidence["category"]]))]
    if options.kinds:
        found = [h for h in found if h.kind in options.kinds]
    found = [h for h in found if h.importance >= options.min_importance]
    found = _diversify(found)[:options.max_items]
    counters: dict[str, int] = {}
    for rank, item in enumerate(found, start=1):
        counters[item.kind] = counters.get(item.kind, 0) + 1
        item.id = f"hl-{item.kind}-{counters[item.kind]}"
        item.rank = rank
    return found
