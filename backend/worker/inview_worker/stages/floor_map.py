"""Stage: top-down floor/obstacle/walkable rasters and their vector summaries."""
from __future__ import annotations

import base64

from .. import floor_map
from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register


@register
class FloorMapStage(Stage):
    name = "floor_map"
    provides = (ProductName.FLOOR_MAP,)

    def run(self, ctx) -> StageResult:
        fm = floor_map.build(ctx.inputs)
        if fm is None:
            return StageResult(notices=["No floor map: the scan has no usable floor, mesh, depth, or camera evidence."])
        result = dict(fm.result)
        result["image_png_base64"] = base64.b64encode(floor_map.render(fm)).decode()
        summary = {key: result[key] for key in ("walkable_area_m2", "floor_area_m2", "walked_length_m")}
        summary["narrow_passages"] = len(result["narrow_passages"])
        summary["obstacles"] = len(result["obstacles"])
        return StageResult({ProductName.FLOOR_MAP: Product(result, fm)}, summary)
