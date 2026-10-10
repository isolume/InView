"""Attach semantic anchors (doors, region centroids, places) to the skeleton graph.

Every anchor connects to the nearest *reachable* skeleton point: candidates are tried in order of
straight-line distance and the first whose straight segment stays inside the free space (or, failing
that, the walkable raster, i.e. it never crosses the obstacle raster) wins. The skeleton edge is split
there and a straight connector edge joins the anchor node.

Doors:
- If the skeleton passes through the doorway (a skeleton point within half the door width of its
  centre, in line of sight), that point becomes the door node, so every route through the door
  passes the node and its edges carry the door's clear width.
- Otherwise (a door narrower than the body-clearance skeleton allows, or a skeleton that misses it),
  the door centre becomes a node joined by connectors to the nearest reachable skeleton point on
  each side of the door plane. Those connectors record the door's (possibly failing) width.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np

from . import measure
from .topology import PixelGraph

MAX_LOS_TRIES = 400


@dataclass
class AnchorContext:
    graph: PixelGraph
    grid: object
    walkable: np.ndarray
    free: np.ndarray
    max_snap_px: float
    max_access_px: float
    approach_px: float = 6.0
    unattached: list[dict] = field(default_factory=list)
    _targets: tuple[np.ndarray, np.ndarray, np.ndarray] | None = None

    # --- skeleton targets --------------------------------------------------------------------
    def targets(self) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """(points (N, 2), edge ids, indices) of every skeleton node (edge id -1, index = node id)
        and every skeleton-edge path point."""
        if self._targets is None:
            nodes = sorted(n for n, node in self.graph.nodes.items() if node.is_skeleton)
            pts = [np.array([self.graph.nodes[n].pos for n in nodes]).reshape(-1, 2)]
            eids, idxs = [np.full(len(nodes), -1)], [np.array(nodes, dtype=int)]
            for edge_id, edge in sorted(self.graph.edges.items()):
                if edge.kind != "skeleton":
                    continue
                pts.append(edge.path)
                eids.append(np.full(len(edge.path), edge_id))
                idxs.append(np.arange(len(edge.path)))
            self._targets = (np.vstack(pts), np.concatenate(eids).astype(int), np.concatenate(idxs).astype(int))
        return self._targets

    def invalidate(self) -> None:
        self._targets = None

    def nearest(self, point: np.ndarray, masks: tuple[np.ndarray, ...], max_px: float,
                keep=None, los=measure.clear_line) -> tuple[int, int] | None:
        """Closest skeleton (edge, index) in straight-line sight of `point` through any of `masks`
        (tried in order: the first mask with a hit wins)."""
        pts, eids, idxs = self.targets()
        if not len(pts):
            return None
        distance = np.linalg.norm(pts - point, axis=1)
        ok = distance <= max_px
        if keep is not None:
            ok &= keep(pts)
        candidates = np.nonzero(ok)[0]
        order = candidates[np.lexsort((idxs[candidates], eids[candidates], distance[candidates]))]
        for mask in masks:
            for i in order[:MAX_LOS_TRIES]:
                if los(mask, point, pts[i]):
                    return int(eids[i]), int(idxs[i])
        return None

    def position(self, hit: tuple[int, int]) -> np.ndarray:
        if hit[0] < 0:
            return self.graph.nodes[hit[1]].pos.copy()
        return self.graph.edges[hit[0]].path[hit[1]].copy()

    def at(self, position: np.ndarray) -> tuple[int, int]:
        """The (edge, index) currently holding exactly `position` (first in deterministic order)."""
        pts, eids, idxs = self.targets()
        i = int(np.argmin(np.linalg.norm(pts - position, axis=1)))
        return int(eids[i]), int(idxs[i])

    def snap(self, hit: tuple[int, int]) -> int:
        if hit[0] < 0:
            return hit[1]
        node = self.graph.split_edge(hit[0], hit[1], kind="snap")
        self.invalidate()
        return node

    # --- access points -------------------------------------------------------------------------
    def access_point(self, point: np.ndarray, within: np.ndarray | None = None,
                     from_obstacle: bool = False) -> np.ndarray | None:
        """`point` if it is free space, else the nearest free cell (optionally inside `within`)."""
        rows, cols, inside = measure.cells(point[None], self.free.shape)
        if inside[0] and self.free[rows[0], cols[0]] and (within is None or within[rows[0], cols[0]]):
            return point
        mask = self.free > 0
        if within is not None:
            mask &= within > 0
        r, c = np.nonzero(mask)
        if not len(r):
            return None
        cand = np.column_stack((c, r)).astype(np.float64)
        distance = np.linalg.norm(cand - point, axis=1)
        order = np.lexsort((r, c, distance))
        for i in order[:MAX_LOS_TRIES]:
            if within is None and distance[i] > self.max_access_px:   # places only; regions use their polygon
                break
            if within is not None or (measure.exit_then_clear(self.walkable, point, cand[i]) if from_obstacle
                                      else measure.clear_line(self.walkable, point, cand[i])):
                return cand[i]
        return None

    def connect(self, point: np.ndarray, kind: str, key: str, label: str | None, meta: dict) -> int | None:
        hit = self.nearest(point, (self.free, self.walkable), self.max_snap_px)
        if hit is None:
            return None
        target = self.snap(hit)
        node = self.graph.add_node(point, kind, key=key, label=label, meta=meta)
        self.graph.add_edge(node, target, [point, self.graph.nodes[target].pos], kind="connector")
        return node


def _px(grid, xz) -> np.ndarray:
    return grid.cells(np.asarray([xz], dtype=np.float64))[0]


def _approaches(ctx: AnchorContext, door_node: int) -> None:
    """Split every edge leaving a door node `approach_px` away from it, so only the short edges
    across the doorway carry the door's clear width; longer edges keep their own measurement."""
    for edge_id in ctx.graph.incident(door_node):
        if ctx.graph.split_at_distance(edge_id, door_node, ctx.approach_px, kind="approach") is not None:
            ctx.invalidate()


def attach_doors(ctx: AnchorContext, doors: list[dict]) -> dict[str, dict]:
    grid, graph = ctx.grid, ctx.graph
    details: dict[str, dict] = {}
    for door in sorted(doors or [], key=lambda d: str(d.get("id"))):
        door_id = str(door.get("id"))
        try:
            centre = _px(grid, door["center_xz_m"])
            a, b = (_px(grid, p) for p in door["span_xz_m"])
        except (KeyError, TypeError, ValueError, IndexError):
            ctx.unattached.append({"kind": "door", "id": door_id, "reason": "missing_geometry"})
            continue
        width = door.get("measured_clear_width_m") or door.get("nominal_width_m")
        label = "Opening" if door.get("kind") == "opening" else "Door"
        meta = {"door_id": door_id, "clear_width_m": width, "meets_clear_width": door.get("meets_clear_width"),
                "width_cap_m": float(width) if width else None, "issues": list(door.get("issues") or [])}
        half_px = max(float(np.linalg.norm(b - a)) / 2, 0.3 / grid.resolution)
        span = b - a
        along = span / max(float(np.linalg.norm(span)), 1e-9)
        normal = np.array([-along[1], along[0]])

        # 1. The skeleton passes through the doorway: the nearest such point becomes the door node.
        def in_doorway(pts, centre=centre, normal=normal, along=along, half_px=half_px):
            rel = pts - centre
            return (np.abs(rel @ normal) <= 0.3 / grid.resolution) & (np.abs(rel @ along) <= half_px)

        hit = ctx.nearest(centre, (ctx.walkable,), half_px * 1.5, keep=in_doorway)
        if hit is not None:
            node = ctx.snap(hit)
            if graph.nodes[node].is_skeleton:
                graph.nodes[node].kind, graph.nodes[node].key = "door", door_id
                graph.nodes[node].label, graph.nodes[node].meta = label, meta
                _approaches(ctx, node)
                details[door_id] = {"node": node, "connection": "skeleton", **meta}
                continue

        # 2. Connect the door centre to the skeleton on both sides of the door plane. A door leaf
        #    captured closed blocks the centre cell; doors are opened to pass, so the connector may
        #    start inside that obstacle as long as it then stays walkable (recorded as a note).
        rows, cols, inside = measure.cells(centre[None], ctx.walkable.shape)
        if not inside[0]:
            ctx.unattached.append({"kind": "door", "id": door_id, "reason": "door_outside_floor_map"})
            continue
        if not ctx.walkable[rows[0], cols[0]]:
            meta["notes"] = ["door_centre_blocked_at_capture (closed leaf?)"]
        positions = []
        for side in (1.0, -1.0):
            def on_side(pts, side=side, centre=centre, normal=normal):
                return side * ((pts - centre) @ normal) > 1.0
            side_hit = ctx.nearest(centre, (ctx.walkable,), ctx.max_snap_px, keep=on_side,
                                   los=measure.exit_then_clear)
            if side_hit is not None:
                positions.append(ctx.position(side_hit))
        if not positions:
            ctx.unattached.append({"kind": "door", "id": door_id, "reason": "no_reachable_skeleton"})
            continue
        node = graph.add_node(centre, "door", key=door_id, label=label, meta=meta)
        # Splitting one edge renumbers it, so look each target up again by position.
        targets = [ctx.snap(ctx.at(position)) for position in positions]
        for target in dict.fromkeys(targets):
            graph.add_edge(node, target, [centre, graph.nodes[target].pos], kind="door_connector")
        _approaches(ctx, node)
        details[door_id] = {"node": node, "connection": "connectors" if len(set(targets)) == 2 else "one_side", **meta}
    return details


def _polygon_mask(grid, shape, polygon) -> np.ndarray | None:
    if not polygon or len(polygon) < 3:
        return None
    mask = np.zeros(shape, np.uint8)
    cv2.fillPoly(mask, [np.round(grid.cells(np.asarray(polygon, dtype=np.float64))).astype(np.int32)], 255)
    return mask if mask.any() else None


def attach_regions(ctx: AnchorContext, regions: list[dict], door_positions: list[np.ndarray]) -> dict[str, int]:
    """One node per room/corridor/open area, at its centroid (moved into free space if needed)."""
    grid, nodes = ctx.grid, {}
    for region in sorted(regions or [], key=lambda r: str(r.get("id"))):
        region_id = str(region.get("id"))
        centroid = region.get("centroid_xz_m")
        if centroid is None or len(centroid) != 2:
            ctx.unattached.append({"kind": "region", "id": region_id, "reason": "missing_centroid"})
            continue
        point = _px(grid, centroid)
        if region.get("kind") == "doorway" and any(
                np.linalg.norm(point - d) * grid.resolution < 0.75 for d in door_positions):
            continue                                # the door node already represents it
        within = _polygon_mask(grid, ctx.free.shape, region.get("polygon_xz_m"))
        access = ctx.access_point(point, within)
        if access is None:
            ctx.unattached.append({"kind": "region", "id": region_id, "reason": "no_free_space_in_region"})
            continue
        label = region.get("label") or str(region.get("kind") or "area").replace("_", " ").title()
        node = ctx.connect(access, "region", region_id, label,
                           {"region_id": region_id, "region_kind": region.get("kind"),
                            "centroid_xz_m": [round(float(v), 3) for v in centroid],
                            "moved_m": round(float(np.linalg.norm(access - point) * grid.resolution), 3)})
        if node is None:
            ctx.unattached.append({"kind": "region", "id": region_id, "reason": "no_reachable_skeleton"})
            continue
        nodes[region_id] = node
    return nodes


def attach_places(ctx: AnchorContext, places: list[dict]) -> dict[str, int]:
    """One node per place at its access point: the place itself when it stands in free space, else
    the nearest free cell reached by leaving the object and then staying walkable."""
    grid, nodes = ctx.grid, {}
    for place in sorted(places or [], key=lambda p: str(p.get("id"))):
        place_id = str(place.get("id"))
        position = place.get("position_m")
        if not position or len(position) != 3 or not all(np.isfinite(np.asarray(position, dtype=np.float64))):
            ctx.unattached.append({"kind": "place", "id": place_id, "reason": "missing_position"})
            continue
        point = _px(grid, [position[0], position[2]])
        access = ctx.access_point(point, from_obstacle=True)
        if access is None:
            ctx.unattached.append({"kind": "place", "id": place_id, "reason": "no_access_point"})
            continue
        label = place.get("name") or str(place.get("category") or "place").replace("_", " ").title()
        node = ctx.connect(access, "place", place_id, label,
                           {"place_id": place_id, "category": place.get("category"),
                            "position_m": [round(float(v), 3) for v in position],
                            "access_offset_m": round(float(np.linalg.norm(access - point) * grid.resolution), 3)})
        if node is None:
            ctx.unattached.append({"kind": "place", "id": place_id, "reason": "no_reachable_skeleton"})
            continue
        nodes[place_id] = node
    return nodes
