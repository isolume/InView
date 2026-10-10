"""Stage: routable navigation graph (backend Graph v1) from the floor map and optional semantics."""
from __future__ import annotations

from .. import navgraph
from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register
from ..geometry import box_corners


def _ids(ctx, cfg: navgraph.NavGraphConfig) -> tuple[str, str]:
    manifest = ctx.manifest() or {}
    map_id = cfg.map_id or manifest.get("map_id") or ctx.scan_id
    floor_id = cfg.floor_id or manifest.get("floor_id") or "ground"
    return str(map_id), str(floor_id)


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
                ProductName.HAZARDS, ProductName.ROOMPLAN)
    provides = (ProductName.NAV_GRAPH,)

    def run(self, ctx) -> StageResult:
        cfg = navgraph.NavGraphConfig.from_mapping(ctx.config.get("nav_graph"))
        map_id, floor_id = _ids(ctx, cfg)
        floors = [float(box_corners(s.matrix, s.dimensions)[:, 1].mean())
                  for s in ctx.inputs.surfaces if s.kind == "floor"]
        height_product = ctx.product(ProductName.HEIGHT_MAP)
        result = navgraph.build(
            ctx.data(ProductName.FLOOR_MAP), scan_id=ctx.scan_id, map_id=map_id, floor_id=floor_id,
            doors=_items(ctx, ProductName.DOORS), regions=_items(ctx, ProductName.REGIONS),
            places=_items(ctx, ProductName.PLACES),
            height_map=None if height_product is None else height_product.data,
            hazards=_items(ctx, ProductName.HAZARDS),
            level=navgraph.single_level(ctx.json(ProductName.ROOMPLAN), floors), config=cfg)
        return StageResult({ProductName.NAV_GRAPH: Product(result.graph, result.adjacency)},
                           result.summary, result.notices)
