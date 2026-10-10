"""Stage: door/opening clear-width and headroom screening."""
from __future__ import annotations

from .. import doors
from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register


@register
class DoorsStage(Stage):
    name = "doors"
    optional = (ProductName.FLOOR_MAP,)
    provides = (ProductName.DOORS,)

    def run(self, ctx) -> StageResult:
        results = doors.check(ctx.inputs, ctx.data(ProductName.FLOOR_MAP))
        summary = {"checked": len(results), "below_min_width": sum(not d["meets_clear_width"] for d in results),
                   "below_headroom": sum(not d["meets_headroom"] for d in results)}
        return StageResult({ProductName.DOORS: Product(results)}, summary)
