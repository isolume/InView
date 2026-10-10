"""Tolerant decoders for the JSON that Swift's `JSONEncoder` writes for RoomPlan types.

The iPhone writes `JSONEncoder().encode([CapturedRoom])` verbatim (ScanExporter.nativeRoomPlanData).
Apple does not document that Codable layout and it has shifted between iOS releases, so every
decoder here accepts the shapes Swift can produce and returns `None` instead of raising:

- enums: synthesized Codable writes `{"door": {"isOpen": true}}` / `{"wall": {}}`; older or custom
  encodings use a bare string (`"wall"`), and associated values may be positional (`{"_0": ...}`).
- `simd_float4x4`: an unkeyed container of four column vectors (`[[c0], [c1], [c2], [c3]]`); a flat
  column-major array of 16 also appears in exports and the portable capture uses it.
- `SIMD2/3<Float>`: `[x, y, z]`; keyed `{"x":..}` variants are accepted too.
- `Measurement<UnitAngle>`: `{"value": 1.57, "unit": {"symbol": "rad", ...}}`.
"""
from __future__ import annotations

import math
import re
from typing import Any

import numpy as np

_CAMEL = re.compile(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")


def snake(name: str) -> str:
    """`livingRoom` -> `living_room`, `ChairType` -> `chair_type`, `washerDryer` -> `washer_dryer`."""
    return _CAMEL.sub("_", str(name)).replace("-", "_").replace(" ", "_").lower()


def enum_case(value: Any) -> tuple[str | None, dict[str, Any]]:
    """(snake_case case name, associated values) for a Swift enum in any Codable spelling."""
    if isinstance(value, str):
        return (snake(value) or None), {}
    if not isinstance(value, dict):
        return None, {}
    for key in ("rawValue", "type", "case"):  # e.g. {"rawValue": "wall"} or {"type": "door", "isOpen": true}
        if isinstance(value.get(key), str):
            return snake(value[key]), {k: v for k, v in value.items() if k != key}
    if len(value) == 1:
        (name, payload), = value.items()
        return snake(name), payload if isinstance(payload, dict) else {"_0": payload}
    return None, {}


def number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    return value if math.isfinite(value) else None


def vector(value: Any, size: int) -> np.ndarray | None:
    """A finite SIMD vector of `size` components (extra components, e.g. homogeneous w, dropped)."""
    if isinstance(value, dict):
        value = [value.get(k) for k in "xyzw"[:size]]
    if not isinstance(value, (list, tuple)) or len(value) < size:
        return None
    components = [number(v) for v in value[:size]]
    if any(c is None for c in components):
        return None
    return np.asarray(components, dtype=np.float64)


def _homogeneous(m: np.ndarray) -> bool:
    return bool(np.allclose(m[3], [0, 0, 0, 1], atol=1e-3))


def matrix4(value: Any) -> np.ndarray | None:
    """World-from-local 4×4 for a Codable `simd_float4x4` (columns), or None if unusable.

    Both layouts are interpreted as columns first (Swift encodes `columns.0 ... columns.3`). If that
    does not yield an affine matrix but the transpose does, the producer wrote rows; accept it.
    """
    if isinstance(value, dict):
        value = value.get("columns", value.get("matrix"))
    if not isinstance(value, (list, tuple)):
        return None
    if len(value) == 4 and all(isinstance(c, (list, tuple, dict)) for c in value):
        columns = [vector(c, 4) for c in value]
        if any(c is None for c in columns):
            return None
        m = np.column_stack(columns)
    elif len(value) == 16:
        flat = vector(value, 16)
        if flat is None:
            return None
        m = flat.reshape(4, 4, order="F")
    else:
        return None
    if _homogeneous(m):
        return m
    return m.T if _homogeneous(m.T) else None


def points3(value: Any) -> np.ndarray:
    """N×3 array from a list of SIMD3 values, skipping malformed entries."""
    if not isinstance(value, (list, tuple)):
        return np.zeros((0, 3))
    rows = [v for v in (vector(p, 3) for p in value) if v is not None]
    return np.asarray(rows, dtype=np.float64).reshape(-1, 3)


def angle_degrees(value: Any) -> float | None:
    """Degrees from a `Measurement<UnitAngle>` (or a plain number taken as radians)."""
    plain = number(value)
    if plain is not None:
        return math.degrees(plain)
    if not isinstance(value, dict):
        return None
    amount = number(value.get("value"))
    if amount is None:
        return None
    unit = value.get("unit")
    symbol = (unit.get("symbol") if isinstance(unit, dict) else unit) or "rad"
    return amount if str(symbol).strip().lower() in {"°", "deg", "degrees"} else math.degrees(amount)


def identifier(value: Any) -> str | None:
    """UUIDs encode as strings; normalise to upper case like Foundation's `uuidString`."""
    if isinstance(value, str) and value.strip():
        return value.strip().upper()
    return None
