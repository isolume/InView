"""Stage: routable navigation graph (backend Graph v1) from the floor map and optional semantics."""
from __future__ import annotations

import math

from .. import navgraph
from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register
from ..geometry import box_corners


def _ids(ctx, cfg: navgraph.NavGraphConfig) -> tuple[str, str]:
    manifest = ctx.manifest() or {}
    map_id = cfg.map_id or manifest.get("map_id") or ctx.scan_id
    floor_id = cfg.floor_id or manifest.get("floor_id") or "unassigned"
    return str(map_id), str(floor_id)


def _multiple_levels(ctx, floor_heights: list[float]) -> bool:
    """The raster builder cannot separate overlapping stories or create floor transitions."""
    roomplan = ctx.json(ProductName.ROOMPLAN) or {}
    records = [r for name in ("rooms", "stories", "doors", "openings", "objects")
               for r in roomplan.get(name, []) if isinstance(r, dict)]
    stories = {r["story"] for r in records if isinstance(r.get("story"), (str, int))}
    floor_ids = {r["floor_id"] for r in records if isinstance(r.get("floor_id"), str) and r["floor_id"]}
    if len(stories) > 1 or len(floor_ids) > 1:
        return True
    hints = (ctx.json(ProductName.GEOREF) or {}).get("level_hint") or {}
    if hints.get("multi_level") is True:
        return True
    heights = [h for h in floor_heights if math.isfinite(h)]
    heights.extend(float(r["floor_y_m"]) for r in records
                   if isinstance(r.get("floor_y_m"), (int, float)) and math.isfinite(r["floor_y_m"]))
    return bool(heights and max(heights) - min(heights) >= 1.5)


def _items(ctx, name: str) -> list[dict]:
    """A list product; tolerates a `{name: [...]}` wrapper."""
    value = ctx.json(name)
    if isinstance(value, dict):
        value = value.get(name)
    return [item for item in value or [] if isinstance(item, dict)] if isinstance(value, list) else []


@register
class NavGraphStage(Stage):
    name = "nav_graph"
    requires = (ProductName.FLOOR_MAP,)
    optional = (ProductName.DOORS, ProductName.REGIONS, ProductName.PLACES, ProductName.HEIGHT_MAP,
                ProductName.HAZARDS, ProductName.ROOMPLAN, ProductName.GEOREF)
    provides = (ProductName.NAV_GRAPH,)

    def run(self, ctx) -> StageResult:
        cfg = navgraph.NavGraphConfig.from_mapping(ctx.config.get("nav_graph"))
        map_id, floor_id = _ids(ctx, cfg)
        floors = [float(box_corners(s.matrix, s.dimensions)[:, 1].mean())
                  for s in ctx.inputs.surfaces if s.kind == "floor"]
        if _multiple_levels(ctx, floors):
            return StageResult(summary={"status": "unavailable", "reason": "multiple_levels"}, notices=[
                "Navigation graph not generated: this capture spans multiple levels. Process each floor "
                "separately and review its connections before building a route between floors."])
        height_product = ctx.product(ProductName.HEIGHT_MAP)
        result = navgraph.build(
            ctx.data(ProductName.FLOOR_MAP), scan_id=ctx.scan_id, map_id=map_id, floor_id=floor_id,
            doors=_items(ctx, ProductName.DOORS), regions=_items(ctx, ProductName.REGIONS),
            places=_items(ctx, ProductName.PLACES),
            height_map=None if height_product is None else height_product.data,
            hazards=_items(ctx, ProductName.HAZARDS),
            level=navgraph.single_level(ctx.json(ProductName.ROOMPLAN), floors), config=cfg)
        if floor_id == "unassigned":
            result.notices.append("Floor identifier unavailable; the draft graph belongs only to this scan.")
        return StageResult({ProductName.NAV_GRAPH: Product(result.graph, result.adjacency)},
                           result.summary, result.notices)
