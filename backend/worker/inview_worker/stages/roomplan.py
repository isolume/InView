"""Stage: RoomPlan semantics (labelled room polygons, door states, openings, objects, stories)."""
from __future__ import annotations

import json
from typing import Any

from .. import roomplan
from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register


def _original(capture: Any) -> Any:
    return capture.get("roomplan_original") if isinstance(capture, dict) else None


# Richest first: the iPhone's verbatim `[CapturedRoom]` file, then the copy embedded in capture.json.
NATIVE_ASSETS = (("roomplan.json", lambda value: value), ("capture.json", _original))


def _native(ctx) -> tuple[roomplan.Capture | None, str | None, list[str]]:
    notices: list[str] = []
    for asset, pick in NATIVE_ASSETS:
        data = ctx.asset(asset)
        if not data:
            continue
        try:
            capture = roomplan.load(pick(json.loads(data)))
        except (ValueError, UnicodeDecodeError) as error:
            notices.append(f"{asset} could not be decoded as RoomPlan JSON ({error}).")
            continue
        if not capture.empty:
            return capture, asset, notices
    return None, None, notices


@register
class RoomplanStage(Stage):
    name = "roomplan"
    provides = (ProductName.ROOMPLAN,)

    def run(self, ctx) -> StageResult:
        capture, asset, notices = _native(ctx)
        if capture is None:
            capture = roomplan.from_portable(ctx.inputs.surfaces, ctx.inputs.objects)
            if capture.empty:
                notices.append("No RoomPlan export or portable surfaces were available; no room semantics.")
                return StageResult(summary={"source": "none"}, notices=notices)
            notices.append("No native RoomPlan export was available; rooms come from the portable capture "
                           "(no section labels, floor polygons or door open/closed state).")
        product = roomplan.build(capture)
        summary = {**roomplan.summarize(product, capture), "asset": asset}
        if capture.skipped:
            notices.append(f"{capture.skipped} malformed RoomPlan component(s) were ignored.")
        return StageResult({ProductName.ROOMPLAN: Product(product, capture)}, summary, notices)
