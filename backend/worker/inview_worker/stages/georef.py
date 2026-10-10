"""Stage: geographic building reference (latitude, longitude, heading of local -Z, accuracy)."""
from __future__ import annotations

import json

from ..contracts import ProductName
from ..core import Product, Stage, StageResult, register
from ..geo import reference


def _semantics(ctx) -> dict | None:
    data = ctx.asset("semantics.json")
    if not data:
        return None
    try:
        parsed = json.loads(data)
    except (ValueError, UnicodeDecodeError):
        return None
    return parsed if isinstance(parsed, dict) else None


@register
class GeorefStage(Stage):
    name = "georef"
    provides = (ProductName.GEOREF,)

    def run(self, ctx) -> StageResult:
        config = ctx.config.get("georef") or {}
        notices: list[str] = []
        samples = reference.samples_from_manifest(ctx.manifest())
        sensor, reason = reference.estimate_from_samples(
            samples, yaw_correction=config.get("yaw_correction", True),
            max_horizontal_accuracy_m=config.get("max_horizontal_accuracy_m", reference.MAX_HORIZONTAL_ACCURACY_M),
            max_heading_accuracy_degrees=config.get("max_heading_accuracy_degrees", reference.MAX_HEADING_ACCURACY_DEG))
        device, device_problem = reference.device_reference(_semantics(ctx))
        if device_problem:
            notices.append(device_problem)

        if device is not None:
            result = device
            if sensor is not None:
                result["cross_check"] = reference.cross_check(device, sensor)
                if "altitude_m" in sensor:
                    result["altitude_m"] = sensor["altitude_m"]
        elif sensor is not None:
            result = sensor
        else:
            why = reason if samples else "the package has no environment (GPS/compass) samples"
            notices.append(f"Geo-reference unavailable: {why}; GeoJSON export skipped.")
            return StageResult(summary={"status": "unavailable", "reason": why, "samples": len(samples)},
                               notices=notices)

        levels = reference.level_hints(samples)
        if levels is not None:
            result["level_hint"] = levels
        if levels and levels["multi_level"]:
            notices.append(f"Barometric altitude suggests {levels['level_count']} levels in this capture; "
                           "the floor products assume one level.")
        summary = {"method": result["method"], "latitude": result["latitude"], "longitude": result["longitude"],
                   "heading_degrees": result["heading_degrees"],
                   "horizontal_accuracy_m": result.get("horizontal_accuracy_m"),
                   "samples_used": result["samples_used"], "levels": levels["level_count"] if levels else None}
        return StageResult({ProductName.GEOREF: Product(result)}, summary, notices)
