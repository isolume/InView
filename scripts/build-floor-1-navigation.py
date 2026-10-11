#!/usr/bin/env python3
"""Build the measured Floor 1 routing zones and their explicit level connections.

Requires Python 3, NumPy, and Shapely 2.1+. All inputs are retained in the
floor-1-reconstruction evidence directory. Visual floor completion is never
used as routing evidence. Floor 2 and Floor 3 resources are not modified.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import uuid

import numpy as np
from shapely import constrained_delaunay_triangles, make_valid
from shapely.affinity import affine_transform
from shapely.geometry import GeometryCollection, LineString, Point, Polygon, box
from shapely.ops import nearest_points, unary_union

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "models/walkthrough-building/floor-1-reconstruction"
RESOURCES = ROOT / "InView/Resources/StudentCenter"
MEASUREMENTS = EVIDENCE / "navigation-measurements.json"
REGISTRATION = EVIDENCE / "registration.json"
RECONSTRUCTION = EVIDENCE / "reconstruction.json"
GROUND_SUPPORT = EVIDENCE / "navigation-ground-support.json"
LIMITATIONS = EVIDENCE / "navigation-limitations.json"
OUTPUT = RESOURCES / "student-center-east-floor-1-navigation.json"
LAYOUT = RESOURCES / "student-center-east-floor-1-model-layout.json"
REPORT = EVIDENCE / "navigation-validation.json"
NAMESPACE = uuid.UUID("7f789e65-b4f1-4879-a57d-f7c260e7da68")
LEVELS = {"main": 0.0, "raised-l": 1.58, "dining-terrace": 1.1}
ZONE_NAMES = {"main": "Main floor", "raised-l": "Auditorium and window lounge", "dining-terrace": "Dining terrace"}
# Reviewed ground-height bands only. Intermediate treads, the dining terrace,
# and the auditorium's lower seating ground do not become horizontal shortcuts.
BAND_ZONES = {
    "081DA781": {0: "main", 1: "raised-l"},
    "611423DC": {0: "main", 3: "raised-l"},
    "7714E8C3": {0: "main", 2: "dining-terrace", 3: "raised-l"},
    "785D48F6": {1: "raised-l"},
    "92ED4CB7": {0: "main", 1: "main"},
    "3F8FE86D": {0: "main", 1: "main"},
    "D598D846": {0: "main"},
}
# Route to the observed auditorium foyer; internal seating/stage levels remain
# visual geometry until their individual transitions have a measured route.
RAISED_FOYER_LIMIT = box(-10, -16, 18, 4)
TRACE_RADIUS = 0.30
TRACE_EVIDENCE_REACH = 0.80
DEPTH_PIXEL_ALLOWANCE = 0.12
GRID_EDGE_INSET = 0.075


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identifier(value):
    return str(uuid.uuid5(NAMESPACE, value)).upper()


def parts(geometry):
    if geometry.is_empty:
        return []
    if isinstance(geometry, Polygon):
        return [geometry]
    return [p for g in geometry.geoms for p in parts(g)]


def polygons(records):
    return unary_union([make_valid(Polygon(p["outer_xz"], p.get("holes_xz", [])))
                        for p in records])


def transform_xz(geometry, matrix):
    return affine_transform(geometry, [matrix[0, 0], matrix[0, 2], matrix[2, 0], matrix[2, 2],
                                       matrix[0, 3], matrix[2, 3]])


def transform_point(point, matrix):
    return (matrix @ np.r_[point, 1])[:3]


def footprint_shape(feature):
    if feature.get("polygon"):
        return Polygon(feature["polygon"])
    w, d = np.array(feature["size"]) / 2
    c, s = math.cos(feature["yaw"]), math.sin(feature["yaw"])
    x, z = feature["center"]
    return Polygon([(x + c * u - s * v, z + s * u + c * v)
                    for u, v in [(-w, -d), (w, -d), (w, d), (-w, d)]])


def footprint_from_box(source_id, kind, matrix, dimensions, zone_id, furniture=None):
    axis = matrix[[0, 2], 0]
    result = {"id": identifier(f"{zone_id}:{source_id}"), "kind": kind,
              "center": matrix[[0, 2], 3].tolist(),
              "size": [float(dimensions[0]), float(max(dimensions[2], 0.14))],
              "yaw": math.atan2(axis[1], axis[0]), "bottom": LEVELS[zone_id],
              "height": float(dimensions[1])}
    if furniture:
        result["furniture"] = furniture
    return result


def measured_coverage(data, sources, transforms):
    per_scan = {}
    depth_by_zone = {z: [] for z in LEVELS}
    for scan in data["scans"]:
        capture_id = scan["capture_id"]
        for index, zone in BAND_ZONES[capture_id[:8]].items():
            band = scan["strict_height_bands"][index]
            geometry = transform_xz(polygons(band["strict_measured_polygons"]), transforms[capture_id])
            per_scan[(capture_id, index)] = geometry
            depth_by_zone[zone].append(geometry)
    # Recover directly measured ground lost by a narrow global height peak as
    # the handheld scan drifts. These polygons use paired-frame floor estimates,
    # confidence-2 horizontal depth, and explicit physical-zone height bounds.
    for capture in read(GROUND_SUPPORT)["captures"]:
        depth_by_zone["main"].append(polygons(capture["common_polygons"]))
    depth = {zone: unary_union(items) for zone, items in depth_by_zone.items()}
    trace_support = {zone: geometry.buffer(TRACE_EVIDENCE_REACH) for zone, geometry in depth.items()}
    trace_lines = {zone: [] for zone in LEVELS}
    trace_points = {zone: [] for zone in LEVELS}
    accepted_segments = []
    for capture_id, source in sources.items():
        short = capture_id[:8]
        native = source["walk_trace"]["samples"]
        samples = [(p, transform_point(p["cameraPosition"], transforms[capture_id])) for p in native]

        def zone_for(position):
            if short in {"92ED4CB7", "3F8FE86D", "D598D846"}:
                return "main"
            if 1.30 <= position[1] <= 1.82:
                return "main"
            if 2.85 <= position[1] <= 3.40:
                return "raised-l"
            if short == "7714E8C3" and 2.32 <= position[1] <= 2.68:
                return "dining-terrace"
            return None

        for (previous, a), (current, b) in zip(samples, samples[1:]):
            zone = zone_for(a)
            dt = current["timestampSeconds"] - previous["timestampSeconds"]
            distance = float(np.linalg.norm(b[[0, 2]] - a[[0, 2]]))
            if (zone is None or zone != zone_for(b) or current["startsSegment"]
                    or not 0 < dt <= 1.75 or distance > 2.5 or distance / dt > 2.2
                    or abs(float(a[1] - b[1])) > 0.12):
                continue
            line = LineString([a[[0, 2]], b[[0, 2]]])
            # A continuous camera walk can support its narrow centerline where
            # downward-facing depth is missing, but it cannot bridge remote gaps.
            if not trace_support[zone].covers(line):
                continue
            trace_lines[zone].append(line)
            trace_points[zone].extend([a[[0, 2]].tolist(), b[[0, 2]].tolist()])
            accepted_segments.append({"capture_id": capture_id, "zone_id": zone,
                                      "timestamps": [previous["timestampSeconds"], current["timestampSeconds"]],
                                      "a_xz": a[[0, 2]].tolist(), "b_xz": b[[0, 2]].tolist()})
    trace = {zone: unary_union(lines).buffer(TRACE_RADIUS, cap_style=2, join_style=2)
             if lines else GeometryCollection() for zone, lines in trace_lines.items()}
    coverage = {}
    for zone in LEVELS:
        # 12 cm is below one depth-support cell. Preserve all larger holes and
        # never use the broad native RoomPlan rectangles as coverage.
        coverage[zone] = depth[zone].buffer(DEPTH_PIXEL_ALLOWANCE).union(trace[zone])
        if zone == "raised-l":
            coverage[zone] = coverage[zone].intersection(RAISED_FOYER_LIMIT)
        coverage[zone] = coverage[zone].buffer(-GRID_EDGE_INSET, join_style=2)
    return coverage, depth, trace, trace_points, accepted_segments


def measured_features(sources, transforms, coverage):
    features = {zone: [] for zone in LEVELS}
    records = []
    # Prefer the short landing scan, then the coherent auditorium and other
    # locally authoritative captures. Overlapping duplicate planes are dropped.
    order = {s: i for i, s in enumerate(["081DA781", "785D48F6", "7714E8C3", "92ED4CB7",
                                        "3F8FE86D", "D598D846", "611423DC"])}
    kept_walls = {z: [] for z in LEVELS}
    furniture_names = {"chair", "table", "sofa", "bed", "storage", "sink", "toilet", "bathtub", "television", "fireplace"}
    for capture_id, source in sorted(sources.items(), key=lambda pair: order[pair[0][:8]]):
        T = transforms[capture_id]
        for room in source["native_rooms"]:
            for category in ["walls", "windows", "doors", "openings", "objects"]:
                for item in room.get(category, []):
                    m = T @ np.array(item["transform"]).reshape(4, 4, order="F")
                    dims = np.array(item["dimensions"], dtype=float)
                    if min(dims[:2]) <= 0.02:
                        continue
                    kind = {"walls": "wall", "windows": "window", "doors": "door", "openings": "opening", "objects": "obstacle"}[category]
                    native_kind = next(iter(item.get("category", {})), None)
                    furniture = native_kind if native_kind in furniture_names else None
                    allowed_zones = sorted(set(BAND_ZONES[capture_id[:8]].values()))
                    for zone in allowed_zones:
                        feature = footprint_from_box(capture_id + ":" + item["identifier"], kind, m, dims, zone, furniture)
                        shape = footprint_shape(feature)
                        if shape.distance(coverage[zone]) > 0.65:
                            continue
                        if kind == "obstacle":
                            bottom = m[1, 3] - dims[1] / 2
                            # Main corridor scans have reviewed gradual Y drift;
                            # in mixed-elevation scans keep furniture on its level.
                            if capture_id[:8] not in {"92ED4CB7", "3F8FE86D", "D598D846"} and abs(bottom - LEVELS[zone]) > 0.42:
                                continue
                            if dims[2] <= 0.03:
                                continue
                        if kind == "wall":
                            axis = m[[0, 2], 0]
                            center = m[[0, 2], 3]
                            line = LineString([center - axis * dims[0] / 2, center + axis * dims[0] / 2])
                            duplicate = any(abs(math.sin(feature["yaw"] - yaw)) < 0.10
                                            and line.intersection(existing.buffer(0.36)).length > 0.70 * min(line.length, existing.length)
                                            for existing, yaw in kept_walls[zone])
                            if duplicate:
                                continue
                            kept_walls[zone].append((line, feature["yaw"]))
                        # Prevent duplicate native UUIDs repeated by RoomPlan rooms.
                        if any(f["id"] == feature["id"] for f in features[zone]):
                            continue
                        features[zone].append(feature)
                        records.append({"id": feature["id"], "capture_id": capture_id,
                                        "source_id": item["identifier"], "zone_id": zone, "kind": kind})
    return features, records


def floor_footprints(region, elevation):
    # Five-metre tiles retain concavities without a huge triangle soup. Rings
    # containing holes, or longer than the app's 128-vertex limit, are triangulated.
    pieces = []
    x0, z0, x1, z1 = region.bounds
    for x in range(math.floor(x0 / 5), math.ceil(x1 / 5)):
        for z in range(math.floor(z0 / 5), math.ceil(z1 / 5)):
            for p in parts(region.intersection(box(x * 5, z * 5, x * 5 + 5, z * 5 + 5))):
                p = p.simplify(0.0001, preserve_topology=True)
                if p.area < 0.001:
                    continue
                pieces.extend(list(constrained_delaunay_triangles(p).geoms)
                              if p.interiors or len(p.exterior.coords) > 128 else [p])
    rings = []
    for p in pieces:
        if p.area < 0.001:
            continue
        ring = list(p.exterior.coords)[:-1]
        if not p.exterior.is_ccw:
            ring.reverse()
        first = min(range(len(ring)), key=lambda i: ring[i])
        rings.append(ring[first:] + ring[:first])
    output = []
    for ring in sorted(rings):
        lo, hi = np.min(ring, axis=0), np.max(ring, axis=0)
        output.append({"kind": "floor", "center": ((lo + hi) / 2).tolist(),
                       "size": (hi - lo).tolist(), "yaw": 0, "bottom": elevation,
                       "height": 0, "polygon": ring})
    return output


def add_reviewed_barriers(features, records, coverage):
    # Only reviewed barriers supplement native obstacles. Completed display floors
    # and schematic auditorium seat rows never create routing support or obstacles.
    reconstruction = read(RECONSTRUCTION)
    for wall in reconstruction["walls"]:
        if not wall["id"].startswith(("court-salon-envelope-", "atrium-")):
            continue
        a, b = np.array(wall["a"]), np.array(wall["b"])
        zone = min(LEVELS, key=lambda z: abs(LEVELS[z] - float(a[1])))
        d = b[[0, 2]] - a[[0, 2]]
        feature = {"id": identifier(zone + ":reviewed:" + wall["id"]), "kind": "wall",
                   "center": ((a[[0, 2]] + b[[0, 2]]) / 2).tolist(),
                   "size": [float(np.linalg.norm(d)), wall.get("thickness", 0.14)],
                   "yaw": math.atan2(d[1], d[0]), "bottom": LEVELS[zone], "height": wall["height"]}
        if footprint_shape(feature).distance(coverage[zone]) > 0.65:
            continue
        features[zone].append(feature)
        records.append({"id": feature["id"], "zone_id": zone, "source_id": wall["id"],
                        "kind": "wall", "evidence": wall["evidence"], "source": "reviewed_reconstruction"})
    for item in reconstruction["furniture"]:
        if item["kind"] not in {"counter", "column"}:
            continue
        zone = min(LEVELS, key=lambda z: abs(LEVELS[z] - item["position"][1]))
        feature = {"id": identifier(zone + ":reviewed:" + item["id"]), "kind": "obstacle",
                   "center": [item["position"][0], item["position"][2]],
                   "size": [item["dimensions"][0], item["dimensions"][2]],
                   "yaw": math.radians(item["yaw_degrees"]), "bottom": LEVELS[zone], "height": item["dimensions"][1]}
        features[zone].append(feature)
        records.append({"id": feature["id"], "zone_id": zone, "source_id": item["id"],
                        "kind": "obstacle", "evidence": item["evidence"], "source": "reviewed_reconstruction"})


def add_measured_court_doors(features, records, measurements):
    for portal in measurements["court_salon_portals"]["openings"]:
        jambs = np.array(portal["jambs_canonical_xyz"])[:, [0, 2]]
        axis = jambs[1] - jambs[0]
        yaw = math.atan2(axis[1], axis[0])
        for index, center in enumerate(portal["bay_center_canonical_xyz"]):
            feature = {"id": identifier(portal["id"] + f":bay:{index}"), "kind": "door",
                       "center": [center[0], center[2]],
                       "size": [portal["conservative_min_bay_width_m"][index], 1.4],
                       "yaw": yaw, "bottom": 0, "height": 2.1}
            # Thresholds lie up to 0.6m inside the simplified perimeter plane.
            # The cut spans that measured offset; its width is never enlarged.
            features["main"].append(feature)
            records.append({"id": feature["id"], "zone_id": "main", "source_id": portal["id"],
                            "kind": "door", "evidence": portal["frame"], "source": "measured_video_depth",
                            "observed_width_range_m": portal["observed_bay_width_ranges_m"][index],
                            "width_uncertainty_m": portal["width_uncertainty_m"],
                            "used_clear_width_m": feature["size"][0]})
        post = portal["post_center_canonical_xyz"]
        features["main"].append({"id": identifier(portal["id"] + ":center-post"), "kind": "obstacle",
                                 "center": [post[0], post[2]],
                                 "size": [portal["physical_post_width_m"], 1.4],
                                 "yaw": yaw, "bottom": 0, "height": 2.1})
        records.append({"id": features["main"][-1]["id"], "zone_id": "main", "source_id": portal["id"],
                        "kind": "obstacle", "evidence": "Video-confirmed fixed central mullion; normal depth spans completed-envelope offset",
                        "source": "measured_video_depth"})


def approximate_free(region, features):
    blocked = unary_union([footprint_shape(f) for f in features
                           if f["kind"] in {"wall", "window", "obstacle", "stairs"}])
    doors = [f for f in features if f["kind"] in {"door", "opening"} and f["size"][0] >= 0.81]
    for door in doors:
        cut = dict(door, size=[door["size"][0], door["size"][1] + 0.4])
        blocked = blocked.difference(footprint_shape(cut))
    free = region.difference(blocked.buffer(0.56))
    for door in doors:
        lane = dict(door, size=[max(door["size"][0] - 0.3, 0.3), door["size"][1] + 1.3])
        free = free.union(footprint_shape(lane).intersection(region))
    return free


def choose_landing(seed, zone, free, trace_points, maximum_move=1.2):
    point = Point(seed)
    interior = free[zone].buffer(-0.03)
    if interior.covers(point):
        return np.asarray(seed, dtype=float)
    candidates = [p for p in trace_points[zone]
                  if math.dist(p, seed) <= maximum_move and interior.covers(Point(p))]
    if candidates:
        return np.array(min(candidates, key=lambda p: math.dist(p, seed)))
    nearest = nearest_points(point, free[zone].buffer(-0.06))[1]
    if nearest.is_empty or nearest.distance(point) > maximum_move:
        raise ValueError(f"No measured clear landing near {zone} {seed}: nearest={nearest}")
    return np.array(nearest.coords[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--route-results", type=Path)
    parser.add_argument("--diagnostics-output", type=Path)
    args = parser.parse_args()
    measurements, registration = read(MEASUREMENTS), read(REGISTRATION)
    transforms = {s["capture_id"]: np.array(s["mapFromScan"]).reshape(4, 4, order="F") for s in registration["scans"]}
    sources = {p.stem: read(p) for p in sorted((EVIDENCE / "sources").glob("*.json"))}
    coverage, depth, trace, trace_points, trace_segments = measured_coverage(measurements, sources, transforms)
    atrium_void = Polygon(measurements["protected_atrium_void_common_xz"])
    ramp = measurements["food_court_ramp"]
    ramp_vertices = np.array([transform_point(p, transforms[ramp["captureID"]])[[0, 2]] for p in ramp["vertices"]])
    ramp_polygon = Polygon(ramp_vertices)
    # The sloped run is an explicit transition, never a flat shortcut at either
    # endpoint's elevation. Its horizontal approaches remain ordinary measured floor.
    coverage = {z: p.difference(atrium_void).difference(ramp_polygon) for z, p in coverage.items()}
    features, feature_sources = measured_features(sources, transforms, coverage)
    add_reviewed_barriers(features, feature_sources, coverage)
    add_measured_court_doors(features, feature_sources, measurements)

    corners = measurements["main_stair_corners"]
    stair_ring = np.array([corners[i]["xyz"] for i in [0, 4, 7, 2]])[:, [0, 2]]
    stair_polygon = Polygon(stair_ring)
    bottom, top = stair_ring[:2].mean(axis=0), stair_ring[2:].mean(axis=0)
    direction = (top - bottom) / np.linalg.norm(top - bottom)
    side = stair_ring[1] - stair_ring[0]
    width = float(max(np.linalg.norm(stair_ring[1] - stair_ring[0]), np.linalg.norm(stair_ring[2] - stair_ring[3])))
    for zone in LEVELS:
        coverage[zone] = coverage[zone].difference(stair_polygon.buffer(0.10))
        features[zone].append({"id": identifier(f"{zone}:wide-stair-exclusion"), "kind": "stairs",
            "center": ((bottom + top) / 2).tolist(), "size": [width + 0.12, float(np.linalg.norm(top - bottom)) + 0.16],
            "yaw": math.atan2(side[1], side[0]), "bottom": LEVELS[zone], "height": 1.58})
    free = {z: approximate_free(coverage[z], features[z]) for z in LEVELS}
    if args.diagnostics_output:
        write(args.diagnostics_output, {"coverage": {z: coverage[z].__geo_interface__ for z in LEVELS},
            "free": {z: free[z].__geo_interface__ for z in LEVELS}, "features": features,
            "traces": trace_points, "destinations": [dict(p, canonical_camera=transform_point(
                p["camera_position_native_m"], transforms[p["capture_id"]]).tolist())
                for p in measurements["destination_observations"]]})
    landing_records = []

    def location(seed, zone, evidence, maximum_move=1.2):
        chosen = choose_landing(seed, zone, free, trace_points, maximum_move)
        landing_records.append({"zone_id": zone, "seed_xz": list(seed), "position_xz": chosen.tolist(),
                                "movement_m": float(np.linalg.norm(chosen - seed)), "evidence": evidence})
        return {"zoneID": zone, "position": [float(chosen[0]), LEVELS[zone], float(chosen[1])]}

    stairs_from = location(bottom - direction * 1.05, "main", "LiDAR-confirmed lower landing before main stair")
    stairs_to = location(top + direction * 1.05, "raised-l", "LiDAR-confirmed upper landing beyond main stair")
    portal_locations = {}
    for kind, zone, short in [("lower_left", "main", "92ED4CB7"), ("upper_right", "raised-l", "081DA781")]:
        portal = next(p for p in measurements["elevator_portals"]["portals"] if p["kind"] == kind and p["captureID"].startswith(short))
        T = transforms[portal["captureID"]]
        threshold = transform_point(portal["threshold_xyz"], T)[[0, 2]]
        landing = np.array([transform_point(p, T)[[0, 2]] for p in portal["landing_footprint_xyz"]])
        approach = landing.mean(axis=0) - threshold
        approach /= np.linalg.norm(approach)
        portal_locations[zone] = location(threshold + approach * 1.05, zone,
            f"{portal['captureID']} {portal['frame']} measured wide elevator approach", maximum_move=1.0)
    connectors = [
        {"id": "main-to-l-stairs", "name": "Main stairs", "kind": "stairs", "from": stairs_from,
         "to": stairs_to, "bidirectional": True, "availability": "available", "stepFree": False,
         "minimumClearWidthMeters": 1.2, "estimatedSeconds": 12},
        {"id": "main-to-l-elevator", "name": "Elevator", "kind": "elevator", "from": portal_locations["main"],
         "to": portal_locations["raised-l"], "bidirectional": True, "availability": "available", "stepFree": True,
         "minimumClearWidthMeters": 1.0, "estimatedSeconds": 45},
    ]
    ramp_top, ramp_bottom = ramp_vertices[:2].mean(axis=0), ramp_vertices[2:].mean(axis=0)
    ramp_direction = (ramp_top - ramp_bottom) / np.linalg.norm(ramp_top - ramp_bottom)
    ramp_from = location(ramp_bottom - ramp_direction * 0.45, "main", "Video-reviewed continuous food-court ramp lower approach", maximum_move=1.5)
    ramp_to = location(ramp_top + ramp_direction * 0.45, "dining-terrace", "Video-reviewed continuous food-court ramp terrace approach", maximum_move=1.5)
    connectors.append({"id": "main-to-dining-terrace-ramp", "name": "Dining terrace ramp", "kind": "ramp",
        "from": ramp_from, "to": ramp_to, "bidirectional": True, "availability": "available", "stepFree": True,
        "minimumClearWidthMeters": ramp["width_m"], "slopeDegrees": math.degrees(math.atan2(1.1, ramp["run_m"])),
        "estimatedSeconds": float(np.linalg.norm(ramp_top - ramp_bottom)) / 1.15})
    points = {z: [] for z in LEVELS}
    for observation in measurements["destination_observations"]:
        zone = observation["zone_id"]
        seed = transform_point(observation["camera_position_native_m"], transforms[observation["capture_id"]])[[0, 2]]
        target = location(seed, zone, f"{observation['capture_id']} {observation['source_frame']} @{observation['presentation_seconds']}s", maximum_move=1.5)
        points[zone].append({"id": identifier("destination:" + observation["name"]), "kind": "destination",
                             "name": observation["name"], "position": target["position"], "source": "manual",
                             "confidence": 0.9, "requiresAssistance": False})
    zones = []
    area_report = []
    for zone, elevation in LEVELS.items():
        floors = floor_footprints(coverage[zone], elevation)
        retained = unary_union([footprint_shape(f) for f in floors])
        assert retained.difference(depth[zone].buffer(DEPTH_PIXEL_ALLOWANCE).union(trace[zone])).area < 0.005
        assert retained.intersection(stair_polygon).area < 1e-6
        assert retained.intersection(atrium_void).area < 1e-6
        assert retained.intersection(ramp_polygon).area < 1e-6
        zones.append({"id": zone, "name": ZONE_NAMES[zone], "map": {
            "createdAt": "2026-10-11T01:07:00Z", "floorY": elevation,
            "footprints": floors + features[zone], "points": points[zone],
            "requiresMeasuredFloorCoverage": True, "requiresOptimizedLocalization": True}})
        area_report.append({"zone_id": zone, "height_m": elevation, "strict_depth_support_m2": depth[zone].area,
                            "continuous_walk_support_m2": trace[zone].area, "retained_coverage_m2": retained.area,
                            "floor_footprints": len(floors), "other_footprints": len(features[zone]),
                            "floor_vertices_maximum": max(len(f["polygon"]) for f in floors)})
    navigation = {"schemaVersion": 1, "displayFloor": 1, "zones": zones, "connectors": connectors}
    assert sum(len(z["map"]["footprints"]) for z in zones) <= 10000
    write(OUTPUT, navigation)
    write(LAYOUT, {"floor_elevations_m": {"1": 0.0}, "physical_levels_m": {"main": 0.0, "raised_l": 1.58, "dining_terrace": 1.1},
                   "labels": [{"floor": 1, "title": p["name"], "position": p["position"]} for z in zones for p in z["map"]["points"]]})
    report = {"schema_version": 1, "navigation_map_sha256": digest(OUTPUT), "layout_sha256": digest(LAYOUT),
              "registration_sha256": digest(REGISTRATION), "measurements_sha256": digest(MEASUREMENTS),
              "method": "Measured depth height bands, per-frame ground support across reviewed handheld drift and continuous observed walking segments; separate horizontal zones joined only by explicit stairs, elevator and measured-ramp landings",
              "depth_pixel_allowance_m": DEPTH_PIXEL_ALLOWANCE, "walk_trace_radius_m": TRACE_RADIUS,
              "walk_trace_evidence_reach_m": TRACE_EVIDENCE_REACH, "grid_edge_inset_m": GRID_EDGE_INSET,
              "zones": area_report, "landings_and_destinations": landing_records,
              "feature_sources": feature_sources, "continuous_walk_segments": trace_segments,
              "stair_exclusion_polygon_xz": stair_ring.tolist(),
              "ramp_exclusion_polygon_xz": ramp_vertices.tolist(),
              "protected_atrium_void_common_xz": measurements["protected_atrium_void_common_xz"],
              "constraints": ["All elevations belong to displayed Floor 1", "No lower-to-L ramp",
                              "Dining terrace joins main floor only through the video-reviewed measured ramp; lower auditorium seating remains excluded pending measured transitions",
                              "Visual completion and native RoomPlan floor rectangles do not add routing coverage",
                              "Court Salon double-door sets retain their center posts; measured bays use widths after subtracting 0.08m uncertainty, including one eligible 0.81m or 0.816m bay per set under the existing 0.81m doorway policy",
                              "Wide elevator doorway is a conservative 1.0m estimate from repeated measured jambs; the user established the level connection, while exact car identity is inferred"]}
    if args.route_results:
        native = read(args.route_results)
        assert native["navigation_map_sha256"] == digest(OUTPUT)
        assert native["all_routes_pass"]
        assert native["all_named_routes_pass"] and native["surface_safety_pass"]
        native["validator_source_sha256"] = digest(ROOT / "scripts/validate-floor-1-navigation.swift")
        core_sources = sorted((ROOT / "Packages/AccessCore/Sources/AccessCore").glob("*.swift"))
        native["access_core_sources_sha256"] = hashlib.sha256("\n".join(
            f"{p.name}:{digest(p)}" for p in core_sources).encode()).hexdigest()
        report["native_route_validation"] = native
        limitations = read(LIMITATIONS)
        assert limitations["navigation_map_sha256"] == digest(OUTPUT)
        report["coverage_limitations"] = limitations
    write(REPORT, report)
    write(EVIDENCE / "navigation-source-manifest.json", {
        "schema_version": 1, "generator": "scripts/build-floor-1-navigation.py",
        "generator_sha256": digest(Path(__file__)),
        "inputs": [{"path": str(p.relative_to(ROOT)), "sha256": digest(p)}
                   for p in [REGISTRATION, MEASUREMENTS, GROUND_SUPPORT, RECONSTRUCTION, LIMITATIONS,
                             ROOT / "scripts/validate-floor-1-navigation.swift"] + sorted((EVIDENCE / "sources").glob("*.json"))],
        "outputs": [{"path": str(p.relative_to(ROOT)), "sha256": digest(p)} for p in [OUTPUT, LAYOUT, REPORT]],
        "source_policy": "Strict depth support retained separately from visual completion; raw scan metadata and UUIDs preserved in compact sources."})
    print(json.dumps({"navigation": str(OUTPUT), "zones": area_report,
                      "destinations": [p["name"] for z in zones for p in z["map"]["points"]]}, indent=2))


if __name__ == "__main__":
    main()
