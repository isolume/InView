"""Route geometry for GeoJSON: actual directed edge paths, separated by map and floor."""
from __future__ import annotations

import numpy as np


def surface_legs(graph: dict, route: dict, projection_map_id: str | None) -> tuple[list[dict], list[str]]:
    nodes = {n.get("id"): n for n in graph.get("nodes", []) if isinstance(n, dict)}
    edges = {e.get("id"): e for e in graph.get("edges", []) if isinstance(e, dict)}
    node_ids = route.get("node_ids") or []
    if any(n not in nodes for n in node_ids):
        return [], ["references unknown nav_graph node(s); skipped"]
    edge_ids = route.get("edge_ids") or []
    if not edge_ids:
        return [], ["has no selected edge_ids; route geometry was not exported"]
    if any(e not in edges for e in edge_ids):
        return [], ["references unknown nav_graph edge(s); skipped"]
    selected = [edges[e] for e in edge_ids]
    chain = [selected[0].get("from")] + [e.get("to") for e in selected]
    if (any(e.get("from") != chain[i] for i, e in enumerate(selected)) or
            any(n not in nodes for n in chain) or (node_ids and node_ids != chain)):
        return [], ["edge_ids do not describe the selected node path; skipped"]

    # A reference belongs to a local map frame. Never project a second map's coordinates through
    # the first map's origin/heading, even if both floors have the same display name.
    maps = {n.get("map_id") for n in nodes.values() if n.get("map_id")}
    if projection_map_id is None and len(maps) == 1:
        projection_map_id = next(iter(maps))
    legs, notices, active = [], [], None
    for edge in selected:
        segment = edge.get("segment") or {}
        if not isinstance(segment, dict) or segment.get("type") != "surface":
            active = None
            continue
        source, target = nodes[edge["from"]], nodes[edge["to"]]
        map_id, floor_id = segment.get("map_id"), segment.get("floor_id")
        if not map_id or not floor_id or any(
                n.get("map_id") != map_id or n.get("floor_id") != floor_id for n in (source, target)):
            notices.append(f"edge {edge['id']} has inconsistent map/floor identity; skipped")
            active = None
            continue
        if map_id != projection_map_id:
            notices.append(f"map {map_id} has no matching geographic reference; its route leg was not exported")
            active = None
            continue
        try:
            points = np.asarray([[p["x"], p["y"], p["z"]] for p in segment.get("path_points", [])], float)
        except (TypeError, ValueError, KeyError):
            points = np.empty((0, 3))
        if points.ndim != 2 or points.shape[1:] != (3,) or len(points) < 2 or not np.isfinite(points).all():
            notices.append(f"edge {edge['id']} has no usable surface path; skipped")
            active = None
            continue
        key = (map_id, floor_id)
        if active is not None and active["key"] == key and np.allclose(active["points"][-1], points[0], atol=1e-6, rtol=0):
            active["points"] = np.vstack((active["points"], points[1:]))
            active["edge_ids"].append(edge["id"])
        else:
            active = {"key": key, "points": points, "edge_ids": [edge["id"]]}
            legs.append(active)
    return legs, list(dict.fromkeys(notices))
