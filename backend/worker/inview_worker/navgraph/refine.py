"""Topology clean-up of the raw skeleton graph: spur pruning, junction merging, chain dissolving."""
from __future__ import annotations

import cv2
import numpy as np

from .topology import PixelGraph


def _clearance(dt: np.ndarray, pos: np.ndarray) -> float:
    col = int(np.clip(round(pos[0]), 0, dt.shape[1] - 1))
    row = int(np.clip(round(pos[1]), 0, dt.shape[0] - 1))
    return float(dt[row, col])


def prune_spurs(graph: PixelGraph, dt: np.ndarray, spur_min_px: float, spur_ratio: float) -> int:
    """Remove dead-end branches that are very short or only reach into a corner.

    A thinning spur into a convex corner gets narrower towards its tip and its length is explained by
    that narrowing (about sqrt(2) x the clearance drop for a right-angle corner). A real dead-end
    corridor keeps its clearance, and a branch into a larger space gains clearance; both are kept.
    """
    removed = 0
    degrees = graph.degrees()
    spurs = []
    for edge_id, edge in graph.edges.items():
        for tip, base in ((edge.u, edge.v), (edge.v, edge.u)):
            if tip != base and degrees[tip] == 1 and degrees[base] >= 3 and graph.nodes[tip].is_skeleton:
                spurs.append((edge.length_px(), edge_id, tip, base))
    for length, edge_id, tip, base in sorted(spurs):
        if edge_id not in graph.edges or graph.degree(base) < 3 or graph.degree(tip) != 1:
            continue
        drop = _clearance(dt, graph.nodes[base].pos) - _clearance(dt, graph.nodes[tip].pos)
        if length < spur_min_px or (drop > 0 and length < spur_ratio * drop + spur_min_px):
            graph.remove_node(tip)
            removed += 1
    return removed


def dissolve_chains(graph: PixelGraph) -> int:
    count = 0
    for node_id in sorted(graph.nodes):
        if node_id in graph.nodes and graph.dissolve(node_id):
            count += 1
    return count


def merge_junctions(graph: PixelGraph, dt: np.ndarray, merge_px: float) -> int:
    """Contract short skeleton edges between two branching nodes (near-duplicate junctions)."""
    merged = 0
    while True:
        degrees = graph.degrees()
        short = sorted((edge.length_px(), edge_id) for edge_id, edge in graph.edges.items()
                       if edge.kind == "skeleton" and edge.u != edge.v and edge.length_px() < merge_px
                       and degrees[edge.u] >= 3 and degrees[edge.v] >= 3
                       and graph.nodes[edge.u].is_skeleton and graph.nodes[edge.v].is_skeleton)
        if not short:
            return merged
        _, edge_id = short[0]
        edge = graph.edges[edge_id]
        cu, cv = _clearance(dt, graph.nodes[edge.u].pos), _clearance(dt, graph.nodes[edge.v].pos)
        keep = edge.u if (cu, -edge.u) >= (cv, -edge.v) else edge.v
        graph.contract(edge_id, keep)
        graph.nodes[keep].kind = "junction"
        graph.break_loops()
        merged += 1


def drop_fragments(graph: PixelGraph, min_length_px: float) -> int:
    """Remove tiny isolated pieces (free-space specks behind furniture)."""
    dropped = 0
    for component in graph.components():
        members = set(component)
        length = sum(e.length_px() for e in graph.edges.values() if e.u in members)
        if length < min_length_px:
            for node_id in component:
                graph.remove_node(node_id)
            dropped += 1
    return dropped


def cover_free_components(graph: PixelGraph, free: np.ndarray, dt: np.ndarray, min_area_px: float) -> int:
    """Give every sizeable free-space component at least one node.

    A convex, empty room thins to a single point (or its corner spurs are all pruned): its correct
    graph is one node at the point of maximum clearance, from which every anchor is in straight sight.
    """
    count, labels, stats, _ = cv2.connectedComponentsWithStats((free > 0).astype(np.uint8), connectivity=8)
    covered = set()
    for node in graph.nodes.values():
        col, row = int(round(node.pos[0])), int(round(node.pos[1]))
        if 0 <= row < labels.shape[0] and 0 <= col < labels.shape[1]:
            covered.add(int(labels[row, col]))
    for edge in graph.edges.values():
        mid = edge.path[len(edge.path) // 2]
        covered.add(int(labels[int(round(mid[1])), int(round(mid[0]))]))
    added = 0
    for label in range(1, count):
        if label in covered or stats[label, cv2.CC_STAT_AREA] < min_area_px:
            continue
        masked = np.where(labels == label, dt, -1.0)
        row, col = np.unravel_index(int(np.argmax(masked)), masked.shape)
        graph.add_node((float(col), float(row)), "centre", meta={"clearance_px": float(dt[row, col])})
        added += 1
    return added


def refine(graph: PixelGraph, dt: np.ndarray, free: np.ndarray, resolution: float, spur_min_m: float,
           spur_ratio: float, merge_m: float, min_component_m2: float, max_rounds: int = 25) -> dict[str, int]:
    stats = {"spurs_pruned": 0, "junctions_merged": 0, "fragments_dropped": 0, "centre_nodes": 0}
    graph.break_loops()
    for _ in range(max_rounds):
        pruned = prune_spurs(graph, dt, spur_min_m / resolution, spur_ratio)
        merged = merge_junctions(graph, dt, merge_m / resolution)
        dissolved = dissolve_chains(graph)
        stats["spurs_pruned"] += pruned
        stats["junctions_merged"] += merged
        if not (pruned or merged or dissolved):
            break
    stats["fragments_dropped"] = drop_fragments(graph, 2 * spur_min_m / resolution)
    # Isolated nodes left by pruning carry no routes.
    for node_id in [n for n, d in graph.degrees().items() if d == 0]:
        graph.remove_node(node_id)
    stats["centre_nodes"] = cover_free_components(graph, free, dt, min_component_m2 / resolution ** 2)
    return stats
