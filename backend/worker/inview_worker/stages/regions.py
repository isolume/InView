"""Stage: rooms, corridors, open areas and doorways segmented from the floor map."""
from __future__ import annotations

from .. import regions
from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register


@register
class RegionsStage(Stage):
    name = "regions"
    requires = (ProductName.FLOOR_MAP,)
    optional = (ProductName.DOORS, ProductName.ROOMPLAN)
    provides = (ProductName.REGIONS,)

    def run(self, ctx) -> StageResult:
        region_map = regions.build(ctx.data(ProductName.FLOOR_MAP), ctx.json(ProductName.DOORS),
                                   ctx.json(ProductName.ROOMPLAN))
        found = region_map.regions
        summary = {kind: sum(r["kind"] == kind for r in found) for kind in ("room", "corridor", "open_area", "doorway")}
        summary["links"] = sum(len(r["adjacent"]) for r in found) // 2
        summary["labelled"] = sum(1 for r in found if r["kind"] != "doorway" and r.get("label"))
        notices = [] if found else ["No regions: the floor map has no walkable space to segment."]
        return StageResult({ProductName.REGIONS: Product(found, region_map)}, summary, notices)
