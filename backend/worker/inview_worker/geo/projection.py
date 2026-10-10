"""Local X/Z meters <-> WGS84 latitude/longitude.

A line-by-line port of `Packages/AccessCore/Sources/AccessCore/BuildingMapReference.swift` so the
worker and the iOS app place the same scan on exactly the same spot:

- heading is clockwise from true north to the scan's local -Z axis (local +X is heading + 90 deg);
- a local Web Mercator projection (WGS84 semi-major axis, the map renderers' sphere) whose scale is
  corrected at the reference latitude, suitable for building-sized scans;
- longitudes are wrapped into [-180, 180) so a scan straddling the antimeridian stays local.

All functions accept scalars or arrays; `to_lonlat`/`to_local` work on (N, 2) arrays.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

EARTH_RADIUS_M = 6_378_137.0          # WGS84 semi-major axis (Web Mercator sphere)
MAX_LATITUDE = 85.05112878            # Web Mercator coverage
_RAD = math.pi / 180


class GeoError(ValueError):
    """Invalid reference, coordinate or point, or a result outside the map's coverage."""


def projected_y(latitude):
    """Web Mercator northing (meters) of a latitude in degrees."""
    return EARTH_RADIUS_M * np.log(np.tan(math.pi / 4 + np.asarray(latitude, dtype=np.float64) * _RAD / 2))


_MAX_PROJECTED_Y = float(projected_y(MAX_LATITUDE))


def wrap_degrees(degrees):
    """Swift `wrappedDegrees`: truncating remainder by 360, then into [-180, 180)."""
    value = np.fmod(np.asarray(degrees, dtype=np.float64), 360.0)
    value = np.where(value >= 180, value - 360, value)
    value = np.where(value < -180, value + 360, value)
    return float(value) if value.ndim == 0 else value


def _check_coordinates(latitude: np.ndarray, longitude: np.ndarray) -> None:
    if not (np.all(np.isfinite(latitude)) and np.all(np.abs(latitude) < MAX_LATITUDE)):
        raise GeoError("latitude outside the map's coverage")
    if not (np.all(np.isfinite(longitude)) and np.all((longitude >= -180) & (longitude <= 180))):
        raise GeoError("longitude outside [-180, 180]")


@dataclass(frozen=True)
class LocalProjection:
    """Places the scan's unchanged local floor coordinates on a geographic map (ARKit origin)."""
    latitude: float
    longitude: float
    heading_degrees: float = 0.0
    horizontal_accuracy_m: float | None = None

    @classmethod
    def from_georef(cls, georef: dict) -> "LocalProjection":
        projection = cls(float(georef["latitude"]), float(georef["longitude"]),
                         float(georef.get("heading_degrees") or 0.0), georef.get("horizontal_accuracy_m"))
        projection.validate()
        return projection

    def validate(self) -> None:
        _check_coordinates(np.asarray(self.latitude, dtype=np.float64), np.asarray(self.longitude, dtype=np.float64))
        if not math.isfinite(self.heading_degrees):
            raise GeoError("heading is not finite")
        accuracy = self.horizontal_accuracy_m
        if accuracy is not None and not (math.isfinite(accuracy) and accuracy >= 0):
            raise GeoError("horizontal accuracy must be finite and non-negative")

    @property
    def _heading_radians(self) -> float:
        return math.fmod(self.heading_degrees, 360.0) * _RAD

    def to_lonlat(self, xz) -> np.ndarray:
        """Local (x, z) meters, shape (N, 2) or (2,), -> [longitude, latitude] degrees (GeoJSON order)."""
        self.validate()
        points = np.asarray(xz, dtype=np.float64)
        flat = points.reshape(-1, 2)
        if not np.all(np.isfinite(flat)):
            raise GeoError("map point is not finite")
        angle = self._heading_radians
        x, z = flat[:, 0], flat[:, 1]
        east = x * math.cos(angle) - z * math.sin(angle)
        north = -x * math.sin(angle) - z * math.cos(angle)
        scale = math.cos(self.latitude * _RAD)
        with np.errstate(over="ignore", invalid="ignore"):
            northing = float(projected_y(self.latitude)) + north / scale
        if not (np.all(np.isfinite(northing)) and np.all(np.abs(northing) < _MAX_PROJECTED_Y)):
            raise GeoError("point outside the map's coverage")
        latitude = np.arctan(np.sinh(northing / EARTH_RADIUS_M)) / _RAD
        longitude = np.asarray(wrap_degrees(self.longitude + east / scale / EARTH_RADIUS_M / _RAD), dtype=np.float64)
        _check_coordinates(latitude, longitude)
        return np.column_stack((longitude, latitude)).reshape(points.shape)

    def to_local(self, lonlat) -> np.ndarray:
        """[longitude, latitude] degrees, shape (N, 2) or (2,), -> local (x, z) meters."""
        self.validate()
        points = np.asarray(lonlat, dtype=np.float64)
        flat = points.reshape(-1, 2)
        longitude, latitude = flat[:, 0], flat[:, 1]
        _check_coordinates(latitude, longitude)
        scale = math.cos(self.latitude * _RAD)
        east = np.asarray(wrap_degrees(longitude - self.longitude)) * _RAD * EARTH_RADIUS_M * scale
        north = (projected_y(latitude) - float(projected_y(self.latitude))) * scale
        angle = self._heading_radians
        x = east * math.cos(angle) - north * math.sin(angle)
        z = -east * math.sin(angle) - north * math.cos(angle)
        result = np.column_stack((x, z))
        if not np.all(np.isfinite(result)):
            raise GeoError("map point is not finite")
        return result.reshape(points.shape)

    # Scalar conveniences mirroring the Swift API names.
    def coordinate(self, x: float, z: float) -> tuple[float, float]:
        """Swift `coordinate(for:)`: local (x, z) -> (latitude, longitude)."""
        longitude, latitude = self.to_lonlat([x, z])
        return float(latitude), float(longitude)

    def map_point(self, latitude: float, longitude: float) -> tuple[float, float]:
        """Swift `mapPoint(for:)`: (latitude, longitude) -> local (x, z)."""
        x, z = self.to_local([longitude, latitude])
        return float(x), float(z)


def offset_m(origin_lat: float, origin_lon: float, latitude, longitude) -> np.ndarray:
    """(east, north) meters of coordinates from an origin in the same local projection."""
    x, z = LocalProjection(origin_lat, origin_lon).to_local(
        np.column_stack((np.atleast_1d(longitude), np.atleast_1d(latitude)))).T
    return np.column_stack((x, -z))
