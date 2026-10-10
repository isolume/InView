"""Undirected multigraph in raster (column, row) coordinates with editing operations.

Every edge keeps its full polyline (`path[0]` is the start node's position, `path[-1]` the end
node's), so splitting, merging and pruning never lose geometry. IDs are integers allocated in a
deterministic order; string IDs are assigned only at export.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterator

import numpy as np

SKELETON_KINDS = frozenset({"junction", "endpoint", "split", "snap", "centre", "approach"})


@dataclass
class GNode:
    pos: np.ndarray                 # float (col, row)
    kind: str                       # junction | endpoint | split | snap | door | region | place
    label: str | None = None
    key: str | None = None          # stable source key for anchors, e.g. door id
    meta: dict[str, Any] = field(default_factory=dict)

    @property
    def is_skeleton(self) -> bool:
        return self.kind in SKELETON_KINDS


@dataclass
class GEdge:
    u: int
    v: int
    path: np.ndarray                # (N, 2) float (col, row), N >= 2
    kind: str = "skeleton"          # skeleton | connector | door_connector
    width_cap_m: float | None = None  # e.g. a door's measured clear width on edges through it
    meta: dict[str, Any] = field(default_factory=dict)

    def length_px(self) -> float:
        return float(np.linalg.norm(np.diff(self.path, axis=0), axis=1).sum())

    def other(self, node: int) -> int:
        return self.v if node == self.u else self.u

    def oriented(self, start: int) -> np.ndarray:
        """Path running from `start` to the other end."""
        return self.path if self.u == start else self.path[::-1]


class PixelGraph:
    def __init__(self) -> None:
        self.nodes: dict[int, GNode] = {}
        self.edges: dict[int, GEdge] = {}
        self._next_node = 0
        self._next_edge = 0

    # --- construction ---------------------------------------------------------------------
    def add_node(self, pos, kind: str, **kwargs) -> int:
        node_id = self._next_node
        self._next_node += 1
        self.nodes[node_id] = GNode(np.asarray(pos, dtype=np.float64), kind, **kwargs)
        return node_id

    def add_edge(self, u: int, v: int, path, kind: str = "skeleton", **kwargs) -> int:
        path = np.asarray(path, dtype=np.float64).reshape(-1, 2)
        if len(path) < 2:
            path = np.vstack((path, path))
        path = path.copy()
        path[0], path[-1] = self.nodes[u].pos, self.nodes[v].pos
        edge_id = self._next_edge
        self._next_edge += 1
        self.edges[edge_id] = GEdge(u, v, path, kind, **kwargs)
        return edge_id

    def remove_edge(self, edge_id: int) -> GEdge:
        return self.edges.pop(edge_id)

    def remove_node(self, node_id: int) -> None:
        for edge_id in self.incident(node_id):
            self.edges.pop(edge_id)
        self.nodes.pop(node_id)

    # --- queries ----------------------------------------------------------------------------
    def incident(self, node_id: int) -> list[int]:
        return [e for e, edge in self.edges.items() if edge.u == node_id or edge.v == node_id]

    def degree(self, node_id: int) -> int:
        return sum((edge.u == node_id) + (edge.v == node_id) for edge in self.edges.values())

    def degrees(self) -> dict[int, int]:
        result = dict.fromkeys(self.nodes, 0)
        for edge in self.edges.values():
            result[edge.u] += 1
            result[edge.v] += 1
        return result

    def iter_edges(self, kind: str | None = None) -> Iterator[tuple[int, GEdge]]:
        for edge_id, edge in self.edges.items():
            if kind is None or edge.kind == kind:
                yield edge_id, edge

    def components(self) -> list[list[int]]:
        """Connected components (node id lists), largest first, ties by smallest node id."""
        parent = {n: n for n in self.nodes}

        def find(n: int) -> int:
            while parent[n] != n:
                parent[n] = parent[parent[n]]
                n = parent[n]
            return n

        for edge in self.edges.values():
            a, b = find(edge.u), find(edge.v)
            if a != b:
                parent[max(a, b)] = min(a, b)
        groups: dict[int, list[int]] = {}
        for n in sorted(self.nodes):
            groups.setdefault(find(n), []).append(n)
        return sorted(groups.values(), key=lambda g: (-len(g), g[0]))

    # --- editing ----------------------------------------------------------------------------
    def split_edge(self, edge_id: int, index: int, kind: str = "split") -> int:
        """Insert a node at `path[index]`; returns the node (an existing end for index 0/-1)."""
        edge = self.edges[edge_id]
        last = len(edge.path) - 1
        if index <= 0:
            return edge.u
        if index >= last:
            return edge.v
        node = self.add_node(edge.path[index], kind)
        self.remove_edge(edge_id)
        common = dict(kind=edge.kind, width_cap_m=edge.width_cap_m, meta=dict(edge.meta))
        self.add_edge(edge.u, node, edge.path[:index + 1], **common)
        self.add_edge(node, edge.v, edge.path[index:], **common)
        return node

    def split_at_distance(self, edge_id: int, start: int, distance_px: float, kind: str = "split") -> int | None:
        """Insert a node `distance_px` along the edge from `start` (interpolating between path
        points); None when the edge is not longer than twice that distance."""
        edge = self.edges[edge_id]
        if edge.length_px() <= 2 * distance_px or edge.u == edge.v:
            return None
        path = edge.oriented(start)
        steps = np.linalg.norm(np.diff(path, axis=0), axis=1)
        cumulative = np.concatenate(([0.0], np.cumsum(steps)))
        i = int(np.searchsorted(cumulative, distance_px))       # path[i] is the first at/after it
        if abs(cumulative[i] - distance_px) > 1e-9:
            t = (distance_px - cumulative[i - 1]) / max(steps[i - 1], 1e-12)
            point = path[i - 1] + (path[i] - path[i - 1]) * t
            path = np.vstack((path[:i], point, path[i:]))
        oriented = path if edge.u == start else path[::-1]
        index = i if edge.u == start else len(path) - 1 - i
        edge.path = oriented
        return self.split_edge(edge_id, index, kind)

    def dissolve(self, node_id: int) -> bool:
        """Join the two edges of a degree-2 skeleton node into one (never creates a self-loop)."""
        node = self.nodes[node_id]
        incident = self.incident(node_id)
        if not node.is_skeleton or len(incident) != 2:
            return False
        a, b = (self.edges[e] for e in incident)
        if a.kind != b.kind or a.u == a.v or b.u == b.v:
            return False
        start, end = a.other(node_id), b.other(node_id)
        if start == end:
            return False
        path = np.vstack((a.oriented(start), b.oriented(node_id)[1:]))
        caps = [c for c in (a.width_cap_m, b.width_cap_m) if c is not None]
        meta = {**a.meta, **b.meta}
        for e in incident:
            self.remove_edge(e)
        self.nodes.pop(node_id)
        self.add_edge(start, end, path, kind=a.kind, width_cap_m=min(caps) if caps else None, meta=meta)
        return True

    def contract(self, edge_id: int, keep: int) -> None:
        """Merge the far end of `edge_id` into `keep`, extending its other edges along the edge."""
        edge = self.remove_edge(edge_id)
        gone = edge.other(keep)
        bridge = edge.oriented(keep)            # keep -> gone
        for other_id in self.incident(gone):
            other = self.edges[other_id]
            if other.u == gone and other.v == gone:
                other.u = other.v = keep
                other.path = np.vstack((bridge, other.path[1:-1], bridge[::-1]))
                continue
            if other.u == gone:
                other.u = keep
                other.path = np.vstack((bridge, other.path[1:]))
            else:
                other.v = keep
                other.path = np.vstack((other.path[:-1], bridge[::-1]))
        self.nodes.pop(gone)

    def break_loops(self) -> None:
        """Split self-loops at their midpoint so every edge joins two distinct nodes."""
        for edge_id in [e for e, edge in self.edges.items() if edge.u == edge.v]:
            edge = self.edges[edge_id]
            if len(edge.path) < 3:
                self.remove_edge(edge_id)
                continue
            self.split_edge(edge_id, len(edge.path) // 2, kind="split")
