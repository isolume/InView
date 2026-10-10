"""Stage: fuse objects, rooms, regions, doors, signs, OCR text and hazards into navigable places."""
from __future__ import annotations

import json

import cv2
import numpy as np

from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register
from ..geometry import box_corners
from ..semantics import places


def floor_id(ctx) -> str:
    """Capture floor: config override, package manifest, capture.json, else "ground"."""
    if ctx.config.get("floor_id"):
        return str(ctx.config["floor_id"])
    try:
        manifest = ctx.manifest() or {}
        if manifest.get("floor_id"):
            return str(manifest["floor_id"])
        capture = ctx.asset("capture.json")
        if capture:
            value = json.loads(capture).get("floor_id")
            if value:
                return str(value)
    except Exception:  # noqa: BLE001 - a missing/unreadable package must not cost the places
        pass
    return "ground"


def _objects(ctx) -> list[dict]:
    """RoomPlan objects with world centre and top-down footprint hull; roomplan-product extras."""
    out, seen = [], set()
    for box in ctx.inputs.objects:
        try:
            corners = box_corners(box.matrix, box.dimensions)[:, [0, 2]].astype(np.float32)
        except (TypeError, ValueError):
            continue
        if not np.isfinite(corners).all() or not np.isfinite(box.matrix[:3, 3]).all():
            continue
        hull = cv2.convexHull(corners).reshape(-1, 2)
        out.append({"id": box.id, "category": box.category, "center_m": box.matrix[:3, 3].tolist(),
                    "footprint_xz_m": hull.astype(np.float64).tolist()})
        seen.add(box.id)
    roomplan = ctx.json(ProductName.ROOMPLAN)
    for item in _dicts(roomplan.get("objects") if isinstance(roomplan, dict) else None):
        center = places._finite_array(item.get("center_m"))
        if item.get("id") in seen or center is None or len(center) < 3:
            continue
        center = center[:3]
        dimensions = places._finite_array(item.get("dimensions_m"))
        if dimensions is None or len(dimensions) < 3 or (dimensions[[0, 2]] <= 0).any():
            dimensions = np.array([0.4, 0.4, 0.4])
        half = dimensions[[0, 2]] / 2
        square = center[[0, 2]] + np.array([[-1, -1], [1, -1], [1, 1], [-1, 1]]) * half
        out.append({"id": item["id"], "category": item.get("category"), "center_m": center.tolist(),
                    "footprint_xz_m": square.tolist()})
    return out


def _dicts(items) -> list[dict]:
    """Only well-formed entries of an upstream list product (anything else is skipped)."""
    return [item for item in items if isinstance(item, dict)] if isinstance(items, list) else []


def scene(ctx) -> places.Scene:
    floor_map = ctx.json(ProductName.FLOOR_MAP)
    floor_map = floor_map if isinstance(floor_map, dict) else {}
    roomplan = ctx.json(ProductName.ROOMPLAN)
    roomplan = roomplan if isinstance(roomplan, dict) else {}
    rooms = roomplan.get("rooms") or []
    floor_y = places._number(floor_map.get("floor_height_m"), float("nan"))
    if not np.isfinite(floor_y):
        heights = [h for h in (places._number(r.get("floor_y_m"), float("nan")) for r in rooms if isinstance(r, dict))
                   if np.isfinite(h)]
        floor_y = float(np.median(heights)) if heights else 0.0
    return places.Scene(
        floor_id=floor_id(ctx), floor_y=float(floor_y), objects=_objects(ctx),
        rooms=[r for r in rooms if isinstance(r, dict)],
        regions=_dicts(ctx.json(ProductName.REGIONS)),
        doors=_dicts(ctx.json(ProductName.DOORS) or roomplan.get("doors")),
        outlines=[o["polygon_xz_m"] for o in floor_map.get("outlines") or []
                  if isinstance(o, dict) and places._contour(o.get("polygon_xz_m")) is not None],
        signs=_dicts(ctx.json(ProductName.SIGNS)), texts=_dicts(ctx.json(ProductName.TEXT)),
        hazards=_dicts(ctx.json(ProductName.HAZARDS)))


@register
class PlacesStage(Stage):
    name = "places"
    optional = (ProductName.FLOOR_MAP, ProductName.DOORS, ProductName.ROOMPLAN, ProductName.REGIONS,
                ProductName.SIGNS, ProductName.TEXT, ProductName.HAZARDS)
    provides = (ProductName.PLACES,)

    def run(self, ctx) -> StageResult:
        results, summary = places.build(scene(ctx))
        notices = [] if results else ["No places found: no objects, rooms, entrances, signs or text gave place evidence."]
        return StageResult({ProductName.PLACES: Product(results)}, summary, notices)
