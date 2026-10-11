"""RFC 7946 GeoJSON export of the navigation products, with IMDF-inspired feature properties.

Every feature carries `feature_type` (venue | level | unit | opening | amenity | obstruction | sign |
route), a `category`, optional `name`/`names` (BCP-47 -> text), `level_id`, and an `accessibility`
object of screening flags. Geometry is WGS84 [longitude, latitude] with 7 decimals (~1 cm).

Polygons are simplified with OpenCV's Douglas-Peucker (`cv2.approxPolyDP`) in local meters, areas use
`cv2.contourArea`, obstacle footprints use `cv2.boxPoints`; exterior rings are closed and
counterclockwise (right-hand rule) in lon/lat. `validate` checks a collection against those rules.
"""
from __future__ import annotations

import math
from typing import Any

import cv2
import numpy as np

from .projection import GeoError, LocalProjection, wrap_degrees
from .routes import surface_legs

COORDINATE_DECIMALS = 7
SIMPLIFY_EPSILON_M = 0.05
UNIT_CATEGORY = {"room": "room", "corridor": "walkway", "open_area": "room", "doorway": "opening"}
NOT_STEP_FREE_PLACES = {"stairs", "escalator"}
NOT_STEP_FREE_HAZARDS = {"step", "stairs", "level_change", "drop_off"}


# --- Geometry --------------------------------------------------------------------------------------

def _finite_xz(points) -> np.ndarray | None:
    try:
        array = np.asarray(points, dtype=np.float64)
    except (TypeError, ValueError):
        return None
    if array.ndim != 2 or array.shape[1] < 2 or not np.all(np.isfinite(array[:, :2])):
        return None
    return array[:, :2]


def simplify_ring(xz: np.ndarray, epsilon_m: float = SIMPLIFY_EPSILON_M) -> np.ndarray:
    """Douglas-Peucker simplification of a closed ring (local meters); keeps >= 3 vertices."""
    ring = xz[:-1] if len(xz) > 1 and np.allclose(xz[0], xz[-1]) else xz
    if len(ring) <= 3 or epsilon_m <= 0:
        return ring
    simplified = cv2.approxPolyDP(ring.astype(np.float32).reshape(-1, 1, 2), epsilon_m, True).reshape(-1, 2)
    return simplified.astype(np.float64) if len(simplified) >= 3 else ring


def ring_area_m2(xz: np.ndarray) -> float:
    return float(abs(cv2.contourArea(np.asarray(xz, dtype=np.float32).reshape(-1, 1, 2))))


def signed_area_lonlat(ring: list[list[float]]) -> float:
    """Shoelace area in degrees^2 (positive = counterclockwise); longitude deltas wrapped locally."""
    points = np.asarray(ring, dtype=np.float64)
    lon = points[0, 0] + np.asarray(wrap_degrees(points[:, 0] - points[0, 0]))
    lat = points[:, 1]
    return float(0.5 * np.sum(lon[:-1] * lat[1:] - lon[1:] * lat[:-1]))


def _round(lonlat: np.ndarray) -> list[list[float]]:
    rounded = []
    for lon, lat in np.round(lonlat, COORDINATE_DECIMALS).tolist():
        position = [float(lon), float(lat)]
        if not rounded or rounded[-1] != position:
            rounded.append(position)
    return rounded


def polygon(projection: LocalProjection, xz, epsilon_m: float = SIMPLIFY_EPSILON_M) -> dict | None:
    points = _finite_xz(xz)
    if points is None or len(points) < 3:
        return None
    ring = _round(projection.to_lonlat(simplify_ring(points, epsilon_m)))
    if len(ring) > 1 and ring[0] == ring[-1]:
        ring.pop()
    if len({tuple(p) for p in ring}) < 3:
        return None
    ring.append(list(ring[0]))
    area = signed_area_lonlat(ring)
    if area == 0:
        return None
    if area < 0:
        ring.reverse()
    return {"type": "Polygon", "coordinates": [ring]}


def line(projection: LocalProjection, xz) -> dict | None:
    points = _finite_xz(xz)
    if points is None or len(points) < 2:
        return None
    coordinates = _round(projection.to_lonlat(points))
    return {"type": "LineString", "coordinates": coordinates} if len(coordinates) >= 2 else None


def point(projection: LocalProjection, xz) -> dict | None:
    points = _finite_xz([xz])
    if points is None:
        return None
    return {"type": "Point", "coordinates": _round(projection.to_lonlat(points))[0]}


def _xz(position_m) -> list[float] | None:
    """[x, z] from a 3D `*_m` position (or a 2D `*_xz_m` one)."""
    if not isinstance(position_m, (list, tuple)) or len(position_m) not in (2, 3):
        return None
    return [position_m[0], position_m[2]] if len(position_m) == 3 else list(position_m)


# --- Features --------------------------------------------------------------------------------------

def _feature(feature_id: str, geometry: dict | None, properties: dict[str, Any]) -> dict | None:
    if geometry is None:
        return None
    return {"type": "Feature", "id": feature_id, "geometry": geometry,
            "properties": {k: v for k, v in properties.items() if v is not None}}


def _names(item: dict) -> tuple[str | None, dict | None]:
    names = item.get("names") if isinstance(item.get("names"), dict) else None
    name = item.get("name") or item.get("label") or (next(iter(names.values())) if names else None)
    return name, names or None


def build(projection: LocalProjection, *, scan_id: str = "", level_id: str = "ground", georef: dict | None = None,
          map_id: str | None = None,
          floor_map: dict | None = None, regions: list | None = None, doors: list | None = None,
          places: list | None = None, hazards: list | None = None, signs: list | None = None,
          nav_graph: dict | None = None, routes: dict | None = None,
          epsilon_m: float = SIMPLIFY_EPSILON_M) -> tuple[dict, list[str]]:
    """(FeatureCollection, notices). Every input is optional; missing or malformed items are skipped."""
    features: list[dict | None] = []
    notices: list[str] = []
    georef = georef or {}
    level = f"level:{level_id}"

    features.append(_feature(f"venue:{scan_id or 'scan'}", point(projection, [0.0, 0.0]), {
        "feature_type": "venue", "category": "unspecified", "name": scan_id or None,
        "georef_method": georef.get("method"), "heading_degrees": projection.heading_degrees,
        "horizontal_accuracy_m": projection.horizontal_accuracy_m, "altitude_m": georef.get("altitude_m"),
    }))

    floor_map = floor_map if isinstance(floor_map, dict) else {}
    for index, outline in enumerate(floor_map.get("outlines") or []):
        xz = _finite_xz(outline.get("polygon_xz_m"))
        features.append(_feature(f"{level}:outline:{index}", polygon(projection, outline.get("polygon_xz_m"), epsilon_m), {
            "feature_type": "level", "category": "walkable_floor", "level_id": level_id, "ordinal": 0,
            "floor_height_m": floor_map.get("floor_height_m"),
            "area_m2": round(ring_area_m2(xz), 2) if xz is not None and len(xz) >= 3 else None,
        }))
    for index, obstacle in enumerate(floor_map.get("obstacles") or []):
        center, size = obstacle.get("center_xz_m"), obstacle.get("size_m")
        if not (isinstance(center, list) and isinstance(size, list) and len(center) == 2 and len(size) == 2):
            continue
        box = cv2.boxPoints(((float(center[0]), float(center[1])), (float(size[0]), float(size[1])),
                             float(obstacle.get("angle_deg") or 0.0)))
        features.append(_feature(f"obstruction:floor:{index}", polygon(projection, box.astype(np.float64), 0.0), {
            "feature_type": "obstruction", "category": "obstacle", "level_id": level_id,
            "area_m2": obstacle.get("area_m2"), "source": "floor_map",
        }))

    for index, region in enumerate(regions or []):
        if not isinstance(region, dict):
            continue
        name, names = _names(region)
        xz = _finite_xz(region.get("polygon_xz_m"))
        kind = region.get("kind")
        features.append(_feature(f"unit:{region.get('id', index)}", polygon(projection, region.get("polygon_xz_m"), epsilon_m), {
            "feature_type": "unit", "category": UNIT_CATEGORY.get(kind, "unspecified"), "kind": kind,
            "name": name, "names": names, "level_id": level_id, "source_id": region.get("id"),
            "area_m2": region.get("area_m2") or (round(ring_area_m2(xz), 2) if xz is not None and len(xz) >= 3 else None),
        }))

    for index, door in enumerate(doors or []):
        if not isinstance(door, dict):
            continue
        accessibility = {key: door[key] for key in ("meets_clear_width", "meets_headroom") if key in door}
        features.append(_feature(f"opening:{door.get('id', index)}", line(projection, door.get("span_xz_m")), {
            "feature_type": "opening", "category": "pedestrian", "kind": door.get("kind"), "level_id": level_id,
            "source_id": door.get("id"), "width_m": door.get("measured_clear_width_m") or door.get("nominal_width_m"),
            "accessibility": accessibility or None,
        }))

    place_names = {}
    for index, place in enumerate(places or []):
        if not isinstance(place, dict):
            continue
        name, names = _names(place)
        category = place.get("category", "unknown")
        place_names[place.get("id")] = name
        accessibility = {"step_free": False} if category in NOT_STEP_FREE_PLACES else None
        xz = _xz(place.get("position_m"))
        features.append(_feature(f"amenity:{place.get('id', index)}", point(projection, xz) if xz else None, {
            "feature_type": "amenity", "category": category, "name": name, "names": names, "level_id": level_id,
            "source_id": place.get("id"), "access_point_kind": place.get("access_point_kind"),
            "confidence": place.get("confidence"), "accessibility": accessibility,
        }))

    for index, hazard in enumerate(hazards or []):
        if not isinstance(hazard, dict):
            continue
        kind = hazard.get("kind")
        geometry = polygon(projection, hazard.get("polygon_xz_m"), epsilon_m) if hazard.get("polygon_xz_m") else None
        if geometry is None:
            xz = _xz(hazard.get("position_m"))
            geometry = point(projection, xz) if xz else None
        features.append(_feature(f"obstruction:{hazard.get('id', index)}", geometry, {
            "feature_type": "obstruction", "category": kind, "severity": hazard.get("severity"), "level_id": level_id,
            "source_id": hazard.get("id"), "measure": hazard.get("measure"),
            "accessibility": {"barrier": hazard.get("severity") == "barrier",
                              **({"step_free": False} if kind in NOT_STEP_FREE_HAZARDS else {})},
        }))

    for index, sign in enumerate(signs or []):
        if not isinstance(sign, dict):
            continue
        xz = _xz(sign.get("position_m"))
        features.append(_feature(f"sign:{sign.get('id', index)}", point(projection, xz) if xz else None, {
            "feature_type": "sign", "category": sign.get("category") or sign.get("kind"), "level_id": level_id,
            "source_id": sign.get("id"), "text": sign.get("text"), "languages": sign.get("languages"),
            "accessibility": {k: sign[k] for k in ("braille", "contrast_ratio", "mounting_height_m", "issues")
                              if sign.get(k) is not None} or None,
        }))

    graph = nav_graph if isinstance(nav_graph, dict) else {}
    nodes = graph.get("nodes") or []
    route_list = (routes or {}).get("routes") if isinstance(routes, dict) else None
    if route_list and not nodes:
        notices.append("routes present but nav_graph has no nodes; route lines were not exported")
    for index, route in enumerate((route_list or []) if nodes else []):
        if not isinstance(route, dict):
            continue
        legs, problems = surface_legs(graph, route, map_id)
        notices.extend(f"route {index} {problem}" for problem in problems)
        from_place, to_place = route.get("from_place"), route.get("to_place")
        route_id = route.get("id") or f"{from_place}:{to_place}:{route.get('profile', index)}"
        for leg_index, leg in enumerate(legs):
            leg_map, leg_floor = leg["key"]
            base = f"route:{route_id}"
            feature_id = f"{base}:leg:{leg_index}" if len(legs) > 1 else base
            features.append(_feature(feature_id, line(projection, leg["points"][:, [0, 2]]), {
                "feature_type": "route", "category": route.get("profile"), "level_id": leg_floor,
                "map_id": leg_map, "segment_index": leg_index, "edge_ids": leg["edge_ids"],
                "from_place": from_place, "to_place": to_place,
                "name": f"{place_names.get(from_place) or from_place} to {place_names.get(to_place) or to_place}",
                "length_m": round(float(np.linalg.norm(np.diff(leg["points"], axis=0), axis=1).sum()), 3),
                "route_length_m": route.get("length_m"), "route_estimated_seconds": route.get("estimated_seconds"),
            }))

    kept = [f for f in features if f is not None]
    collection = {
        "type": "FeatureCollection",
        "name": f"{scan_id}-geojson" if scan_id else "inview-geojson",
        "features": kept,
    }
    bbox = _bbox(kept)
    if bbox:
        collection["bbox"] = bbox
    return collection, notices


def _positions(geometry: dict):
    kind, coordinates = geometry["type"], geometry["coordinates"]
    if kind == "Point":
        yield coordinates
    elif kind == "LineString":
        yield from coordinates
    elif kind == "Polygon":
        for ring in coordinates:
            yield from ring


def _bbox(features: list[dict]) -> list[float] | None:
    positions = [p for f in features for p in _positions(f["geometry"])]
    if not positions:
        return None
    lon, lat = np.asarray(positions).T
    if lon.max() - lon.min() > 180:          # antimeridian: RFC 7946 §5.2 lets west > east
        lon = np.where(lon < 0, lon + 360, lon)
        west, east = float(wrap_degrees(lon.min())), float(wrap_degrees(lon.max()))
    else:
        west, east = float(lon.min()), float(lon.max())
    return [round(west, COORDINATE_DECIMALS), round(float(lat.min()), COORDINATE_DECIMALS),
            round(east, COORDINATE_DECIMALS), round(float(lat.max()), COORDINATE_DECIMALS)]


# --- Validation ------------------------------------------------------------------------------------

def _valid_position(position) -> bool:
    return (isinstance(position, list) and len(position) in (2, 3)
            and all(isinstance(v, (int, float)) and math.isfinite(v) for v in position)
            and -180 <= position[0] <= 180 and -90 <= position[1] <= 90)


def validate(collection: dict) -> list[str]:
    """RFC 7946 structural checks: types, positions, LineString length, closed CCW exterior rings."""
    errors = []
    if not isinstance(collection, dict) or collection.get("type") != "FeatureCollection":
        return ["not a FeatureCollection"]
    if not isinstance(collection.get("features"), list):
        return ["features is not a list"]
    seen = set()
    for index, feature in enumerate(collection["features"]):
        where = f"feature {index}"
        if not isinstance(feature, dict) or feature.get("type") != "Feature":
            errors.append(f"{where}: not a Feature")
            continue
        if feature.get("id") in seen:
            errors.append(f"{where}: duplicate id {feature.get('id')!r}")
        seen.add(feature.get("id"))
        if not isinstance(feature.get("properties"), (dict, type(None))):
            errors.append(f"{where}: properties must be an object or null")
        geometry = feature.get("geometry")
        if not isinstance(geometry, dict):
            errors.append(f"{where}: missing geometry")
            continue
        kind, coordinates = geometry.get("type"), geometry.get("coordinates")
        if kind == "Point":
            if not _valid_position(coordinates):
                errors.append(f"{where}: invalid Point position")
        elif kind == "LineString":
            if not isinstance(coordinates, list) or len(coordinates) < 2 or not all(map(_valid_position, coordinates)):
                errors.append(f"{where}: LineString needs >= 2 valid positions")
        elif kind == "Polygon":
            if not isinstance(coordinates, list) or not coordinates:
                errors.append(f"{where}: Polygon has no rings")
                continue
            for ring_index, ring in enumerate(coordinates):
                if not isinstance(ring, list) or len(ring) < 4 or not all(map(_valid_position, ring)):
                    errors.append(f"{where}: ring {ring_index} needs >= 4 valid positions")
                    continue
                if ring[0] != ring[-1]:
                    errors.append(f"{where}: ring {ring_index} is not closed")
                    continue
                area = signed_area_lonlat(ring)
                if ring_index == 0 and area <= 0:
                    errors.append(f"{where}: exterior ring is not counterclockwise")
                elif ring_index > 0 and area >= 0:
                    errors.append(f"{where}: hole {ring_index} is not clockwise")
        else:
            errors.append(f"{where}: unsupported geometry type {kind!r}")
    return errors


__all__ = ["GeoError", "build", "validate", "polygon", "line", "point", "simplify_ring", "signed_area_lonlat"]
