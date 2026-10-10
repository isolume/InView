"""Stage: colored sign plates and text-line candidates in RGB keyframes, placed in 3D."""
from __future__ import annotations

from .. import signs
from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register


@register
class SignsStage(Stage):
    name = "signs"
    provides = (ProductName.SIGNS,)

    def run(self, ctx) -> StageResult:
        results, examined = signs.analyze(ctx.inputs.frames, ctx.image)
        notices = [] if examined else ["No RGB keyframes were available, so signs and text were not analysed."]
        summary = {"keyframes_examined": examined,
                   "sign_candidates": sum(s["kind"] != "text_region" for s in results),
                   "text_regions": sum(s["kind"] == "text_region" for s in results)}
        return StageResult({ProductName.SIGNS: Product(results)}, summary, notices)
