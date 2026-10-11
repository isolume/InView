#!/usr/bin/env python3
"""Reconstruct the observed parts of floors 2 and 3 from IMG_5439.MOV.

Run with Blender 4.5 --background --factory-startup --python-exit-code 1
  --python scripts/build-walkthrough-floors.py -- --samples 24
This is a stylized visual reconstruction, not measured or navigable geometry.
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
OUT = ROOT / "models/walkthrough-building/floors-2-3"
spec = importlib.util.spec_from_file_location("building_primitives", ROOT / "scripts/build-walkthrough-building.py")
B = importlib.util.module_from_spec(spec)
spec.loader.exec_module(B)
B.PALETTE.update({"accent": "#b4bfcb", "ochre": "#c1b994", "upholstery": "#a8b9b4", "gallery": "#d8d9d1", "mural": "#a5b6c6", "mural-light": "#c0cbd0", "core": "#dce0d7"})
HEIGHT = 4.0
ACTIVE = 2
ZONE = ""
COLLECTIONS = {}
POIS = []
EVIDENCE = []


def level(): return 0 if ACTIVE == 2 else HEIGHT


def stamp(start):
    for obj in B.MODEL[start:]:
        obj["floor"] = ACTIVE
        obj["zone"] = ZONE
        obj["estimated_from_video"] = True
        for col in list(obj.users_collection): col.objects.unlink(obj)
        COLLECTIONS[ACTIVE].objects.link(obj)


def emit(fn, *args, **kwargs):
    start = len(B.MODEL)
    result = fn(*args, **kwargs)
    stamp(start)
    return result


def box(name, x, y, z, width, depth, height, color="wall", bevel=.025):
    return emit(B.box, name, (x,y,z+level()), (width,depth,height), color, bevel)


def slab(name,x1,x2,y1,y2,color="floor",z=0,depth=.20):
    assert x2 > x1 and y2 > y1
    return emit(B.slab,name,x1,x2,y1,y2,z+level(),color,depth)


def wall(name,a,b,height=1.03,color="wall",thickness=.17):
    return emit(B.wall,name,a,b,height,level(),thickness,color)


def rail(name,a,b,z=0,height=.91):
    return emit(B.railing,name,a,b,z+level(),height)


def furniture(key,x,y,angle=0,scale=1,z=0):
    emit(B.furniture,key,x,y,angle,z+level(),scale)
    B.FURNITURE[-1].update({"floor": ACTIVE,"zone":ZONE})


def zone(floor,name):
    global ACTIVE,ZONE
    ACTIVE=floor;ZONE=name


def poi(title,x,y,z=.6):
    POIS.append({"floor":ACTIVE,"title":title,"position":[x,level()+z,-y]})


def panel(name,x,y,width=1,height=.56,angle=0,color="accent",z=.77):
    obj=box(name,x,y,z,width,.028,height,color,.009)
    obj.rotation_euler.z=math.radians(angle)
    return obj


def doorway(name, a, b, color="door", closed=True):
    # Short jambs retain the opening in a cutaway wall.
    dx,dy=b[0]-a[0],b[1]-a[1];length=math.hypot(dx,dy);angle=math.atan2(dy,dx)
    for x,y in (a,b): box(name+" · jamb",x,y,.58,.095,.095,1.16,"cap",.008)
    if closed:
        obj=box(name,(a[0]+b[0])/2,(a[1]+b[1])/2,.535,length-.075,.07,1.07,color,.012)
        obj.rotation_euler.z=angle
    return angle


def facade(name,a,b,doors,height=1.03):
    """Straight wall broken at normalized (0..1) intervals for doors."""
    dx,dy=b[0]-a[0],b[1]-a[1]
    def at(t): return (a[0]+dx*t,a[1]+dy*t)
    previous=0
    for start,end in sorted(doors):
        if start>previous: wall(name,at(previous),at(start),height)
        doorway(name+" · door",at(start),at(end))
        previous=end
    if previous<1: wall(name,at(previous),b,height)


def glazed_wall(name,a,b,height=1.17):
    dx,dy=b[0]-a[0],b[1]-a[1];length=math.hypot(dx,dy);count=max(1,math.ceil(length/1.45))
    for i in range(count):
        x=a[0]+dx*(i+.5)/count;y=a[1]+dy*(i+.5)/count
        p=box(name+" · frosted pane",x,y,height/2+.08,length/count-.07,.045,height-.16,"glass",.006)
        p.rotation_euler.z=math.atan2(dy,dx)
    for i in range(count+1):
        x=a[0]+dx*i/count;y=a[1]+dy*i/count
        box(name+" · mullion",x,y,height/2,.065,.065,height,"cap",.008)
    for z in (.14,height): emit(B.beam,name+" · frame",(*a,z+level()),(*b,z+level()),.027,"cap")


def column(x,y,height=1.5):
    emit(B.beam,"Column",(x,y,level()),(x,y,level()+height),.21,"metal")
    emit(B.beam,"Column · blue base",(x,y,level()+.025),(x,y,level()+.50),.217,"accent")


def bench(x,y,width=2.0,angle=0):
    # Gallery benches have a white plinth rather than the balcony bench's legs.
    parts=[box("Gallery bench · plinth",x,y,.21,width,.54,.42,"cap",.025),box("Gallery bench · cushion",x,y,.445,width-.055,.50,.09,"seat",.04)]
    for obj in parts: obj.rotation_euler.z=math.radians(angle)


def banquette(x,y,width=2.1,angle=0):
    a=math.radians(angle)
    for name,offset,size,col,bevel in [
        ("base",(0,0,.24),(width,.66,.48),"seat",.045),
        ("seat",(0,.07,.49),(width-.045,.55,.11),"upholstery",.035),
        ("back",(0,-.25,.82),(width,.15,.67),"seat-light",.045),
    ]:
        px=x+offset[0]*math.cos(a)-offset[1]*math.sin(a);py=y+offset[0]*math.sin(a)+offset[1]*math.cos(a)
        obj=box("Banquette · "+name,px,py,offset[2],*size,col,bevel);obj.rotation_euler.z=a


def modular_island(x,y):
    box("Modular lounge island · base",x,y,.22,2.6,1.45,.44,"seat",.085)
    box("Modular lounge island · cushion",x,y,.46,2.50,1.35,.10,"upholstery",.075)
    box("Modular lounge island · back",x-.25,y+.29,.73,1.33,.32,.55,"seat",.07)
    box("Modular lounge island · accent back",x+.68,y+.29,.73,.49,.32,.55,"ochre",.06)
    box("Modular lounge island · side shelf",x+1.00,y-.25,.55,.55,.66,.06,"tile",.018)


def table(x,y,width=1.5,depth=.7,height=.75,color="tile"):
    box("Desk · top",x,y,height,width,depth,.06,color,.018)
    for dx in (-width/2+.07,width/2-.07):
        for dy in (-depth/2+.07,depth/2-.07): box("Desk · leg",x+dx,y+dy,height/2,.055,.055,height,"metal",.012)


def water_fountain(x,y):
    for dx,z in ((-.30,.62),(.30,.84)):
        box("Drinking fountain · support",x+dx,y,z/2,.48,.35,z,"seat-light",.05)
        box("Drinking fountain · basin",x+dx,y-.08,z,.54,.45,.085,"metal",.04)
        box("Drinking fountain · water bowl",x+dx,y-.1,z+.044,.36,.26,.012,"dark",.03)


def lift_bank():
    # Repeated floor plaques establish the same lift bank on both levels.
    wall("Lift bank wall",(-2.75,-9),(3.15,-9),1.48)
    for x in (-1.30,1.07):
        box("Lift · surround",x,-8.88,.69,1.56,.09,1.38,"cap",.012)
        for dx in (-.345,.345): box("Lift · sliding panel",x+dx,-8.82,.65,.68,.035,1.28,"door",.01)
        panel("Lift · floor marker",x,-8.79,.12,.12,z=.82,color="metal")
        box("Lift · indicator",x,-8.79,1.38,.29,.045,.055,"metal",.008)
    panel("Lift · shared call panel",-.12,-8.78,.09,.2,z=.80,color="metal")
    doorway("Core service door",(2.08,-8.88),(3.01,-8.88),"tile")


def low_detail_catalogue():
    """Preserve furniture silhouettes, with fewer tiny bevel faces at map scale."""
    keys=("lounge-chair","modular-sofa","large-drum-table","small-drum-table","charging-stand","lectern","sign-stand","waste-bin","square-planter","floor-sign")
    for key in keys:
        start=len(B.MODEL);B.furniture(key,0,0)
        temporary=B.MODEL[start:]
        meshes=[]
        for obj in temporary:
            bpy.context.view_layer.objects.active=obj
            if len(obj.data.polygons)>350:
                mod=obj.modifiers.new("Map scale detail","DECIMATE");mod.ratio=.32;mod.use_collapse_triangulate=True
                bpy.ops.object.modifier_apply(modifier=mod.name)
            meshes.append(obj.data)
        B.ASSET_MESHES[key]=meshes
        for obj in temporary: bpy.data.objects.remove(obj,do_unlink=True)
        del B.MODEL[start:];B.FURNITURE.pop()


def second_floor():
    zone(2,"Lounge suite")
    slab("Lounge · base",-10,-2.75,-3.9,5.2,"plinth",depth=.24)
    slab("Lounge · carpet",-9.93,-2.82,-3.83,5.13,"carpet",z=.018,depth=.021)
    wall("Lounge west",(-10,-3.9),(-10,5.2))
    wall("Lounge south",(-10,-3.9),(-2.75,-3.9),.63)
    facade("Lounge north",(-10,5.2),(-2.75,5.2),[(.60,.78)])
    wall("Lounge balcony wall",(-2.75,-3.9),(-2.75,-.75),.92)
    wall("Lounge balcony wall",(-2.75,.5),(-2.75,5.2),.92)
    doorway("Lounge exit",(-2.75,-.75),(-2.75,.5),closed=False)
    door=box("Lounge · open exit",-3.24,-.60,.54,1.04,.06,1.08,"tile",.012);door.rotation_euler.z=math.radians(-20)
    furniture("modular-sofa",-9.42,-1.65,-90)
    furniture("modular-sofa",-9.42,1.04,-90)
    furniture("modular-sofa",-6.6,4.57,180)
    for x,y,angle in [(-7.25,-2.45,18),(-5.72,-2.45,-18),(-7.3,.94,164),(-5.7,.94,194),(-4,2.45,65),(-4.12,4.23,105)]: furniture("lounge-chair",x,y,angle)
    for x,y in [(-6.55,-.9),(-6.55,2.6)]: furniture("large-drum-table",x,y)
    for x,y in [(-8.55,-.12),(-4.1,3.4)]: furniture("small-drum-table",x,y)
    furniture("charging-stand",-4.8,-1.5,20);furniture("lectern",-3.4,1.8,90)
    furniture("waste-bin",-3.35,-2.4);furniture("square-planter",-9.4,4.55,scale=.63)
    # The opening sequence adds the carpeted internal spur and side-room doors.
    slab("Lounge suite · internal passage",-6.4,-4.0,5.2,10.7,"carpet")
    facade("Suite west room fronts",(-6.4,5.2),(-6.4,10.7),[(.13,.30),(.67,.84)])
    facade("Suite east room fronts",(-4,5.2),(-4,10.7),[(.30,.47)])
    facade("Suite end",(-6.4,10.7),(-4,10.7),[(.28,.72)])
    poi("Lounge",-7.1,1.4)

    zone(2,"Original atrium balcony")
    slab("East balcony",-2.75,0,-9,10.8)
    slab("Main lift and stair lobby",0,8.6,-9,-4.7)
    wall("Corridor room fronts",(-2.75,5.2),(-2.75,8.1),.96)
    doorway("Room 203",(-2.75,8.1),(-2.75,9.12))
    wall("Corridor room fronts",(-2.75,9.12),(-2.75,10.8),.96)
    facade("Far double-door wall",(-2.75,10.8),(0,10.8),[(.06,.94)],1.3)
    for x in (-2.04,-.78): panel("Room 200 · timber door",x,10.735,1.12,1.15,z=.6,color="wood")
    rail("Tall atrium · balcony edge",(-.035,-4.65),(-.035,10.55))
    rail("Tall atrium · lobby edge",(.035,-4.65),(5.4,-4.65))
    for y in (-4.1,.15,4.5,8.6): slab("Balcony · pale floor band",-2.65,-.1,y-.19,y+.19,"tile",z=.005,depth=.007)
    lift_bank()
    wall("Main stair east edge",(8.6,-9),(8.6,.2),.80)
    # Low perimeter glazing suggests the open atrium without filling its void.
    glazed_wall("Atrium opposite glazing",(9.18,-4.7),(9.18,10.65),1.15)
    for y in (-2.1,5.8): panel("Atrium blue panel",9.13,y,.68,.85,90,"glass-accent",.58)
    poi("Lifts",-.2,-7.5)

    zone(2,"Main stair · lower flight")
    emit(B.flight,"Main stair 2 to landing",6.10,-4.7,-1.1,0,HEIGHT/2,1.40,12)

    zone(2,"Seating concourse")
    slab("Main seating concourse",-29,-2.75,-9,-3.9)
    # At this turn the video reveals a second railed opening.
    rail("Inner opening · long balcony",(-28.9,-3.88),(-11.1,-3.88))
    for x in (-10.25,-6.95,-3.75): modular_island(x,-5.0)
    wall("Concourse back edge",(-29,-9),(-6.2,-9),.84)
    for x in (-26,-21,-16,-11): slab("Concourse · floor band",x-.19,x+.19,-8.9,-4.05,"tile",z=.005,depth=.007)
    column(-22.4,-5.15);column(-12.2,-5.20)
    furniture("waste-bin",-13.2,-4.6);furniture("square-planter",-27.9,-7.8,scale=.77)
    for x in (-8.0,-4.3): panel("Concourse · notice panel",x,-3.98,1.25,.52,z=.79)
    poi("Seating concourse",-17.6,-6.5)

    zone(2,"Windowed desk area")
    slab("West desk lounge",-29,-22.6,-3.9,3.9)
    rail("Desk area · inner opening",(-22.62,-3.82),(-22.62,3.78))
    glazed_wall("Desk lounge · outer glazing",(-29,-3.85),(-29,3.9),1.25)
    wall("Desk lounge rear",(-29,3.9),(-22.6,3.9),1.1)
    table(-25.0,2.1,3.7,.88);table(-23.75,.45,.8,2.4)
    box("Desk · front panel",-25,1.75,.38,3.65,.075,.74,"seat-light",.022)
    for x in (-26.1,-24.6):
        box("Desk · monitor stand",x,2.2,.90,.07,.07,.25,"metal",.009)
        panel("Desk · screen",x,2.21,.53,.34,z=1.12,color="dark")
    furniture("lounge-chair",-27.8,-.70,-90,scale=.91)
    furniture("lounge-chair",-27.8,1.0,-90,scale=.91)
    furniture("small-drum-table",-27.25,.2)
    column(-28,3.25)
    box("Desk area · display case",-23.2,3.58,.65,.8,.36,1.3,"seat-light",.025)
    poi("Desk area",-25.7,1.0)

    zone(2,"Interior gallery corridor")
    # A filmed branch, not a fabricated connection to another wing.
    slab("Gallery corridor",-42,-29,-7.65,-4.5,"gallery")
    facade("Gallery · north room fronts",(-42,-4.5),(-29,-4.5),[(.09,.17),(.33,.41),(.61,.69),(.85,.93)])
    facade("Gallery · south room fronts",(-42,-7.65),(-29,-7.65),[(.16,.24),(.50,.58),(.80,.88)],.92)
    wall("Gallery · unfilmed continuation",(-42,-7.65),(-42,-4.5),.46)
    glazed_wall("Gallery entrance north leaf",(-29,-4.5),(-29,-5.25),1.13)
    glazed_wall("Gallery entrance south leaf",(-29,-6.9),(-29,-7.65),1.13)
    for x,y in [(-39.0,-7.22),(-35.2,-7.22),(-31.7,-7.22)]: bench(x,y,1.7)
    for x in (-40.6,-37.0,-33.7,-30.2): panel("Gallery · artwork",x,-4.60,.66,.46,z=.76,color="mural-light")
    slab("Gallery · recessed doorway bay",-38.0,-35.8,-9.0,-7.65,"gallery")
    facade("Gallery · bay back",(-38,-9),(-35.8,-9),[(.28,.73)],1.0)
    wall("Gallery · bay sides",(-38,-9),(-38,-7.65),.94);wall("Gallery · bay sides",(-35.8,-9),(-35.8,-7.65),.94)
    furniture("waste-bin",-40.6,-6.8,scale=.80)
    poi("Gallery",-36.2,-6.1)

    zone(2,"Restroom passage")
    slab("Restroom and noticeboard passage",-29,-2.75,-12.2,-9)
    facade("Restroom passage south",(-29,-12.2),(-2.75,-12.2),[(.29,.34),(.70,.75),(.85,.90)],1.02)
    wall("West connector",(-29,-12.2),(-29,-9),.8)
    for x in (-23.5,-17.5): panel("Passage noticeboard",x,-12.08,1.1,.48,z=.77)
    box("Fountain niche backing",-10.1,-12.08,.65,1.8,.18,1.3,"wall",.018)
    water_fountain(-10.1,-11.79)
    for x in (-8.1,-4.2): panel("Restroom · sign",x,-12.08,.18,.20,z=.86,color="metal")
    furniture("square-planter",-26.7,-11.4,scale=.68)
    # The main concourse continues into the lift core here.
    poi("Restrooms",-10.1,-10.6)


def third_floor():
    zone(3,"Lift and glazed stair landing")
    slab("Upper lift landing",-3.1,8.6,-9,-4.7,"tile")
    lift_bank()
    wall("Upper lobby east",(8.6,-9),(8.6,-4.7),1.02)
    glazed_wall("Main stair glazed enclosure",(3.05,-4.7),(6.90,-4.7),1.20)
    doorway("Main stair entry",(6.93,-4.7),(8.50,-4.7),closed=False)
    glazed_wall("Stair entry return",(3.05,-7.0),(3.05,-4.7),1.18)
    banquette(4.25,-5.12,2.00,180);banquette(6.53,-5.12,1.82,180)
    box("Stair lounge · wood table",5.44,-5.12,.3,.40,.55,.6,"wood",.025)
    column(3.63,-7.6,1.6)
    furniture("waste-bin",2.77,-7.6,scale=.84)
    poi("Main stair",6.6,-5.8)
    poi("Lifts",-.35,-7.55)

    zone(3,"Main stair · upper flight")
    emit(B.flight,"Main stair landing to 3",7.73,-1.1,-4.7,HEIGHT/2,HEIGHT,1.40,12)
    # The half landing is shared by the two flights in the combined model.
    emit(B.slab,"Main stair · half landing",5.38,8.45,-1.1,.22,HEIGHT/2,"tile",.18)
    emit(B.railing,"Main stair · half landing guard",(5.42,.18),(8.40,.18),HEIGHT/2,.91)
    wall("Stairwell window wall",(8.60,-4.7),(8.60,.22),.67)
    panel("Stairwell · high window",8.50,-.3,.60,.48,90,"glass",.65)

    zone(3,"Window-side lounge")
    slab("Long window lounge",-29,-3.1,-9,-3.9,"tile")
    wall("Window lounge north",(-29,-3.9),(-3.1,-3.9),.78)
    # Small high windows are one of the upper floor's clearest landmarks.
    for x in (-27.5,-24.7,-21.9,-19.1,-16.3,-13.5,-10.7,-7.9,-5.1):
        panel("Upper lounge · small window frame",x,-4.005,.78,.38,z=.55,color="cap")
        panel("Upper lounge · small window",x,-4.033,.64,.28,z=.55,color="glass")
    for i in range(13):
        x=-27.4+i*1.75
        furniture("lounge-chair",x,-4.58,180,scale=.93)
        if i%2==0 and i<12: furniture("small-drum-table",x+.86,-4.68,scale=.86)
    for x in (-24.7,-16.0,-7.3): furniture("waste-bin",x,-5.11,scale=.86)
    for x in (-26,-21,-16,-11,-6): slab("Window lounge · cross band",x-.15,x+.15,-8.85,-4.08,"floor",z=.005,depth=.008)
    for x in (-26.1,-20.5,-14.9,-9.3): panel("Upper lounge · wall poster",x,-4.025,.30,.30,z=.47,color="mural")
    poi("Window lounge",-17.5,-6.3)

    zone(3,"Mural corridor")
    # Outline the filmed circulation; closed suite interiors are not invented.
    slab("Mural corridor",-29,-3.1,-16.1,-12.3,"tile")
    slab("Mural corridor · west return",-32,-29,-16.1,-3.9,"tile")
    slab("Mural corridor · east return",-6.2,-3.1,-12.3,-9,"tile")
    wall("Mural corridor south",(-32,-16.1),(-3.1,-16.1),1.12)
    wall("Mural corridor west",(-32,-16.1),(-32,-3.9),1.1)
    wall("Mural corridor east",(-3.1,-16.1),(-3.1,-9),1.00)
    for i in range(9):
        x=-29.85+i*2.8
        panel("Campus mural · blue field",x,-15.995,2.44,.83,z=.68,color="mural")
        panel("Campus mural · pale accent",x-.65,-15.970,.60,.60,z=.68,color="mural-light")
        panel("Campus mural · vertical accent",x+.70,-15.958,.22,.83,z=.68,color="glass-accent")
    for y in (-13.8,-10.8,-7.8): panel("Campus mural return",-31.90,y,2.40,.83,90,"mural",.68)
    glazed_wall("Suite frontage south",(-28.9,-12.3),(-10.4,-12.3),1.1)
    glazed_wall("Suite frontage west",(-29,-12.3),(-29,-6.7),1.1)
    slab("Glazed suite · visible bench recess",-13.7,-10.4,-12.3,-11.0,"tile")
    banquette(-12.0,-11.13,2.25,180)
    # The upper mural branch's exact turn lengths are inferred.
    poi("Mural corridor",-21.8,-14.1)

    zone(3,"Restroom and gallery passage")
    slab("Upper restroom passage",-29,-6.2,-11.0,-9,"tile")
    facade("Upper restroom fronts",(-28.9,-11.0),(-6.2,-11.0),[(.15,.20),(.57,.63),(.80,.86)],.98)
    wall("Upper passage north",(-28.9,-9),(-13.3,-9),.76)
    glazed_wall("Upper lounge interior glazing",(-13.3,-9),(-10.7,-9),1.1)
    wall("Upper restroom return",(-10.7,-9),(-6.2,-9),.77)
    water_fountain(-15.25,-10.58)
    for x in (-18,-10.5): panel("Upper restroom notice",x,-10.91,.19,.20,z=.82,color="metal")
    for x in (-24.6,-21.3): panel("Upper passage · artwork",x,-10.91,.74,.48,z=.78,color="mural-light")
    furniture("square-planter",-27.95,-9.7,scale=.7)
    # The mural corridor's east return also serves the core connection.
    poi("Restrooms",-15.3,-10.15)


def exports(floors=(2, 3), floor_2_source=None):
    bpy.context.view_layer.update()
    for obj in B.MODEL:
        bpy.context.view_layer.objects.active=obj
        for mod in list(obj.modifiers): bpy.ops.object.modifier_apply(modifier=mod.name)
    spec=importlib.util.spec_from_file_location("usd_check",ROOT/"scripts/render-photo-furniture.py")
    checker=importlib.util.module_from_spec(spec);spec.loader.exec_module(checker)
    previous_validation = json.loads((OUT/"validation.json").read_text()) if (OUT/"validation.json").exists() else {}
    records=[]
    for name,objects in [("building",B.MODEL),("floor-2",[o for o in B.MODEL if o["floor"]==2]),("floor-3",[o for o in B.MODEL if o["floor"]==3])]:
        if name.startswith("floor-") and int(name[-1]) not in floors:
            records.extend(record for record in previous_validation.get("native_packages", []) if Path(record["file"]).stem == name)
            continue
        bpy.ops.object.select_all(action="DESELECT")
        for obj in objects: obj.select_set(True)
        bpy.context.view_layer.objects.active=objects[0]
        bpy.ops.export_scene.gltf(filepath=str(OUT/(name+".glb")),export_format="GLB",use_selection=True,export_yup=True,export_cameras=False,export_lights=False,export_extras=True)
        bpy.ops.wm.usd_export(filepath=str(OUT/(name+".usdz")),check_existing=False,selected_objects_only=True,export_animation=False,export_normals=True,export_materials=True,generate_preview_surface=True,export_textures=False,export_lights=False,export_cameras=False,export_hair=False,export_uvmaps=False,export_mesh_colors=False,export_armatures=False,export_shapekeys=False,export_curves=False,export_points=False,export_volumes=False,convert_world_material=False,convert_orientation=True,export_global_forward_selection="NEGATIVE_Z",export_global_up_selection="Y",convert_scene_units="METERS",root_prim_path="/Building",export_custom_properties=False)
        record=checker.validate_usdz(OUT/(name+".usdz"),len(objects));records.append(record)
    meshes=[];low=[float("inf")]*3;high=[-float("inf")]*3;counts={2:0,3:0}
    for obj in B.MODEL:
        mesh=obj.data;mesh.calc_loop_triangles();normal_matrix=obj.matrix_world.to_3x3().inverted().transposed()
        vertices=[];normals=[];indices=[];lookup={}
        for tri in mesh.loop_triangles:
            face=[]
            for li in tri.loops:
                p=obj.matrix_world @ mesh.vertices[mesh.loops[li].vertex_index].co
                n=(normal_matrix @ mesh.corner_normals[li].vector).normalized()
                p=[round(p.x,5),round(p.z,5),round(-p.y,5)];n=[round(n.x,5),round(n.z,5),round(-n.y,5)]
                for axis in range(3): low[axis]=min(low[axis],p[axis]);high[axis]=max(high[axis],p[axis])
                key=tuple(p+n)
                if key not in lookup: lookup[key]=len(vertices);vertices.append(p);normals.append(n)
                face.append(lookup[key])
            if len(set(face))==3: indices.append(face)
        counts[obj["floor"]]+=len(indices)
        meshes.append({"name":obj.name,"floor":obj["floor"],"zone":obj["zone"],"vertices":vertices,"normals":normals,"triangles":indices,"color":mesh.materials[0]["display_hex"]})
    data={"title":"Floors 2 & 3","floors":[{"id":2,"title":"Floor 2","elevation":0},{"id":3,"title":"Floor 3","elevation":HEIGHT}],"meshes":meshes,"bounds":{"min":low,"max":high},"labels":POIS}
    (OUT/"viewer-scene.json").write_text(json.dumps(data,separators=(",",":")))
    (OUT/"validation.json").write_text(json.dumps({"native_packages":records,"triangles_by_floor":counts,"mesh_count":len(meshes),"bounds_y_up_m":data["bounds"]},indent=2)+"\n")
    layout={"title":"Floors 2 & 3","reference_videos":["IMG_5439.MOV","IMG_5436.MOV"],"approximate":True,"navigation_ready":False,"units":"meters","up_axis":"Y","floor_elevations_m":{"2":0,"3":HEIGHT},"furniture":B.FURNITURE,"labels":POIS,
        "observed":[{"floor":2,"time":"0:00–0:24","area":"Carpeted lounge and internal room passage"},{"floor":2,"time":"0:28–1:04","area":"Atrium balcony, room 203, end doors marked 200, lift bank and stairs"},{"floor":2,"time":"1:08–1:28","area":"Modular seating, second railed opening, windowed desk area"},{"floor":2,"time":"1:32–2:24","area":"Gallery corridor branch, room recesses, art and benches"},{"floor":2,"time":"2:28–2:51","area":"Restroom passage, paired fountains, elevators marked 2"},{"floor":3,"time":"2:52–3:44","area":"Mural corridor, glazed suite fronts, elevator with floor 3 plaque"},{"floor":3,"time":"3:48–4:24","area":"Window-side armchairs, interior glazing, restroom passage"},{"floor":3,"time":"4:28–4:49","area":"Glazed bench landing and main stair descent"}],
        "estimated":["Every length, width, floor height, and furniture spacing","The footprints and relative orientation of the two railed openings","The turns and connection back from the gallery/restroom passages","The mural corridor's return shape and its exact alignment over floor 2","The alignment and riser count of the connecting main stair"],
        "not_modeled":["Closed room interiors not entered in the video","Unfilmed building wings","Ground floor","Photographic murals, faces, and personal belongings"],
        "video_discontinuity":"The footage cuts from lifts marked 2 at about 2:51 to the mural corridor at about 2:52. The ride/ascent is not shown; the floor-3 plaque is visible around 3:44.",
        "gallery_topology":"Modeled as a branch. The footage may retrace it; no additional through-connection is claimed.",
        "display_conventions":"Roofless cutaway walls and shortened glazing; split stair flights belong to their adjacent floor; separated preview adds a display-only vertical offset."}
    if floor_2_source is not None:
        layout["floor_2_source"] = floor_2_source
        layout["observed"] = [item for item in layout["observed"] if item["floor"] != 2]
        layout["observed"].insert(0, {"floor": 2, "area": "Earlier lounge scan and registered balcony-to-restroom scan", "source": floor_2_source["scan_id"]})
        layout["estimated"] = ["Furniture silhouettes, cutaway heights, and the unreviewed exterior floor envelope", "Floor 3 lengths, furniture spacing and elevation", "Inter-floor placement; no measured connection is established"]
        layout["not_modeled"] = ["Unscanned Floor 2 wings and closed room interiors", "Ground floor", "Photographic murals, faces, and personal belongings"]
        layout["gallery_topology"] = "The revised Floor 2 asset follows supplied scan structure. Unscanned video branches are retained in the earlier video-model archive, not placed into measured structure."
    (OUT/"layout.json").write_text(json.dumps(layout,indent=2)+"\n")
    print("MODEL_READY "+json.dumps({"meshes":len(meshes),"triangles":counts,"furniture":len(B.FURNITURE)}),flush=True)


def aim(obj,target): obj.rotation_euler=(Vector(target)-obj.location).to_track_quat("-Z","Y").to_euler()


def frame_camera(camera,objects,width,height,direction=(.62,.82,.86),margin=1.14):
    points=[obj.matrix_world @ Vector(v) for obj in objects for v in obj.bound_box]
    low=Vector([min(p[i] for p in points) for i in range(3)]);high=Vector([max(p[i] for p in points) for i in range(3)])
    center=(low+high)/2;direction=Vector(direction).normalized();camera.location=center+direction*150;aim(camera,center)
    right=camera.rotation_euler.to_quaternion() @ Vector((1,0,0));up=camera.rotation_euler.to_quaternion() @ Vector((0,1,0))
    hx=[(p-center).dot(right) for p in points];vy=[(p-center).dot(up) for p in points]
    camera.location+=right*((max(hx)+min(hx))/2)+up*((max(vy)+min(vy))/2)
    camera.data.ortho_scale=max(max(hx)-min(hx),(max(vy)-min(vy))*width/height)*margin


def renders(samples, floors=(2, 3)):
    scene=bpy.context.scene
    ground=B.box("Studio ground",(-16,-2,-.41),(260,260,.1),"#e9ede7",0);B.MODEL.remove(ground)
    world=bpy.data.worlds.new("Soft daylight");world.use_nodes=True
    world.node_tree.nodes["Background"].inputs["Color"].default_value=(.86,.87,.87,1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value=.65;scene.world=world
    for name,pos,power,size in [("Wide key",(-27,-4,42),8000,27),("Atrium fill",(16,18,31),4200,24)]:
        data=bpy.data.lights.new(name,"AREA");data.energy=power;data.shape="DISK";data.size=size
        obj=bpy.data.objects.new(name,data);scene.collection.objects.link(obj);obj.location=pos;aim(obj,(-15,-2,1))
    bpy.ops.object.camera_add();camera=bpy.context.object;camera.name="Map camera";camera.data.type="ORTHO";scene.camera=camera
    scene.render.engine="CYCLES";scene.cycles.device="CPU";scene.cycles.samples=samples;scene.cycles.use_denoising=True;scene.cycles.max_bounces=4
    scene.render.image_settings.file_format="PNG";scene.render.image_settings.color_mode="RGB"
    scene.view_settings.view_transform="Standard";scene.view_settings.look="None";scene.view_settings.exposure=0
    scene.render.resolution_percentage=100
    by_floor={f:[o for o in B.MODEL if o["floor"]==f] for f in (2,3)}
    def render(name,objects,top=False):
        width,height=(2100,1550) if not top else (2100,1450)
        scene.render.resolution_x=width;scene.render.resolution_y=height
        frame_camera(camera,objects,width,height,(0,.001,1) if top else (.62,.82,.90),1.13)
        scene.render.filepath=str(OUT/(name+".png"));bpy.ops.render.render(write_still=True)
    # Save the source at true elevations, with all floors available as collections.
    frame_camera(camera,B.MODEL,2300,1700)
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT/"building.blend"))
    for floor in floors:
        for obj in B.MODEL: obj.hide_render=obj["floor"]!=floor
        ground.location.z=(-.41 if floor==2 else HEIGHT-2.31)
        render(f"floor-{floor}",by_floor[floor])
        render(f"floor-{floor}-plan",by_floor[floor],True)
    for obj in B.MODEL: obj.hide_render=False
    ground.location.z=-.41
    # Separated presentation only; exported assets and saved blend stay true-height.
    for obj in by_floor[3]: obj.location.z+=11.0
    bpy.context.view_layer.update()
    render("preview",B.MODEL)
    for obj in by_floor[3]: obj.location.z-=11.0
    bpy.context.view_layer.update()
    print("RENDERS_READY",flush=True)


if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--samples",type=int,default=24);parser.add_argument("--skip-render",action="store_true")
    args=parser.parse_args(sys.argv[sys.argv.index("--")+1:] if "--" in sys.argv else [])
    OUT.mkdir(parents=True,exist_ok=True);bpy.context.preferences.filepaths.save_version=0
    bpy.ops.object.select_all(action="SELECT");bpy.ops.object.delete(use_global=False)
    bpy.context.scene.unit_settings.system="METRIC";bpy.context.scene.unit_settings.scale_length=1
    for f in (2,3):
        col=bpy.data.collections.new(f"Floor {f}");bpy.context.scene.collection.children.link(col);COLLECTIONS[f]=col
    B.CAT={m["id"]:m for m in json.loads(B.CATALOG.read_text())["models"]}
    low_detail_catalogue();second_floor();third_floor();exports()
    if not args.skip_render: renders(args.samples)
