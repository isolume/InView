"""Read-only view of a backend Graph v1 document (`backend/src/graph.rs`) with the backend's routing
semantics (`backend/src/routing.rs`): directed edges, only `availability == "available"` edges are
usable, missing measurements never satisfy a requirement, stairs/escalators are never step-free.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

STEP_CONNECTORS = frozenset({"stairs", "escalator"})


@dataclass(frozen=True)
class Requirements:
    """Mirror of the backend `Requirements`; hard filters that are never relaxed."""
    requires_step_free: bool = False
    minimum_clear_width_m: float | None = None
    maximum_slope: float | None = None

    def to_json(self) -> dict[str, Any]:
        return {"requires_step_free": self.requires_step_free,
                "minimum_clear_width_m": self.minimum_clear_width_m, "maximum_slope": self.maximum_slope}


@dataclass(frozen=True)
class Node:
    index: int
    id: str
    map_id: str
    floor_id: str
    position: tuple[float, float, float]
    label: str | None = None


@dataclass(frozen=True)
class Edge:
    index: int
    id: str
    source: int
    target: int
    raw: dict[str, Any]
    kind: str                                # "surface" or "transition"
    points: tuple[tuple[float, float, float], ...] = ()
    connector: str | None = None             # elevator | stairs | escalator (transitions)
    transition_seconds: float = 0.0
    length_m: float = 0.0

    @property
    def available(self) -> bool:
        return self.raw.get("availability", "unknown") == "available"

    @property
    def step_free(self) -> bool | None:
        return self.raw.get("step_free")

    @property
    def clear_width_m(self) -> float | None:
        return self.raw.get("minimum_clear_width_m")

    @property
    def slope(self) -> float | None:
        return self.raw.get("maximum_slope")


def _distance(a: tuple[float, float, float], b: tuple[float, float, float]) -> float:
    # Same evaluation order as the backend's `Point3::distance` (hypot of hypot).
    return math.hypot(math.hypot(a[0] - b[0], a[1] - b[1]), a[2] - b[2])


def polyline_length(points: tuple[tuple[float, float, float], ...] | list) -> float:
    return sum(_distance(points[i], points[i + 1]) for i in range(len(points) - 1))


@dataclass
class NavGraph:
    id: str
    nodes: list[Node]
    edges: list[Edge]
    metadata: dict[str, Any] = field(default_factory=dict)
    index: dict[str, int] = field(default_factory=dict)

    @classmethod
    def from_json(cls, document: dict[str, Any]) -> NavGraph:
        nodes, index = [], {}
        for raw in document.get("nodes", []):
            node = Node(len(nodes), str(raw["id"]), str(raw.get("map_id", "")), str(raw.get("floor_id", "")),
                        (float(raw["x"]), float(raw["y"]), float(raw["z"])), raw.get("label"))
            if node.id in index:
                raise ValueError(f"Duplicate node id: {node.id}")
            index[node.id] = node.index
            nodes.append(node)
        edges = []
        for raw in document.get("edges", []):
            if raw.get("from") not in index or raw.get("to") not in index:
                raise ValueError(f"Edge {raw.get('id')} references a missing node")
            segment = raw.get("segment") or {}
            source, target = index[raw["from"]], index[raw["to"]]
            if segment.get("type") == "transition":
                seconds = float(segment.get("estimated_seconds", 0.0))
                edges.append(Edge(len(edges), str(raw["id"]), source, target, raw, "transition",
                                  connector=segment.get("kind"), transition_seconds=seconds))
            else:
                points = tuple((float(p["x"]), float(p["y"]), float(p["z"])) for p in segment.get("path_points", []))
                if len(points) < 2:
                    points = (nodes[source].position, nodes[target].position)
                edges.append(Edge(len(edges), str(raw["id"]), source, target, raw, "surface",
                                  points=points, length_m=polyline_length(points)))
        return cls(str(document.get("id", "")), nodes, edges, dict(document.get("metadata") or {}), index)

    def node(self, node_id: str) -> Node:
        return self.nodes[self.index[node_id]]

    def node_kind(self, node_id: str) -> str | None:
        return (self.metadata.get("node_kinds") or {}).get(node_id)


def eligible(edge: Edge, requirements: Requirements) -> bool:
    """Exactly the backend filter: unknown values never pass a requirement."""
    if not edge.available:
        return False
    if requirements.requires_step_free and (edge.step_free is not True or
                                            (edge.kind == "transition" and edge.connector in STEP_CONNECTORS)):
        return False
    if requirements.minimum_clear_width_m is not None and not (
            edge.clear_width_m is not None and edge.clear_width_m >= requirements.minimum_clear_width_m):
        return False
    if requirements.maximum_slope is not None and not (
            edge.slope is not None and edge.slope <= requirements.maximum_slope):
        return False
    return True


def edge_seconds(edge: Edge, speed_mps: float) -> float:
    return edge.length_m / speed_mps if edge.kind == "surface" else edge.transition_seconds
