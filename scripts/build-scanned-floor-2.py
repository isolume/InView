#!/usr/bin/env python3
"""Replace the Floor 2 illustration with the registered scans; preserve Floor 3.

Blender 4.5 --background --factory-startup --python-exit-code 1
  --python scripts/build-scanned-floor-2.py -- --samples 24

The original video reconstruction is read from floors-2-3-video.zip. The native
new floor envelope is presentation-only and never changes routing coverage.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sys
import tempfile
import zipfile

import bpy
import bmesh
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "models/walkthrough-building/floors-2-3"
EVIDENCE = ROOT / "models/walkthrough-building/floor-2-evidence"
SCAN_ID = "E3CF408C-680C-4ECF-B9EB-F09117308BD3"
SOURCE = EVIDENCE / SCAN_ID
ARCHIVE = ROOT / "models/walkthrough-building/floors-2-3-video.zip"
spec = importlib.util.spec_from_file_location("floors", ROOT / "scripts/build-walkthrough-floors.py")
F = importlib.util.module_from_spec(spec)
spec.loader.exec_module(F)
B = F.B


def read(path): return json.loads(path.read_text())
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def registration(venue):
    """Use the app's existing common asset frame; do not move its elevator pins."""
    ids = ("0252CB01-29DC-4136-8A98-AB2076782D1E", "457D4F40-982C-48BA-854F-F35DCF158A80")
    destinations = [next(p["position"] for p in venue["points"] if p["id"] == uid) for uid in ids]
    a, b = destinations
    angle = math.atan2(b[2] - a[2], b[0] - a[0])
    scale = math.hypot(b[0] - a[0], b[2] - a[2]) / 2.37
    c, s = math.cos(angle), math.sin(angle)
    translation = (a[0] - scale * (c * -1.30 - s * 8.82), a[2] - scale * (s * -1.30 + c * 8.82))
    assert 0.5 <= scale <= 2

    def point(x, z):
        dx, dz = x - translation[0], z - translation[1]
        return ((c * dx + s * dz) / scale, (s * dx - c * dz) / scale)

    return point, scale, angle


def stamp(start, source_id, routing=False):
    for obj in B.MODEL[start:]:
        obj["floor"] = 2
        obj["zone"] = "Scanned Floor 2"
        obj["source_id"] = source_id
        obj["estimated_from_video"] = False
        obj["routing_coverage"] = routing
        for collection in list(obj.users_collection): collection.objects.unlink(obj)
        F.COLLECTIONS[2].objects.link(obj)


def polygon_floor(footprint, index, point, scale, routing):
    outline = footprint["polygon"]
    vertices = [point(*p) for p in outline]
    area = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(vertices, vertices[1:] + vertices[:1]))
    if area < 0: vertices.reverse()
    assert abs(area) > 1e-6
    mesh = bpy.data.meshes.new(f"Floor 2 floor {index}")
    # Original floor regions overlap. Millimeter presentation offsets keep their
    # tops distinct without a destructive mesh union or changes to map polygons.
    elevation = index * 0.001 / scale if routing else 0
    mesh.from_pydata([(x, y, elevation) for x, y in vertices], [], [list(range(len(vertices)))])
    mesh.update()
    edit = bmesh.new(); edit.from_mesh(mesh)
    bmesh.ops.triangulate(edit, faces=list(edit.faces))
    bad = [face for face in edit.faces if face.calc_area() < 1e-10]
    if bad: bmesh.ops.delete(edit, geom=bad, context="FACES_ONLY")
    edit.to_mesh(mesh); edit.free()
    mesh.materials.append(B.material("floor"))
    obj = bpy.data.objects.new(f"Floor 2 · floor {index}", mesh)
    bpy.context.scene.collection.objects.link(obj)
    solid = obj.modifiers.new("Floor base", "SOLIDIFY")
    solid.thickness = 0.15 / scale
    solid.offset = -1
    start = len(B.MODEL); B.MODEL.append(obj)
    stamp(start, f"floor-{index}", routing)


def wall_segments(wall, openings):
    """Cut only measured, collinear openings out of the display wall."""
    x, z = wall["center"]; c, s = math.cos(wall["yaw"]), math.sin(wall["yaw"])
    half = wall["size"][0] / 2
    cuts = []
    for door in openings:
        if abs(math.cos(door["yaw"] - wall["yaw"])) < 0.985: continue
        dx, dz = door["center"][0] - x, door["center"][1] - z
        if abs(-s * dx + c * dz) > 0.18: continue
        along = c * dx + s * dz; width = door["size"][0]
        lo, hi = max(-half, along - width / 2), min(half, along + width / 2)
        if hi > lo: cuts.append((lo, hi))
    intervals = []; cursor = -half
    for lo, hi in sorted(cuts):
        if lo > cursor + 0.03: intervals.append((cursor, lo))
        cursor = max(cursor, hi)
    if half > cursor + 0.03: intervals.append((cursor, half))
    return [((x + c * lo, z + s * lo), (x + c * hi, z + s * hi)) for lo, hi in intervals]


def structure(venue, point, scale):
    openings = [f for f in venue["footprints"] if f["kind"] in ("door", "opening")]
    for index, footprint in enumerate(venue["footprints"]):
        kind = footprint["kind"]
        if kind not in ("wall", "door", "opening"): continue
        start = len(B.MODEL)
        if kind == "wall":
            for a, b in wall_segments(footprint, openings):
                B.wall("Floor 2 · wall", point(*a), point(*b), min(1.08, footprint.get("height", 2.4)) / scale,
                       thickness=footprint["size"][1] / scale)
        else:
            x, z = footprint["center"]; c, s = math.cos(footprint["yaw"]), math.sin(footprint["yaw"])
            width = footprint["size"][0]
            a, b = point(x - c * width / 2, z - s * width / 2), point(x + c * width / 2, z + s * width / 2)
            for px, py in (a, b): B.box("Floor 2 · door jamb", (px, py, 0.56 / scale), (0.065 / scale, 0.065 / scale, 1.12 / scale), "cap", 0.008)
            if kind == "door":
                # Elevator doors retain two leaves; their measured opening fixes placement.
                elevator = any(math.hypot(p["position"][0] - x, p["position"][2] - z) < 0.85 for p in venue["points"] if p["kind"] == "elevator")
                count = 2 if elevator else 1
                for leaf in range(count):
                    t = (leaf + 0.5) / count
                    px, py = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
                    obj = B.box("Floor 2 · lift door" if elevator else "Floor 2 · door", (px, py, 0.50 / scale),
                                ((width / count - 0.025) / scale, 0.05 / scale, 1.00 / scale), "door", 0.012)
                    obj.rotation_euler.z = math.atan2(b[1] - a[1], b[0] - a[0])
        stamp(start, footprint.get("id", f"{kind}-{index}"))


def furnishings(venue, point, scale, angle):
    for index, footprint in enumerate(venue["footprints"]):
        if footprint["kind"] != "obstacle": continue
        x, y = point(*footprint["center"])
        width, depth = [v / scale for v in footprint["size"]]
        height = footprint.get("height", 0.8) / scale
        yaw = -(footprint["yaw"] - angle)
        start = len(B.MODEL)
        key = "modular-sofa" if footprint.get("furniture") == "sofa" and footprint["size"][0] > 1.3 else "lounge-chair"
        if footprint.get("furniture") == "table":
            if abs(width - depth) / max(width, depth) < 0.28:
                key = "large-drum-table"
            else:
                top = B.box("Floor 2 · measured table", (x, y, height - 0.025 / scale), (width, depth, 0.05 / scale), "wood", 0.016)
                top.rotation_euler.z = yaw
                for dx in (-width / 2 + 0.05, width / 2 - 0.05):
                    for dy in (-depth / 2 + 0.05, depth / 2 - 0.05):
                        px, py = x + math.cos(yaw) * dx - math.sin(yaw) * dy, y + math.sin(yaw) * dx + math.cos(yaw) * dy
                        B.box("Floor 2 · table leg", (px, py, height / 2), (0.04 / scale, 0.04 / scale, height), "metal", 0.008)
                stamp(start, f"obstacle-{index}")
                continue
        B.furniture(key, x, y, math.degrees(yaw))
        dimensions = B.CAT[key]["dimensions_m"]
        for obj in B.MODEL[start:]: obj.scale = (width / dimensions[0], depth / dimensions[2], height / dimensions[1])
        B.FURNITURE[-1].update({"floor": 2, "zone": "Scanned lounge", "source_id": f"obstacle-{index}", "measured_dimensions_m": [footprint["size"][0], footprint.get("height", 0.8), footprint["size"][1]]})
        stamp(start, f"obstacle-{index}")


def labels(venue, point, scale):
    def add(title, x, z):
        px, py = point(x, z)
        F.POIS.append({"floor": 2, "title": title, "position": [px, 0.6 / scale, -py]})
    lounge = [f["center"] for f in venue["footprints"] if f.get("furniture") in ("sofa", "table")]
    add("Lounge", *(sum(p[i] for p in lounge) / len(lounge) for i in (0, 1)))
    lifts = [p["position"] for p in venue["points"] if p["kind"] == "elevator"]
    add("Lifts", *(sum(p[i] for p in lifts) / len(lifts) for i in (0, 2)))
    raw = read(SOURCE / "raw-snapshot.json")["walkTrace"]["samples"]
    transform = read(EVIDENCE / "registration.json")
    theta = transform["horizontal_rotation_radians"]; c, s = math.cos(theta), math.sin(theta)
    tx, tz = transform["translation_xz_m"]
    def center(samples):
        positions = [(c * p["cameraPosition"][0] - s * p["cameraPosition"][2] + tx,
                      s * p["cameraPosition"][0] + c * p["cameraPosition"][2] + tz) for p in samples]
        return [sum(p[i] for p in positions) / len(positions) for i in (0, 1)]
    add("Balcony", *center(raw[:len(raw) // 3]))
    add("Restroom passage", *center(raw[-20:]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=24)
    parser.add_argument("--skip-render", action="store_true")
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    venue = read(EVIDENCE / "merged-floor-2.json")
    display_floors = read(OUT / "illustration-floors.json")
    point, scale, angle = registration(venue)
    with zipfile.ZipFile(ARCHIVE) as archive, tempfile.TemporaryDirectory(prefix="inview-video-model-") as directory:
        F.restore_floor_exports(archive, (3,))
        baseline = json.loads(archive.read("floors-2-3/layout.json"))
        source = Path(directory) / "building.blend"
        source.write_bytes(archive.read("floors-2-3/building.blend"))
        bpy.ops.wm.open_mainfile(filepath=str(source))
    for obj in list(bpy.data.objects):
        if obj.get("floor") != 3: bpy.data.objects.remove(obj, do_unlink=True)
    B.MODEL[:] = [obj for obj in bpy.data.objects if obj.get("floor") == 3]
    for obj in B.MODEL: obj.hide_render = False
    F.COLLECTIONS[3] = bpy.data.collections["Floor 3"]
    F.COLLECTIONS[2] = bpy.data.collections.get("Floor 2") or bpy.data.collections.new("Floor 2")
    if F.COLLECTIONS[2].name not in bpy.context.scene.collection.children: bpy.context.scene.collection.children.link(F.COLLECTIONS[2])
    B.CAT = {model["id"]: model for model in read(B.CATALOG)["models"]}
    B.FURNITURE[:] = [f for f in baseline["furniture"] if f["floor"] == 3]
    F.POIS[:] = [p for p in baseline["labels"] if p["floor"] == 3]
    for index, footprint in enumerate(display_floors): polygon_floor(footprint, index, point, scale, index < 12)
    structure(venue, point, scale)
    furnishings(venue, point, scale, angle)
    labels(venue, point, scale)
    provenance = {"scan_id": SCAN_ID, "map_sha256": digest(EVIDENCE / "merged-floor-2.json"),
                  "display_floors_sha256": digest(OUT / "illustration-floors.json"), "source": "registered supplied scans",
                  "routing_floor_polygons": 12, "new_floor_envelope": "native RoomPlan only, display-only, not reviewed routing coverage",
                  "registration": "rigid fit from shared balcony corner; source coordinates preserved in evidence archive",
                  "asset_frame": "inverse of existing app elevator registration; Floor 3 retained from video archive"}
    bpy.context.preferences.filepaths.save_version = 0
    F.exports(floors=(2,), floor_2_source=provenance)
    if not args.skip_render: F.renders(args.samples, floors=(2,))


if __name__ == "__main__": main()
