"""Stage: RFC 7946 GeoJSON export (WGS84) of outlines, units, openings, amenities, obstructions, routes."""
from __future__ import annotations

from collections import Counter

from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register
from ..geo import geojson
from ..geo.projection import LocalProjection


@register
class GeojsonStage(Stage):
    name = "geojson"
    requires = (ProductName.GEOREF,)
    optional = (ProductName.FLOOR_MAP, ProductName.DOORS, ProductName.REGIONS, ProductName.PLACES,
                ProductName.HAZARDS, ProductName.SIGNS, ProductName.NAV_GRAPH, ProductName.ROUTES)
    provides = (ProductName.GEOJSON,)

    def run(self, ctx) -> StageResult:
        georef = ctx.json(ProductName.GEOREF)
        projection = LocalProjection.from_georef(georef)
        manifest = ctx.manifest() or {}
        signs = ctx.json(ProductName.SIGNS)
        collection, notices = geojson.build(
            projection, scan_id=ctx.scan_id, level_id=str(manifest.get("floor_id") or "ground"), georef=georef,
            floor_map=ctx.json(ProductName.FLOOR_MAP), regions=ctx.json(ProductName.REGIONS),
            doors=ctx.json(ProductName.DOORS), places=ctx.json(ProductName.PLACES),
            hazards=ctx.json(ProductName.HAZARDS), signs=signs if isinstance(signs, list) else None,
            nav_graph=ctx.json(ProductName.NAV_GRAPH), routes=ctx.json(ProductName.ROUTES),
            epsilon_m=float((ctx.config.get("geojson") or {}).get("simplify_epsilon_m", geojson.SIMPLIFY_EPSILON_M)))
        errors = geojson.validate(collection)
        notices = [f"GeoJSON: {n}" for n in notices] + [f"GeoJSON validation: {e}" for e in errors[:10]]
        counts = Counter(f["properties"]["feature_type"] for f in collection["features"])
        summary = {"features": len(collection["features"]), "by_type": dict(sorted(counts.items())),
                   "valid": not errors, "bbox": collection.get("bbox")}
        return StageResult({ProductName.GEOJSON: Product(collection)}, summary, notices)
