"""Medial-axis skeleton of the walkable space and its conversion into a pixel graph.

Pipeline (all OpenCV):
1. `clearance`: `distanceTransform` of the walkable raster (pixels to the nearest non-walkable cell;
   unknown space counts as non-walkable, so measurements are conservative).
2. `free_space`: cells with more than the body clearance radius, smoothed by a morphological opening.
3. `thin`: `cv2.ximgproc.thinning` (Zhang-Suen or Guo-Hall) to a one-pixel medial axis.
4. `classify`: neighbour counts via `filter2D` (endpoints have one neighbour) plus the crossing number
   (0->1 transitions around the 8-neighbourhood; >= 3 means branches meet). Junction pixels are
   grouped with `connectedComponents` so a thick crossing becomes one node.
5. `trace`: skeleton pixels minus node pixels split into simple segments (`connectedComponents`);
   each segment is ordered by a breadth-first walk between the nodes it touches. Closed loops and
   segments that return to one node get an extra split node so every edge joins distinct nodes.
"""
from __future__ import annotations

from collections import deque

import cv2
import numpy as np

from .topology import PixelGraph

NEIGHBOURS = ((-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1))  # (dr, dc) clockwise
_RING = np.ones((3, 3), np.float32)
_RING[1, 1] = 0


def clearance(walkable: np.ndarray) -> np.ndarray:
    """Distance in pixels from each walkable cell centre to the nearest non-walkable cell centre."""
    padded = cv2.copyMakeBorder((walkable > 0).astype(np.uint8), 1, 1, 1, 1, cv2.BORDER_CONSTANT, value=0)
    return cv2.distanceTransform(padded, cv2.DIST_L2, cv2.DIST_MASK_5)[1:-1, 1:-1]


def free_space(dt: np.ndarray, radius_px: float, smooth_px: int) -> np.ndarray:
    free = (dt > radius_px).astype(np.uint8) * 255
    if smooth_px > 0:
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * smooth_px + 1, 2 * smooth_px + 1))
        free = cv2.morphologyEx(free, cv2.MORPH_OPEN, kernel)
    return free


def _simple_lut() -> np.ndarray:
    """For each 8-neighbourhood code (bit i = NEIGHBOURS[i] set): is the centre a simple point?

    Simple (removable without changing topology) means the foreground neighbours form exactly one
    8-connected group and the background neighbours 4-adjacent to the centre form exactly one
    4-connected group (no hole is opened, no branch is cut)."""
    lut = np.zeros(256, bool)
    for code in range(256):
        on = [i for i in range(8) if code >> i & 1]
        off = [i for i in range(8) if not code >> i & 1]

        def groups(members, adjacent) -> int:
            seen, count = set(), 0
            for start in members:
                if start in seen:
                    continue
                count += 1
                stack = [start]
                while stack:
                    i = stack.pop()
                    if i in seen:
                        continue
                    seen.add(i)
                    stack.extend(j for j in members if j not in seen and adjacent(i, j))
            return count

        def adj8(i, j):
            (a, b), (c, d) = NEIGHBOURS[i], NEIGHBOURS[j]
            return max(abs(a - c), abs(b - d)) == 1

        def adj4(i, j):
            (a, b), (c, d) = NEIGHBOURS[i], NEIGHBOURS[j]
            return abs(a - c) + abs(b - d) == 1

        fg = groups(on, adj8)
        bg = 0
        seen: set[int] = set()
        for start in (i for i in off if i % 2 == 0):    # N, E, S, W touch the centre
            if start in seen:
                continue
            component, stack = set(), [start]
            while stack:
                i = stack.pop()
                if i in component:
                    continue
                component.add(i)
                stack.extend(j for j in off if j not in component and adj4(i, j))
            seen |= component
            bg += 1
        lut[code] = fg == 1 and bg == 1
    return lut


SIMPLE = _simple_lut()


def minimal(skeleton: np.ndarray) -> np.ndarray:
    """Sequentially remove simple non-end pixels (raster order) so the skeleton is strictly one
    pixel wide; thinning can leave two-pixel staircases and diagonals that look like junctions."""
    on = np.pad(skeleton > 0, 1)
    weights = [1 << i for i in range(8)]
    changed = True
    while changed:
        changed = False
        for r, c in zip(*np.nonzero(on)):
            code, count = 0, 0
            for (dr, dc), weight in zip(NEIGHBOURS, weights):
                if on[r + dr, c + dc]:
                    code |= weight
                    count += 1
            if count >= 2 and SIMPLE[code]:
                on[r, c] = False
                changed = True
    return on[1:-1, 1:-1].astype(np.uint8) * 255


def thin(free: np.ndarray, method: str = "zhang_suen") -> np.ndarray:
    kinds = {"zhang_suen": cv2.ximgproc.THINNING_ZHANGSUEN, "guo_hall": cv2.ximgproc.THINNING_GUOHALL}
    if method not in kinds:
        raise ValueError(f"Unknown thinning method {method!r}; use one of {sorted(kinds)}")
    return minimal(cv2.ximgproc.thinning(free, thinningType=kinds[method]))


def _shifted(mask: np.ndarray) -> list[np.ndarray]:
    padded = np.pad(mask, 1)
    h, w = mask.shape
    return [padded[1 + dr:1 + dr + h, 1 + dc:1 + dc + w] for dr, dc in NEIGHBOURS]


def classify(skeleton: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """(neighbour count, endpoint mask, junction mask) of a one-pixel skeleton."""
    on = (skeleton > 0).astype(np.uint8)
    count = cv2.filter2D(on, cv2.CV_16S, _RING, borderType=cv2.BORDER_CONSTANT).astype(np.int32) * on
    ring = _shifted(on)
    crossing = sum(((ring[i] == 0) & (ring[(i + 1) % 8] == 1)).astype(np.int32) for i in range(8)) * on
    endpoints = (on > 0) & (count == 1)
    junctions = (on > 0) & ((crossing >= 3) | (count >= 4))
    return count, endpoints, junctions


def _bfs_path(pixels: set[tuple[int, int]], start: tuple[int, int], goal: tuple[int, int] | None):
    """Shortest 8-connected path inside `pixels` (to `goal`, or to the farthest pixel)."""
    parent = {start: None}
    queue = deque([start])
    last = start
    while queue:
        cur = queue.popleft()
        last = cur
        if cur == goal:
            break
        r, c = cur
        for dr, dc in NEIGHBOURS:
            nxt = (r + dr, c + dc)
            if nxt in pixels and nxt not in parent:
                parent[nxt] = cur
                queue.append(nxt)
    end = goal if goal is not None and goal in parent else last
    path = []
    while end is not None:
        path.append(end)
        end = parent[end]
    return path[::-1]


def _segments(skeleton: np.ndarray, node_mask: np.ndarray):
    """Node clusters, segment labels, and each segment's attachments {node: [segment pixels]}."""
    n_nodes, node_labels = cv2.connectedComponents(node_mask.astype(np.uint8), connectivity=8)
    seg_mask = ((skeleton > 0) & ~node_mask).astype(np.uint8)
    n_segs, seg_labels = cv2.connectedComponents(seg_mask, connectivity=8)
    rows, cols = np.nonzero(seg_mask)
    segs = seg_labels[rows, cols]
    padded = np.pad(node_labels, 1)
    attachments: dict[int, dict[int, list[tuple[int, int]]]] = {s: {} for s in range(1, n_segs)}
    for dr, dc in NEIGHBOURS:
        touched = padded[rows + 1 + dr, cols + 1 + dc]
        for i in np.nonzero(touched)[0]:
            attachments[int(segs[i])].setdefault(int(touched[i]), []).append((int(rows[i]), int(cols[i])))
    pixels: dict[int, set[tuple[int, int]]] = {s: set() for s in range(1, n_segs)}
    for r, c, s in zip(rows.tolist(), cols.tolist(), segs.tolist()):
        pixels[s].add((r, c))
    return n_nodes, node_labels, pixels, attachments


def to_graph(skeleton: np.ndarray, dt: np.ndarray, max_rounds: int = 6) -> PixelGraph:
    """Convert a one-pixel skeleton into a PixelGraph whose edges carry pixel polylines."""
    _, endpoints, junctions = classify(skeleton)
    # Branch pixels right next to a junction can touch each other diagonally, which would join two
    # branches into one segment; absorb that first ring into the junction's cluster.
    ring = cv2.dilate(junctions.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
    node_mask = endpoints | (ring & (skeleton > 0))
    for _ in range(max_rounds):
        n_nodes, node_labels, pixels, attachments = _segments(skeleton, node_mask)
        extra = []
        for seg in sorted(pixels):
            attach = attachments[seg]
            members = pixels[seg]
            if not attach:                          # closed loop: seed a node at its first pixel
                extra.append(min(members))
            elif len(attach) == 1:                  # returns to the same node: split in the middle
                (node, touching), = attach.items()
                start = min(touching)
                path = _bfs_path(members, start, None)
                if len(members) > 2 and len(path) >= 3:
                    extra.append(path[len(path) // 2])
                elif len(members) > 2:
                    extra.append(path[-1])
            elif len(attach) > 2:                   # branches still touch: grow every touching cluster
                for node in sorted(attach):
                    extra.extend(attach[node])
        if not extra:
            break
        for r, c in extra:
            node_mask[r, c] = True
    else:
        n_nodes, node_labels, pixels, attachments = _segments(skeleton, node_mask)

    graph = PixelGraph()
    ids: dict[int, int] = {}
    all_rows, all_cols = np.nonzero(node_labels)
    labels = node_labels[all_rows, all_cols]
    order = np.argsort(labels, kind="stable")
    bounds = np.searchsorted(labels[order], np.arange(1, n_nodes + 1))
    for label in range(1, n_nodes):
        members = order[bounds[label - 1]:bounds[label]]
        rows, cols = all_rows[members], all_cols[members]
        centre = np.array([rows.mean(), cols.mean()])
        best = int(np.argmin((rows - centre[0]) ** 2 + (cols - centre[1]) ** 2))
        cluster_has_junction = bool(junctions[rows, cols].any())
        cluster_has_end = bool(endpoints[rows, cols].any())
        kind = "junction" if cluster_has_junction else ("endpoint" if cluster_has_end else "split")
        ids[label] = graph.add_node((float(cols[best]), float(rows[best])), kind,
                                    meta={"clearance_px": float(dt[rows[best], cols[best]])})

    for seg in sorted(pixels):
        attach = attachments[seg]
        if len(attach) < 2:
            continue                                # unresolved tiny loop; ignore
        (a, a_pix), (b, b_pix) = sorted(attach.items())[:2]
        path = _bfs_path(pixels[seg], min(a_pix), min(b_pix))
        polyline = [graph.nodes[ids[a]].pos] + [(float(c), float(r)) for r, c in path] + [graph.nodes[ids[b]].pos]
        graph.add_edge(ids[a], ids[b], polyline)
    return graph
