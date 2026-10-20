#!/usr/bin/env python3
"""Assemble the reviewed visual floor specification (NumPy + Shapely 2 required).

Inputs are compact depth/RoomPlan fits and video-identified furniture in
models/walkthrough-building/floor-2-reconstruction. Original sensor bytes are
identified by their hashes in manifest.json and remain outside the app bundle.
The floor outline is a reviewed architectural simplification of measured depth,
with the earlier measured lounge outline completing occlusions under furniture.
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
from pathlib import Path

import numpy as np
from shapely import constrained_delaunay_triangles
from shapely.geometry import Polygon, LineString, Point, box
from shapely.ops import unary_union
from shapely.geometry.polygon import orient

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"models/walkthrough-building/floor-2-reconstruction"
A=np.array([[.9255238,-.3786894],[.3786894,.9255238]])


def read(name):return json.loads((OUT/name).read_text())
def save(name,data): (OUT/name).write_text(json.dumps(data,indent=2,allow_nan=False)+"\n")


def floor_record(polygon,identifier,material):
    # Boolean joins can retain numerically collinear vertices. Remove these
    # sub-micron redundancies before triangulation so float32 exports cannot
    # turn microscopic slivers into collapsed faces.
    polygon=orient(polygon.simplify(1e-6,preserve_topology=True),sign=1)
    vertices=[];triangles=[];lookup={}
    for triangle in constrained_delaunay_triangles(polygon).geoms:
        # GEOS can still emit zero-area faces between collinear join points.
        if triangle.area<1e-10:continue
        coords=list(orient(triangle,sign=1).exterior.coords)[:-1]
        face=[]
        for p in coords:
            key=tuple(round(float(v),7) for v in p)
            if key not in lookup:lookup[key]=len(vertices);vertices.append(list(key))
            face.append(lookup[key])
        triangles.append(face)
    pieces=[Polygon([vertices[i] for i in face]) for face in triangles]
    covered=unary_union(pieces)
    assert min(p.area for p in pieces)>1e-8, f"Degenerate floor triangle: {identifier}"
    assert covered.symmetric_difference(polygon).area<1e-5, f"Incomplete floor triangulation: {identifier}"
    assert sum(p.area for p in pieces)-covered.area<1e-6, f"Overlapping floor triangles: {identifier}"
    return {"id":identifier,"material":material,"outer_uv":list(polygon.exterior.coords)[:-1],
            "holes_uv":[list(r.coords)[:-1] for r in polygon.interiors],"vertices_uv":vertices,
            "triangles":triangles,"area_m2":polygon.area,"routing_coverage":False,
            "evidence":"reviewed_depth_outline_and_measured_lounge"}


def main():
    structural=read("structural-evidence.json")
    reg=read("registration.json")
    furniture=read("furnishing-evidence.json")
    cafe_evidence=read("cafe-evidence.json")
    source=read("source-geometry.json")
    original=json.loads((ROOT/"models/walkthrough-building/floor-2-evidence/original-floor-2.json").read_text())
    t=reg["horizontal_rotation_radians"];R=np.array([[math.cos(t),-math.sin(t)],[math.sin(t),math.cos(t)]])
    def previous_uv(points):return (np.array(points)-reg["translation_xz_m"])@R@A.T
    # The floor is bounded by measured wall lines, video/depth railing anchors,
    # and floor observations. It deliberately does not bridge the open atrium
    # or put floors into rooms whose interiors were not scanned.
    lounge=Polygon(previous_uv(original["footprints"][1]["polygon"]))
    balcony=Polygon([[-23.92,-9.47],[-21.15,-9.47],[-21.15,-7.25],[19.42,-7.25],
                     [19.42,-5.12],[16.62,-5.12],[16.62,.08],[15.12,.08],
                     [15.12,-5.12],[10.57,-5.12],[10.57,-4.12],[9.1,-4.12],
                     [9.1,-5.12],[1.87,-5.12],[1.87,-3.82],[.27,-3.82],
                     [.27,-5.12],[-19.23,-5.12],[-19.23,-.22],[-23.23,-.22],
                     [-23.23,7.33],[-21.5,7.33],[-21.5,8.35],[-22.85,8.35],
                     [-22.85,10.05],[-23.23,10.05],
                     [-23.23,12.625],[-22.53,12.625],[-22.53,13.7],[-23.23,13.7],
                     [-23.23,17.1],[-22.2,17.1],[-22.2,18.53],[-23.23,18.53],
                     [-23.23,31.925],[-26.03,31.925],[-26.03,11],[-25.85,-.3],[-25.23,-4.26]])
    seating=Polygon([[-30.1,8.25],[-25.8,9.6],[-25.9,11],[-23.23,11],
                     [-23.23,-.22],[-19.23,-.22],[-19.23,-5.12],[-21.4,-5.12],
                     [-24,-5.0],[-26.9,-3.4],[-28.0,.1],[-29.1,3.6],[-30.1,6.9]])
    gallery=Polygon([[-26.03,29.66],[-13.04,29.66],[-13.04,28.78],[-11.48,28.78],
                     [-11.48,29.66],[-7.2,29.66],[-7.2,29.375],[16.97,29.375],
                     [16.97,32.32],[15,32.32],[15,33.18],[12.02,33.18],
                     [12.02,32.213],[6.18,32.213],[6.18,31.925],[5.4,31.925],[5.4,33.18],[3.42,33.18],
                     [3.42,31.925],[-16.8,31.925],[-16.8,32.825],[-18.18,32.825],
                     [-18.18,31.925],[-26.03,31.925]])
    spur=Polygon([[-7.23,31.9],[-4.58,31.9],[-4.58,41.337],[-7.23,41.337]])
    cafe=Polygon([[-37.2,33.5],[-35,32.1],[-32,32.1],[-29.4,33],[-27.5,33.4],[-26.03,29.1],
                  [-23.23,29.1],[-23.23,35.25],[-22.18,35.25],[-22.18,36.98],
                  [-32.4,36.98],[-32.4,37.95],[-37.2,37.95]])
    for polygon in [lounge,balcony,seating,gallery,spur,cafe]:
        assert polygon.is_valid and polygon.area>0
    # Union a 12cm threshold overlap to join the independent lounge scan's
    # roughly 5cm boundary residual without retaining duplicate floor layers.
    threshold=Polygon([[-2.85,-5.2],[4.5,-5.2],[4.5,-4.85],[-2.85,-4.85]])
    # The two captures leave a 2cm sliver at the measured lounge doorway.
    # Complete its threshold between the existing jambs, inside the earlier
    # measured floor; a route must not cross an empty seam in the illustration.
    lounge_door_threshold=box(.27,-3.84,1.87,-3.77)
    recycling_pad=box(-28.35,28.75,-25.9,30.2)
    floor=unary_union([lounge,balcony,seating,gallery,spur,cafe,threshold,lounge_door_threshold,recycling_pad])
    assert floor.geom_type=="Polygon" and floor.is_valid
    tile=floor.difference(lounge)
    assert tile.geom_type=="Polygon"
    floors=[floor_record(tile,"continuous-tile-floor","floor"),floor_record(lounge,"lounge-carpet","carpet")]

    # These are back faces glimpsed inside unentered recesses. Keeping them
    # would leave detached walls outside the reviewed floor outline.
    omitted_walls={"wall-49":"secondary face behind the landing wall",
                   "wall-66":"isolated return inside an unentered room"}
    walls=[copy.deepcopy(w) for w in structural["walls"] if w["id"] not in omitted_walls]
    by_id={w["id"]:w for w in walls}
    for repair in read("structural-repairs.json")["repairs"]:
        if repair["action"]=="replace_endpoints":by_id[repair["wall_id"]]["ends_uv"]=repair["ends_uv"]
        else:walls.append({"id":repair["id"],"ends_uv":repair["ends_uv"],"source":"depth_supported_repair","source_ids":[]})
    # Complete only the revisited lounge from its earlier measured walls. The
    # newer long walk has lost several of these surfaces from its final state.
    existing=unary_union([LineString(w["ends_uv"]).buffer(.18,cap_style="square") for w in walls])
    for i in [*range(10,27),35,37]:
        old=original["footprints"][i]
        c=np.array(old["center"]);axis=np.array([math.cos(old["yaw"]),math.sin(old["yaw"])])
        endpoints=previous_uv([c-axis*old["size"][0]/2,c+axis*old["size"][0]/2])
        line=LineString(endpoints)
        if line.difference(existing).length>.30:
            # Use full source segments for a clean join, suppress overlapping
            # new fragments on this particular measured lounge wall only.
            nearby=line.buffer(.20,cap_style="square")
            retained=[]
            for w in walls:
                q=LineString(w["ends_uv"])
                if nearby.covers(q):continue
                retained.append(w)
            walls=retained
            walls.append({"id":f"retained-lounge-wall-{i}","ends_uv":endpoints.tolist(),"source":"registered_previous_lounge_measurement","source_ids":[str(i)]})
    # Snap measured near-joins to one corner; do not stretch distant fragments.
    for wall in walls:
        p=np.array(wall["ends_uv"]);direction=p[1]-p[0]
        axis=int(abs(direction[1])>abs(direction[0]))
        for i in (0,1):
            candidates=[]
            for other in walls:
                if other is wall:continue
                q=np.array(other["ends_uv"]);delta=q[1]-q[0]
                if int(abs(delta[1])>abs(delta[0]))==axis:continue
                intersection=p[i].copy();intersection[axis]=q[0,axis]
                if np.linalg.norm(intersection-p[i])<.18 and min(np.linalg.norm(intersection-q[0]),np.linalg.norm(intersection-q[1]))<.18:
                    candidates.append(intersection)
            if candidates:p[i]=min(candidates,key=lambda x:np.linalg.norm(x-p[i]))
        wall["ends_uv"]=p.tolist()

    # Native door widths cut actual holes in the wall mesh.
    doors=copy.deepcopy(structural["doors"])
    for i in [*range(39,47),49,50,52]:
        old=original["footprints"][i];c=np.array(old["center"]);axis=np.array([math.cos(old["yaw"]),math.sin(old["yaw"])])
        endpoints=previous_uv([c-axis*old["size"][0]/2,c+axis*old["size"][0]/2]);center=endpoints.mean(axis=0)
        if any(np.linalg.norm(center-np.mean(d["ends_uv"],axis=0))<.35 for d in doors):continue
        doors.append({"id":f"retained-lounge-door-{i}","ends_uv":endpoints.tolist()})
    openings=[{"id":d["id"],"ends_uv":d["ends_uv"]} for d in doors]
    # The filmed passage continues through this overhead portal. Depth high in
    # the opening was also recorded as a full wall; retain the side piers only.
    openings.append({"id":"restroom-passage-portal","ends_uv":[[-6.95,39.16],[-4.9,39.16]]})
    glazing=[]
    for glass in cafe_evidence["glazing"]:
        a,b=np.array(glass["endpoints_xz_m"])@A.T
        openings.append({"id":glass["id"],"ends_uv":[a.tolist(),b.tolist()]})
        glazing.append({"id":glass["id"],"a":a.tolist(),"b":b.tolist(),"kind":"glass","height":1.30,"evidence":"paired_video_depth_frame_edges"})
    clean=[]
    for wall in walls:
        a,b=np.array(wall["ends_uv"]);delta=b-a;length=np.linalg.norm(delta);direction=delta/length
        cuts=[]
        for opening in openings:
            q=np.array(opening["ends_uv"])
            if max(abs(direction[0]*(p-a)[1]-direction[1]*(p-a)[0]) for p in q)>.22:continue
            t=(q-a)@direction
            lo,hi=max(0,min(t)),min(length,max(t))
            if hi>lo:cuts.append((lo,hi))
        cursor=0;intervals=[]
        for lo,hi in sorted(cuts):
            if lo>cursor+.06:intervals.append((cursor,lo))
            cursor=max(cursor,hi)
        if cursor<length-.06:intervals.append((cursor,length))
        for i,(lo,hi) in enumerate(intervals):
            p,q=a+direction*lo,a+direction*hi
            if hi-lo<.10:continue
            clean.append({"id":wall["id"]+f"-{i}","a":p.tolist(),"b":q.tolist(),"height":1.15,
                          "thickness":.14,"evidence":wall.get("source","depth"),"source_ids":wall.get("source_ids",[])})
    # Railing positions come from the same video/depth frame pairs. The east
    # balcony edge is evident along the floor boundary in both scan captures.
    rail_lines=[("long-atrium-rail",[-26.03,28.75],[-25.85,10.5]),
                ("gallery-rail-return",[-28.35,28.75],[-26.03,28.75]),
                ("lower-balcony-rail",[-20.5,-7.25],[19.42,-7.25])]
    for identifier,a,b in rail_lines:
        clean.append({"id":identifier,"a":a,"b":b,"kind":"rail","height":1.03,"evidence":"video_and_depth_edge_anchors"})
    clean.extend(glazing)

    objects=[]
    category={"backless_bench":"bench","rectangular_planter":"planter","wall_fountain":"fountain",
              "three_module_sofa":"sofa","cabinet":"cabinet","recycling_cabinet":"recycling",
              "modular_seating_island":"modular-island","round_column":"column",
              "round_high_table":"pedestal-table","half_round_table":"table","round_coffee_table":"drum-table",
              "high_stool":"stool","swivel_lounge_chair":"lounge-chair","tub_chair":"lounge-chair"}
    for obj in furniture["objects"]+cafe_evidence["objects"]:
        center=A@obj["center_xz_m"];axis=A@obj["long_axis_xz"]
        width,height,depth=obj["size_m"]
        if obj["category"]=="round_column":height=1.65
        if obj["category"]=="three_module_sofa":height=.47
        objects.append({"id":obj["id"],"kind":category[obj["category"]],"center_uv":center.tolist(),
                        "dimensions_m":[width,depth,height],"angle_degrees":math.degrees(math.atan2(axis[1],axis[0])),
                        "uncertainty_m":obj["uncertainty_m"],"evidence":"paired_video_depth","material":"ochre" if obj["category"]=="three_module_sofa" else "seat"})
    # Earlier scan measured the complete lounge furniture that RoomPlan later
    # dropped from its six-object final result. Retain it in the registered room.
    for i,obj in enumerate(original["footprints"]):
        if obj["kind"]!="obstacle" or obj.get("furniture") not in ("sofa","table","chair"):continue
        uv=(np.array(obj["center"])-reg["translation_xz_m"])@R@A.T
        if not lounge.buffer(.2).covers(Point(uv)):continue
        axis=np.array([math.cos(obj["yaw"]),math.sin(obj["yaw"])])@R@A.T
        w,d=obj["size"];h=obj.get("height",.8)
        kind="modular-sofa" if obj.get("furniture")=="sofa" and w>1.3 else "lounge-chair"
        if obj.get("furniture")=="table":kind="drum-table" if abs(w-d)/max(w,d)<.28 else "table"
        objects.append({"id":f"measured-lounge-{i}","kind":kind,"center_uv":uv.tolist(),"dimensions_m":[w,d,h],
                        "angle_degrees":math.degrees(math.atan2(axis[1],axis[0])),"evidence":"registered_previous_lounge_measurement","zone":"Lounge"})
    # New RoomPlan door surfaces preserve their measured width and position.
    for door in doors:
        a,b=np.array(door["ends_uv"]);axis=b-a
        elevator=door["id"] in ("retained-lounge-door-49","retained-lounge-door-50")
        count=2 if elevator else 1
        for leaf in range(count):
            center=a+axis*((leaf+.5)/count)
            objects.append({"id":door["id"]+f"-leaf-{leaf}","kind":"door","center_uv":center.tolist(),
                            "dimensions_m":[float(np.linalg.norm(axis))/count-.035,.045,1.06],
                            "angle_degrees":math.degrees(math.atan2(axis[1],axis[0])),
                            "evidence":"retained_measured_roomplan" if door["id"].startswith("retained") else "native_roomplan",
                            "glazed":not elevator})
    labels=[{"title":"Lounge","position_uv":[1,0]}, {"title":"Balcony","position_uv":[-5,-6.1]},
            {"title":"Lifts","position_uv":[-22.6,-7.1]}, {"title":"Gallery","position_uv":[1,30.8]},
            {"title":"Restroom passage","position_uv":[-5.8,36]},
            {"title":"Seating","position_uv":[-26.7,4]}, {"title":"West seating","position_uv":[-31.5,35.7]}]
    result={"schema_version":1,"coordinate_frame":"scan_principal_uv","principal_axis_matrix":A.tolist(),
            "floor_y_m":reg["source_native_floor_y_m"],"floor_is_flattened":True,"routing_coverage":False,
            "floors":floors,"walls":clean,"furniture":objects,"labels":labels,
            "omitted_interior_wall_fragments":omitted_walls}
    for obj in objects:
        if obj["kind"]=="door":continue
        w,d,_=obj["dimensions_m"];angle=math.radians(obj["angle_degrees"])
        rotation=np.array([[math.cos(angle),-math.sin(angle)],[math.sin(angle),math.cos(angle)]])
        footprint=Polygon(np.array([[-w/2,-d/2],[w/2,-d/2],[w/2,d/2],[-w/2,d/2]])@rotation.T+obj["center_uv"])
        assert footprint.difference(floor.buffer(.08)).area<.01, f"Furniture extends beyond floor: {obj['id']}"
    for wall in clean:
        assert LineString([wall["a"],wall["b"]]).difference(floor.buffer(.22)).length<.30, f"Detached wall: {wall['id']}"
    save("reconstruction.json",result)
    evidence=read("floor-evidence.json")
    measured=unary_union([Polygon(p["outer_uv"],p.get("holes_uv",[])) for p in evidence["polygons"]])
    report={"floor_area_m2":floor.area,"measured_depth_support_area_m2":measured.area,
            "clean_floor_within_35cm_depth_support_m2":floor.intersection(measured.buffer(.35)).area,
            "lounge_completed_from_prior_measurements_m2":lounge.area,
            "floor_components":1,"overlapping_floor_material_area_m2":tile.intersection(lounge).area,
            "wall_segments":len(clean),"furnishings":len(objects),"triangles":sum(len(f["triangles"]) for f in floors),
            "notes":["Floor silhouette is a visual simplification; areas under furniture and within measured lounge walls are completed.",
                     "The depth floor samples vary vertically across the walk. Geometry is flattened for the illustration.",
                     "Atrium and unobserved interior are left open. Source wall fragments are shortened to cutaway height.",
                     "No routing map, clearance, AR localization or inter-floor connection is created."]}
    save("preparation-validation.json",report)
    manifest=read("manifest.json")
    manifest["derived_files"]=[{"filename":p.name,"sha256":hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(OUT.glob("*.json")) if p.name not in ("manifest.json","native-load-validation.json","reconstruction.json","preparation-validation.json","navigation-validation.json")]
    save("manifest.json",manifest)
    print(json.dumps(report,indent=2))


if __name__=="__main__":main()
