"""Route endpoints (places, region centroids, or graph extremities) and bounded pair selection."""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

from ..contracts import PlaceCategory
from .graph import NavGraph

# Destinations people most often need; routed between each other first.
KEY_CATEGORIES = (PlaceCategory.ENTRANCE, PlaceCategory.EXIT, PlaceCategory.EMERGENCY_EXIT,
                  PlaceCategory.ACCESSIBLE_RESTROOM, PlaceCategory.RESTROOM, PlaceCategory.ELEVATOR,
                  PlaceCategory.INFORMATION, PlaceCategory.RECEPTION, PlaceCategory.RAMP)
KEY_RANK = {category.value: rank for rank, category in enumerate(KEY_CATEGORIES)}
SOURCE_CATEGORIES = ("entrance", "exit")  # origins for "from every entrance to every place"


@dataclass(frozen=True)
class Endpoint:
    id: str
    kind: str                         # place | region | node
    node_id: str
    snap_m: float
    category: str = "unknown"
    name: str | None = None
    names: dict[str, str] = field(default_factory=dict)
    position: tuple[float, float, float] | None = None
    raw: dict[str, Any] = field(default_factory=dict)

    @property
    def is_key(self) -> bool:
        return self.category in KEY_RANK

    def to_json(self) -> dict[str, Any]:
        return {"id": self.id, "kind": self.kind, "node_id": self.node_id, "snap_m": round(self.snap_m, 3),
                "category": self.category, "name": self.name}


def _nearest_node(graph: NavGraph, x: float, z: float, floor_id: str | None, y: float | None = None) -> tuple[str, float] | None:
    best: tuple[float, str] | None = None
    floors = {node.floor_id for node in graph.nodes}
    for node in graph.nodes:
        if floor_id in floors and node.floor_id != floor_id:
            continue
        if floor_id not in floors and y is not None and abs(node.position[1] - y) > 2.0:
            continue  # Unknown floor id: stay within one storey of the reported height.
        distance = math.hypot(node.position[0] - x, node.position[2] - z)
        if best is None or (distance, node.id) < best:
            best = (distance, node.id)
    return None if best is None else (best[1], best[0])


def place_endpoints(graph: NavGraph, places: list[dict], max_snap_m: float) -> tuple[list[Endpoint], list[dict]]:
    """Map each place to a graph node: the generator's `metadata.place_nodes`, else the nearest node on
    its floor within `max_snap_m`. Returns endpoints and the places that could not be mapped."""
    explicit = graph.metadata.get("place_nodes") or {}
    endpoints, unmapped = [], []
    for place in sorted(places, key=lambda p: str(p.get("id"))):
        place_id = str(place.get("id"))
        position = place.get("position_m")
        pos3 = tuple(float(v) for v in position[:3]) if position and len(position) >= 3 else None
        node_id, snap = explicit.get(place_id), 0.0
        if node_id is not None and node_id in graph.index:
            if pos3 is not None:
                node = graph.node(node_id)
                snap = math.hypot(node.position[0] - pos3[0], node.position[2] - pos3[2])
        elif pos3 is not None:
            found = _nearest_node(graph, pos3[0], pos3[2], place.get("floor_id"), pos3[1])
            if found is None or found[1] > max_snap_m:
                unmapped.append({"id": place_id, "reason": "no graph node within snap distance"})
                continue
            node_id, snap = found
        else:
            unmapped.append({"id": place_id, "reason": "no position and no place_nodes entry"})
            continue
        endpoints.append(Endpoint(place_id, "place", node_id, snap, str(place.get("category") or "unknown"),
                                  place.get("name"), dict(place.get("names") or {}), pos3, place))
    return endpoints, unmapped


def region_endpoints(graph: NavGraph, regions: list[dict], max_snap_m: float) -> list[Endpoint]:
    explicit = graph.metadata.get("region_nodes") or {}
    endpoints = []
    for region in sorted(regions, key=lambda r: str(r.get("id"))):
        if region.get("kind") == "doorway":
            continue
        region_id, centroid = str(region.get("id")), region.get("centroid_xz_m")
        node_id, snap = explicit.get(region_id), 0.0
        if node_id not in graph.index:
            if not centroid:
                continue
            found = _nearest_node(graph, float(centroid[0]), float(centroid[1]), None)
            if found is None or found[1] > max_snap_m:
                continue
            node_id, snap = found
        node = graph.node(node_id)
        position = (float(centroid[0]), node.position[1], float(centroid[1])) if centroid else node.position
        category = "corridor" if region.get("kind") == "corridor" else "room"
        endpoints.append(Endpoint(f"region:{region_id}", "region", node_id, snap, category,
                                  region.get("label"), {}, position, region))
    return endpoints


def extremity_endpoints(graph: NavGraph, limit: int) -> list[Endpoint]:
    """Dead ends of the surface network (undirected degree 1); else add the farthest-apart pair on one floor."""
    neighbours: dict[int, set[int]] = {node.index: set() for node in graph.nodes}
    for edge in graph.edges:
        if edge.source != edge.target:
            neighbours[edge.source].add(edge.target)
            neighbours[edge.target].add(edge.source)
    chosen = sorted(graph.nodes[i].id for i, adjacent in neighbours.items() if len(adjacent) == 1)
    if len(chosen) < 2 and len(graph.nodes) >= 2:
        best = None
        for a in graph.nodes:
            for b in graph.nodes:
                if a.index < b.index and (a.map_id, a.floor_id) == (b.map_id, b.floor_id):
                    distance = math.hypot(a.position[0] - b.position[0], a.position[2] - b.position[2])
                    if best is None or distance > best[0]:
                        best = (distance, a.id, b.id)
        chosen = sorted(set(chosen) | ({best[1], best[2]} if best else set()))
    return [Endpoint(f"node:{node_id}", "node", node_id, 0.0, graph.node_kind(node_id) or "unknown",
                     graph.node(node_id).label, {}, graph.node(node_id).position)
            for node_id in chosen[:limit]]


def select_pairs(endpoints: list[Endpoint], max_pairs: int) -> tuple[list[tuple[Endpoint, Endpoint]], int]:
    """Ordered (origin, destination) pairs in priority order, capped. Returns pairs and the number
    dropped by the cap. Priority: every entrance/exit to every endpoint, then key-to-key, then the rest."""
    ordered = sorted(endpoints, key=lambda e: (KEY_RANK.get(e.category, len(KEY_RANK)), e.id))
    sources = [e for e in ordered if e.category in SOURCE_CATEGORIES]
    pairs, seen = [], set()

    def add(a: Endpoint, b: Endpoint, symmetric: bool) -> None:
        if a.id == b.id or a.node_id == b.node_id or (a.id, b.id) in seen:
            return
        if symmetric and (b.id, a.id) in seen:
            return
        seen.add((a.id, b.id))
        pairs.append((a, b))

    for source in sources:
        for target in ordered:
            add(source, target, False)
    keys = [e for e in ordered if e.is_key]
    for i, a in enumerate(keys):
        for b in keys[i + 1:]:
            add(a, b, True)
    for i, a in enumerate(ordered):
        for b in ordered[i + 1:]:
            add(a, b, True)
    return pairs[:max_pairs], max(0, len(pairs) - max_pairs)
