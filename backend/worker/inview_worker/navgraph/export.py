"""Backend Graph v1 JSON (backend/src/graph.rs) and an in-process adjacency structure.

The backend rejects unknown fields, so everything beyond the schema goes into `metadata`. Every
undirected connection becomes two directed edges with reversed surface paths.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np

from . import measure
from .attributes import EdgeAttributes
from .topology import PixelGraph

KIND_PREFIX = {"door": "door-", "region": "region-", "place": "place-"}


@dataclass(frozen=True)
class NavEdge:
    id: str
    source: str
    target: str
    length_m: float
    minimum_clear_width_m: float
    maximum_slope: float | None
    step_free: bool | None
    kind: str
    path_xz_m: tuple[tuple[float, float], ...]


@dataclass
class NavGraph:
    """Networkx-free routing structure: nodes and outgoing directed edges per node."""
    graph_id: str
    nodes: dict[str, dict] = field(default_factory=dict)
    adjacency: dict[str, list[NavEdge]] = field(default_factory=dict)
    components: list[list[str]] = field(default_factory=list)

    def neighbors(self, node_id: str) -> list[str]:
        return [edge.target for edge in self.adjacency.get(node_id, [])]

    def edge(self, source: str, target: str) -> NavEdge | None:
        candidates = [e for e in self.adjacency.get(source, []) if e.target == target]
        return min(candidates, key=lambda e: e.length_m) if candidates else None


def simplify(path: np.ndarray, walkable: np.ndarray, epsilon_px: float) -> np.ndarray:
    """approxPolyDP polyline that still stays on walkable cells; endpoints are kept exactly."""
    path = np.asarray(path, dtype=np.float64)
    keep = np.concatenate(([True], np.linalg.norm(np.diff(path, axis=0), axis=1) > 1e-9))
    path = path[keep] if keep.sum() >= 2 else path[[0, -1]]
    if len(path) <= 2:
        return np.vstack((path[0], path[-1]))
    eps = epsilon_px
    while eps >= 0.25:
        simple = cv2.approxPolyDP(path.astype(np.float32).reshape(-1, 1, 2), eps, False).reshape(-1, 2)
        simple = simple.astype(np.float64)
        simple[0], simple[-1] = path[0], path[-1]
        if len(simple) >= 2 and measure.path_clear(walkable, simple):
            return simple
        eps /= 2
    return path


def _assign_node_ids(graph: PixelGraph) -> dict[int, str]:
    ids, used = {}, set()
    order = sorted(graph.nodes, key=lambda n: (graph.nodes[n].kind not in KIND_PREFIX, str(graph.nodes[n].key),
                                                round(graph.nodes[n].pos[1], 3), round(graph.nodes[n].pos[0], 3), n))
    for n in order:
        node = graph.nodes[n]
        if node.kind in KIND_PREFIX and node.key is not None:
            base = f"{KIND_PREFIX[node.kind]}{node.key}"
        else:
            base = f"node-{int(round(node.pos[0]))}-{int(round(node.pos[1]))}"
        candidate, suffix = base, 2
        while candidate in used:
            candidate, suffix = f"{base}-{suffix}", suffix + 1
        used.add(candidate)
        ids[n] = candidate
    return ids


def build_graph_json(graph: PixelGraph, attributes: dict[int, EdgeAttributes], *, graph_id: str, map_id: str,
                     floor_id: str, grid, floor_y: float, walkable: np.ndarray, epsilon_px: float,
                     metadata: dict, elevation: np.ndarray | None = None) -> tuple[dict, NavGraph, dict[int, str]]:
    res = grid.resolution

    def world(p) -> tuple[float, float]:
        return round(grid.x0 + float(p[0]) * res, 3), round(grid.z0 + float(p[1]) * res, 3)

    y = round(float(floor_y), 3)

    def height(p) -> float:
        if elevation is not None:
            rows, cols, inside = measure.cells(np.asarray([p]), elevation.shape)
            if inside[0] and np.isfinite(elevation[rows[0], cols[0]]):
                return round(float(elevation[rows[0], cols[0]]), 3)
        return y

    node_ids = _assign_node_ids(graph)
    nodes_json, nav = [], NavGraph(graph_id)
    for n in sorted(graph.nodes, key=lambda n: node_ids[n]):
        node = graph.nodes[n]
        x, z = world(node.pos)
        node_y = height(node.pos)
        entry = {"id": node_ids[n], "map_id": map_id, "floor_id": floor_id, "x": x, "y": node_y, "z": z}
        if node.label:
            entry["label"] = node.label
        nodes_json.append(entry)
        nav.nodes[node_ids[n]] = {"kind": node.kind, "position_m": [x, node_y, z], "label": node.label, "key": node.key}
        nav.adjacency[node_ids[n]] = []

    def undirected_key(e):
        edge = graph.edges[e]
        a, b = sorted((node_ids[edge.u], node_ids[edge.v]))
        return a, b, attributes[e].length_m, e

    edges_json, details, lengths = [], {}, {}
    for index, e in enumerate(sorted(graph.edges, key=undirected_key)):
        edge, attr = graph.edges[e], attributes[e]
        source, target = node_ids[edge.u], node_ids[edge.v]
        path = edge.path if source <= target else edge.path[::-1]
        if source > target:
            source, target = target, source
        # X/Z-only simplification can erase a ramp or landing. Keep cell-spaced samples when a
        # surface model is present so the exported path preserves the measured elevation changes.
        simple = (measure.dense(path, 1.0) if elevation is not None else
                  simplify(path, walkable, epsilon_px) if edge.kind == "skeleton" else np.vstack((path[0], path[-1])))
        points = [(world(p)[0], height(p), world(p)[1]) for p in simple]
        length_m = round(float(np.linalg.norm(np.diff(points, axis=0), axis=1).sum()), 3)
        lengths[e] = length_m
        base = f"e{index:04d}"
        for suffix, a, b, pts in (("f", source, target, points), ("r", target, source, points[::-1])):
            edge_id = f"{base}{suffix}"
            item = {"id": edge_id, "from": a, "to": b, "step_free": attr.step_free, "availability": "available",
                    "minimum_clear_width_m": attr.clear_width_m}
            if attr.maximum_slope is not None:
                item["maximum_slope"] = attr.maximum_slope
            item["segment"] = {"type": "surface", "map_id": map_id, "floor_id": floor_id,
                               "path_points": [{"x": px, "y": py, "z": pz} for px, py, pz in pts]}
            edges_json.append(item)
            nav.adjacency[a].append(NavEdge(edge_id, a, b, length_m, attr.clear_width_m, attr.maximum_slope,
                                            attr.step_free, edge.kind, tuple((px, pz) for px, _, pz in pts)))
        details[base] = {"kind": edge.kind, "length_m": length_m, "walked_fraction": attr.walked_fraction,
                         "step_free_basis": attr.step_free_basis, "hazards": attr.hazards}

    components = []
    for i, component in enumerate(graph.components()):
        members = set(component)
        names = sorted(node_ids[n] for n in component)
        length = sum(lengths[e] for e, edge in graph.edges.items() if edge.u in members)
        components.append({"id": f"c{i}", "node_count": len(component),
                           "edge_count": sum(edge.u in members for edge in graph.edges.values()),
                           "length_m": round(length, 2), "nodes": names})
        nav.components.append(names)

    meta = dict(metadata)
    meta.update({
        "node_kinds": {node_ids[n]: graph.nodes[n].kind for n in sorted(graph.nodes, key=lambda n: node_ids[n])},
        "components": components,
        "edges": details,
    })
    graph_json = {"schema_version": 1, "id": graph_id, "nodes": nodes_json, "edges": edges_json, "metadata": meta}
    return graph_json, nav, node_ids
