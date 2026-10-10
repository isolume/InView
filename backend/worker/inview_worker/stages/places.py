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
        corners = box_corners(box.matrix, box.dimensions)[:, [0, 2]].astype(np.float32)
        hull = cv2.convexHull(corners).reshape(-1, 2)
        out.append({"id": box.id, "category": box.category, "center_m": box.matrix[:3, 3].tolist(),
                    "footprint_xz_m": hull.astype(np.float64).tolist()})
        seen.add(box.id)
    for item in (ctx.json(ProductName.ROOMPLAN) or {}).get("objects") or []:
        if item.get("id") in seen or item.get("center_m") is None:
            continue
        center = np.asarray(item["center_m"], dtype=np.float64)
        half = np.asarray(item.get("dimensions_m") or [0.4, 0.4, 0.4], dtype=np.float64)[[0, 2]] / 2
        square = center[[0, 2]] + np.array([[-1, -1], [1, -1], [1, 1], [-1, 1]]) * half
        out.append({"id": item["id"], "category": item.get("category"), "center_m": center.tolist(),
                    "footprint_xz_m": square.tolist()})
    return out


def scene(ctx) -> places.Scene:
    floor_map = ctx.json(ProductName.FLOOR_MAP) or {}
    roomplan = ctx.json(ProductName.ROOMPLAN) or {}
    rooms = roomplan.get("rooms") or []
    floor_y = floor_map.get("floor_height_m")
    if floor_y is None:
        heights = [r["floor_y_m"] for r in rooms if r.get("floor_y_m") is not None]
        floor_y = float(np.median(heights)) if heights else 0.0
    return places.Scene(
        floor_id=floor_id(ctx), floor_y=float(floor_y), objects=_objects(ctx), rooms=rooms,
        regions=ctx.json(ProductName.REGIONS) or [],
        doors=ctx.json(ProductName.DOORS) or roomplan.get("doors") or [],
        outlines=[o["polygon_xz_m"] for o in floor_map.get("outlines") or [] if o.get("polygon_xz_m")],
        signs=ctx.json(ProductName.SIGNS) or [], texts=ctx.json(ProductName.TEXT) or [],
        hazards=ctx.json(ProductName.HAZARDS) or [])


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
