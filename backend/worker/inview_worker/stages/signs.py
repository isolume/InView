"""Stage: sign plates, pictograms, arrows, braille and sign accessibility screening, placed in 3D."""
from __future__ import annotations

from collections import Counter

import numpy as np

from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register
from ..geometry import matrix
from ..signage import analyze as signage


def floor_height(ctx) -> tuple[float | None, str | None]:
    floor_map = ctx.json(ProductName.FLOOR_MAP) or {}
    if floor_map.get("floor_height_m") is not None:
        return float(floor_map["floor_height_m"]), "floor_map"
    floors = [s.matrix[1, 3] for s in ctx.inputs.surfaces if s.kind == "floor"]
    if floors:
        return float(np.median(floors)), "roomplan_floor"
    return None, None


def camera_positions(ctx) -> dict[str, np.ndarray]:
    cameras = {}
    for observation in (ctx.manifest() or {}).get("observations", []):
        if observation.get("id") and observation.get("map_from_camera"):
            cameras[observation["id"]] = matrix(observation["map_from_camera"])[:3, 3]
    return cameras


@register
class SignsStage(Stage):
    name = "signs"
    optional = (ProductName.FLOOR_MAP, ProductName.TEXT)
    provides = (ProductName.SIGNS,)

    def run(self, ctx) -> StageResult:
        height, height_source = floor_height(ctx)
        texts = ctx.json(ProductName.TEXT) or []
        results, examined = signage.analyze(ctx.inputs.frames, ctx.image, texts=texts if isinstance(texts, list) else [],
                                            floor_height=height, cameras=camera_positions(ctx),
                                            ocr=ctx.config.get("signs_ocr", True))
        notices = [] if examined else ["No RGB keyframes were available, so signs and text were not analysed."]
        plates = [s for s in results if s["kind"] != "text_region"]
        summary = {"keyframes_examined": examined,
                   "sign_candidates": len(plates),
                   "text_regions": len(results) - len(plates),
                   "categories": dict(sorted(Counter(s["category"] for s in plates).items())),
                   "pictograms": sum(len(s["pictograms"]) for s in plates),
                   "arrows": sum(len(s["arrows"]) for s in plates),
                   "braille": sum(s["braille"] for s in plates),
                   "with_issues": sum(bool(s["issues"]) for s in plates),
                   "floor_height_source": height_source}
        return StageResult({ProductName.SIGNS: Product(results)}, summary, notices)
