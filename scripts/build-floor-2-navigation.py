#!/usr/bin/env python3
"""Build Floor 2 navigation from the registered video/LiDAR measurements.

Requires Python 3 with Shapely >= 2.1. Run from any directory:
    python scripts/build-floor-2-navigation.py

The original scan remains unchanged. Captured floor support and reconciled
structure extend routing through the gallery and restroom passage, while the
visible floor, atrium boundaries and measured furniture constrain every route.
Use --route-results with native AccessCore output to attach path verification.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import uuid

from shapely import constrained_delaunay_triangles
from shapely.affinity import affine_transform
from shapely.geometry import LineString, Point, Polygon
from shapely.ops import unary_union

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "InView/Resources/StudentCenter"
EVIDENCE = ROOT / "models/walkthrough-building/floor-2-reconstruction"
ORIGINAL = RESOURCES / "student-center-east-floor-2.json"
RECONSTRUCTION = EVIDENCE / "reconstruction.json"
REGISTRATION = EVIDENCE / "registration.json"
OUTPUT = RESOURCES / "student-center-east-floor-2-navigation.json"
REPORT = EVIDENCE / "navigation-validation.json"
FLOOR_EVIDENCE = EVIDENCE / "floor-evidence.json"
LOCALIZATION = RESOURCES / "student-center-east-floor-2-localization.json"
MANIFEST = EVIDENCE / "manifest.json"
FEATURE_NAMESPACE = uuid.UUID("8184f693-d851-4c68-94f2-9fe96f020134")
# Observed depth has small gaps at furniture and wall bases. Its reviewed
# boundary allowance is still clipped to the reconstructed captured floor.
DEPTH_BOUNDARY_ALLOWANCE = 0.35
# A cell center can be half a cell diagonal from its corner. Inset the floor
# outline by more than that distance so smoothed paths cannot clip a corner.
GRID_BOUNDARY_MARGIN = 0.075
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


def feature_footprint(identifier, center, size, yaw, kind, height, elevation, reconstruction, registration):
    position = source_to_map(Point(center), reconstruction, registration)
    axis = source_to_map(Point(center[0] + math.cos(yaw), center[1] + math.sin(yaw)),
                         reconstruction, registration)
    return {"id": str(uuid.uuid5(FEATURE_NAMESPACE, identifier)).upper(),
            "kind": kind, "center": [position.x, position.y], "size": size,
            "yaw": math.atan2(axis.y - position.y, axis.x - position.x),
            "bottom": elevation, "height": height}


def measured_features(original, reconstruction, registration):
    """Use one reconciled structure; never stack the drifting old balcony walls."""
    elevation = original["floorY"]
    walls, doors, objects, preserved = [], [], [], []

    def footprint(identifier, center, size, yaw, kind, height):
        return feature_footprint(identifier, center, size, yaw, kind, height, elevation,
                                 reconstruction, registration)

    for wall in reconstruction["walls"]:
        a, b = wall["a"], wall["b"]
        walls.append(footprint(wall["id"], [(a[i] + b[i]) / 2 for i in (0, 1)],
                               [math.dist(a, b), wall.get("thickness", 0.14)],
                               math.atan2(b[1] - a[1], b[0] - a[0]), "wall", wall["height"]))

    door_groups = {}
    for item in reconstruction["furniture"]:
        if item["kind"] == "door":
            door_groups.setdefault(item["id"].rsplit("-leaf-", 1)[0], []).append(item)
            continue
        if item["id"].startswith("measured-lounge-"):
            index = int(item["id"].rsplit("-", 1)[1])
            original_item = original["footprints"][index]
            assert original_item["kind"] == "obstacle"
            objects.append(original_item)
            preserved.append(index)
            continue
        width, depth, height = item["dimensions_m"]
        objects.append(footprint(item["id"], item["center_uv"], [width, depth],
                                 math.radians(item["angle_degrees"]), "obstacle", height))

    for identifier, leaves in sorted(door_groups.items()):
        if identifier.startswith("retained-lounge-door-"):
            index = int(identifier.rsplit("-", 1)[1])
            original_door = original["footprints"][index]
            assert original_door["kind"] == "door"
            doors.append(original_door)
            continue
        # Restore the measured width before the illustration's leaf-edge gap.
        width = sum(item["dimensions_m"][0] + 0.035 for item in leaves)
        center = [sum(item["center_uv"][i] for item in leaves) / len(leaves) for i in (0, 1)]
        doors.append(footprint(identifier, center, [width, 0.18],
                               math.radians(leaves[0]["angle_degrees"]), "door", 2.1))
    # The reconstruction cuts this filmed overhead portal out of a wall return.
    doors.append(footprint("restroom-passage-portal", [-5.925, 39.16], [2.05, 0.18],
                           0, "opening", 2.1))
    return walls + doors + objects, {
        "wall_rail_and_glazing_segments": len(walls), "measured_passages": len(doors),
        "obstacle_footprints": len(objects), "preserved_lounge_obstacle_indices": preserved,
        "furniture_method": "Observed footprint envelopes before visual template scaling, with planner clearance applied once; source measurement uncertainty remains in furnishing evidence"
    }


def route_validation(path, navigation_digest, displayed, retained, balcony_edge, expected_destinations):
    result = read(path)
    assert result["navigation_map_sha256"] == navigation_digest, "Routes must use this exact generated map"
    routes = result["routes"]
    assert all(route["success"] for route in routes)
    assert expected_destinations.issubset({route["destination"] for route in routes})
    summaries = []
    for route in routes:
        line = LineString(route["waypoints_map_xz"])
        outside = line.difference(displayed).length
        outside_coverage = line.difference(retained).length
        edge_clearance = line.distance(balcony_edge)
        # Float32 SceneKit/AccessCore coordinates leave sub-micron seam noise.
        assert outside < 1e-5 and outside_coverage < 1e-5 and edge_clearance >= 0.45
        assert route["clearance"] >= 0.4499999
        summaries.append({"destination": route["destination"], "length_m": route["length"],
                          "obstacle_clearance_m": route["clearance"],
                          "outside_model_floor_m": outside,
                          "outside_navigation_coverage_m": outside_coverage,
                          "balcony_edge_clearance_m": edge_clearance})
    return {"method": "Native AccessCore step-free routes from the Lounge label; exact path containment against exported floor triangles",
            "navigation_map_sha256": navigation_digest, "routes": summaries}


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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--route-results", type=Path, help="Native planner output for this generated map")
    args = parser.parse_args()
    original = read(ORIGINAL)
    reconstruction = read(RECONSTRUCTION)
    registration = read(REGISTRATION)
    evidence = read(FLOOR_EVIDENCE)
    observed = [footprint_polygon(f) for f in original["footprints"] if f["kind"] == "floor"
                and f.get("bottom") is not None and abs(f["bottom"] - original["floorY"]) <= 0.35]
    assert observed and all(p.is_valid and p.area > 0 for p in observed)
    measured = unary_union(observed)
    displayed = model_floor_in_map(reconstruction, registration)
    depth = source_to_map(unary_union([Polygon(item["outer_uv"], item.get("holes_uv", []))
                                      for item in evidence["polygons"]]), reconstruction, registration)
    assert depth.is_valid and depth.area > 0
    supported = measured.union(depth.buffer(DEPTH_BOUNDARY_ALLOWANCE))
    # Use unrounded rings for the inset so microscopic shared-triangle seams
    # cannot become artificial walls across the measured lounge doorway.
    outline = source_to_map(unary_union([Polygon(item["outer_uv"], item["holes_uv"])
                                        for item in reconstruction["floors"]]), reconstruction, registration)
    inside_outline = outline.buffer(-GRID_BOUNDARY_MARGIN, join_style=2)
    balcony_edge = source_to_map(LineString(BALCONY_EDGE_UV), reconstruction, registration)
    assert balcony_edge.difference(displayed.boundary.buffer(1e-5)).length < 1e-5
    # Preserve measured doorways: a coverage boundary is not necessarily an
    # obstacle. Apply the extra edge clearance only at the exposed balcony.
    balcony_guard = balcony_edge.buffer(BALCONY_EDGE_MARGIN, quad_segs=32)
    retained = supported.intersection(displayed).intersection(inside_outline).difference(balcony_guard)
    assert retained.is_valid and retained.area > 0
    floors = floor_footprints(retained, original["floorY"])
    serialized = unary_union([footprint_polygon(f) for f in floors])
    # Containment guarantees use complete polygon areas, not vertex-only checks.
    assert serialized.difference(supported).area < 1e-7
    assert serialized.difference(displayed).area < 1e-7
    assert serialized.difference(inside_outline).area < 1e-7
    assert serialized.intersection(balcony_guard).area < 1e-7
    assert serialized.symmetric_difference(retained).area < 1e-5
    nonfloors, feature_report = measured_features(original, reconstruction, registration)
    navigation = dict(original, footprints=floors + nonfloors, requiresMeasuredFloorCoverage=True)
    write(OUTPUT, navigation)
    navigation_digest = digest(OUTPUT)
    report = {
        "schema_version": 2,
        "method": "Registered measured depth support and valid prior floor, clipped to reconstructed floor triangles; reconciled walls, observed furniture and measured passages replace obsolete balcony geometry",
        "original_map_sha256": digest(ORIGINAL),
        "reconstruction_sha256": digest(RECONSTRUCTION),
        "registration_sha256": digest(REGISTRATION),
        "floor_evidence_sha256": digest(FLOOR_EVIDENCE),
        "navigation_map_sha256": navigation_digest,
        "prior_measured_floor_area_m2": measured.area,
        "depth_support_floor_area_m2": depth.area,
        "depth_boundary_allowance_m": DEPTH_BOUNDARY_ALLOWANCE,
        "model_floor_area_m2": displayed.area,
        "retained_floor_area_m2": retained.area,
        "removed_floor_area_m2": measured.difference(retained).area,
        "added_floor_area_m2": serialized.difference(measured).area,
        "floor_area_outside_measured_support_m2": serialized.difference(supported).area,
        "floor_area_outside_model_m2": serialized.difference(displayed).area,
        "grid_boundary_margin_m": GRID_BOUNDARY_MARGIN,
        "balcony_edge_uv_m": BALCONY_EDGE_UV,
        "balcony_edge_margin_m": BALCONY_EDGE_MARGIN,
        "minimum_obstacle_clearance_m": 0.45,
        "floor_polygon_count": len(floors),
        "maximum_floor_vertices": max(len(f["polygon"]) for f in floors),
        "features": feature_report,
        "preserved_access_point_ids": [p["id"] for p in original["points"]],
        "route_regression_test": "Floor2RoutingTests verifies routes from Lounge through the captured Floor 2 network against actual bundled floor geometry."
    }
    if args.route_results:
        expected_destinations = {point["name"] for point in original["points"]}
        expected_destinations.update(item["title"] for item in reconstruction["labels"]
                                     if item["title"] != "Lounge")
        report["native_route_validation"] = route_validation(args.route_results, navigation_digest,
                                                            displayed, serialized, balcony_edge,
                                                            expected_destinations)
    write(REPORT, report)
    localization = read(LOCALIZATION)
    localization["mapSHA256"] = navigation_digest
    write(LOCALIZATION, localization)
    manifest = read(MANIFEST)
    manifest["navigation_map_sha256"] = navigation_digest
    manifest["derived_files"] = [{"filename": path.name, "sha256": digest(path)}
                                 for path in sorted(EVIDENCE.glob("*.json"))
                                 if path.name not in ("manifest.json", "native-load-validation.json")]
    write(MANIFEST, manifest)
    print(f"Wrote {OUTPUT.relative_to(ROOT)}: {len(floors)} floor polygons, {retained.area:.3f} m² retained")
    print(f"Prior floor removed {report['removed_floor_area_m2']:.3f} m²; captured floor added {report['added_floor_area_m2']:.3f} m²")


if __name__ == "__main__":
    main()
