"""Stage: 2.5D walking-surface height map and 3D hazards (steps, stairs, ramps, headroom, protrusions)."""
from __future__ import annotations

from collections import Counter

import numpy as np

from .. import terrain
from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register


@register
class HazardsStage(Stage):
    name = "hazards"
    requires = (ProductName.FLOOR_MAP,)
    provides = (ProductName.HEIGHT_MAP, ProductName.HAZARDS)

    def run(self, ctx) -> StageResult:
        fm = ctx.data(ProductName.FLOOR_MAP)
        hm = terrain.build(ctx.inputs, fm.grid, fm.floor_height)
        region = np.maximum(fm.floor, fm.walked)
        height_json = terrain.summary(hm, region)
        hazards = terrain.detect(hm, ctx.inputs.objects)
        kinds = Counter(h["kind"] for h in hazards)
        summary = {"source": hm.source, "coverage": height_json["coverage"], "hazards": len(hazards),
                   "barriers": sum(h["severity"] == "barrier" for h in hazards), "by_kind": dict(sorted(kinds.items()))}
        notices = []
        if not hm.measured:
            notices.append("Height map from RoomPlan floor planes only (no LiDAR mesh or depth): steps, ramps, "
                           "drop-offs, headroom and protrusions were not screened.")
        elif height_json["coverage"] is not None and height_json["coverage"] < 0.5:
            notices.append(f"Height map covers {height_json['coverage']:.0%} of the floor; hazards outside the "
                           "measured surface were not screened.")
        return StageResult({ProductName.HEIGHT_MAP: Product(height_json, hm),
                            ProductName.HAZARDS: Product(hazards)}, summary, notices)
