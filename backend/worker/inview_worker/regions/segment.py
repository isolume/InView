"""Room / corridor / doorway segmentation of the floor map's free space.

Pipeline (all OpenCV on the floor map grid):
1. Domain: walkable cells with enclosed furniture islands filled (`fill_holes`) and specks removed.
2. Door spans from the `doors` product are cut into the domain so rooms separate at doorways.
3. `cv2.distanceTransform` of the cut domain; persistent maxima give one marker per space
   (`seeds.persistent_markers`), and `cv2.watershed` grows them until they meet inside the
   constrictions.
4. Doorway rectangles are stamped over the door spans as their own regions.
5. Over-segmentation is merged: regions whose shared passage is nearly as wide as the narrower
   region (not a constriction), or too small to be a space, are fused with their neighbour, unless
   RoomPlan says they are different rooms.
6. `describe.describe_regions` classifies, vectorises and links the result.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np

from ..geometry import Grid
from .masks import Doorway, cut_doorways, drop_specks, fill_holes, fill_polygon
from .seeds import persistent_markers


@dataclass(frozen=True)
class Params:
    max_hole_m2: float = 6.0              # Enclosed obstacles up to this size belong to the room.
    min_space_m2: float = 0.5             # Free-space fragments smaller than this are dropped.
    min_region_m2: float = 1.5            # Regions smaller than this are merged into a neighbour.
    min_level_m: float = 0.25             # Lowest clearance level swept (0.5 m wide passages).
    min_persistence_m: float = 0.3        # A space must rise this far above its saddle ...
    saddle_ratio: float = 0.75            # ... and the saddle must be this much narrower.
    merge_ratio: float = 0.8              # Passage width / narrower space width above which regions fuse.
    door_extend_m: float = 0.15           # Door cut extends past the jambs by this much.
    doorway_half_depth_m: float = 0.15    # Doorway regions reach this far either side of the span.
    corridor_slenderness: float = 2.0     # Medial-axis length / mean width for corridors ...
    corridor_elongation: float = 2.5      # ... or minAreaRect long / short side ...
    corridor_max_width_m: float = 3.0     # ... and never wider than this.
    open_area_m2: float = 120.0           # Spaces this large are open areas (halls, lobbies).
    open_enclosure: float = 0.5           # Spaces bounded by obstacles less than this are open areas.
    inferred_doorway_max_m: float = 1.6   # Undocumented constrictions up to this wide become doorways.


@dataclass
class Segmentation:
    """Intermediate result: integer label raster plus which labels are doorways."""
    grid: Grid
    labels: np.ndarray                    # int32, 0 = not a region
    domain: np.ndarray                    # bool free-space domain
    clearance: np.ndarray                 # float32 distance to the nearest barrier (m)
    doorways: dict[int, Doorway] = field(default_factory=dict)
    room_hint: dict[int, str] = field(default_factory=dict)


def boundary_stats(labels: np.ndarray, clearance: np.ndarray | None = None) -> dict[tuple[int, int], tuple[int, float]]:
    """4-neighbour contacts between distinct positive labels: {(low, high): (pixels, max clearance)}.

    The largest clearance on a shared boundary is half the width of the passage between the two
    regions (a doorway or constriction is narrow; a false split inside one room is wide).
    """
    keys, values = [], []
    for (a, b), (ca, cb) in (((labels[:, :-1], labels[:, 1:]), _pair(clearance, 1)),
                             ((labels[:-1, :], labels[1:, :]), _pair(clearance, 0))):
        touching = (a != b) & (a > 0) & (b > 0)
        low, high = np.minimum(a[touching], b[touching]), np.maximum(a[touching], b[touching])
        keys.append(low.astype(np.int64) << 32 | high.astype(np.int64))
        values.append(np.zeros(len(low)) if ca is None else np.maximum(ca[touching], cb[touching]))
    keys_all, values_all = np.concatenate(keys), np.concatenate(values)
    unique, inverse, counts = np.unique(keys_all, return_inverse=True, return_counts=True)
    peak = np.zeros(len(unique))
    np.maximum.at(peak, inverse, values_all)
    return {(int(k >> 32), int(k & 0xFFFFFFFF)): (int(c), float(m)) for k, c, m in zip(unique, counts, peak)}


def _pair(values: np.ndarray | None, axis: int):
    if values is None:
        return None, None
    return (values[:, :-1], values[:, 1:]) if axis == 1 else (values[:-1, :], values[1:, :])


def boundary_pairs(labels: np.ndarray) -> dict[tuple[int, int], int]:
    """4-neighbour contact counts between distinct positive labels: {(low, high): pixels}."""
    return {pair: count for pair, (count, _) in boundary_stats(labels).items()}


def _fill_unlabeled(labels: np.ndarray, domain: np.ndarray, blocked: set[int], iterations: int = 200) -> None:
    """Grow non-blocked labels into unlabelled domain cells (watershed lines, orphan fragments)."""
    kernel = np.ones((3, 3), np.uint8)
    frozen = np.isin(labels, list(blocked))   # Blocked labels never grow, so this stays valid.
    for _ in range(iterations):
        todo = domain & (labels == 0)
        if not todo.any():
            return
        source = np.where(frozen, 0, labels)
        grown = cv2.dilate(source.astype(np.float32), kernel).astype(np.int32)
        take = todo & (grown > 0)
        if not take.any():
            return
        labels[take] = grown[take]


def bounding_boxes(labels: np.ndarray, pad: int = 0) -> dict[int, tuple[slice, slice]]:
    """Per positive label, the (rows, cols) slices of its bounding box grown by `pad` cells."""
    rows, cols = np.nonzero(labels > 0)
    values = labels[rows, cols]
    if not len(values):
        return {}
    size = int(values.max()) + 1
    r0, c0 = np.full(size, labels.shape[0]), np.full(size, labels.shape[1])
    r1, c1 = np.full(size, -1), np.full(size, -1)
    np.minimum.at(r0, values, rows)
    np.minimum.at(c0, values, cols)
    np.maximum.at(r1, values, rows)
    np.maximum.at(c1, values, cols)
    height, width = labels.shape
    return {int(l): (slice(max(int(r0[l]) - pad, 0), min(int(r1[l]) + 1 + pad, height)),
                     slice(max(int(c0[l]) - pad, 0), min(int(c1[l]) + 1 + pad, width)))
            for l in np.unique(values)}


def _keep_largest_parts(labels: np.ndarray, protected: set[int]) -> None:
    """A region is one connected piece: detach smaller fragments so they can be re-grown."""
    for label, box in bounding_boxes(labels).items():
        if label in protected:
            continue
        crop = labels[box]
        count, parts, stats, _ = cv2.connectedComponentsWithStats((crop == label).astype(np.uint8), connectivity=4)
        if count > 2:
            largest = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
            crop[(parts > 0) & (parts != largest)] = 0


def _room_hints(labels: np.ndarray, rooms: list[tuple[str, np.ndarray]]) -> dict[int, str]:
    """RoomPlan room covering most of each label (>= half of it), used to veto cross-room merges."""
    hints = {}
    for label, box in bounding_boxes(labels).items():
        mask = labels[box] == label
        area = int(mask.sum())
        best = max(((int((mask & room[box]).sum()), rid) for rid, room in rooms), default=(0, None))
        if best[1] is not None and best[0] * 2 >= area:
            hints[int(label)] = best[1]
    return hints


def split_by_rooms(seeds: np.ndarray, rooms: list[tuple[str, np.ndarray]], min_px: int) -> np.ndarray:
    """Split markers that span several RoomPlan rooms (open-plan spaces with no wall between them).

    Each sizeable part of a marker inside one room becomes its own marker; parts outside every room
    stay with the original marker. The merge step later refuses to fuse regions of different rooms.
    """
    out = np.zeros_like(seeds)
    label = 0
    for marker in range(1, int(seeds.max()) + 1):
        cells = seeds == marker
        if not cells.any():
            continue
        parts = [cells & room for _, room in rooms]
        parts = [part for part in parts if int(part.sum()) >= min_px]
        rest = cells.copy()
        for part in parts if len(parts) > 1 else []:
            part &= out == 0
            label += 1
            out[part] = label
            rest &= ~part
        if rest.any() and (len(parts) <= 1 or int(rest.sum()) >= min_px):
            label += 1
            out[rest & (out == 0)] = label
    return out


def _merge(seg: Segmentation, params: Params) -> None:
    res = seg.grid.resolution
    min_px = params.min_region_m2 / res ** 2
    doors = set(seg.doorways)
    while True:
        labels = seg.labels
        ids = [int(l) for l in np.unique(labels) if l > 0 and l not in doors]
        if len(ids) < 2:
            return
        flat = labels.ravel()
        counts = np.bincount(flat[flat > 0], minlength=int(labels.max()) + 1)
        peaks = np.zeros(len(counts))
        np.maximum.at(peaks, flat[flat > 0], seg.clearance.ravel()[flat > 0])
        area = {l: int(counts[l]) for l in ids}
        width = {l: 2 * float(peaks[l]) for l in ids}
        best = None
        for (a, b), (contact, passage) in sorted(boundary_stats(labels, seg.clearance).items()):
            if a in doors or b in doors or contact < 2:
                continue
            ha, hb = seg.room_hint.get(a), seg.room_hint.get(b)
            if ha and hb and ha != hb:
                continue
            if min(area[a], area[b]) < min_px:
                score = (1, contact)    # Too small to be a space of its own: fuse with the widest contact.
            else:
                score = (0, 2 * passage / max(min(width[a], width[b]), res))
                if score[1] < params.merge_ratio:
                    continue            # A real constriction between two spaces.
            if best is None or score > best[0]:
                best = (score, a, b)
        if best is None:
            # Small regions touching only doorways or nothing stay; nothing else to merge.
            return
        _, a, b = best
        keep, drop = (a, b) if area[a] >= area[b] else (b, a)
        labels[labels == drop] = keep
        if keep not in seg.room_hint and drop in seg.room_hint:
            seg.room_hint[keep] = seg.room_hint[drop]
        seg.room_hint.pop(drop, None)


def segment(walkable: np.ndarray, grid: Grid, doorways: list[Doorway] | None = None,
            rooms: list[tuple[str, np.ndarray]] | None = None, params: Params = Params()) -> Segmentation:
    """Segment `walkable` (uint8/bool raster on `grid`) into labelled spaces and doorways.

    `rooms` are optional RoomPlan rooms as (id, boolean raster) used to keep rooms apart.
    """
    res = grid.resolution
    doorways = doorways or []
    domain = fill_holes((walkable > 0).astype(np.uint8) * 255, int(params.max_hole_m2 / res ** 2))
    domain = drop_specks(domain, max(1, int(params.min_space_m2 / res ** 2)))
    cut = cut_doorways(domain, grid, doorways, params.door_extend_m)
    clearance = cv2.distanceTransform(cut, cv2.DIST_L2, 5) * res
    in_domain = domain > 0
    seg = Segmentation(grid, np.zeros(domain.shape, np.int32), in_domain, clearance)
    if not in_domain.any():
        return seg

    seeds = persistent_markers(
        clearance, res, params.min_level_m, params.min_persistence_m, params.saddle_ratio,
        max(1, int(0.05 / res ** 2)))
    if rooms:
        seeds = split_by_rooms(seeds, rooms, int(params.min_region_m2 / res ** 2))
    markers = np.where(seeds > 0, seeds + 1, 0).astype(np.int32)
    markers[cut == 0] = 1          # Background basin: outside the domain and along door cuts.
    # cv2.watershed floods by the colour *difference* between neighbours, not by absolute level, so
    # a distance-map relief would race along the flat strip by the walls. A flat image makes the
    # flood a geodesic Voronoi partition between the markers, which already reach up to the
    # saddles; the boundaries therefore settle inside the constrictions.
    cv2.watershed(np.zeros((*cut.shape, 3), np.uint8), markers)
    labels = np.where(markers > 1, markers - 1, 0).astype(np.int32)
    labels[~in_domain] = 0

    # Doorway regions override the watershed along each door span.
    next_label = int(labels.max()) + 1
    near_domain = cv2.dilate(in_domain.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
    stamped = np.zeros(labels.shape, bool)
    for door in doorways:
        core = fill_polygon(grid, door.rectangle(0.0, params.doorway_half_depth_m))
        wide = fill_polygon(grid, door.rectangle(params.door_extend_m, params.doorway_half_depth_m))
        # The exact span counts even where a door leaf or jamb blocked the free-space evidence.
        cells = (wide & in_domain) | (core & near_domain)
        cells &= ~stamped    # A door and an opening reported at one span: the first one wins.
        if int(cells.sum()) < 2:
            continue
        stamped |= cells
        labels[cells] = next_label
        seg.domain |= cells
        seg.doorways[next_label] = door
        next_label += 1
    seg.labels = labels
    protected = set(seg.doorways)
    _keep_largest_parts(labels, protected)
    _fill_unlabeled(labels, seg.domain, protected)
    seg.room_hint = _room_hints(labels, rooms or [])
    for door_label in protected:
        seg.room_hint.pop(door_label, None)
    _merge(seg, params)
    if params.inferred_doorway_max_m > 0:
        _infer_doorways(seg, params)
        protected = set(seg.doorways)
    _keep_largest_parts(labels, protected)
    _fill_unlabeled(labels, seg.domain, protected)
    return seg


def _infer_doorways(seg: Segmentation, params: Params) -> None:
    """Stamp a doorway on every narrow passage between two spaces that no door/opening explains.

    Walk-only captures (no RoomPlan) still get doorway nodes: the shared watershed boundary gives
    the passage line (principal axis of its pixels) and its clearance gives the width.
    """
    grid, labels, res = seg.grid, seg.labels, seg.grid.resolution
    cross = cv2.getStructuringElement(cv2.MORPH_CROSS, (3, 3))
    found = []
    boxes = bounding_boxes(labels)
    for (a, b), (contact, passage) in sorted(boundary_stats(labels, seg.clearance).items()):
        if a in seg.doorways or b in seg.doorways or contact < 2 or 2 * passage > params.inferred_doorway_max_m:
            continue
        ra, ca = boxes[a]
        rb, cb = boxes[b]
        rows_box = slice(max(min(ra.start, rb.start) - 1, 0), max(ra.stop, rb.stop) + 1)
        cols_box = slice(max(min(ca.start, cb.start) - 1, 0), max(ca.stop, cb.stop) + 1)
        crop = labels[rows_box, cols_box]
        in_a, in_b = crop == a, crop == b
        edge = (in_a & (cv2.dilate(in_b.astype(np.uint8), cross) > 0)) | (in_b & (cv2.dilate(in_a.astype(np.uint8), cross) > 0))
        rows, cols = np.nonzero(edge)
        rows, cols = rows + rows_box.start, cols + cols_box.start
        points = np.column_stack((cols, rows)).astype(np.float64)
        centre = points.mean(axis=0)
        _, _, axes = np.linalg.svd(points - centre, full_matrices=False)
        direction = axes[0]
        projection = (points - centre) @ direction
        ends = centre + np.outer([projection.min() - 0.5, projection.max() + 0.5], direction)
        world = np.column_stack((grid.x0 + ends[:, 0] * res, grid.z0 + ends[:, 1] * res))
        found.append((world, 2 * passage))
    found.sort(key=lambda f: (round(float(f[0].mean(axis=0)[1]), 2), round(float(f[0].mean(axis=0)[0]), 2)))
    next_label = int(labels.max()) + 1
    taken = np.isin(labels, list(seg.doorways))
    for index, (world, width) in enumerate(found, start=1):
        door = Doorway(f"inferred-{index}", "inferred_opening", world[0], world[1], round(width, 3))
        cells = fill_polygon(grid, door.rectangle(0.0, params.doorway_half_depth_m)) & seg.domain & (labels > 0)
        cells &= ~taken
        if not cells.any():
            continue
        taken |= cells
        labels[cells] = next_label
        seg.doorways[next_label] = door
        next_label += 1
