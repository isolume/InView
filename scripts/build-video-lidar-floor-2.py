#!/usr/bin/env python3
"""Build the reviewed Floor 2 reconstruction in Blender; retain Floor 3.

Blender --background --factory-startup --python-exit-code 1
  --python scripts/build-video-lidar-floor-2.py -- --samples 24

The compact reconstruction specification is in scan principal-axis meters.
Its rigid registration and the inverse app registration preserve scan scale
when the asset is displayed in InView. It supplies no routing geometry.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
from pathlib import Path
import sys
import tempfile
import zipfile

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "models/walkthrough-building/floors-2-3"
EVIDENCE = ROOT / "models/walkthrough-building/floor-2-reconstruction"
ARCHIVE = ROOT / "models/walkthrough-building/floors-2-3-video.zip"
spec = importlib.util.spec_from_file_location("scan_builder", ROOT / "scripts/build-scanned-floor-2.py")
S = importlib.util.module_from_spec(spec)
spec.loader.exec_module(S)
F, B = S.F, S.B


def read(path): return json.loads(path.read_text())


class Builder:
    def __init__(self, source):
        self.source = source
        self.reg = read(EVIDENCE / "registration.json")
        venue = read(ROOT / "InView/Resources/StudentCenter/student-center-east-floor-2.json")
        self.map_point, self.scale, _ = S.registration(venue)
        self.A = source["principal_axis_matrix"]
        self.theta = self.reg["horizontal_rotation_radians"]

    def point(self, uv, height=0):
        # UV = A * scan XZ; A is orthonormal.
        u, v = uv
        x = self.A[0][0] * u + self.A[1][0] * v
        z = self.A[0][1] * u + self.A[1][1] * v
        c, s = math.cos(self.theta), math.sin(self.theta)
        tx, tz = self.reg["translation_xz_m"]
        px, py = self.map_point(c*x-s*z+tx, s*x+c*z+tz)
        return (px, py, height/self.scale)

    def angle(self, angle_degrees):
        a = math.radians(angle_degrees)
        origin, along = Vector(self.point((0, 0))), Vector(self.point((math.cos(a), math.sin(a))))
        return math.atan2(along.y-origin.y, along.x-origin.x)

    def stamp(self, start, record):
        S.stamp(start, record["id"])
        for obj in B.MODEL[start:]:
            obj["zone"] = record.get("zone", "Second floor")
            obj["evidence"] = record.get("evidence", "video_and_lidar")

    def floor(self, record):
        vertices = [self.point(p) for p in record["vertices_uv"]]
        # UV->Blender has negative determinant; reverse the top face winding.
        faces = [list(reversed(t)) for t in record["triangles"]]
        mesh = bpy.data.meshes.new(record["id"])
        mesh.from_pydata(vertices, [], faces)
        mesh.update()
        mesh.materials.append(B.material(record.get("material", "floor")))
        obj = bpy.data.objects.new("Floor 2 · " + record["id"], mesh)
        bpy.context.scene.collection.objects.link(obj)
        solid = obj.modifiers.new("Continuous floor slab", "SOLIDIFY")
        solid.thickness = .18/self.scale
        solid.offset = -1
        start = len(B.MODEL)
        B.MODEL.append(obj)
        self.stamp(start, record)

    def wall(self, record):
        start = len(B.MODEL)
        a, b = self.point(record["a"]), self.point(record["b"])
        height = record.get("height", 1.15)/self.scale
        name = "Floor 2 · " + record["id"]
        if record.get("kind") == "rail":
            # Five horizontal rods and spaced upright posts, as in the video.
            length = math.dist(a, b)
            count = max(1, math.ceil(length*self.scale/1.45))
            for i in range(count+1):
                p = Vector(a).lerp(Vector(b), i/count)
                B.beam(name+" · post", p, p+Vector((0,0,height)), .023/self.scale, "rail")
            for h in (.17,.34,.51,.68,.85):
                B.beam(name+" · rod", (a[0],a[1],h/self.scale), (b[0],b[1],h/self.scale), .012/self.scale,"rail")
            B.beam(name+" · handrail", (a[0],a[1],height), (b[0],b[1],height), .038/self.scale,"metal")
        elif record.get("kind") == "glass":
            count = max(1,math.ceil(math.dist(a,b)*self.scale/1.4))
            yaw = math.atan2(b[1]-a[1],b[0]-a[0])
            for i in range(count):
                p = Vector(a).lerp(Vector(b),(i+.5)/count)
                obj = B.box(name+" · glazing", (p.x,p.y,height/2), (math.dist(a,b)/count-.055/self.scale,.032/self.scale,height-.10/self.scale), "glass", .005)
                obj.rotation_euler.z=yaw
            for i in range(count+1):
                p=Vector(a).lerp(Vector(b),i/count)
                B.beam(name+" · mullion",p,p+Vector((0,0,height)),.023/self.scale,"metal")
        else:
            B.wall(name,a[:2],b[:2],height,thickness=record.get("thickness",.14)/self.scale,color=record.get("material","wall"))
        self.stamp(start,record)

    def local_box(self, name, uv, size, z, angle=0, color="wall", bevel=.025):
        obj=B.box(name,self.point(uv,z),tuple(v/self.scale for v in size),color,bevel/self.scale)
        obj.rotation_euler.z=self.angle(angle)
        return obj

    def furnishing(self, record):
        start=len(B.MODEL)
        name="Floor 2 · "+record["id"]
        uv=record["center_uv"]
        width,depth,height=record["dimensions_m"]
        angle=record.get("angle_degrees",0)
        a=math.radians(angle)
        def at(x,y): return [uv[0]+x*math.cos(a)-y*math.sin(a),uv[1]+x*math.sin(a)+y*math.cos(a)]
        def box(suffix,x,y,z,w,d,h,color,bevel=.025):
            return self.local_box(name+" · "+suffix,at(x,y),(w,d,h),z,angle,color,bevel)
        kind=record["kind"]
        if kind in ("lounge-chair","modular-sofa","drum-table","planter","waste-bin"):
            key={"drum-table":"large-drum-table","planter":"square-planter"}.get(kind,kind)
            cx,cy,_=self.point(uv)
            B.furniture(key,cx,cy,math.degrees(self.angle(angle)))
            dim=B.CAT[key]["dimensions_m"]
            sx,sy,sz=width/dim[0]/self.scale,depth/dim[2]/self.scale,height/dim[1]/self.scale
            for obj in B.MODEL[start:]: obj.scale=(sx,sy,sz)
            B.FURNITURE[-1].update({"floor":2,"zone":record.get("zone","Second floor"),"source_id":record["id"],"dimensions_m":[width,height,depth],"evidence":record.get("evidence")})
        elif kind in ("bench","sofa"):
            box("base",0,0,height*.40,width-.05,depth-.05,height*.72,"metal",.015)
            box("seat",0,0,height*.86,width,depth,height*.28,record.get("material","seat"),.05)
            if kind=="sofa":
                box("back",0,-depth*.36,height*1.30,width,depth*.22,height*.85,"ochre",.04)
        elif kind=="modular-island":
            box("plinth",0,0,.14,width-.08,depth-.08,.28,"dark",.04)
            box("cushion",0,0,.38,width,depth,.22,"upholstery",.08)
            for dx in (-width*.24,width*.24):
                box("back",dx,depth*.18,.72,width*.35,.30,.56,"ochre",.035)
            box("side table",width*.36,-depth*.22,.51,width*.20,depth*.42,.045,"tile",.01)
        elif kind=="table":
            box("top",0,0,height-.025,width,depth,.05,"wood",.02)
            for dx in (-width*.35,width*.35):
                box("leg",dx,0,(height-.06)/2,.05,depth*.7,height-.06,"metal",.01)
        elif kind=="pedestal-table":
            p=self.point(uv)
            B.beam(name+" · stem",p,(p[0],p[1],(height-.04)/self.scale),.042/self.scale,"metal")
            B.beam(name+" · foot",(p[0],p[1],.01/self.scale),(p[0],p[1],.035/self.scale),width*.32/self.scale,"metal")
            B.beam(name+" · top",(p[0],p[1],(height-.045)/self.scale),(p[0],p[1],height/self.scale),width/2/self.scale,"tile")
        elif kind=="stool":
            seat=height*.64
            box("seat",0,0,seat,width,depth,.08,"seat",.035)
            box("back",0,-depth*.42,(seat+height)/2,width,.06,height-seat,"seat",.03)
            for dx in (-width*.4,width*.4):
                for dy in (-depth*.38,depth*.38):box("leg",dx,dy,seat/2,.027,.027,seat,"metal",.005)
        elif kind=="column":
            p=self.point(uv)
            B.beam(name+" · column",p,(p[0],p[1],height/self.scale),width/2/self.scale,"metal")
            B.beam(name+" · blue base",p,(p[0],p[1],.48/self.scale),(width/2+.008)/self.scale,"accent")
        elif kind=="fountain":
            box("body",0,0,height*.53,width*.76,depth*.80,height*.72,"metal",.055)
            box("basin",0,0,height,width,depth,.10,"metal",.045)
            box("bowl",0,0,height+.052,width*.68,depth*.60,.018,"dark",.04)
            box("tap",0,-depth*.25,height+.10,.055,.055,.09,"metal",.012)
        elif kind in ("cabinet","recycling"):
            box("body",0,0,height/2,width,depth,height,"dark",.03)
            if kind=="recycling":
                for dx in (-width*.24,width*.24): box("label",dx,depth/2+.008,height*.49,width*.36,.015,height*.55,"tile",.006)
            else:
                for z in (height*.35,height*.68): box("shelf",0,depth/2+.008,z,width*.8,.012,height*.18,"metal",.005)
        elif kind=="door":
            box("leaf",0,0,height/2,width,depth,height,record.get("material","door"),.012)
            if record.get("glazed"):
                box("window",0,depth/2+.006,height*.67,width*.65,.015,height*.45,"glass",.006)
        else:
            raise ValueError("Unknown furnishing type "+kind)
        self.stamp(start,record)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples",type=int,default=24)
    parser.add_argument("--skip-render",action="store_true")
    args=parser.parse_args(sys.argv[sys.argv.index("--")+1:] if "--" in sys.argv else [])
    data=read(EVIDENCE/"reconstruction.json")
    B.PALETTE.update({"wall":"#e5e4de","cap":"#f4f2ed","floor":"#b9b8ae","carpet":"#aab7bc",
                      "seat":"#727e98","upholstery":"#829895","wood":"#ccbfa2","ochre":"#c5b783",
                      "rail":"#637890","metal":"#a4afad","dark":"#687577","door":"#a2adb2",
                      "glass":"#bdd1d0","accent":"#738cab","tile":"#e4e0d3"})
    with zipfile.ZipFile(ARCHIVE) as archive,tempfile.TemporaryDirectory(prefix="inview-baseline-") as directory:
        F.restore_floor_exports(archive, (3,))
        source=Path(directory)/"building.blend"
        source.write_bytes(archive.read("floors-2-3/building.blend"))
        baseline=json.loads(archive.read("floors-2-3/layout.json"))
        bpy.ops.wm.open_mainfile(filepath=str(source))
    for obj in list(bpy.data.objects):
        if obj.get("floor")!=3:bpy.data.objects.remove(obj,do_unlink=True)
    B.MODEL[:]=[obj for obj in bpy.data.objects if obj.get("floor")==3]
    for obj in B.MODEL:obj.hide_render=False
    for f in (2,3):
        F.COLLECTIONS[f]=bpy.data.collections.get(f"Floor {f}") or bpy.data.collections.new(f"Floor {f}")
        if F.COLLECTIONS[f].name not in bpy.context.scene.collection.children:bpy.context.scene.collection.children.link(F.COLLECTIONS[f])
    B.CAT={x["id"]:x for x in read(B.CATALOG)["models"]}
    B.FURNITURE[:]=[x for x in baseline["furniture"] if x["floor"]==3]
    F.POIS[:]=[x for x in baseline["labels"] if x["floor"]==3]
    builder=Builder(data)
    for item in data["floors"]:builder.floor(item)
    for item in data["walls"]:builder.wall(item)
    for item in data["furniture"]:builder.furnishing(item)
    for item in data["labels"]:
        x,y,z=builder.point(item["position_uv"],.6)
        F.POIS.append({"floor":2,"title":item["title"],"position":[x,z,-y]})
    manifest=read(EVIDENCE/"manifest.json")
    provenance={"scan_id":manifest["capture_id"],"source":"synchronized video, LiDAR and RoomPlan",
                "reconstruction_sha256":S.digest(EVIDENCE/"reconstruction.json"),
                "registration":"rigid lounge registration; 4.97 cm fitted endpoint RMS",
                "asset_frame":"inverse existing elevator display registration; floor 3 unchanged",
                "floor_area_m2":sum(x["area_m2"] for x in data["floors"]),
                "routing_coverage":False,"geometry_manifest":"../floor-2-reconstruction/manifest.json"}
    F.exports(floors=(2,),floor_2_source=provenance)
    layout=read(OUT/"layout.json")
    layout["reference_videos"]=[manifest["capture_id"]+".inviewvideo.tar","IMG_5439.MOV"]
    layout["observed"][0]={"floor":2,"area":"Lounge, atrium balconies, gallery, restroom passage and west seating","source":manifest["capture_id"],"video_duration_seconds":351.5}
    layout["estimated"]=["Clean floor boundaries beneath furniture, simplified silhouettes, flattened floor and cutaway wall heights","RoomPlan and depth alignment retain local AR tracking drift","Floor 3 dimensions and the relationship between levels"]
    layout["gallery_topology"]="One continuous measured U-shaped circulation network with its filmed spurs; unobserved interior remains empty."
    layout["display_conventions"]="One clean Floor 2 reconstruction; roofless cutaway, muted materials and simplified furnishings. No camera imagery or people embedded."
    (OUT/"layout.json").write_text(json.dumps(layout,indent=2)+"\n")
    bpy.context.preferences.filepaths.save_version=0
    if args.skip_render:
        bpy.ops.wm.save_as_mainfile(filepath=str(OUT/"building.blend"))
    else:F.renders(args.samples,floors=(2,))


if __name__=="__main__":main()
