"""Stage: accessible routes between places with localized turn-by-turn guidance."""
from __future__ import annotations

from .. import guidance
from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register


@register
class RoutesStage(Stage):
    name = "routes"
    requires = (ProductName.NAV_GRAPH,)
    optional = (ProductName.PLACES, ProductName.SIGNS, ProductName.REGIONS, ProductName.DOORS,
                ProductName.HAZARDS, ProductName.TEXT)
    provides = (ProductName.ROUTES,)

    def run(self, ctx) -> StageResult:
        config = {key.removeprefix("routes_"): value for key, value in ctx.config.items()
                  if key.startswith("routes_") and key not in ("routes_languages",)}
        languages = ctx.config.get("routes_languages")
        product, summary = guidance.build_routes(
            ctx.json(ProductName.NAV_GRAPH), places=ctx.json(ProductName.PLACES), signs=ctx.json(ProductName.SIGNS),
            regions=ctx.json(ProductName.REGIONS), doors=ctx.json(ProductName.DOORS),
            hazards=ctx.json(ProductName.HAZARDS), text=ctx.json(ProductName.TEXT), config=config,
            languages=tuple(languages) if languages else None)
        notices = []
        if summary["endpoint_source"] != "places":
            notices.append(f"No routable places; routes connect {summary['endpoint_source'].replace('_', ' ')} instead.")
        if summary["pairs_truncated"]:
            notices.append(f"Route pairs capped; {summary['pairs_truncated']} lower-priority pairs were not routed.")
        notices.append("Routes and turn-by-turn guidance are screening output from measured scan evidence, "
                       "not verified accessible routes.")
        return StageResult({ProductName.ROUTES: Product(product)}, summary, notices)
