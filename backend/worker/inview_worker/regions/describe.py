"""Turn a label raster into `Region` records: kind, polygon, centroid, area, labels, adjacency."""
from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from ..geometry import Grid
from .masks import fill_polygon
from .segment import Params, Segmentation, boundary_stats, bounding_boxes

KIND_ORDER = {"room": 0, "corridor": 1, "open_area": 2, "doorway": 3}


@dataclass
class Shape:
    """Measured shape of one region."""
    area_m2: float
    clear_width_m: float      # 2 × mean clearance along the medial axis core
    max_width_m: float        # inscribed circle diameter
    axis_length_m: float      # medial axis core length
    elongation: float         # minAreaRect long / short side
    enclosure: float          # share of the outer rim that is an obstacle (vs unknown space)
    rect: tuple               # cv2.minAreaRect in grid pixels


def measure(mask: np.ndarray, obstacle: np.ndarray | None, others: np.ndarray, res: float) -> Shape:
    """`mask`: this region; `others`: cells of other regions (shared rims are neither open nor walled)."""
    area_px = int(mask.sum())
    ys, xs = np.nonzero(mask)
    y0, y1, x0, x1 = max(ys.min() - 2, 0), ys.max() + 3, max(xs.min() - 2, 0), xs.max() + 3
    crop = mask[y0:y1, x0:x1].astype(np.uint8) * 255
    padded = cv2.copyMakeBorder(crop, 1, 1, 1, 1, cv2.BORDER_CONSTANT, value=0)
    dt = cv2.distanceTransform(padded, cv2.DIST_L2, 5)[1:-1, 1:-1] * res
    skeleton = cv2.ximgproc.thinning(crop, thinningType=cv2.ximgproc.THINNING_ZHANGSUEN) > 0
    peak = float(dt.max())
    # The core of the medial axis (clearance >= 70 % of the widest point) drops the branches that
    # run into corners, leaving the space's spine: long for corridors, short for rooms.
    core = skeleton & (dt >= 0.7 * peak)
    if not core.any():
        core = dt >= peak
    clear_width = 2 * float(dt[core].mean())
    axis_length = max(float(core.sum()) * res, clear_width / 2)

    points = np.column_stack((xs, ys)).astype(np.float32)
    rect = cv2.minAreaRect(points)
    sides = sorted(rect[1])
    elongation = (sides[1] + 1) / (sides[0] + 1)

    rim = (cv2.dilate(mask.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0) & ~mask & ~others
    if obstacle is not None and rim.any():
        walled = int((rim & (obstacle > 0)).sum())
        enclosure = walled / int(rim.sum())
    else:
        enclosure = 1.0
    return Shape(area_px * res ** 2, clear_width, 2 * peak, axis_length, float(elongation), float(enclosure), rect)


def classify(shape: Shape, params: Params) -> str:
    """Unwalled spaces are open areas; long narrow ones corridors (any length); very large ones open."""
    if shape.enclosure < params.open_enclosure:
        return "open_area"
    slender = shape.axis_length_m / max(shape.clear_width_m, 1e-6)
    if shape.clear_width_m <= params.corridor_max_width_m and (
            slender >= params.corridor_slenderness or shape.elongation >= params.corridor_elongation):
        return "corridor"
    return "open_area" if shape.area_m2 >= params.open_area_m2 else "room"


def polygon(grid: Grid, mask: np.ndarray, offset: tuple[int, int] = (0, 0)) -> list[list[float]]:
    """Outer boundary of `mask` (cropped at column/row `offset`) as a simplified world polygon."""
    contours, _ = cv2.findContours(mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE,
                                   offset=offset)
    if not contours:
        return []
    contour = max(contours, key=cv2.contourArea)
    poly = cv2.approxPolyDP(contour, max(1.0, 0.05 / grid.resolution), True).reshape(-1, 2)
    return [grid.world(float(c), float(r)) for c, r in poly]


def _anchor(mask: np.ndarray) -> tuple[int, int]:
    """Most interior cell (pole of inaccessibility): always inside, even for L-shaped spaces."""
    padded = cv2.copyMakeBorder(mask.astype(np.uint8), 1, 1, 1, 1, cv2.BORDER_CONSTANT, value=0)
    dt = cv2.distanceTransform(padded, cv2.DIST_L2, 5)[1:-1, 1:-1]
    row, col = np.unravel_index(int(np.argmax(dt)), dt.shape)
    return int(col), int(row)


def _axis(grid: Grid, rect: tuple, offset: tuple[int, int]) -> list[list[float]]:
    """Long axis of a minAreaRect (crop pixels) as two world points: a corridor's centreline."""
    (cx, cy), (w, h), angle = rect
    cx, cy = cx + offset[0], cy + offset[1]
    theta = np.radians(angle)
    direction = np.array([np.cos(theta), np.sin(theta)])
    half = w / 2
    if h > w:
        direction, half = np.array([-np.sin(theta), np.cos(theta)]), h / 2
    a, b = np.array([cx, cy]) - direction * half, np.array([cx, cy]) + direction * half
    return [grid.world(*a), grid.world(*b)]


def label_rooms(masks: dict[int, tuple[np.ndarray, tuple[slice, slice]]], rooms: list[dict],
                grid: Grid) -> dict[int, dict]:
    """Best RoomPlan room per label by overlap (it must cover at least half the region).

    `masks` maps label -> (cropped mask, crop box).
    """
    rasters = []
    for room in rooms:
        poly = room.get("polygon_xz_m") or []
        if len(poly) >= 3:
            rasters.append((room, fill_polygon(grid, np.asarray(poly, float))))
    out = {}
    for label, (mask, box) in masks.items():
        area = int(mask.sum())
        scored = [(int((mask & raster[box]).sum()), str(room.get("id")), room) for room, raster in rasters]
        scored = [s for s in scored if s[0] * 2 >= area]
        if scored:
            overlap, _, room = max(scored, key=lambda s: (s[0], s[1]))
            out[label] = {"room": room, "overlap": overlap / max(area, 1)}
    return out


def describe_regions(seg: Segmentation, obstacle: np.ndarray | None, rooms: list[dict],
                     params: Params) -> tuple[list[dict], dict[int, str]]:
    """Region records (sorted, stable ids) and the label -> id map for the raster."""
    grid, labels = seg.grid, seg.labels
    res = grid.resolution
    boxes = bounding_boxes(labels, pad=2)
    present = sorted(boxes)
    masks = {l: (labels[boxes[l]] == l, boxes[l]) for l in present}
    matches = label_rooms({l: m for l, m in masks.items() if l not in seg.doorways}, rooms, grid)

    drafts = []
    for label in present:
        mask, box = masks[label]
        offset = (box[1].start, box[0].start)   # (column, row) of the crop
        door = seg.doorways.get(label)
        others = (labels[box] > 0) & ~mask
        shape = measure(mask, None if obstacle is None else obstacle[box], others, res)
        kind = "doorway" if door else classify(shape, params)
        moments = cv2.moments(mask.astype(np.uint8), binaryImage=True)
        centroid = grid.world(moments["m10"] / moments["m00"] + offset[0], moments["m01"] / moments["m00"] + offset[1])
        col, row = _anchor(mask)
        if door is not None:
            centroid = [round(float(v), 3) for v in (door.a + door.b) / 2]
        record = {"kind": kind, "polygon_xz_m": polygon(grid, mask, offset), "centroid_xz_m": centroid,
                  "anchor_xz_m": centroid if door else grid.world(col + offset[0], row + offset[1]),
                  "area_m2": round(shape.area_m2, 2), "label": None, "adjacent": []}
        if door is not None:
            inferred = door.kind == "inferred_opening"
            record.update(door_id=door.id, door_kind=door.kind, label=None if inferred else door.kind,
                          span_xz_m=[[round(float(v), 3) for v in door.a], [round(float(v), 3) for v in door.b]],
                          clear_width_m=round(door.clear_width_m if door.clear_width_m is not None else door.width, 3),
                          evidence="constriction" if inferred else "doors")
        else:
            record["metrics"] = {"clear_width_m": round(shape.clear_width_m, 2),
                                 "max_width_m": round(shape.max_width_m, 2),
                                 "axis_length_m": round(shape.axis_length_m, 2),
                                 "elongation": round(shape.elongation, 2),
                                 "enclosure": round(shape.enclosure, 2)}
            if kind == "corridor":
                record["axis_xz_m"] = _axis(grid, shape.rect, offset)
            match = matches.get(label)
            if match:
                room = match["room"]
                record.update(label=room.get("label"), roomplan_room_id=str(room.get("id")),
                              roomplan_overlap=round(match["overlap"], 2))
                if room.get("story") is not None:
                    record["story"] = room["story"]
        drafts.append((label, record))

    # Stable ids: spaces by kind then position (row-major in the map), doorways by door id.
    def sort_key(item):
        label, record = item
        if record["kind"] == "doorway":
            return (KIND_ORDER["doorway"], 0.0, 0.0, record["door_id"])
        x, z = record["anchor_xz_m"]
        return (KIND_ORDER[record["kind"]], round(z, 2), round(x, 2), "")

    ids, counters = {}, {}
    for label, record in sorted(drafts, key=sort_key):
        if record["kind"] == "doorway":
            ids[label] = f"doorway-{record['door_id']}"
        else:
            counters[record["kind"]] = counters.get(record["kind"], 0) + 1
            ids[label] = f"{record['kind']}-{counters[record['kind']]}"
        record["id"] = ids[label]

    contacts = boundary_stats(labels, seg.clearance)
    neighbours: dict[int, set[int]] = {l: set() for l in present}
    for (a, b), (count, _) in contacts.items():
        if count >= 2 or a in seg.doorways or b in seg.doorways:
            neighbours[a].add(b)
            neighbours[b].add(a)
    regions = []
    for label, record in sorted(drafts, key=sort_key):
        record["adjacent"] = sorted(ids[n] for n in neighbours[label])
        if record["kind"] == "doorway":
            record["connects"] = sorted(ids[n] for n in neighbours[label] if n not in seg.doorways)
        else:
            links = []
            for n in sorted(neighbours[label], key=lambda n: ids[n]):
                count, passage = contacts[(min(label, n), max(label, n))]
                door = seg.doorways.get(n)
                width = (door.clear_width_m if door.clear_width_m is not None else door.width) if door else 2 * passage
                links.append({"to": ids[n], "contact_m": round(count * res, 2), "passage_width_m": round(width, 2)})
            record["links"] = links
        regions.append({"id": record.pop("id"), **record})
    return regions, ids
