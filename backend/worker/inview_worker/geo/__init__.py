"""Geo-referencing: place the scan's local ARKit X/Z frame on the globe and export GeoJSON.

- `projection`: local X/Z meters <-> WGS84, a numerical port of AccessCore's `BuildingMapReference`.
- `reference`: robust building reference from the manifest's GPS/compass/barometer samples.
- `geojson`: RFC 7946 FeatureCollection export of the navigation products (IMDF-inspired properties).
"""
from .projection import EARTH_RADIUS_M, MAX_LATITUDE, GeoError, LocalProjection, wrap_degrees

__all__ = ["EARTH_RADIUS_M", "MAX_LATITUDE", "GeoError", "LocalProjection", "wrap_degrees"]
