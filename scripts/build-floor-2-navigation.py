#!/usr/bin/env python3
"""Restrict Floor 2 navigation to coverage shared by the scan and current model.

Requires Python 3 with Shapely >= 2.1. Run from any directory:
    python scripts/build-floor-2-navigation.py

The original scan remains unchanged. Its walls, openings, obstacles and access
points are copied unchanged; this output only reduces its measured floor union.
The display reconstruction never adds navigation coverage to the new wings.
"""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

from shapely import constrained_delaunay_triangles
from shapely.affinity import affine_transform
from shapely.geometry import LineString, Polygon
from shapely.ops import unary_union

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "InView/Resources/StudentCenter"
EVIDENCE = ROOT / "models/walkthrough-building/floor-2-reconstruction"
ORIGINAL = RESOURCES / "student-center-east-floor-2.json"
RECONSTRUCTION = EVIDENCE / "reconstruction.json"
REGISTRATION = EVIDENCE / "registration.json"
OUTPUT = RESOURCES / "student-center-east-floor-2-navigation.json"
REPORT = EVIDENCE / "navigation-validation.json"
# The measured open balcony edge is a physical boundary. Keep the route's
# 0.45m clearance plus a 0.075m allowance for the 0.1m occupancy-grid cells.
BALCONY_EDGE_UV = [[-21.15, -7.25], [19.42, -7.25]]
BALCONY_EDGE_MARGIN = 0.525


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def footprint_polygon(item):
    if item.get("polygon"):
        return Polygon(item["polygon"])
    c, s = math.cos(item["yaw"]), math.sin(item["yaw"])
    x, z = item["center"]
    w, d = [v / 2 for v in item["size"]]
    return Polygon([(x + c * u - s * v, z + s * u + c * v)
                    for u, v in ((-w, -d), (w, -d), (w, d), (-w, d))])


def source_to_map(geometry, reconstruction, registration):
    # Source principalUV -> scan XZ (A transpose) -> existing map XZ (R, t).
    A = reconstruction["principal_axis_matrix"]
    theta = registration["horizontal_rotation_radians"]
    c, s = math.cos(theta), math.sin(theta)
    tx, tz = registration["translation_xz_m"]
    transform = [c * A[0][0] - s * A[0][1], c * A[1][0] - s * A[1][1],
                 s * A[0][0] + c * A[0][1], s * A[1][0] + c * A[1][1], tx, tz]
    return affine_transform(geometry, transform)


def model_floor_in_map(reconstruction, registration):
    """Use the exported floor triangles, including their holes and concave edges."""
    triangles = [Polygon([floor["vertices_uv"][i] for i in indices])
                 for floor in reconstruction["floors"] for indices in floor["triangles"]]
    assert all(p.is_valid and p.area > 0 for p in triangles)
    return source_to_map(unary_union(triangles), reconstruction, registration)


def floor_footprints(region, elevation):
    """Constrained triangulation keeps holes excluded and every ring below 128 vertices."""
    triangles = list(constrained_delaunay_triangles(region).geoms)
    triangles = [p for p in triangles if p.area > 5e-7]
    assert triangles and all(p.is_valid and not p.interiors for p in triangles)
    # Normalize winding and sort for deterministic output across repeated builds.
    rings = []
    for polygon in triangles:
        ring = list(polygon.exterior.coords)[:-1]
        if not polygon.exterior.is_ccw:
            ring.reverse()
        first = min(range(len(ring)), key=lambda i: ring[i])
        rings.append(ring[first:] + ring[:first])
    rings.sort()
    output = []
    for ring in rings:
        lo = [min(p[i] for p in ring) for i in (0, 1)]
        hi = [max(p[i] for p in ring) for i in (0, 1)]
        output.append({"kind": "floor", "center": [(a + b) / 2 for a, b in zip(lo, hi)],
                       "size": [b - a for a, b in zip(lo, hi)], "yaw": 0,
                       "bottom": elevation, "height": 0, "polygon": ring})
    return output


def main():
    original = read(ORIGINAL)
    reconstruction = read(RECONSTRUCTION)
    registration = read(REGISTRATION)
    observed = [footprint_polygon(f) for f in original["footprints"] if f["kind"] == "floor"
                and f.get("bottom") is not None and abs(f["bottom"] - original["floorY"]) <= 0.35]
    assert observed and all(p.is_valid and p.area > 0 for p in observed)
    measured = unary_union(observed)
    displayed = model_floor_in_map(reconstruction, registration)
    balcony_edge = source_to_map(LineString(BALCONY_EDGE_UV), reconstruction, registration)
    assert balcony_edge.difference(displayed.boundary.buffer(1e-5)).length < 1e-5
    # Preserve measured doorways: a coverage boundary is not necessarily an
    # obstacle. Apply the extra edge clearance only at the exposed balcony.
    balcony_guard = balcony_edge.buffer(BALCONY_EDGE_MARGIN, quad_segs=32)
    retained = measured.intersection(displayed).difference(balcony_guard)
    assert retained.is_valid and retained.area > 0
    floors = floor_footprints(retained, original["floorY"])
    serialized = unary_union([footprint_polygon(f) for f in floors])
    # Both containment guarantees are geometric, not approximate vertex-only checks.
    assert serialized.difference(measured).area < 1e-7
    assert serialized.difference(displayed).area < 1e-7
    assert serialized.intersection(balcony_guard).area < 1e-7
    assert serialized.symmetric_difference(retained).area < 1e-5
    nonfloors = [f for f in original["footprints"] if f["kind"] != "floor"]
    navigation = dict(original, footprints=floors + nonfloors, requiresMeasuredFloorCoverage=True)
    write(OUTPUT, navigation)
    report = {
        "schema_version": 1,
        "method": "Original measured floor union intersected with reconstructed display floor triangles in canonical map coordinates, with clearance at the exposed balcony edge; no added coverage",
        "original_map_sha256": digest(ORIGINAL),
        "reconstruction_sha256": digest(RECONSTRUCTION),
        "registration_sha256": digest(REGISTRATION),
        "navigation_map_sha256": digest(OUTPUT),
        "measured_floor_area_m2": measured.area,
        "model_floor_area_m2": displayed.area,
        "retained_floor_area_m2": retained.area,
        "removed_floor_area_m2": measured.difference(retained).area,
        "added_floor_area_m2": serialized.difference(measured).area,
        "floor_area_outside_model_m2": serialized.difference(displayed).area,
        "balcony_edge_uv_m": BALCONY_EDGE_UV,
        "balcony_edge_margin_m": BALCONY_EDGE_MARGIN,
        "minimum_obstacle_clearance_m": 0.45,
        "floor_polygon_count": len(floors),
        "maximum_floor_vertices": max(len(f["polygon"]) for f in floors),
        "preserved_nonfloor_footprints": len(nonfloors),
        "preserved_access_point_ids": [p["id"] for p in original["points"]],
        "routes": "Run Floor2RoutingTests to verify both known elevator routes against this map and the bundled model."
    }
    write(REPORT, report)
    print(f"Wrote {OUTPUT.relative_to(ROOT)}: {len(floors)} floor polygons, {retained.area:.3f} m² retained")
    print(f"Removed {report['removed_floor_area_m2']:.3f} m²; added {report['added_floor_area_m2']:.9f} m²")


if __name__ == "__main__":
    main()
