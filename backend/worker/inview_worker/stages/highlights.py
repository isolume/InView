"""Stage: the key aspects of a scan, ranked, with an OpenCV-annotated plan of them."""
from __future__ import annotations

import base64
from collections import Counter
from typing import Any

import cv2
import numpy as np

from .. import floor_map
from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register
from ..highlights import Options, collect, render_scene
from ..highlights.rank import route_polylines

SCHEMA_VERSION = 1


def _base_image(ctx, fm_json: dict[str, Any]) -> np.ndarray | None:
    """The floor raster as BGRA: from the in-process FloorMap, else from the published PNG."""
    data = ctx.data(ProductName.FLOOR_MAP)
    if data is not None:
        raw = floor_map.render(data)
    else:
        encoded = fm_json.get("image_png_base64")
        if not isinstance(encoded, str):
            return None
        raw = base64.b64decode(encoded)
    image = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_UNCHANGED)
    if image is None:
        return None
    if image.ndim == 2:
        image = cv2.cvtColor(image, cv2.COLOR_GRAY2BGRA)
    elif image.shape[2] == 3:
        image = cv2.cvtColor(image, cv2.COLOR_BGR2BGRA)
    return image


@register
class HighlightsStage(Stage):
    name = "highlights"
    requires = (ProductName.FLOOR_MAP,)
    optional = (ProductName.DOORS, ProductName.SIGNS, ProductName.HAZARDS, ProductName.PLACES,
                ProductName.NAV_GRAPH, ProductName.ROUTES, ProductName.REGIONS, ProductName.HEIGHT_MAP)
    provides = (ProductName.HIGHLIGHTS,)

    def run(self, ctx) -> StageResult:
        options = Options.from_config(ctx.config)
        fm = ctx.json(ProductName.FLOOR_MAP)
        nav_graph, routes = ctx.json(ProductName.NAV_GRAPH), ctx.json(ProductName.ROUTES)
        items = collect(floor_map=fm, doors=ctx.json(ProductName.DOORS), hazards=ctx.json(ProductName.HAZARDS),
                        places=ctx.json(ProductName.PLACES), signs=ctx.json(ProductName.SIGNS), routes=routes,
                        nav_graph=nav_graph, options=options)
        result: dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "floor_id": str((ctx.manifest() or {}).get("floor_id") or "ground"),
            "items": [item.to_json() for item in items],
            "counts": {"total": len(items), "by_severity": dict(sorted(Counter(i.severity for i in items).items())),
                       "by_kind": dict(sorted(Counter(i.kind for i in items).items()))},
            "options": {"max_items": options.max_items, "min_importance": options.min_importance,
                        "callouts": options.callouts, "kinds": list(options.kinds) if options.kinds else None},
        }
        notices: list[str] = []
        base = _base_image(ctx, fm) if isinstance(fm, dict) else None
        if base is None:
            notices.append("Highlights: no floor raster to draw on; the ranked list is still published.")
        else:
            png, meta = render_scene(base, fm["grid"], items, route_polylines(routes, nav_graph), options)
            placed = meta.pop("items")
            for item in result["items"]:
                item.update(placed.get(item["id"], {}))
            result["image"] = {"png_base64": base64.b64encode(png).decode(), "format": "png", **meta}
        summary = {"items": len(items), "barriers": sum(1 for i in items if i.severity == "barrier"),
                   "top": items[0].title if items else None,
                   "image_bytes": len(result["image"]["png_base64"]) * 3 // 4 if "image" in result else 0}
        return StageResult({ProductName.HIGHLIGHTS: Product(result, items)}, summary, notices)
