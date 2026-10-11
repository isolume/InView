#!/usr/bin/env python3
"""Build the approximate filmed atrium section, using the existing furniture.

Blender 4.5: --background --factory-startup --python-exit-code 1
  --python scripts/build-walkthrough-building.py -- --samples 32
Coordinates here are Z-up meters; exported GLB/USDZ/viewer data are Y-up.
All dimensions and unseen continuations are artistic estimates, not survey data.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
from pathlib import Path
import sys

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "models/walkthrough-building"
CATALOG = ROOT / "Packages/AccessCore/Sources/AccessCore/Resources/photo-furniture.json"
PALETTE = {
    "wall": "#e3e7df", "cap": "#f2f3ed", "plinth": "#aeb8ad",
    "floor": "#d2d8ce", "carpet": "#bdc9c5", "tile": "#e7e6da",
    "seat": "#9bafad", "seat-light": "#b1c0bc", "wood": "#c8bea8",
    "metal": "#8d9f9c", "rail": "#a6b3ad", "door": "#adbdc2",
    "glass": "#c6d8d6", "glass-accent": "#a1b5c2", "leaf": "#99ad91",
    "lower-floor": "#dde2d9", "dark": "#788e8e",
}
MATS = {}
ASSET_MESHES = {}
MODEL = []
FURNITURE = []


def linear(v):
    return v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4


def material(key):
    if key in MATS:
        return MATS[key]
    color = PALETTE.get(key, key)
    rgb = tuple(linear(int(color[i:i + 2], 16) / 255) for i in (1, 3, 5))
    mat = bpy.data.materials.new(key)
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = (*rgb, 1)
    shader.inputs["Roughness"].default_value = .86
    shader.inputs["Specular IOR Level"].default_value = .18
    mat.diffuse_color = (*rgb, 1)
    mat["display_hex"] = color
    MATS[key] = mat
    return mat


def box(name, center, size, color="wall", bevel=.025):
    bpy.ops.mesh.primitive_cube_add(size=1, location=center)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(material(color))
    if bevel:
        mod = obj.modifiers.new("Soft edges", "BEVEL")
        mod.width = min(bevel, min(size) * .24)
        mod.segments = 2
        mod = obj.modifiers.new("Weighted corner normals", "WEIGHTED_NORMAL")
        mod.keep_sharp = True
    MODEL.append(obj)
    return obj


def slab(name, x1, x2, y1, y2, z=0, color="floor", depth=.22):
    return box(name, ((x1+x2)/2, (y1+y2)/2, z-depth/2), (x2-x1,y2-y1,depth),color,.035)


def wall(name, a, b, height=1.05, base=0, thickness=.17, color="wall"):
    dx, dy = b[0]-a[0], b[1]-a[1]
    length = math.hypot(dx,dy)
    center = ((a[0]+b[0])/2,(a[1]+b[1])/2,base+height/2)
    obj=box(name,center,(length,thickness,height),color,.016)
    obj.rotation_euler.z=math.atan2(dy,dx)
    # A tiny height offset avoids coplanar cap faces at perpendicular joins.
    cap_z=base+height+(.017 if abs(dy)>abs(dx) else .013)
    cap=box(name+" · pale cut edge",(center[0],center[1],cap_z),(length+.015,thickness+.028,.026),"cap",.008)
    cap.rotation_euler.z=obj.rotation_euler.z


def beam(name, a, b, radius=.025, color="rail"):
    direction=Vector(b)-Vector(a)
    bpy.ops.mesh.primitive_cylinder_add(vertices=10,radius=radius,depth=direction.length,location=(Vector(a)+Vector(b))/2)
    obj=bpy.context.object
    obj.name=name
    obj.rotation_euler=direction.to_track_quat("Z","Y").to_euler()
    obj.data.materials.append(material(color))
    for face in obj.data.polygons: face.use_smooth=True
    MODEL.append(obj)
    return obj


def railing(name, a, b, z=0, height=.92):
    length=math.dist(a,b)
    count=max(1,math.ceil(length/1.45))
    for i in range(count+1):
        x=a[0]+(b[0]-a[0])*i/count; y=a[1]+(b[1]-a[1])*i/count
        beam(name+" · post",(x,y,z),(x,y,z+height),.025,"metal")
    for h in (.2,.4,.6,.8):
        beam(name+" · rail",(*a,z+h),(*b,z+h),.016,"rail")
    beam(name+" · handrail",(*a,z+height),(*b,z+height),.04,"cap")


def slope_rail(name,x,y1,y2,z1,z2):
    for t in (0,.25,.5,.75,1):
        y=y1+(y2-y1)*t; z=z1+(z2-z1)*t
        beam(name+" · post",(x,y,z),(x,y,z+.88),.024,"metal")
    for h in (.2,.4,.6,.88):
        beam(name,(x,y1,z1+h),(x,y2,z2+h),.035 if h==.88 else .016,"cap" if h==.88 else "rail")


def flight(name,x,y1,y2,z1,z2,width=1.28,count=10):
    for i in range(count):
        t=(i+.5)/count; y=y1+(y2-y1)*t
        z=z1+(z2-z1)*(i+1)/count
        box(name+f" · tread {i+1:02}",(x,y,z-.075),(width,abs(y2-y1)/count+.012,.15),"tile",.012)
    # Solid inclined carriage beneath the treads.
    start=Vector((x,y1,z1-.17)); end=Vector((x,y2,z2-.17))
    stringer=box(name+" · carriage",(start+end)/2,(width-.06,(end-start).length,.16),"wall",.008)
    stringer.rotation_euler.x=math.atan2(z2-z1,y2-y1)
    for edge in (-1,1): slope_rail(name+" · balustrade",x+edge*width/2,y1,y2,z1,z2)


def furniture(key,x,y,angle=0,z=0,scale=1):
    source=CAT[key]
    if key not in ASSET_MESHES:
        pieces=[]
        for part in source["meshes"]:
            mesh=bpy.data.meshes.new(key+" / "+part["name"])
            mesh.from_pydata([(p[0],-p[2],p[1]+source["dimensions_m"][1]/2) for p in part["vertices"]],[],part["triangles"])
            mesh.update()
            for poly in mesh.polygons: poly.use_smooth=True
            mesh.normals_split_custom_set_from_vertices([(n[0],-n[2],n[1]) for n in part["normals"]])
            desc=part["name"].lower()
            if key in ("lounge-chair","modular-sofa"):
                col="metal" if any(t in desc for t in ("leg","foot","feet")) else "seat"
            elif "table" in key: col="wood" if any(t in desc for t in ("top","body","drum")) else "metal"
            elif key=="square-planter": col="leaf" if any(t in desc for t in ("leaf","foliage","stem")) else "tile"
            elif key=="bench": col="wood" if "slat" in desc else "metal"
            else: col="seat-light"
            mesh.materials.append(material(col))
            pieces.append(mesh)
        ASSET_MESHES[key]=pieces
    for mesh in ASSET_MESHES[key]:
        obj=bpy.data.objects.new(source["title"]+" · "+mesh.name,mesh)
        bpy.context.scene.collection.objects.link(obj)
        obj.location=(x,y,z);obj.rotation_euler.z=math.radians(angle);obj.scale=(scale,)*3
        MODEL.append(obj)
    FURNITURE.append({"asset":key,"position_m":[x,z,-y],"yaw_degrees":angle,"scale":scale})


def architecture():
    # Lounge and the straight balcony are the directly observed, connected core.
    slab("Lounge · foundation",-10,-2.75,-3.9,5.2,color="plinth",depth=.28)
    slab("Lounge · carpet",-9.94,-2.81,-3.84,5.14,z=.022,color="carpet",depth=.025)
    slab("Upper balcony",-2.75,0,-7,10.2)
    slab("Lift and stair landing",0,8.6,-7,-4.5)
    slab("Far corridor threshold",-2.75,0,10.2,10.8)
    # Ground below is context only, deliberately quiet and sparsely furnished.
    slab("Atrium · lower floor",0,9.25,-4.5,9.6,z=-3.15,color="lower-floor",depth=.18)
    slab("Lower stair arrival",2.82,8.6,-7,-4.5,z=-3.15,color="lower-floor",depth=.18)
    wall("Lounge west",(-10,-3.9),(-10,5.2))
    wall("Lounge south",(-10,-3.9),(-2.75,-3.9),.55)
    wall("Lounge north",(-10,5.2),(-2.75,5.2),1.05)
    wall("Lounge corridor wall south",(-2.75,-7),(-2.75,-.75),.96)
    wall("Lounge corridor wall north",(-2.75,.5),(-2.75,10.8),.96)
    # Windowed exit: retain the opening, with door leaf visibly swung inside room.
    door=box("Lounge · open windowed door",(-3.27,-.56,.54),(1.02,.07,1.08),"tile",.014)
    door.rotation_euler.z=math.radians(-22)
    pane=box("Lounge · door window",(-3.27,-.595,.73),(.59,.075,.38),"glass",.008)
    pane.rotation_euler.z=math.radians(-22)
    for y in (-.77,.52): box("Lounge · doorway jamb",(-2.75,y,.58),(.21,.09,1.16),"cap",.008)
    slab("Lounge · threshold",-2.9,-2.58,-.71,.47,z=.029,color="tile",depth=.025)
    # Thin bands reflect the polished corridor floor without photographic texture.
    for y in (-4.25,.15,4.65,8.85): slab("Balcony · floor band",-2.66,-.08,y-.2,y+.2,z=.008,color="tile",depth=.01)
    railing("Atrium balcony",(-.03,-4.48),(-.03,9.65))
    railing("Lift lobby atrium edge",(.04,-4.48),(2.78,-4.48))
    wall("Far corridor end",(-2.75,10.8),(0,10.8),1.4)
    for x in (-2.01,-.77):
        box("Far corridor · timber double door",(x,10.70,.62),(1.12,.07,1.24),"wood",.015)
        box("Far corridor · door pull",(x+(.4 if x<-1 else -.4),10.65,.59),(.025,.035,.19),"metal",.005)
    # The video establishes two lifts; their cutaway height is stylized.
    wall("Lift lobby end wall",(-2.75,-7),(8.6,-7),1.45)
    for x in (-1.32,1.08):
        box("Lift · surround",(x,-6.88,.68),(1.54,.1,1.36),"cap",.014)
        for offset in (-.345,.345): box("Lift · sliding door",(x+offset,-6.81,.655),(.68,.035,1.27),"door",.008)
        box("Lift · header",(x,-6.79,1.36),(.35,.055,.065),"metal",.008)
    box("Lift · call panel",(-.1,-6.78,.75),(.09,.04,.18),"metal",.01)
    wall("Stair landing outer edge",(8.6,-7),(8.6,-3.0),.65)
    # Up and down stair flights share the lobby. Landings beyond view are inferred.
    flight("Stair up · first flight",7.6,-4.5,-1.3,0,1.6)
    slab("Stair up · half landing",6.96,8.6,-1.3,.15,z=1.6,color="tile",depth=.18)
    railing("Stair up · landing guard",(7.0,.12),(8.55,.12),z=1.6)
    flight("Stair down · first flight",4.9,-4.5,-1.3,0,-1.6)
    slab("Stair down · half landing",2.82,5.56,-1.3,.15,z=-1.6,color="tile",depth=.18)
    flight("Stair down · return",3.5,-1.3,-4.5,-1.6,-3.15)
    railing("Lower stair · landing guard",(2.84,.12),(5.54,.12),z=-1.6)
    # Opposite glazing is lowered to keep the interior legible from above.
    wall("Atrium window base",(9.25,-4.5),(9.25,9.6),.3,base=-3.15,color="plinth")
    for i in range(6):
        y=-4.45+i*2.33
        box("Atrium · glazing",(9.25,y+1.10,-1.3),(.075,2.13,3.15),"glass",.008)
        box("Atrium · mullion",(9.18,y,-1.25),(.11,.09,3.55),"cap",.008)
        if i in (1,4): box("Atrium · blue window accent",(9.15,y+.46,-1.65),(.08,.66,2.35),"glass-accent",.009)
    for z in (-1.45,.4): beam("Atrium · horizontal glazing frame",(9.16,-4.48,z),(9.16,9.57,z),.035,"cap")
    for y in (-3.95,5.18): box("Lounge · column",(-2.92,y,.68),(.38,.38,1.36),"wall",.028)


def furnishings():
    # A simplified reading of the visible seating groups; counts are estimates.
    furniture("modular-sofa",-9.4,-1.7,-90)
    furniture("modular-sofa",-9.4,1.1,-90)
    furniture("modular-sofa",-6.6,4.6,180)
    furniture("lounge-chair",-7.3,-2.5,18)
    furniture("lounge-chair",-5.75,-2.45,-18)
    furniture("lounge-chair",-7.3,.9,164)
    furniture("lounge-chair",-5.75,.9,195)
    furniture("lounge-chair",-4.0,2.5,65)
    furniture("lounge-chair",-4.2,4.25,105)
    furniture("large-drum-table",-6.55,-.9)
    furniture("large-drum-table",-6.6,2.55)
    furniture("small-drum-table",-8.65,-.2)
    furniture("small-drum-table",-4.15,3.45)
    furniture("charging-stand",-4.75,-1.5,20)
    furniture("lectern",-3.4,1.8,90)
    furniture("sign-stand",-3.45,.7,90,scale=.77)
    furniture("waste-bin",-3.4,-2.6)
    furniture("bench",-2.35,-5.35,90)
    furniture("square-planter",-2.15,-3.7,scale=.78)
    furniture("floor-sign",.04,-5.8,15,scale=.85)
    furniture("square-planter",-9.35,4.57,scale=.68)
    # Sparse ground-floor context visible through the void.
    for y in (2.7,5.4):
        furniture("modular-sofa",7.8,y,-90,z=-3.15)
    furniture("large-drum-table",6.1,3.9,z=-3.15)
    furniture("lounge-chair",4.65,3.25,80,z=-3.15)
    furniture("lounge-chair",4.65,4.7,105,z=-3.15)


def export_models():
    # Apply modifiers before exporting so native and browser assets agree exactly.
    for obj in MODEL:
        bpy.context.view_layer.objects.active=obj
        for mod in list(obj.modifiers): bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in MODEL: obj.select_set(True)
    bpy.context.view_layer.objects.active=MODEL[0]
    bpy.ops.export_scene.gltf(filepath=str(OUT/"building.glb"),export_format="GLB",use_selection=True,export_yup=True,export_cameras=False,export_lights=False,export_extras=True)
    bpy.ops.wm.usd_export(filepath=str(OUT/"building.usdz"),check_existing=False,selected_objects_only=True,export_animation=False,export_normals=True,export_materials=True,generate_preview_surface=True,export_textures=False,export_lights=False,export_cameras=False,export_hair=False,export_uvmaps=False,export_mesh_colors=False,export_armatures=False,export_shapekeys=False,export_curves=False,export_points=False,export_volumes=False,convert_world_material=False,convert_orientation=True,export_global_forward_selection="NEGATIVE_Z",export_global_up_selection="Y",convert_scene_units="METERS",root_prim_path="/Building",export_custom_properties=False)
    spec=importlib.util.spec_from_file_location("furniture_export",ROOT/"scripts/render-photo-furniture.py")
    exporter=importlib.util.module_from_spec(spec);spec.loader.exec_module(exporter)
    validation=exporter.validate_usdz(OUT/"building.usdz",len(MODEL))
    # Viewer geometry is grouped per object, with world transforms baked in.
    meshes=[]; low=[float("inf")]*3; high=[-float("inf")]*3; triangles=0
    for obj in MODEL:
        mesh=obj.data;mesh.calc_loop_triangles()
        vertices=[];normals=[];indices=[];vertex_lookup={}
        normal_matrix=obj.matrix_world.to_3x3().inverted().transposed()
        for tri in mesh.loop_triangles:
            face=[]
            for loop_index in tri.loops:
                p=obj.matrix_world @ mesh.vertices[mesh.loops[loop_index].vertex_index].co
                n=(normal_matrix @ mesh.corner_normals[loop_index].vector).normalized()
                p=[p.x,p.z,-p.y];n=[n.x,n.z,-n.y]
                for i in range(3): low[i]=min(low[i],p[i]);high[i]=max(high[i],p[i])
                p=[round(v,5) for v in p];n=[round(v,5) for v in n]
                key=tuple(p+n)
                if key not in vertex_lookup:
                    vertex_lookup[key]=len(vertices);vertices.append(p);normals.append(n)
                face.append(vertex_lookup[key])
            indices.append(face)
        meshes.append({"name":obj.name,"vertices":vertices,"normals":normals,"triangles":indices,"color":mesh.materials[0]["display_hex"]})
        triangles+=len(indices)
    (OUT/"viewer-scene.json").write_text(json.dumps({"title":"Atrium & lounge","meshes":meshes,"bounds":{"min":low,"max":high}},separators=(",",":")))
    validation.update({"triangle_count":triangles,"bounds_y_up_m":{"min":low,"max":high},"furniture_instances":len(FURNITURE)})
    (OUT/"validation.json").write_text(json.dumps(validation,indent=2)+"\n")
    (OUT/"layout.json").write_text(json.dumps({"title":"Atrium & lounge","reference_video":"IMG_5436.MOV","approximate":True,"units":"meters","up_axis":"Y","furniture":FURNITURE,"observed":["Lounge exits to a straight upper atrium balcony","Balcony continues in both directions","Two elevators at one end with adjacent open stairs","Opposite tall glazing with blue accents","Seating visible on the floor below"],"estimated":["Every dimension and height","Lounge perimeter and furniture counts","Unseen stair landing and lower floor extents"],"navigation_ready":False},indent=2)+"\n")
    print("MODEL VALIDATION "+json.dumps(validation),flush=True)


def aim(obj,target): obj.rotation_euler=(Vector(target)-obj.location).to_track_quat("-Z","Y").to_euler()


def render(samples):
    scene=bpy.context.scene
    # Studio is excluded from the exported assets above.
    ground=box("Studio ground",(0,0,-3.39),(200,200,.1),"#e9ede7",0)
    MODEL.remove(ground)
    world=bpy.data.worlds.new("Soft daylight");world.use_nodes=True
    world.node_tree.nodes["Background"].inputs["Color"].default_value=(.86,.87,.87,1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value=.65
    scene.world=world
    for name,position,power,size in [("Large softbox",(-12,-6,28),4200,18),("Atrium fill",(12,8,20),1900,15)]:
        light=bpy.data.lights.new(name,"AREA");light.energy=power;light.shape="DISK";light.size=size
        obj=bpy.data.objects.new(name,light);scene.collection.objects.link(obj);obj.location=position;aim(obj,(0,1,0))
    bpy.ops.object.camera_add(location=(26,34,34))
    camera=bpy.context.object;camera.name="Map camera";camera.data.type="ORTHO";camera.data.ortho_scale=29.5
    aim(camera,(-.1,1.45,-.45));scene.camera=camera
    scene.render.engine="CYCLES";scene.cycles.device="CPU";scene.cycles.samples=samples;scene.cycles.use_denoising=True;scene.cycles.max_bounces=5
    scene.render.resolution_x=2000;scene.render.resolution_y=1600;scene.render.resolution_percentage=100
    scene.render.image_settings.file_format="PNG";scene.render.image_settings.color_mode="RGB"
    scene.view_settings.view_transform="Standard";scene.view_settings.look="None";scene.view_settings.exposure=0
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT/"building.blend"))
    scene.render.filepath=str(OUT/"preview.png");bpy.ops.render.render(write_still=True)
    camera.location=(0,1.8,35);aim(camera,(0,1.8,0));camera.data.ortho_scale=25
    scene.render.resolution_x=1800;scene.render.resolution_y=1800
    scene.render.filepath=str(OUT/"floor-plan.png");bpy.ops.render.render(write_still=True)


if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--samples",type=int,default=32);parser.add_argument("--skip-render",action="store_true")
    args=parser.parse_args(sys.argv[sys.argv.index("--")+1:] if "--" in sys.argv else [])
    OUT.mkdir(parents=True,exist_ok=True)
    bpy.context.preferences.filepaths.save_version=0
    bpy.ops.object.select_all(action="SELECT");bpy.ops.object.delete(use_global=False)
    bpy.context.scene.unit_settings.system="METRIC";bpy.context.scene.unit_settings.scale_length=1
    CAT={model["id"]:model for model in json.loads(CATALOG.read_text())["models"]}
    architecture();furnishings();bpy.context.view_layer.update();export_models()
    if not args.skip_render: render(args.samples)
