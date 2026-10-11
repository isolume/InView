#!/usr/bin/env python3
"""Assemble a clean visual Floor 1 model from registered scan evidence.

The output is a visual reconstruction, not walkable coverage. Registration is
rigid in X/Z; continuous floors are levelled to remove accumulated camera drift.
The raised auditorium lobby and dining terrace retain their physical heights.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
from shapely import affinity, constrained_delaunay_triangles
from shapely.geometry import LineString, Point, Polygon
from shapely.ops import unary_union

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "models/walkthrough-building/floor-1-reconstruction"


def polygons(geometry):
    if geometry.is_empty:
        return []
    if geometry.geom_type == "Polygon":
        return [geometry]
    if geometry.geom_type not in ("MultiPolygon", "GeometryCollection"):
        return []
    return sorted((p for g in geometry.geoms for p in polygons(g)), key=lambda p: p.normalize().wkb)


def filled(geometry):
    # Unseen patches beneath furniture are not architectural holes.
    return unary_union([Polygon(p.exterior) for p in polygons(geometry)])


def clean(geometry, radius=.75, tolerance=.35):
    return filled(geometry.buffer(radius, join_style=2).buffer(-radius, join_style=2)).simplify(tolerance)


def transform_polygon(value, matrix):
    polygon = Polygon(value["outer_xz"], value.get("holes_xz", [])).buffer(0)
    return affinity.affine_transform(polygon, [matrix[0, 0], matrix[0, 2], matrix[2, 0], matrix[2, 2], matrix[0, 3], matrix[2, 3]])


def transform_point(value, matrix):
    return (matrix @ np.r_[value, 1])[:3]


def floor_record(identifier, polygon, height, material="floor", evidence="registered depth and visual completion"):
    if polygon.is_empty or not polygon.is_valid or polygon.area <= 0:
        raise ValueError(f"Invalid floor polygon: {identifier}")
    rings = [polygon.exterior, *polygon.interiors]
    if not all(math.isfinite(value) for ring in rings for point in ring.coords for value in point):
        raise ValueError(f"Nonfinite floor polygon: {identifier}")
    polygon = polygon.normalize()
    # Unconstrained Delaunay plus a centroid test can span a concave edge or a hole.
    # Constrained triangles retain every boundary, including protected atrium voids.
    triangles = [triangle for triangle in constrained_delaunay_triangles(polygon.normalize()).geoms
                 if triangle.area > 1e-10]
    triangles.sort(key=lambda triangle: tuple(sorted(tuple(p) for p in triangle.exterior.coords[:-1])))
    if not triangles or any(not polygon.covers(triangle) for triangle in triangles):
        raise ValueError(f"Floor triangulation leaves its polygon: {identifier}")
    coverage = unary_union(triangles)
    tolerance = max(1e-8, polygon.area * 1e-10)
    if coverage.symmetric_difference(polygon).area > tolerance or abs(sum(t.area for t in triangles) - polygon.area) > tolerance:
        raise ValueError(f"Incomplete or overlapping floor triangulation: {identifier}")
    vertices, faces = [], []
    lookup = {}
    for triangle in triangles:
        face = []
        for x, z in sorted(tuple(p) for p in triangle.exterior.coords[:-1]):
            y = height(x, z) if callable(height) else height
            key = tuple(float(v) for v in (x, y, z))
            if not all(math.isfinite(v) for v in key):
                raise ValueError(f"Nonfinite floor vertex: {identifier}")
            if key not in lookup:
                lookup[key] = len(vertices)
                vertices.append(list(key))
            face.append(lookup[key])
        a, b, c = (np.asarray(vertices[index]) for index in face)
        normal = np.cross(b-a, c-a)
        if abs(normal[1]) <= 1e-12:
            raise ValueError(f"Degenerate floor triangle: {identifier}")
        if normal[1] < 0:
            face[1], face[2] = face[2], face[1]
        faces.append(face)
    return dict(id=identifier, vertices=vertices, triangles=faces, material=material, evidence=evidence,
                area_m2=polygon.area, outline_xz=list(polygon.exterior.coords)[:-1],
                holes_xz=[list(ring.coords)[:-1] for ring in polygon.interiors])


def main():
    registration = json.loads((EVIDENCE / "registration.json").read_text())
    matrices = {x["capture_id"]: np.array(x["matrix_rows"]) for x in registration["scans"]}
    structures = {p.stem: json.loads(p.read_text()) for p in sorted((EVIDENCE / "structure").glob("*.json"))}
    sources = {p.stem: json.loads(p.read_text()) for p in sorted((EVIDENCE / "sources").glob("*.json"))}
    furnishing_evidence = json.loads((EVIDENCE / "furniture-evidence.json").read_text())
    visual_envelopes = json.loads((EVIDENCE / "visual-floor-envelopes.json").read_text())
    for capture in visual_envelopes["captures"]:
        structures[capture["capture_id"]]["height_partition_proposals"] = capture["height_partition_proposals"]
    exclusions = unary_union([Polygon(p["outer_xz"]) for key in
                              ("protected_atrium_void_common_xz", "main_stair_flight_cut_common_xz", "foodcourt_slope_cut_common_xz")
                              for p in visual_envelopes[key]])
    parts, outlines = [], {}
    for capture, data in structures.items():
        matrix = matrices[capture]
        native = unary_union([transform_polygon(p, matrix) for f in data["native_floor_plan_evidence"] for p in f["polygons"]])
        outlines[capture[:4]] = native
        for part in data["height_partition_proposals"]:
            height = part.get("common_frame_proposed_height_y_m", part["proposed_height_y_m"] + matrix[1, 3])
            geom = unary_union([transform_polygon(p, matrix) for p in part["polygons"]])
            # Court Salon is a video-confirmed continuous rectangular room. Its
            # native envelope completes the small gaps around tables and curtains.
            if capture.startswith("D598"):
                geom = native
            else:
                geom = clean(geom)
            parts.append(dict(scan=capture, kind=part["kind"], height=height, geometry=geom))

    auditorium = filled(outlines["785D"])
    # One authoritative envelope prevents double walls from the overlapping
    # auditorium walks. The alternate scan still contributes adjoining lobbies.
    for p in parts:
        if p["scan"].startswith(("785D", "6114")):
            p["geometry"] = p["geometry"].difference(auditorium)

    by_height = {}
    for part in parts:
        h = round(part["height"], 3)
        if part["geometry"].area > .25:
            by_height.setdefault(h, []).append(part["geometry"])
    floors, floor_geometries = [], []
    for h, geoms in sorted(by_height.items()):
        geometry = clean(unary_union(geoms), .4, .22).difference(auditorium).difference(exclusions)
        for i, p in enumerate(polygons(geometry)):
            if p.area < .6:
                continue
            floors.append(floor_record(f"floor-{h:g}-{i}", p, h, "tile" if h > 1 else "floor"))
            floor_geometries.append((p, h))

    transition = json.loads((EVIDENCE / "foodcourt-transition.json").read_text())
    slope_vertices = [transform_point(p, matrices[transition["captureID"]]).tolist() for p in transition["vertices"]]
    for i, p in enumerate(slope_vertices):
        p[1] = transition["canonical_top_y_m"] if i < 2 else transition["canonical_bottom_y_m"]
    floors.append(dict(id=transition["id"], vertices=slope_vertices, triangles=transition["triangles"],
                       material="tile", evidence=transition["evidence"]))

    rake = next(x for x in furnishing_evidence["geometry_annotations"] if x["kind"] == "radial-rake")
    auditorium_matrix = matrices[rake["captureID"]]
    inv_auditorium = np.linalg.inv(auditorium_matrix)
    center = transform_point([rake["center_xz"][0], 0, rake["center_xz"][1]], auditorium_matrix)[[0, 2]]
    def auditorium_height(x, z):
        radius = np.linalg.norm(np.array([x, z])-center)
        return .9 + .68 * max(0, min(1, (radius - 6.55) / 9.5))
    for i, p in enumerate(polygons(auditorium)):
        # Concentric bands follow the two curved seat banks without a single
        # diagonal plane bridging over the front seating area.
        radii = [0, 6.55] + list(np.arange(7, 16, .6)) + [16.05, 80]
        for j, (inner, outer) in enumerate(zip(radii, radii[1:])):
            band = Point(center).buffer(outer, quad_segs=48)
            if inner:
                band = band.difference(Point(center).buffer(inner, quad_segs=48))
            for k, piece in enumerate(polygons(p.intersection(band))):
                floors.append(floor_record(f"auditorium-rake-{i}-{j}-{k}", piece, auditorium_height, "carpet", "native RoomPlan envelope; video-confirmed radial rake"))
    for annotation in furnishing_evidence["geometry_annotations"]:
        if annotation["kind"] != "stage-polygon":
            continue
        stage = transform_polygon({"outer_xz":annotation["outline_xz"]}, matrices[annotation["captureID"]]).intersection(auditorium)
        for i, polygon in enumerate(polygons(stage)):
            record = floor_record(f"auditorium-curved-stage-{i}", polygon, annotation["canonical_top_y_m"], "wood", annotation["evidence"])
            record["thickness"] = .68
            floors.append(record)

    def floor_y(x, z, raw):
        point = Point(x, z)
        if auditorium.covers(point):
            return auditorium_height(x, z)
        matches = [h for geom, h in floor_geometries if geom.buffer(.5).covers(point)]
        return min(matches, key=lambda h: abs(h-raw)) if matches else min((0, 1.1, 1.58), key=lambda h: abs(h-raw))

    walls, candidates, openings = [], [], []
    for capture, data in structures.items():
        matrix = matrices[capture]
        for surface in data["native_surfaces_supported_by_visual_floor"]:
            ends = [transform_point([p[0], surface["bottom_y_m"], p[1]], matrix) for p in surface["ends_xz"]]
            a, b = ends
            line = LineString([a[[0, 2]], b[[0, 2]]])
            if surface["kind"] in ("door", "opening"):
                openings.append(line)
                continue
            if surface["kind"] not in ("wall", "window"):
                continue
            if capture.startswith("D598"):
                # This is one open hall. Fragmented native interior planes come
                # from curtains, tables and stage fronts, not room partitions.
                continue
            if capture.startswith("6114") and auditorium.buffer(.6).covers(line.interpolate(.5, normalized=True)):
                continue
            h = floor_y(*((a+b)/2)[[0, 2]], min(a[1], b[1]))
            a[1] = b[1] = h
            candidates.append(dict(id=surface["source_id"], a=a.tolist(), b=b.tolist(),
                                   height=1.15, kind="glass" if surface["kind"] == "window" else "wall",
                                   evidence=f"{capture}: native {surface['kind']}", line=line))
    court_edges = []
    for index, polygon in enumerate(polygons(outlines["D598"])):
        vertices = list(polygon.exterior.coords)
        for edge, (a, b) in enumerate(zip(vertices, vertices[1:])):
            court_edges.append(LineString([a, b]))
            candidates.append(dict(id=f"court-salon-envelope-{index}-{edge}",
                                   a=[a[0], 0, a[1]], b=[b[0], 0, b[1]], height=1.15, kind="wall",
                                   evidence="D598 native floor perimeter; continuous hall enclosure confirmed by video",
                                   line=LineString([a, b])))
    court_portals = json.loads((EVIDENCE / "court-door-portals.json").read_text())["openings"]
    court_cuts, court_posts = [], []
    for portal in court_portals:
        midpoint = Point(np.mean(np.asarray(portal["jambs_canonical_xyz"])[:, [0, 2]], axis=0))
        edge = min(court_edges, key=lambda item: item.distance(midpoint))
        def project(value):
            return list(edge.interpolate(edge.project(Point(value[0], value[2]))).coords[0])
        court_cuts.append(LineString([project(p) for p in portal["jambs_canonical_xyz"]]))
        ends = [project(p) for p in portal["post_edges_canonical_xyz"]]
        court_posts.append(dict(id=portal["id"]+"-center-mullion", kind="wall", material="metal",
                                a=[ends[0][0], 0, ends[0][1]], b=[ends[1][0], 0, ends[1][1]],
                                height=1.15, thickness=.10, evidence=portal["visual_verification"]))
    # Preserve the best source once at overlapping joins, retaining short returns.
    for record in sorted(candidates, key=lambda x: x["line"].length, reverse=True):
        line = record.pop("line")
        for previous in walls:
            if abs(previous["a"][1]-record["a"][1]) > .3:
                continue
            old = LineString([[previous["a"][0], previous["a"][2]], [previous["b"][0], previous["b"][2]]])
            if old.buffer(.25, cap_style=2).intersection(line).length > line.length*.75:
                line = LineString()
                break
        if line.is_empty:
            continue
        # Cut supported portals out of the wall, including merged RoomPlan walls.
        direction = np.subtract(line.coords[-1], line.coords[0]); direction /= np.linalg.norm(direction)
        for opening in openings:
            if line.distance(opening) < .3:
                od = np.subtract(opening.coords[-1], opening.coords[0]); od /= np.linalg.norm(od)
                if abs(np.dot(direction, od)) > .9:
                    line = line.difference(opening.buffer(.13, cap_style=3))
        if record["id"].startswith("court-salon-envelope-"):
            for opening in court_cuts:
                line = line.difference(opening.buffer(.005, cap_style=2))
        segments = [line] if line.geom_type == "LineString" else list(line.geoms)
        for n, segment in enumerate(segments):
            if segment.length < .2:
                continue
            item = dict(record, id=record["id"]+f"-{n}")
            item["a"] = [segment.coords[0][0], record["a"][1], segment.coords[0][1]]
            item["b"] = [segment.coords[-1][0], record["b"][1], segment.coords[-1][1]]
            walls.append(item)
    walls.extend(court_posts)

    stairs = [dict(id="main-auditorium-steps", bottom=[1.307, 0, -2.216], top=[2.317, 1.58, -5.315],
                   width=6.8, risers=11, center_rail=True,
                   evidence="081DA781 synchronized video and confident depth; full flight jambs and center rail")]
    for rail in furnishing_evidence["walls_native"]:
        matrix = matrices[rail["captureID"]]
        a, b = transform_point(rail["a"], matrix), transform_point(rail["b"], matrix)
        a[1] = b[1] = 0
        walls.append(dict(rail, a=a.tolist(), b=b.tolist()))
    for rail in visual_envelopes["atrium_railings_common_xz"]:
        walls.append(dict(id=rail["id"], a=[rail["a_xz"][0], 0, rail["a_xz"][1]],
                          b=[rail["b_xz"][0], 0, rail["b_xz"][1]], kind="rail", height=rail["height_m"],
                          evidence=rail["evidence"]))
    for a, b in ((0, 3), (1, 2)):
        walls.append(dict(id=f"foodcourt-slope-handrail-{a}", a=slope_vertices[a], b=slope_vertices[b],
                          kind="rail", height=.95, evidence=transition["evidence"]))
    furniture = []
    for obj in furnishing_evidence["furnishings_native"]:
        if obj.get("render") is False:
            continue
        matrix = matrices[obj["captureID"]]
        position = transform_point(obj["position"], matrix)
        if obj.get("requires_clip_to_auditorium_and_aisles") and not auditorium.buffer(-.35).covers(Point(position[[0, 2]])):
            continue
        if obj["kind"] == "auditorium-seat":
            position[1] = auditorium_height(position[0], position[2])
        else:
            position[1] = floor_y(position[0], position[2], position[1])
        dimensions = list(obj["dimensions"])
        if obj.get("clip_height_to_cutaway_wall"):
            position[1] += .35
            dimensions[1] = min(dimensions[1], .78)
        yaw = obj["yaw_degrees"] + math.degrees(math.atan2(matrix[2, 0], matrix[0, 0]))
        furniture.append(dict(obj, position=position.tolist(), dimensions=dimensions, yaw_degrees=yaw))
    portals = json.loads((EVIDENCE / "elevator-portals.json").read_text())["portals"]
    seen_portals = set()
    for portal in portals:
        if portal["kind"] in seen_portals:
            continue
        seen_portals.add(portal["kind"])
        matrix = matrices[portal["captureID"]]
        position = transform_point(portal["threshold_xyz"], matrix)
        position[1] = 0 if portal["kind"].startswith("lower") else 1.58
        a, b = [transform_point(p, matrix) for p in portal["threshold_endpoints_xyz"]]
        yaw = math.degrees(math.atan2(b[2]-a[2], b[0]-a[0]))
        furniture.append(dict(id="elevator-"+portal["kind"], position=position.tolist(),
                              dimensions=[portal["estimated_opening_width_m"], 2.12, .09], yaw_degrees=yaw,
                              kind="elevator", material="accent", evidence=portal["visual_verification"]))
    spec = dict(schema_version=1, display_floor=1, coordinate_frame="meters, Y up",
                floor_policy="One displayed Floor 1; physical heights preserved. Visual completion never creates route coverage.",
                floors=floors, walls=walls, stairs=stairs, furniture=furniture)
    (EVIDENCE / "reconstruction.json").write_text(json.dumps(spec, indent=2, allow_nan=False)+"\n")
    print(json.dumps({k:len(spec[k]) for k in ("floors", "walls", "stairs", "furniture")}))


if __name__ == "__main__":
    main()
