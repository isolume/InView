"""Local mirror of the backend's graph validation (backend/src/graph.rs `Graph::validate` plus serde's
`deny_unknown_fields` and type checks), so the worker never publishes a graph the backend rejects."""
from __future__ import annotations

import math
from typing import Any

GRAPH_FIELDS = {"schema_version", "id", "nodes", "edges", "metadata"}
GRAPH_REQUIRED = {"schema_version", "id", "nodes", "edges"}
NODE_FIELDS = {"id", "map_id", "floor_id", "x", "y", "z", "label"}
NODE_REQUIRED = NODE_FIELDS - {"label"}
EDGE_FIELDS = {"id", "from", "to", "step_free", "availability", "minimum_clear_width_m", "maximum_slope", "segment"}
EDGE_REQUIRED = {"id", "from", "to", "segment"}
SURFACE_FIELDS = {"type", "map_id", "floor_id", "path_points"}
TRANSITION_FIELDS = {"type", "connector_id", "kind", "estimated_seconds"}
POINT_FIELDS = {"x", "y", "z"}
AVAILABILITY = {"available", "closed", "unknown"}
CONNECTOR_KINDS = {"elevator", "stairs", "escalator"}


class GraphValidationError(ValueError):
    pass


def _fields(obj: Any, allowed: set[str], required: set[str], what: str) -> None:
    if not isinstance(obj, dict):
        raise GraphValidationError(f"{what} must be an object.")
    unknown = set(obj) - allowed
    if unknown:
        raise GraphValidationError(f"{what} has unknown fields {sorted(unknown)}.")
    missing = required - set(obj)
    if missing:
        raise GraphValidationError(f"{what} is missing fields {sorted(missing)}.")


def _number(value: Any, what: str, optional: bool = False) -> float | None:
    if value is None and optional:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise GraphValidationError(f"{what} must be a number.")
    return float(value)


def _string(value: Any, what: str) -> str:
    if not isinstance(value, str):
        raise GraphValidationError(f"{what} must be a string.")
    return value


def _nonempty(value: str, name: str) -> None:
    if not value.strip():
        raise GraphValidationError(f"{name} must not be empty.")


def _point(obj: Any, what: str) -> tuple[float, float, float]:
    _fields(obj, POINT_FIELDS, POINT_FIELDS, what)
    return tuple(_number(obj[k], f"{what}.{k}") for k in ("x", "y", "z"))  # type: ignore[return-value]


def _finite(p) -> bool:
    return all(math.isfinite(v) for v in p)


def _distance(a, b) -> float:
    return math.dist(a, b)


def validate_graph(graph: Any) -> None:
    """Raise GraphValidationError with the backend's message when `graph` would be rejected."""
    _fields(graph, GRAPH_FIELDS, GRAPH_REQUIRED, "Graph")
    version = graph["schema_version"]
    if isinstance(version, bool) or not isinstance(version, int) or version < 0:
        raise GraphValidationError("schema_version must be an unsigned integer.")
    if not isinstance(graph.get("metadata", {}), dict):
        raise GraphValidationError("metadata must be an object.")
    if not isinstance(graph["nodes"], list) or not isinstance(graph["edges"], list):
        raise GraphValidationError("nodes and edges must be arrays.")
    if version != 1:
        raise GraphValidationError("Only draft schema_version 1 is supported.")
    _nonempty(_string(graph["id"], "graph id"), "graph id")

    nodes: dict[str, dict] = {}
    for node in graph["nodes"]:
        _fields(node, NODE_FIELDS, NODE_REQUIRED, "Node")
        for key in ("id", "map_id", "floor_id"):
            _string(node[key], key)
        if node.get("label") is not None:
            _string(node["label"], "label")
        position = tuple(_number(node[k], k) for k in ("x", "y", "z"))
        _nonempty(node["id"], "node id")
        _nonempty(node["map_id"], "map_id")
        _nonempty(node["floor_id"], "floor_id")
        if not _finite(position):
            raise GraphValidationError(f"Node {node['id']} has invalid coordinates.")
        if node["id"] in nodes:
            raise GraphValidationError(f"Duplicate node id: {node['id']}.")
        nodes[node["id"]] = {**node, "_pos": position}

    edge_ids = set()
    for edge in graph["edges"]:
        _fields(edge, EDGE_FIELDS, EDGE_REQUIRED, "Edge")
        for key in ("id", "from", "to"):
            _string(edge[key], key)
        if edge.get("step_free") is not None and not isinstance(edge["step_free"], bool):
            raise GraphValidationError("step_free must be a boolean or null.")
        availability = edge.get("availability", "unknown")
        if availability not in AVAILABILITY:
            raise GraphValidationError(f"Unknown availability {availability!r}.")
        width = _number(edge.get("minimum_clear_width_m"), "minimum_clear_width_m", optional=True)
        slope = _number(edge.get("maximum_slope"), "maximum_slope", optional=True)
        segment = edge["segment"]
        if not isinstance(segment, dict) or segment.get("type") not in ("surface", "transition"):
            raise GraphValidationError("segment.type must be 'surface' or 'transition'.")
        if segment["type"] == "surface":
            _fields(segment, SURFACE_FIELDS, SURFACE_FIELDS, "Surface segment")
            _string(segment["map_id"], "map_id")
            _string(segment["floor_id"], "floor_id")
            if not isinstance(segment["path_points"], list):
                raise GraphValidationError("path_points must be an array.")
            points = [_point(p, "path point") for p in segment["path_points"]]
        else:
            _fields(segment, TRANSITION_FIELDS, TRANSITION_FIELDS, "Transition segment")
            _string(segment["connector_id"], "connector_id")
            if segment["kind"] not in CONNECTOR_KINDS:
                raise GraphValidationError(f"Unknown connector kind {segment['kind']!r}.")
            seconds = _number(segment["estimated_seconds"], "estimated_seconds")

        # Graph::validate, in order.
        _nonempty(edge["id"], "edge id")
        if edge["id"] in edge_ids:
            raise GraphValidationError(f"Duplicate edge id: {edge['id']}.")
        edge_ids.add(edge["id"])
        start = nodes.get(edge["from"])
        if start is None:
            raise GraphValidationError(f"Edge {edge['id']} references a missing start node.")
        end = nodes.get(edge["to"])
        if end is None:
            raise GraphValidationError(f"Edge {edge['id']} references a missing end node.")
        if (width is not None and (not math.isfinite(width) or width <= 0)) or \
                (slope is not None and (not math.isfinite(slope) or slope < 0)):
            raise GraphValidationError(f"Edge {edge['id']} has invalid measurements.")
        if segment["type"] == "surface":
            if (start["map_id"] != segment["map_id"] or end["map_id"] != segment["map_id"]
                    or start["floor_id"] != segment["floor_id"] or end["floor_id"] != segment["floor_id"]):
                raise GraphValidationError(f"Surface {edge['id']} crosses map or floor frames.")
            length = sum(_distance(a, b) for a, b in zip(points, points[1:]))
            if len(points) < 2 or not all(_finite(p) for p in points) or not math.isfinite(length):
                raise GraphValidationError(f"Surface {edge['id']} needs a finite 3D path.")
            if _distance(points[0], start["_pos"]) > 0.05 or _distance(points[-1], end["_pos"]) > 0.05:
                raise GraphValidationError(f"Surface {edge['id']} does not meet its endpoints.")
        else:
            _nonempty(segment["connector_id"], "connector_id")
            if not math.isfinite(seconds) or seconds < 0:
                raise GraphValidationError(f"Transition {edge['id']} needs a nonnegative time estimate.")
            if segment["kind"] in ("stairs", "escalator") and edge.get("step_free") is True:
                raise GraphValidationError(f"Transition {edge['id']} cannot be marked step-free.")


def is_valid(graph: Any) -> bool:
    try:
        validate_graph(graph)
    except GraphValidationError:
        return False
    return True
