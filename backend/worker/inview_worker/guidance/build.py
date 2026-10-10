"""Assemble the `routes` product: endpoints, bounded pairs, per-profile routes and localized guidance."""
from __future__ import annotations

import math
from dataclasses import replace
from typing import Any

import numpy as np

from . import geometry as geo
from . import i18n, maneuvers, render
from .endpoints import Endpoint, extremity_endpoints, place_endpoints, region_endpoints, select_pairs
from .graph import NavGraph
from .planner import adjacency, extract, shortest_tree
from .profiles import DEFAULT_PROFILES, EdgeContext, Profile

DEFAULTS = {"max_pairs": 48, "max_snap_m": 4.0, "max_extremities": 8,
            "landmark_reach_m": 2.0, "hazard_reach_m": 1.0}
# Legacy sign-candidate kinds (pre-signage stage) mapped onto sign categories.
LEGACY_SIGN_KINDS = {"exit_sign_candidate": "exit", "accessibility_sign_candidate": "accessible_restroom"}
MAX_SIGN_TEXT = 32


def _sign_text(sign: dict, texts: dict[str, str]) -> str | None:
    pieces = [texts[t] for t in sign.get("text_ids") or [] if texts.get(t)]
    if not pieces and isinstance(sign.get("text"), str):
        pieces = [sign["text"]]
    text = " ".join(" ".join(pieces).split())
    return text if 0 < len(text) <= MAX_SIGN_TEXT else None


def _nearest_floor(graph: NavGraph, xz: tuple[float, float]) -> str | None:
    best = min(((math.hypot(n.position[0] - xz[0], n.position[2] - xz[1]), n.floor_id) for n in graph.nodes),
               default=None)
    return None if best is None else best[1]


def collect_features(graph: NavGraph, places: list, signs: list, doors: list, hazards: list,
                     text: list) -> maneuvers.Features:
    texts = {str(t.get("id")): str(t.get("text", "")).strip() for t in text or [] if t.get("id")}
    out = maneuvers.Features()
    # The legacy sign-candidate shape has no ids; fall back to the stable list position.
    keyed = [(str(sign.get("id") or f"sign-{index}"), sign) for index, sign in enumerate(signs or [])]
    for sign_id, sign in sorted(keyed, key=lambda item: item[0]):
        position = sign.get("position_m")
        if not position or len(position) < 3:
            continue
        category = sign.get("category") or LEGACY_SIGN_KINDS.get(sign.get("kind"), "unknown")
        if sign.get("kind") == "text_region" and not _sign_text(sign, texts):
            continue  # Unread text regions make poor landmarks.
        out.landmarks.append(maneuvers.Feature(sign_id, "sign", (float(position[0]), float(position[2])),
                                               float(position[1]), None, str(category), text=_sign_text(sign, texts)))
    for place in sorted(places or [], key=lambda p: str(p.get("id"))):
        position = place.get("position_m")
        if not position or len(position) < 3:
            continue
        out.landmarks.append(maneuvers.Feature(str(place.get("id")), "place", (float(position[0]), float(position[2])),
                                               float(position[1]), place.get("floor_id"),
                                               str(place.get("category") or "unknown"), place.get("name"),
                                               dict(place.get("names") or {})))
    floors = {node.floor_id for node in graph.nodes}
    door_keys = ("kind", "measured_clear_width_m", "nominal_width_m", "meets_clear_width")
    for door in sorted(doors or [], key=lambda d: str(d.get("id"))):
        center = door.get("center_xz_m")
        if not center:
            continue
        xz = (float(center[0]), float(center[1]))
        # Door records carry no height; attribute each to the floor of the nearest graph node.
        floor = _nearest_floor(graph, xz) if len(floors) > 1 else None
        feature = maneuvers.Feature(str(door.get("id")), "door", xz, None, floor,
                                    extra={k: door[k] for k in door_keys if door.get(k) is not None})
        out.doors.append(feature)
        out.landmarks.append(feature)
    for node in graph.nodes:  # Door nodes from the graph generator not covered by the doors product.
        if graph.node_kind(node.id) != "door":
            continue
        xz = (node.position[0], node.position[2])
        if any(math.dist(xz, d.xz) < 1.0 and d.floor_id in (None, node.floor_id) for d in out.doors):
            continue
        feature = maneuvers.Feature(f"node:{node.id}", "door", xz, node.position[1], node.floor_id)
        out.doors.append(feature)
        out.landmarks.append(feature)
    for hazard in sorted(hazards or [], key=lambda h: str(h.get("id"))):
        position = hazard.get("position_m")
        if not position or len(position) < 3:
            continue
        out.hazards.append(maneuvers.Feature(str(hazard.get("id")), "hazard", (float(position[0]), float(position[2])),
                                             float(position[1]), None, str(hazard.get("kind") or "other"),
                                             extra={"severity": hazard.get("severity", "warning")}))
    return out


def edge_contexts(graph: NavGraph, features: maneuvers.Features, landmark_reach: float,
                  hazard_reach: float) -> dict[int, EdgeContext]:
    """Landmark count and worst nearby hazard per surface edge (drives the low-vision soft costs)."""
    contexts = {}
    for edge in graph.edges:
        if edge.kind != "surface":
            continue
        points = geo.as_array(edge.points)
        cum = geo.cumulative(points)
        low, high = points[:, [0, 2]].min(axis=0), points[:, [0, 2]].max(axis=0)
        floor, y = graph.nodes[edge.source].floor_id, float(points[:, 1].mean())

        def near(candidates: list[maneuvers.Feature], reach: float) -> list[maneuvers.Feature]:
            hits = []
            for feature in candidates:
                xz = np.asarray(feature.xz)
                if np.any(xz < low - reach) or np.any(xz > high + reach) or not maneuvers.on_floor(feature, floor, y):
                    continue
                hit = geo.project(points, cum, xz)
                if hit is not None and hit.distance_m <= reach:
                    hits.append(feature)
            return hits

        count = len(near(features.landmarks, landmark_reach))
        severities = {feature.extra.get("severity") for feature in near(features.hazards, hazard_reach)}
        worst = "barrier" if "barrier" in severities else ("warning" if severities else None)
        if count or worst:
            contexts[edge.index] = EdgeContext(count, worst)
    return contexts


def _endpoints(graph: NavGraph, places: list, regions: list, config: dict) -> tuple[list[Endpoint], str, list[dict]]:
    endpoints, unmapped = place_endpoints(graph, places or [], config["max_snap_m"])
    if len(endpoints) >= 2:
        return endpoints, "places", unmapped
    endpoints = region_endpoints(graph, regions or [], config["max_snap_m"])
    if len(endpoints) >= 2:
        return endpoints, "regions", unmapped
    return extremity_endpoints(graph, config["max_extremities"]), "graph_extremities", unmapped


def _limiting(graph: NavGraph, profile: Profile, source: int, goal: int, cache: dict) -> list[str]:
    """Requirements that, dropped alone, would connect the pair. Diagnostic only: never used to route."""
    names = []
    for field_name, relaxed_value in (("requires_step_free", False), ("minimum_clear_width_m", None),
                                      ("maximum_slope", None)):
        if getattr(profile.requirements, field_name) in (False, None):
            continue
        key = (profile.name, field_name, source)
        if key not in cache:
            relaxed = replace(profile, requirements=replace(profile.requirements, **{field_name: relaxed_value}),
                              soft_costs={})
            cache[key] = shortest_tree(graph, relaxed, source)
        if math.isfinite(cache[key].cost[goal]):
            names.append(field_name)
    return names


def build_routes(nav_graph: dict, places: list | None = None, signs: list | None = None,
                 regions: list | None = None, doors: list | None = None, hazards: list | None = None,
                 text: list | None = None, config: dict | None = None,
                 profiles: tuple[Profile, ...] = DEFAULT_PROFILES,
                 languages: tuple[str, ...] | None = None) -> tuple[dict, dict]:
    """Returns the `routes` product JSON and a summary."""
    config = {**DEFAULTS, **(config or {})}
    languages = tuple(languages or i18n.available_languages())
    locales = [i18n.load(language) for language in languages]
    graph = NavGraph.from_json(nav_graph)
    features = collect_features(graph, places or [], signs or [], doors or [], hazards or [], text or [])
    contexts = edge_contexts(graph, features, config["landmark_reach_m"], config["hazard_reach_m"])
    endpoints, endpoint_source, unmapped = _endpoints(graph, places, regions, config)
    pairs, truncated = select_pairs(endpoints, int(config["max_pairs"]))

    routes, unreachable, reachability, relaxed_cache = [], [], {}, {}
    shortest_length: dict[tuple[str, str], float] = {}
    for profile in profiles:
        adjacent, trees = adjacency(graph, profile), {}
        routed = 0
        for origin, destination in pairs:
            source, goal = graph.index[origin.node_id], graph.index[destination.node_id]
            if source not in trees:
                trees[source] = shortest_tree(graph, profile, source, contexts, adjacent)
            path = extract(graph, trees[source], goal)
            if path is None:
                unreachable.append({"from_place": origin.id, "to_place": destination.id, "profile": profile.name,
                                    "reason": "no_verified_route",
                                    "limiting_requirements": _limiting(graph, profile, source, goal, relaxed_cache)})
                continue
            routed += 1
            steps = maneuvers.build_steps(graph, path.edges, origin, destination, features)
            route = {
                "id": f"{profile.name}:{origin.id}->{destination.id}",
                "from_place": origin.id, "to_place": destination.id, "profile": profile.name,
                "node_ids": path.node_ids, "edge_ids": [edge.id for edge in path.edges],
                "length_m": round(path.length_m, 3), "estimated_seconds": round(path.seconds, 2),
                "cost": round(path.cost, 3),
                "floors": sorted({graph.nodes[graph.index[n]].floor_id for n in path.node_ids}),
                "steps": steps,
                "instructions": {locale.language: render.localize(steps, locale, origin, destination)
                                 for locale in locales},
            }
            routes.append(route)
            key = (origin.id, destination.id)
            shortest_length[key] = min(shortest_length.get(key, math.inf), path.length_m)
        reachability[profile.name] = {"pairs": len(pairs), "routed": routed, "unreachable": len(pairs) - routed,
                                      "fraction": round(routed / len(pairs), 3) if pairs else None}
    for route in routes:
        best = shortest_length[(route["from_place"], route["to_place"])]
        route["detour_ratio"] = round(route["length_m"] / best, 3) if best > 0 else 1.0

    product = {
        "graph_id": graph.id,
        "profiles": {profile.name: profile.to_json() for profile in profiles},
        "languages": [{"code": l.language, "direction": l.direction} for l in locales],
        "endpoint_source": endpoint_source,
        "endpoints": [endpoint.to_json() for endpoint in endpoints],
        "unmapped_places": unmapped,
        "routes": routes,
        "unreachable": unreachable,
        "reachability": reachability,
        "pairs_truncated": truncated,
    }
    summary = {"endpoints": len(endpoints), "endpoint_source": endpoint_source, "pairs": len(pairs),
               "pairs_truncated": truncated, "routes": len(routes), "unreachable": len(unreachable),
               "languages": list(languages),
               "reachable_fraction": {name: value["fraction"] for name, value in reachability.items()}}
    return product, summary
