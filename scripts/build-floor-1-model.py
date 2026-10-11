#!/usr/bin/env python3
"""Export the registered Floor 1 cutaway as one model, including its raised areas.

Blender --background --factory-startup --python-exit-code 1
  --python scripts/build-floor-1-model.py -- --samples 24

Input uses metric Y-up coordinates. Visual floor completion and route coverage
are separate evidence; this exporter never creates walkable connections.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sys

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "models/walkthrough-building/floor-1-reconstruction"
OUT = ROOT / "models/walkthrough-building/floor-1"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


B = module("floor_1_primitives", ROOT / "scripts/build-walkthrough-building.py")


def direct_box(name, center, size, color="wall", bevel=.025):
    # Direct mesh creation avoids thousands of operator-driven scene updates
    # while preserving the same rounded box primitive used by the other floors.
    sx, sy, sz = (v/2 for v in size)
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([(-sx,-sy,-sz),(sx,-sy,-sz),(sx,sy,-sz),(-sx,sy,-sz),
                      (-sx,-sy,sz),(sx,-sy,sz),(sx,sy,sz),(-sx,sy,sz)], [],
                     [(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)])
    mesh.materials.append(B.material(color))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = center
    if bevel:
        mod = obj.modifiers.new("Soft edges", "BEVEL")
        mod.width = min(bevel, min(size)*.24)
        mod.segments = 2
        mod = obj.modifiers.new("Weighted corner normals", "WEIGHTED_NORMAL")
        mod.keep_sharp = True
    B.MODEL.append(obj)
    return obj


def direct_beam(name, a, b, radius=.025, color="rail"):
    direction = Vector(b)-Vector(a)
    count = 10
    verts = [(radius*math.cos(i*2*math.pi/count), radius*math.sin(i*2*math.pi/count), z)
             for z in (-direction.length/2, direction.length/2) for i in range(count)]
    faces = [tuple(reversed(range(count))), tuple(range(count, 2*count))]
    faces += [(i,(i+1)%count,(i+1)%count+count,i+count) for i in range(count)]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.materials.append(B.material(color))
    for face in mesh.polygons:
        face.use_smooth = True
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = (Vector(a)+Vector(b))/2
    obj.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()
    B.MODEL.append(obj)
    return obj


B.box = direct_box
B.beam = direct_beam


def point(value):
    return Vector((value[0], -value[2], value[1]))


def stamp(start, record):
    for obj in B.MODEL[start:]:
        obj["floor"] = 1
        obj["source_id"] = record["id"]
        obj["zone"] = record.get("zone", "Floor 1")
        obj["evidence"] = record.get("evidence", "registered scan")


def floor(record):
    # Blender stores mesh positions as Float32. Boundary vertices that are distinct
    # in the reconstruction's Double coordinates can become identical on import;
    # merge at that actual precision before Solidify creates sides from zero edges.
    vertices, remap, lookup = [], [], {}
    for value in record["vertices"]:
        vertex = point(value)
        key = tuple(vertex)
        if not all(math.isfinite(component) for component in key):
            raise ValueError("Nonfinite floor vertex: " + record["id"])
        if key not in lookup:
            lookup[key] = len(vertices)
            vertices.append(vertex)
        remap.append(lookup[key])
    faces, seen = [], set()
    for triangle in record["triangles"]:
        if len(triangle) != 3 or any(type(index) is not int or not 0 <= index < len(remap) for index in triangle):
            raise ValueError("Invalid floor triangle: " + record["id"])
        face = [remap[index] for index in triangle]
        identity = tuple(sorted(face))
        if len(set(face)) < 3 or identity in seen:
            continue
        a, b, c = (vertices[index] for index in face)
        normal = (b-a).cross(c-a)
        if abs(normal.z) <= 1e-12:
            continue
        if normal.z < 0:
            face[1], face[2] = face[2], face[1]
        faces.append(face)
        seen.add(identity)
    if not faces:
        raise ValueError("Floor has no usable triangles: " + record["id"])
    mesh = bpy.data.meshes.new(record["id"])
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    mesh.materials.append(B.material(record.get("material", "floor")))
    obj = bpy.data.objects.new("Floor 1 · " + record["id"], mesh)
    bpy.context.scene.collection.objects.link(obj)
    solid = obj.modifiers.new("Floor thickness", "SOLIDIFY")
    solid.thickness = record.get("thickness", .18)
    solid.offset = -1
    start = len(B.MODEL)
    B.MODEL.append(obj)
    stamp(start, record)
    obj["collapsed_triangles_removed"] = len(record["triangles"]) - len(faces)


def wall(record):
    start = len(B.MODEL)
    a, b = point(record["a"]), point(record["b"])
    name = "Floor 1 · " + record["id"]
    height = record.get("height", 1.15)
    kind = record.get("kind", "wall")
    if kind == "rail":
        count = max(1, math.ceil((b-a).length / 1.5))
        for i in range(count + 1):
            p = a.lerp(b, i/count)
            B.beam(name + " · post", p, p + Vector((0, 0, height)), .025, "rail")
        for h in (.2, .4, .6, .8, height):
            B.beam(name + " · rail", a + Vector((0, 0, h)), b + Vector((0, 0, h)),
                   .035 if h == height else .012, "rail")
    elif kind == "glass":
        count = max(1, math.ceil((b-a).length / 1.45))
        yaw = math.atan2(b.y-a.y, b.x-a.x)
        for i in range(count):
            p = a.lerp(b, (i+.5)/count)
            obj = B.box(name + " · pane", p + Vector((0, 0, height/2)),
                        ((b-a).length/count-.05, .035, height), "glass", .004)
            obj.rotation_euler.z = yaw
        for i in range(count+1):
            p = a.lerp(b, i/count)
            B.beam(name + " · mullion", p, p + Vector((0, 0, height)), .022, "metal")
    else:
        B.wall(name, a[:2], b[:2], height=height, base=(a.z+b.z)/2,
               thickness=record.get("thickness", .16), color=record.get("material", "wall"))
    stamp(start, record)


def furnishing(record):
    start = len(B.MODEL)
    origin = point(record["position"])
    yaw = -math.radians(record.get("yaw_degrees", 0))
    width, height, depth = record["dimensions"]
    name = "Floor 1 · " + record["id"]
    material = record.get("material", "seat")

    def at(x, y, z):
        return origin + Vector((x*math.cos(yaw)-y*math.sin(yaw),
                                x*math.sin(yaw)+y*math.cos(yaw), z))

    def box(suffix, center, size, color=material, bevel=.025):
        obj = B.box(name + " · " + suffix, at(*center), size, color, bevel)
        obj.rotation_euler.z = yaw
        return obj

    kind = record["kind"]
    if kind in ("auditorium-seat", "chair", "lounge-chair", "sofa", "bench"):
        seat = min(.46, height*.55)
        box("base", (0, 0, seat*.42), (width*.86, depth*.75, seat*.82), "dark", .04)
        box("seat", (0, 0, seat), (width, depth*.84, .13), material, .06)
        if kind != "bench":
            box("back", (0, depth*.34, (height+seat)/2), (width, depth*.19, height-seat), material, .05)
            if kind in ("auditorium-seat", "lounge-chair", "sofa"):
                for x in (-width*.45, width*.45):
                    box("arm", (x, 0, seat+.13), (width*.10, depth*.72, .16), material, .035)
    elif kind in ("table", "round-table"):
        if kind == "round-table":
            B.beam(name + " · top", at(0, 0, height-.055), at(0, 0, height), width/2, "wood")
            B.beam(name + " · stem", at(0, 0, .03), at(0, 0, height-.055), .055, "metal")
            B.beam(name + " · foot", at(0, 0, .015), at(0, 0, .045), width*.25, "metal")
        else:
            box("top", (0, 0, height-.03), (width, depth, .06), record.get("material", "wood"), .025)
            for x in (-width*.4, width*.4):
                box("legs", (x, 0, (height-.06)/2), (.045, depth*.65, height-.06), "metal", .008)
    elif kind == "column":
        B.beam(name, origin, origin+Vector((0, 0, height)), width/2, material)
        B.beam(name + " · base", origin, origin+Vector((0, 0, .40)), width/2+.007, "accent")
    elif kind == "planter":
        box("pot", (0, 0, height*.23), (width*.74, depth*.74, height*.46), "tile", .08)
        B.beam(name + " · leaves", at(0, 0, height*.36), at(0, 0, height), width*.39, "leaf")
    elif kind in ("cabinet", "counter", "stage", "door", "elevator", "acoustic-panel"):
        color = record.get("material", {"door":"door", "elevator":"door", "stage":"wood",
                                       "counter":"tile", "acoustic-panel":"dark"}.get(kind, "dark"))
        box("body", (0, 0, height/2), (width, depth, height), color, .012 if kind == "door" else .035)
        if kind == "elevator":
            box("door seam", (0, -depth/2-.004, height*.48), (.018, .008, height*.93), "metal", 0)
            box("header", (0, -depth/2-.018, height*.96), (width*.28, .025, .08), "accent", .008)
    else:
        raise ValueError("Unknown furnishing: " + kind)
    stamp(start, record)


def stairs(record):
    start = len(B.MODEL)
    a, b = point(record["bottom"]), point(record["top"])
    length = math.hypot(b.x-a.x, b.y-a.y)
    count, width = record["risers"], record["width"]
    yaw = math.atan2(b.y-a.y, b.x-a.x)
    across = Vector((-math.sin(yaw), math.cos(yaw), 0))
    for i in range(count):
        p = a.lerp(b, (i+.5)/count)
        top = a.z + (b.z-a.z)*(i+1)/count
        obj = B.box(record["id"] + f" · step {i+1}", (p.x, p.y, (top+a.z)/2-.04),
                    (length/count+.006, width, top-a.z+.08), "tile", .008)
        obj.rotation_euler.z = yaw
    rail_offsets = [-width/2, width/2]
    if record.get("center_rail"):
        rail_offsets.append(0)
    for offset in rail_offsets:
        for t in (0, .33, .66, 1):
            p = a.lerp(b, t)+across*offset
            B.beam(record["id"] + " · post", p, p+Vector((0, 0, .9)), .026, "rail")
        B.beam(record["id"] + " · handrail", a+across*offset+Vector((0, 0, .9)),
               b+across*offset+Vector((0, 0, .9)), .035, "rail")
    stamp(start, record)


def aim(obj, target):
    obj.rotation_euler = (Vector(target)-obj.location).to_track_quat("-Z", "Y").to_euler()


def frame(camera, width, height, direction):
    corners = [obj.matrix_world @ Vector(v) for obj in B.MODEL for v in obj.bound_box]
    low = Vector([min(p[i] for p in corners) for i in range(3)])
    high = Vector([max(p[i] for p in corners) for i in range(3)])
    center = (low+high)/2
    camera.location = center+Vector(direction).normalized()*180
    aim(camera, center)
    right = camera.rotation_euler.to_quaternion() @ Vector((1, 0, 0))
    up = camera.rotation_euler.to_quaternion() @ Vector((0, 1, 0))
    xs = [(p-center).dot(right) for p in corners]
    ys = [(p-center).dot(up) for p in corners]
    camera.location += right*(max(xs)+min(xs))/2 + up*(max(ys)+min(ys))/2
    camera.data.ortho_scale = max(max(xs)-min(xs), (max(ys)-min(ys))*width/height)*1.1
    return low, high


def export(source, samples, skip_render):
    bpy.context.view_layer.update()
    graph = bpy.context.evaluated_depsgraph_get()
    for obj in B.MODEL:
        if obj.modifiers:
            evaluated = obj.evaluated_get(graph)
            mesh = bpy.data.meshes.new_from_object(evaluated, depsgraph=graph)
            obj.modifiers.clear()
            obj.data = mesh
    bpy.ops.object.select_all(action="DESELECT")
    for obj in B.MODEL:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = B.MODEL[0]
    bpy.ops.export_scene.gltf(filepath=str(OUT / "floor-1.glb"), export_format="GLB", use_selection=True,
                             export_yup=True, export_cameras=False, export_lights=False, export_extras=True)
    bpy.ops.wm.usd_export(filepath=str(OUT / "floor-1.usdz"), check_existing=False,
                         selected_objects_only=True, export_animation=False, export_normals=True,
                         export_materials=True, generate_preview_surface=True, export_textures=False,
                         export_lights=False, export_cameras=False, export_hair=False, export_uvmaps=False,
                         export_mesh_colors=False, export_armatures=False, export_shapekeys=False,
                         export_curves=False, export_points=False, export_volumes=False,
                         convert_world_material=False, convert_orientation=True,
                         export_global_forward_selection="NEGATIVE_Z", export_global_up_selection="Y",
                         convert_scene_units="METERS", root_prim_path="/Floor1", export_custom_properties=False)
    checker = module("floor1_usd_check", ROOT / "scripts/render-photo-furniture.py")
    receipt = checker.validate_usdz(OUT / "floor-1.usdz", len(B.MODEL))
    receipt["specification_sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
    (OUT / "validation.json").write_text(json.dumps(receipt, indent=2)+"\n")
    bpy.context.preferences.filepaths.save_version = 0
    if skip_render:
        bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "floor-1.blend"))
        return
    scene = bpy.context.scene
    world = bpy.data.worlds.new("Daylight")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (.86, .87, .88, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = .65
    scene.world = world
    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.data.type = "ORTHO"
    scene.camera = camera
    low, high = frame(camera, 2200, 1600, (.65, .85, 1.1))
    center = (low+high)/2
    for name, offset, power, size in [("Wide daylight", (-25,-15,55), 18000, 45),
                                      ("Soft fill", (30,25,40), 9500, 40)]:
        light = bpy.data.lights.new(name, "AREA")
        light.energy, light.shape, light.size = power, "DISK", size
        obj = bpy.data.objects.new(name, light)
        scene.collection.objects.link(obj)
        obj.location = center+Vector(offset)
        aim(obj, center)
    ground = B.box("Studio ground", (center.x, center.y, low.z-.20), (300, 300, .1), "#e9ede7", 0)
    B.MODEL.remove(ground)
    scene.render.engine = "CYCLES"
    scene.cycles.device, scene.cycles.samples = "CPU", samples
    scene.cycles.use_denoising, scene.cycles.max_bounces = True, 4
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.view_settings.view_transform, scene.view_settings.look = "Standard", "None"
    scene.render.resolution_percentage = 100
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "floor-1.blend"))
    for name, direction in [("floor-1", (.65,.85,1.1)), ("floor-1-plan", (0,.001,1))]:
        scene.render.resolution_x, scene.render.resolution_y = 2200, 1600
        frame(camera, 2200, 1600, direction)
        scene.render.filepath = str(OUT / (name+".png"))
        bpy.ops.render.render(write_still=True)


def main():
    global OUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", type=Path, default=EVIDENCE / "reconstruction.json")
    parser.add_argument("--output", type=Path, default=OUT)
    parser.add_argument("--samples", type=int, default=24)
    parser.add_argument("--skip-render", action="store_true")
    args = parser.parse_args(sys.argv[sys.argv.index("--")+1:] if "--" in sys.argv else [])
    OUT = args.output
    source = json.loads(args.spec.read_text())
    assert source["display_floor"] == 1
    OUT.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.scale_length = 1
    B.PALETTE.update({"wall":"#e5e4de", "cap":"#f4f2ed", "floor":"#c2c1b5", "carpet":"#aab5be",
                      "seat":"#72879d", "wood":"#cab894", "rail":"#71879b", "metal":"#a6afad",
                      "dark":"#697781", "door":"#9daab4", "glass":"#c4d6d5", "accent":"#6687ae",
                      "tile":"#e4e0d3", "leaf":"#a2b198"})
    for item in source["floors"]: floor(item)
    for item in source["walls"]: wall(item)
    for item in source.get("stairs", []): stairs(item)
    for item in source.get("furniture", []): furnishing(item)
    export(args.spec, args.samples, args.skip_render)
    print("FLOOR_1_READY " + json.dumps({"meshes":len(B.MODEL), "display_floor":1}), flush=True)


if __name__ == "__main__":
    main()
