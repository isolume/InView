#!/usr/bin/env python3
"""Render and export the photo catalogue with Blender's native USDZ exporter.

Run after export-photo-furniture.py:
  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python-exit-code 1 --python scripts/render-photo-furniture.py -- --samples 16

Geometry is in meters, Y-up, facing -Z. Blender uses [x, -z, y].
Only model geometry is exported; the studio, lights, and camera are previews.
No reference images are embedded in the exported packages.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import subprocess
import sys
import zipfile

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
CATALOGUE = ROOT / "Packages/AccessCore/Sources/AccessCore/Resources/photo-furniture.json"
OUTPUT = ROOT / "models/photo-room"


def neutral_color(source: str) -> tuple[float, float, float, float]:
    """Match InView's existing soft gray furniture palette, in linear light."""
    rgb = [int(source[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    brightness = min(0.85, max(0.66, sum(rgb) / 3))
    srgb = [round(brightness * tint * 255) / 255 for tint in (0.97, 0.99, 1)]
    return tuple(v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in srgb) + (1,)


def material(name: str, color: tuple, roughness: float = 0.9):
    result = bpy.data.materials.new(name)
    result.use_nodes = True
    shader = result.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = color
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Metallic"].default_value = 0
    shader.inputs["Specular IOR Level"].default_value = 0.23
    result.diffuse_color = color
    return result


def transform(point):
    return (point[0], -point[2], point[1])


def import_model(model: dict):
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for data in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras, bpy.data.lights):
        for item in list(data):
            if item.users == 0:
                data.remove(item)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1
    scene.unit_settings.length_unit = "METERS"
    objects, points, materials = [], [], {}
    for source in model["meshes"]:
        vertices = [transform(v) for v in source["vertices"]]
        normals = [transform(n) for n in source["normals"]]
        mesh = bpy.data.meshes.new(source["name"])
        mesh.from_pydata(vertices, [], source["triangles"])
        mesh.update()
        for polygon in mesh.polygons:
            polygon.use_smooth = True
        # Source vertices already split at hard edges. Preserve the source normals.
        mesh.normals_split_custom_set_from_vertices(normals)
        obj = bpy.data.objects.new(source["name"], mesh)
        scene.collection.objects.link(obj)
        if source["color"] not in materials:
            materials[source["color"]] = material("Soft gray " + source["color"], neutral_color(source["color"]))
        mesh.materials.append(materials[source["color"]])
        objects.append(obj)
        points.extend(Vector(v) for v in vertices)
    return objects, points


def validate_usdz(path: Path, expected_meshes: int):
    # Native USDZ packages are uncompressed ZIP archives with 64-byte alignment.
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        assert entries, f"Empty USDZ package: {path}"
        assert archive.testzip() is None, f"Corrupt USDZ package: {path}"
        assert entries[0].filename.endswith((".usd", ".usdc", ".usda"))
        for entry in entries:
            assert entry.compress_type == zipfile.ZIP_STORED, "USDZ entries must be uncompressed"
            with path.open("rb") as file:
                file.seek(entry.header_offset)
                header = file.read(30)
            name_size, extra_size = struct.unpack_from("<HH", header, 26)
            assert (entry.header_offset + 30 + name_size + extra_size) % 64 == 0, "USDZ entry is not 64-byte aligned"
    from pxr import Usd, UsdGeom
    stage = Usd.Stage.Open(str(path))
    assert stage is not None, f"USD cannot open {path}"
    assert UsdGeom.GetStageUpAxis(stage) == UsdGeom.Tokens.y
    assert abs(UsdGeom.GetStageMetersPerUnit(stage) - 1) < 1e-8
    meshes = [prim for prim in stage.Traverse() if prim.IsA(UsdGeom.Mesh)]
    assert len(meshes) == expected_meshes
    assert not any(prim.IsA(UsdGeom.Camera) or "Light" in prim.GetTypeName() for prim in stage.Traverse())
    return {"file": path.name, "bytes": path.stat().st_size, "mesh_count": len(meshes), "up_axis": "Y", "meters_per_unit": 1, "entries": [entry.filename for entry in entries]}


def export_usdz(model: dict, objects: list, destination: Path):
    for obj in bpy.context.scene.objects:
        obj.select_set(False)
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    path = destination / (model["id"] + ".usdz")
    # These parameters are supported by the installed Blender 4.5 native exporter.
    result = bpy.ops.wm.usd_export(
        filepath=str(path), check_existing=False,
        selected_objects_only=True, export_animation=False, export_normals=True,
        export_materials=True, generate_preview_surface=True,
        export_textures=False, export_lights=False, export_cameras=False,
        export_hair=False, export_uvmaps=False, export_mesh_colors=False,
        export_armatures=False, export_shapekeys=False, export_curves=False,
        export_points=False, export_volumes=False, convert_world_material=False,
        convert_orientation=True, export_global_forward_selection="NEGATIVE_Z",
        export_global_up_selection="Y", convert_scene_units="METERS",
        root_prim_path="/Furniture", export_custom_properties=False,
    )
    assert result == {"FINISHED"}, f"USDZ export did not finish: {model['id']}"
    return validate_usdz(path, len(objects))


def aim_at(obj, target):
    obj.rotation_euler = (target - obj.location).to_track_quat("-Z", "Y").to_euler()


def studio_render(model: dict, points: list, destination: Path, samples: int, width: int, height: int, device: str):
    scene = bpy.context.scene
    low = Vector([min(p[i] for p in points) for i in range(3)])
    high = Vector([max(p[i] for p in points) for i in range(3)])
    center = (low + high) / 2
    extent = max(high - low)
    ground_height = low.z - 0.006 * extent
    bpy.ops.mesh.primitive_plane_add(size=200 * extent, location=(0, 0, ground_height))
    ground = bpy.context.object
    ground.name = "Preview studio floor"
    ground.data.materials.append(material("Preview studio offwhite", (0.86, 0.86, 0.85, 1)))
    world = bpy.data.worlds.new("Preview studio")
    world.use_nodes = True
    world.node_tree.nodes.get("Background").inputs["Color"].default_value = (0.82, 0.85, 0.88, 1)
    world.node_tree.nodes.get("Background").inputs["Strength"].default_value = 0.5
    scene.world = world
    bpy.ops.object.camera_add()
    camera = bpy.context.object
    camera.name = "Preview camera"
    camera.data.type = "ORTHO"
    direction = Vector((0.85, 1.25, 0.8)).normalized()
    camera.location = center + direction * extent * 8
    aim_at(camera, center)
    right = camera.rotation_euler.to_quaternion() @ Vector((1, 0, 0))
    up = camera.rotation_euler.to_quaternion() @ Vector((0, 1, 0))
    horizontal = [(p - center).dot(right) for p in points]
    vertical = [(p - center).dot(up) for p in points]
    projected_center = right * ((max(horizontal) + min(horizontal)) / 2) + up * ((max(vertical) + min(vertical)) / 2)
    camera.location += projected_center
    aspect = width / height
    camera.data.ortho_scale = max((max(vertical) - min(vertical)) * aspect, max(horizontal) - min(horizontal)) * 1.32
    camera.data.lens = 50
    camera.data.clip_start = 0.01
    camera.data.clip_end = extent * 300
    scene.camera = camera
    for name, position, power, size in [
        ("Preview key", (-3.2, 4, 6), 110, 4.5),
        ("Preview fill", (4, 1, 3.8), 40, 4),
        ("Preview rim", (0, -3, 4), 55, 3.5),
    ]:
        data = bpy.data.lights.new(name, "AREA")
        data.energy = power * extent * extent
        data.shape = "DISK"
        data.size = size * extent
        light = bpy.data.objects.new(name, data)
        scene.collection.objects.link(light)
        light.location = center + Vector(position) * extent
        aim_at(light, center)
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    if device == "metal":
        preferences = bpy.context.preferences.addons["cycles"].preferences
        preferences.compute_device_type = "METAL"
        preferences.get_devices()
        available = [d for d in preferences.devices if d.type == "METAL"]
        assert available, "Metal compute is unavailable; rerun with --device cpu"
        for render_device in preferences.devices:
            render_device.use = render_device.type == "METAL"
        scene.cycles.device = "GPU"
        print("Render device: " + ", ".join(d.name for d in available), flush=True)
    scene.cycles.samples = samples
    scene.cycles.use_denoising = True
    scene.cycles.max_bounces = 4
    scene.cycles.diffuse_bounces = 2
    scene.cycles.glossy_bounces = 2
    scene.render.resolution_x = width
    scene.render.resolution_y = height
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0.7
    scene.view_settings.gamma = 1
    scene.render.filepath = str(destination / (model["id"] + ".png"))
    bpy.ops.render.render(write_still=True)


def contact_sheet(models: list, destination: Path):
    magick = Path("/opt/homebrew/bin/magick")
    font = Path("/System/Library/Fonts/Helvetica.ttc")
    if not magick.exists() or not font.exists():
        print("Contact sheet skipped: local ImageMagick or Helvetica unavailable.", flush=True)
        return
    body = destination / ".contact-sheet-body.png"
    command = [str(magick), "montage", "-font", str(font), "-pointsize", "22", "-fill", "#4a4e53", "-background", "#f5f6f4", "-gravity", "center", "-geometry", "440x370+22+22", "-tile", "4x"]
    for model in models:
        command.extend(["-label", model["title"], str(destination / (model["id"] + ".png"))])
    command.extend(["-depth", "8", str(body)])
    subprocess.run(command, check=True, capture_output=True, text=True)
    subprocess.run([
        str(magick), str(body), "-background", "#f5f6f4", "-gravity", "north", "-splice", "0x135", "-font", str(font), "-fill", "#25292e", "-pointsize", "39", "-annotate", "+0+32", "Room & balcony", "-fill", "#777c82", "-pointsize", "19", "-annotate", "+0+86", f"{len(models)} photo models · Soft gray · Approximate dimensions", "-depth", "8", str(destination / "contact-sheet.png")
    ], check=True, capture_output=True, text=True)
    body.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalogue", type=Path, default=CATALOGUE)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--ids", nargs="*", help="Render selected model IDs for a quick review")
    parser.add_argument("--samples", type=int, default=16)
    parser.add_argument("--device", choices=("cpu", "metal"), default="cpu", help="CPU is portable; Metal can speed up local Apple Silicon renders")
    parser.add_argument("--resume", action="store_true", help="Reuse completed packages and studio previews")
    parser.add_argument("--width", type=int, default=880)
    parser.add_argument("--height", type=int, default=760)
    arguments = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    catalogue = json.loads(arguments.catalogue.read_text())
    assert catalogue["version"] == 1
    models = [m for m in catalogue["models"] if not arguments.ids or m["id"] in arguments.ids]
    assert models, "No models selected"
    native = arguments.output / "usdz"
    previews = arguments.output / "previews"
    native.mkdir(parents=True, exist_ok=True)
    previews.mkdir(parents=True, exist_ok=True)
    reports = []
    for index, model in enumerate(models):
        print(f"[{index + 1}/{len(models)}] Export and render {model['title']}", flush=True)
        if arguments.resume and (native / (model["id"] + ".usdz")).exists() and (previews / (model["id"] + ".png")).exists():
            reports.append(validate_usdz(native / (model["id"] + ".usdz"), len(model["meshes"])))
            print("Reused completed native package and preview.", flush=True)
            continue
        objects, points = import_model(model)
        reports.append(export_usdz(model, objects, native))
        studio_render(model, points, previews, arguments.samples, arguments.width, arguments.height, arguments.device)
    if len(models) == len(catalogue["models"]):
        contact_sheet(models, previews)
    (native / "validation.json").write_text(json.dumps({"blender_version": bpy.app.version_string, "dimensions_are_approximate": True, "models": reports}, indent=2) + "\n")
    print(f"Validated {len(reports)} native USDZ packages and rendered {len(models)} previews.", flush=True)


if __name__ == "__main__":
    main()
