"""Dijkstra over a `NavGraph` with the backend's search order (`backend/src/routing.rs`).

Parity details: adjacency follows edge document order, the queue pops the lowest cost and then the
lowest node index, relaxation is strictly-less-than, non-finite candidates are skipped. A full
single-source tree yields the same parent for each goal as the backend's early-exit search, so one
tree serves every destination from a source.
"""
from __future__ import annotations

import heapq
import math
from dataclasses import dataclass, field

from .graph import Edge, NavGraph, edge_seconds, eligible
from .profiles import EdgeContext, Profile


@dataclass
class Tree:
    source: int
    cost: list[float]
    seconds: list[float]
    parent: list[tuple[int, int] | None]   # (previous node, edge index)


@dataclass
class Path:
    node_ids: list[str]
    edges: list[Edge]
    seconds: float
    cost: float
    length_m: float = field(default=0.0)


def adjacency(graph: NavGraph, profile: Profile) -> list[list[int]]:
    out: list[list[int]] = [[] for _ in graph.nodes]
    for edge in graph.edges:
        if eligible(edge, profile.requirements):
            out[edge.source].append(edge.index)
    return out


def shortest_tree(graph: NavGraph, profile: Profile, source: int,
                  contexts: dict[int, EdgeContext] | None = None,
                  adjacent: list[list[int]] | None = None) -> Tree:
    adjacent = adjacency(graph, profile) if adjacent is None else adjacent
    contexts = contexts or {}
    count = len(graph.nodes)
    cost, seconds = [math.inf] * count, [math.inf] * count
    parent: list[tuple[int, int] | None] = [None] * count
    cost[source], seconds[source] = 0.0, 0.0
    queue = [(0.0, source)]
    while queue:
        current, node = heapq.heappop(queue)
        if current > cost[node]:
            continue
        for edge_index in adjacent[node]:
            edge = graph.edges[edge_index]
            travel = edge_seconds(edge, profile.speed_mps)
            step = travel * profile.multiplier(edge, contexts.get(edge_index, EdgeContext()))
            candidate = current + step
            if not math.isfinite(candidate):
                continue
            if candidate < cost[edge.target]:
                cost[edge.target], seconds[edge.target] = candidate, seconds[node] + travel
                parent[edge.target] = (node, edge_index)
                heapq.heappush(queue, (candidate, edge.target))
    return Tree(source, cost, seconds, parent)


def extract(graph: NavGraph, tree: Tree, goal: int) -> Path | None:
    if not math.isfinite(tree.cost[goal]):
        return None
    edges, cursor = [], goal
    while cursor != tree.source:
        step = tree.parent[cursor]
        if step is None:
            return None
        cursor, edge_index = step
        edges.append(graph.edges[edge_index])
    edges.reverse()
    node_ids = [graph.nodes[tree.source].id] + [graph.nodes[edge.target].id for edge in edges]
    return Path(node_ids, edges, tree.seconds[goal], tree.cost[goal], sum(edge.length_m for edge in edges))


def find_route(graph: NavGraph, profile: Profile, source_id: str, goal_id: str,
               contexts: dict[int, EdgeContext] | None = None) -> Path | None:
    """One route between node ids; `None` when no verified route exists under the requirements."""
    if source_id not in graph.index or goal_id not in graph.index:
        raise KeyError("unknown node")
    tree = shortest_tree(graph, profile, graph.index[source_id], contexts)
    return extract(graph, tree, graph.index[goal_id])
