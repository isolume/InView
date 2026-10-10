#!/usr/bin/env python3
"""Export InView's photo furniture to GLB, the app catalogue, and an offline gallery."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "models/photo-room"
RESOURCE = ROOT / "Packages/AccessCore/Sources/AccessCore/Resources/photo-furniture.json"


def write_atomically(path: Path, contents: str | bytes) -> None:
    """Keep the app and local preview from reading a partially written asset."""
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False) as temporary:
        temporary.write(contents.encode() if isinstance(contents, str) else contents)
        temporary_path = Path(temporary.name)
    try:
        temporary_path.chmod(0o644)
        temporary_path.replace(path)
    finally:
        temporary_path.unlink(missing_ok=True)


def neutral_rgb(hex_color: str) -> list[float]:
    rgb = [int(hex_color[start:start + 2], 16) / 255 for start in (1, 3, 5)]
    brightness = min(0.85, max(0.66, sum(rgb) / 3))
    return [round(brightness * tint * 255) / 255 for tint in (0.97, 0.99, 1)]


def compact(value):
    if isinstance(value, float):
        return round(value, 6)
    if isinstance(value, list):
        return [compact(item) for item in value]
    if isinstance(value, dict):
        return {key: compact(item) for key, item in value.items()}
    return value


def validate_catalogue(catalogue: dict) -> None:
    assert catalogue["version"] == 1
    assert len(catalogue["models"]) == 14, "Expected 14 photo furniture assets"
    ids = set()
    for model in catalogue["models"]:
        assert model["id"] not in ids
        ids.add(model["id"])
        dimensions = model["dimensions_m"]
        assert len(dimensions) == 3 and all(math.isfinite(v) and v > 0 for v in dimensions)
        assert model["meshes"] and all(m["name"] != "measured unknown object" for m in model["meshes"]), f"Missing model: {model['key']}"
        for mesh in model["meshes"]:
            vertices, normals, triangles = mesh["vertices"], mesh["normals"], mesh["triangles"]
            assert vertices and triangles and len(vertices) == len(normals)
            assert len(mesh["color"]) == 7 and mesh["color"].startswith("#")
            for vertex in vertices:
                assert len(vertex) == 3 and all(math.isfinite(v) for v in vertex)
                assert all(abs(v) <= dimensions[axis] * 0.5001 + 1e-6 for axis, v in enumerate(vertex)), f"Out-of-bounds {model['id']} / {mesh['name']}"
            for normal in normals:
                assert len(normal) == 3 and all(math.isfinite(v) for v in normal)
                assert abs(sum(v * v for v in normal) - 1) < 0.002
            for triangle in triangles:
                assert len(triangle) == 3 and len(set(triangle)) == 3
                assert all(isinstance(i, int) and 0 <= i < len(vertices) for i in triangle)


def export_glb(model: dict) -> bytes:
    binary = bytearray()
    views, accessors, meshes, nodes, materials = [], [], [], [], []
    material_lookup = {}

    def accessor(values, count, kind, component_type, target, bounds=None):
        while len(binary) % 4:
            binary.append(0)
        start = len(binary)
        format_code = {5126: "f", 5123: "H", 5125: "I"}[component_type]
        binary.extend(struct.pack("<" + format_code * len(values), *values))
        view_index = len(views)
        views.append({"buffer": 0, "byteOffset": start, "byteLength": len(binary) - start, "target": target})
        entry = {"bufferView": view_index, "componentType": component_type, "count": count, "type": kind}
        if bounds:
            entry.update({"min": bounds[0], "max": bounds[1]})
        accessors.append(entry)
        return len(accessors) - 1

    for mesh in model["meshes"]:
        if mesh["color"] not in material_lookup:
            material_lookup[mesh["color"]] = len(materials)
            # Match the app preview's neutral furniture palette. glTF colors are linear.
            srgb = neutral_rgb(mesh["color"])
            linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in srgb]
            materials.append({"name": "Soft gray " + mesh["color"], "pbrMetallicRoughness": {"baseColorFactor": linear + [1], "metallicFactor": 0, "roughnessFactor": 0.9}})
        vertices, normals = mesh["vertices"], mesh["normals"]
        vertices = [[struct.unpack("<f", struct.pack("<f", value))[0] for value in point] for point in vertices]
        lower = [min(v[axis] for v in vertices) for axis in range(3)]
        upper = [max(v[axis] for v in vertices) for axis in range(3)]
        positions = accessor([v for p in vertices for v in p], len(vertices), "VEC3", 5126, 34962, (lower, upper))
        normal = accessor([v for p in normals for v in p], len(normals), "VEC3", 5126, 34962)
        indices = [i for t in mesh["triangles"] for i in t]
        index = accessor(indices, len(indices), "SCALAR", 5123 if len(vertices) <= 65535 else 5125, 34963, ([min(indices)], [max(indices)]))
        meshes.append({"name": mesh["name"], "primitives": [{"attributes": {"POSITION": positions, "NORMAL": normal}, "indices": index, "material": material_lookup[mesh["color"]], "mode": 4}]})
        nodes.append({"name": mesh["name"], "mesh": len(meshes) - 1})
    root_node = len(nodes)
    nodes.append({"name": model["title"], "children": list(range(root_node)), "extras": {"dimensions_m": model["dimensions_m"], "reference_photos": model["reference_photos"], "approximate_photo_model": True}})
    while len(binary) % 4:
        binary.append(0)
    document = {"asset": {"version": "2.0", "generator": "InView photo furniture exporter"}, "scene": 0, "scenes": [{"nodes": [root_node]}], "nodes": nodes, "meshes": meshes, "materials": materials, "buffers": [{"byteLength": len(binary)}], "bufferViews": views, "accessors": accessors}
    metadata = json.dumps(document, separators=(",", ":")).encode()
    metadata += b" " * (-len(metadata) % 4)
    total = 12 + 8 + len(metadata) + 8 + len(binary)
    return struct.pack("<III", 0x46546C67, 2, total) + struct.pack("<II", len(metadata), 0x4E4F534A) + metadata + struct.pack("<II", len(binary), 0x004E4942) + binary


def validate_glb(data: bytes) -> None:
    magic, version, size = struct.unpack_from("<III", data)
    assert magic == 0x46546C67 and version == 2 and size == len(data)
    json_length, json_kind = struct.unpack_from("<II", data, 12)
    assert json_kind == 0x4E4F534A and json_length % 4 == 0
    document = json.loads(data[20:20 + json_length])
    binary_offset = 20 + json_length
    binary_length, binary_kind = struct.unpack_from("<II", data, binary_offset)
    binary = data[binary_offset + 8:]
    assert binary_kind == 0x004E4942 and len(binary) == binary_length == document["buffers"][0]["byteLength"]
    for view in document["bufferViews"]:
        assert view["byteOffset"] % 4 == 0
        assert view["byteOffset"] + view["byteLength"] <= binary_length
    widths = {"SCALAR": 1, "VEC3": 3}
    for accessor in document["accessors"]:
        view = document["bufferViews"][accessor["bufferView"]]
        item_size = {5126: 4, 5123: 2, 5125: 4}[accessor["componentType"]]
        count = accessor["count"] * widths[accessor["type"]]
        assert count * item_size <= view["byteLength"]
        values = struct.unpack_from("<" + {5126: "f", 5123: "H", 5125: "I"}[accessor["componentType"]] * count, binary, view["byteOffset"])
        assert all(math.isfinite(v) for v in values)
    for mesh in document["meshes"]:
        for primitive in mesh["primitives"]:
            indices = document["accessors"][primitive["indices"]]
            vertices = document["accessors"][primitive["attributes"]["POSITION"]]
            assert indices["max"][0] < vertices["count"]


def export_bundle(models: list[dict]) -> tuple[int, int] | None:
    """Bundle a complete set after the native preview pass has finished."""
    paths = [DESTINATION / name for name in ("README.md", "catalog.json", "gallery.html")]
    paths += [DESTINATION / "glb" / (model["id"] + ".glb") for model in models]
    paths += [DESTINATION / "usdz" / (model["id"] + ".usdz") for model in models]
    paths += [DESTINATION / "previews" / (model["id"] + ".png") for model in models]
    paths += [DESTINATION / "usdz/validation.json", DESTINATION / "previews/contact-sheet.png"]
    if not all(path.is_file() for path in paths):
        return None
    with tempfile.NamedTemporaryFile(dir=DESTINATION, prefix=".photo-furniture.", suffix=".zip", delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        with zipfile.ZipFile(temporary_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for path in paths:
                archive.write(path, path.relative_to(DESTINATION))
        with zipfile.ZipFile(temporary_path) as archive:
            assert len(archive.namelist()) == len(paths) == len(set(archive.namelist()))
            assert archive.testzip() is None, "Bundle CRC validation failed"
        size = temporary_path.stat().st_size
        temporary_path.chmod(0o644)
        temporary_path.replace(DESTINATION / "photo-furniture.zip")
        return len(paths), size
    finally:
        temporary_path.unlink(missing_ok=True)


GALLERY = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="theme-color" content="#eef0ee">
<title>InView · Furniture</title>
<style>
:root{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif;font-synthesis:none;color:#25272a;background:#eef0ee;color-scheme:light}*{box-sizing:border-box}body{margin:0}button,select,a{font:inherit}button,select{cursor:pointer}button,select,a{ -webkit-tap-highlight-color:transparent}button:focus-visible,select:focus-visible,a:focus-visible,canvas:focus-visible{outline:3px solid #007aff;outline-offset:4px}button{border:0}button,a{touch-action:manipulation}[hidden]{display:none!important}.app{position:fixed;inset:0;min-height:440px;background:radial-gradient(ellipse at 50% 40%,#fafbf9,#edf0ec 75%,#e7ebe6)}.header{height:90px;position:absolute;top:0;left:0;right:0;display:flex;align-items:center;justify-content:space-between;padding:20px 32px;z-index:3;gap:20px}.header h1{font-size:27px;letter-spacing:-.8px;margin:0;font-weight:650}.selection{display:flex;gap:10px;align-items:center}select{max-width:250px;min-width:180px;border:0;border-radius:13px;background:#ffffffd9;padding:12px 34px 12px 15px;color:#303235;font-size:14px;box-shadow:0 2px 12px #23332306}.glass{background:#ffffffde;box-shadow:0 3px 15px #2632240c,inset 0 0 0 1px #ffffff90;backdrop-filter:blur(20px)}.overview{height:42px;border-radius:13px;padding:0 15px;color:#007aff;font-size:14px;font-weight:600}.overview[aria-pressed=true]{background:#007aff;color:#fff}.stage{position:absolute;inset:90px 0 126px}canvas{height:100%;width:100%;display:block;touch-action:none;cursor:grab}canvas:active{cursor:grabbing}.footer{position:absolute;left:32px;bottom:28px;max-width:calc(100% - 164px)}.footer h2{font-size:22px;letter-spacing:-.5px;margin:0 0 7px;font-weight:650}.dimensions{font-size:13px;margin:0 0 15px;color:#777b7e;font-variant-numeric:tabular-nums}.download{display:inline-flex;align-items:center;justify-content:center;border-radius:12px;height:37px;padding:0 14px;background:#007aff;color:white;text-decoration:none;font-size:13px;font-weight:600;box-shadow:0 2px 6px #007aff16}.download.usdz{background:#ffffffd9;color:#007aff;margin-left:6px;box-shadow:0 2px 8px #26322408}.note{font-size:11px;color:#8b8e90;margin-left:10px;white-space:nowrap}.controls{position:absolute;right:32px;bottom:30px;display:flex;gap:9px}.controls button{height:42px;width:42px;border-radius:13px;color:#666b6e;font-size:23px;font-weight:350}.controls svg{height:20px;width:20px;fill:none;stroke:#007aff;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}.hint{position:absolute;left:50%;bottom:22px;transform:translateX(-50%);font-size:11px;color:#9b9e9f;pointer-events:none;white-space:nowrap}.tiles{position:absolute;inset:0 24px;display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:7px 18px}.tile{position:relative;background:transparent;min-height:0;cursor:pointer;border-radius:19px;box-shadow:inset 0 0 0 1px #adb5ad15;transition:box-shadow .15s}.tile:hover{box-shadow:inset 0 0 0 1px #007aff55}.tile span{position:absolute;bottom:13px;left:9px;right:9px;text-align:center;font-size:12px;color:#676d70;font-weight:550}.tile:hover span{color:#007aff}.error{position:absolute;inset:0;display:grid;place-items:center;color:#777;padding:24px;text-align:center}@media(max-width:900px){.hint{display:none}.tiles{grid-template-columns:repeat(3,minmax(0,1fr))}.header{padding:20px 24px}.footer{left:24px}.controls{right:24px}}@media(max-width:580px){.app{min-height:540px}.header{height:106px;align-items:flex-start;padding:19px 18px}.header h1{font-size:24px;line-height:42px}.selection{gap:7px;flex-wrap:wrap;justify-content:flex-end}select{font-size:12px;min-width:142px;width:156px;padding:12px 24px 12px 11px}.overview{font-size:12px;height:34px;padding:0 12px}.stage{top:113px;bottom:154px}.tiles{inset:0 10px;grid-template-columns:repeat(2,minmax(0,1fr));gap:5px 9px}.tile span{font-size:10px;bottom:6px}.footer{left:18px;bottom:25px;max-width:calc(100% - 110px)}.footer h2{font-size:20px}.dimensions{font-size:12px;margin-bottom:13px}.note{display:block;margin:9px 0 0;font-size:10px}.controls{right:17px;bottom:26px;display:grid;grid-template-columns:repeat(2,36px);gap:6px}.controls button{width:36px;height:36px;border-radius:11px}.controls button:first-child{grid-column:span 2;width:78px}.overview-open .stage{bottom:107px}.overview-open .footer h2{font-size:18px}.overview-open .footer{bottom:22px}.overview-open .dimensions{margin-bottom:0}.overview-open .note{margin-top:6px}}@media(prefers-reduced-motion:reduce){*{transition:none!important}}
</style>
</head>
<body>
<main class="app" id="app">
<header class="header"><h1>Furniture</h1><div class="selection"><select id="choose" aria-label="Choose furniture"></select><button type="button" class="overview glass" id="overview" aria-pressed="false">Overview</button></div></header>
<div class="stage" id="stage"><canvas id="view" tabindex="0" aria-label="Furniture preview. Drag to rotate, scroll or pinch to zoom. Arrow keys rotate, plus and minus zoom, and zero recenters."></canvas><div id="tiles" class="tiles" hidden></div><div class="error" id="error" role="status" hidden></div></div>
<section class="footer" aria-live="polite"><h2 id="title">Furniture</h2><p class="dimensions" id="dimensions"></p><a class="download" id="download" href="#" download>Download model</a><a class="download usdz" id="download-usdz" href="#" download hidden>USDZ</a><span class="note">Estimated from your photos</span></section>
<div class="controls" aria-label="Preview controls"><button class="glass" id="reset" type="button" aria-label="Recenter model"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m20 4-6 16-3-7-7-3Z"/></svg></button><button class="glass" id="zoom-out" type="button" aria-label="Zoom out">−</button><button class="glass" id="zoom-in" type="button" aria-label="Zoom in">+</button></div><span class="hint">Drag to rotate · Scroll to zoom</span>
</main>
<script id="catalogue" type="application/json">__CATALOGUE__</script>
<script>
'use strict';
const catalogue=JSON.parse(document.querySelector('#catalogue').textContent),models=catalogue.models,$=s=>document.querySelector(s),canvas=$('#view'),stage=$('#stage'),gl=canvas.getContext('webgl',{alpha:true,antialias:true}),pointers=new Map();
let selected=0,overview=false,yaw=2.38,pitch=.43,zoom=1,gesture;
const dot=(a,b)=>a.reduce((s,v,i)=>s+v*b[i],0),subtract=(a,b)=>a.map((v,i)=>v-b[i]),normalize=a=>{const d=Math.hypot(...a)||1;return a.map(v=>v/d)},cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
function neutral(hex){const rgb=[1,3,5].map(i=>parseInt(hex.slice(i,i+2),16)/255),b=Math.max(.66,Math.min(.85,rgb.reduce((s,v)=>s+v,0)/3));return[.97,.99,1].map(v=>Math.round(b*v*255)/255)}
for(const [index,model]of models.entries()){const option=document.createElement('option');option.value=index;option.textContent=model.title;$('#choose').append(option);const tile=document.createElement('button');tile.type='button';tile.className='tile';tile.setAttribute('aria-label',`View ${model.title.toLowerCase()}`);tile.innerHTML='<span></span>';tile.firstChild.textContent=model.title;tile.addEventListener('click',()=>choose(index));$('#tiles').append(tile)}
if(!gl){$('#error').hidden=false;$('#error').textContent='This browser cannot display the models. You can still download them.';}
let program,locations,shadowBuffer;
function shader(type,source){const shader=gl.createShader(type);gl.shaderSource(shader,source);gl.compileShader(shader);if(!gl.getShaderParameter(shader,gl.COMPILE_STATUS)){console.error(gl.getShaderInfoLog(shader));throw Error('The furniture preview could not start.');}return shader}
if(gl){try{program=gl.createProgram();gl.attachShader(program,shader(gl.VERTEX_SHADER,`precision mediump float;attribute vec3 position;attribute vec3 normal;attribute vec4 color;uniform vec3 center,right,up,toward;uniform vec2 scale,offset;uniform float depth;varying vec3 surfaceNormal;varying vec4 tint;void main(){vec3 p=position-center;gl_Position=vec4(dot(p,right)*scale.x+offset.x,dot(p,up)*scale.y+offset.y,-dot(p,toward)/depth,1.0);surfaceNormal=normal;tint=color;}`));gl.attachShader(program,shader(gl.FRAGMENT_SHADER,`precision mediump float;varying vec3 surfaceNormal;varying vec4 tint;uniform vec3 toward;uniform bool shadow;void main(){if(shadow){gl_FragColor=tint;return;}vec3 n=normalize(surfaceNormal);vec3 light=normalize(vec3(-.45,.92,-.3));vec3 halfVector=normalize(light+toward);float strength=.78+.19*max(0.0,dot(n,light))+.045*max(0.0,n.y);float shine=pow(max(0.0,dot(n,halfVector)),24.0)*.035;gl_FragColor=vec4(tint.rgb*strength+shine,tint.a);}`));gl.linkProgram(program);if(!gl.getProgramParameter(program,gl.LINK_STATUS)){console.error(gl.getProgramInfoLog(program));throw Error('The furniture preview could not start.');}gl.useProgram(program);locations={};for(const name of['center','right','up','toward','scale','offset','depth','shadow'])locations[name]=gl.getUniformLocation(program,name);for(const name of['position','normal','color'])locations[name]=gl.getAttribLocation(program,name);gl.enable(gl.DEPTH_TEST);gl.depthFunc(gl.LEQUAL);gl.enable(gl.BLEND);gl.blendFunc(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA);for(const model of models){const data=[],all=[];for(const mesh of model.meshes){const color=neutral(mesh.color);all.push(...mesh.vertices);for(const triangle of mesh.triangles)for(const i of triangle)data.push(...mesh.vertices[i],...mesh.normals[i],...color,1)}model.buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,model.buffer);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(data),gl.STATIC_DRAW);model.count=data.length/10;model.low=[Infinity,Infinity,Infinity];model.high=[-Infinity,-Infinity,-Infinity];for(const point of all)for(let axis=0;axis<3;axis++){model.low[axis]=Math.min(model.low[axis],point[axis]);model.high[axis]=Math.max(model.high[axis],point[axis])}model.center=model.low.map((v,i)=>(v+model.high[i])/2);model.fitPoints=Array.from({length:8},(_,index)=>model.low.map((v,axis)=>index&(1<<axis)?model.high[axis]:v));model.points=all;model.shadow=makeShadow(model)}shadowBuffer=gl.createBuffer();}catch(error){$('#error').hidden=false;$('#error').textContent=error.message;program=null}}
function hull(points){const sorted=[...points].sort((a,b)=>a[0]-b[0]||a[2]-b[2]),turn=(a,b,c)=>(b[0]-a[0])*(c[2]-a[2])-(b[2]-a[2])*(c[0]-a[0]),lower=[],upper=[];for(const p of sorted){while(lower.length>1&&turn(lower.at(-2),lower.at(-1),p)<=0)lower.pop();lower.push(p)}for(const p of sorted.reverse()){while(upper.length>1&&turn(upper.at(-2),upper.at(-1),p)<=0)upper.pop();upper.push(p)}return lower.slice(0,-1).concat(upper.slice(0,-1))}
function makeShadow(model){const result=[],[w,h,d]=model.dimensions_m,floor=model.low[1]-.002,cast=hull(model.points.map(p=>[p[0]+(p[1]-floor)*.15,floor,p[2]+(p[1]-floor)*.12])),contact=Array.from({length:36},(_,i)=>[Math.cos(i/36*Math.PI*2)*w*.39,floor+.0006,Math.sin(i/36*Math.PI*2)*d*.39]);for(const [shape,spread,opacity]of[[cast,.055,.007],[contact,.04,.012]]){const mid=shape.reduce((s,p)=>s.map((v,i)=>v+p[i]),[0,0,0]).map(v=>v/shape.length);for(let ring=6;ring>=0;ring--){const perimeter=shape.map(p=>{const n=normalize([p[0]-mid[0],0,p[2]-mid[2]]);return[p[0]+n[0]*spread*ring/6,p[1],p[2]+n[2]*spread*ring/6]});for(let i=1;i<perimeter.length-1;i++)for(const p of[perimeter[0],perimeter[i],perimeter[i+1]])result.push(...p,0,1,0,.25,.28,.26,opacity*(1-ring/10))}}return new Float32Array(result)}
function bind(buffer){gl.bindBuffer(gl.ARRAY_BUFFER,buffer);for(const [name,size,offset]of[['position',3,0],['normal',3,12],['color',4,24]]){gl.enableVertexAttribArray(locations[name]);gl.vertexAttribPointer(locations[name],size,gl.FLOAT,false,40,offset)}}
function renderModel(model,rect,localYaw,localPitch,localZoom){const pixelRatio=Math.min(2,devicePixelRatio||1),viewWidth=rect.width,viewHeight=rect.height;if(viewWidth<2||viewHeight<2)return;const origin=canvas.getBoundingClientRect();gl.viewport(Math.round((rect.left-origin.left)*pixelRatio),Math.round((origin.bottom-rect.bottom)*pixelRatio),Math.round(viewWidth*pixelRatio),Math.round(viewHeight*pixelRatio));const right=[Math.cos(localYaw),0,-Math.sin(localYaw)],up=[-Math.sin(localYaw)*Math.sin(localPitch),Math.cos(localPitch),-Math.cos(localYaw)*Math.sin(localPitch)],toward=[Math.sin(localYaw)*Math.cos(localPitch),Math.sin(localPitch),Math.cos(localYaw)*Math.cos(localPitch)];let lowX=Infinity,highX=-Infinity,lowY=Infinity,highY=-Infinity;for(const point of model.fitPoints){const p=subtract(point,model.center),x=dot(p,right),y=dot(p,up);lowX=Math.min(lowX,x);highX=Math.max(highX,x);lowY=Math.min(lowY,y);highY=Math.max(highY,y)}const availableHeight=overview?viewHeight-37:viewHeight*.81,pixels=Math.min(viewWidth*(overview?.76:.67)/Math.max(.1,highX-lowX),availableHeight*.88/Math.max(.1,highY-lowY))*localZoom,scale=[2*pixels/viewWidth,2*pixels/viewHeight],offset=[-(lowX+highX)/2*scale[0],-(lowY+highY)/2*scale[1]+(overview?.10:.03)],depth=Math.max(...model.dimensions_m)*5;gl.uniform3fv(locations.center,model.center);gl.uniform3fv(locations.right,right);gl.uniform3fv(locations.up,up);gl.uniform3fv(locations.toward,toward);gl.uniform2fv(locations.scale,scale);gl.uniform2fv(locations.offset,offset);gl.uniform1f(locations.depth,depth);gl.uniform1i(locations.shadow,1);gl.depthMask(false);gl.bindBuffer(gl.ARRAY_BUFFER,shadowBuffer);gl.bufferData(gl.ARRAY_BUFFER,model.shadow,gl.DYNAMIC_DRAW);bind(shadowBuffer);gl.drawArrays(gl.TRIANGLES,0,model.shadow.length/10);gl.depthMask(true);gl.uniform1i(locations.shadow,0);bind(model.buffer);gl.drawArrays(gl.TRIANGLES,0,model.count)}
function draw(){if(!program)return;gl.viewport(0,0,canvas.width,canvas.height);gl.clearColor(0,0,0,0);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);if(overview){for(const [i,tile]of [...$('#tiles').children].entries())renderModel(models[i],tile.getBoundingClientRect(),2.38,.43,1)}else renderModel(models[selected],canvas.getBoundingClientRect(),yaw,pitch,zoom)}
function resize(){const rect=canvas.getBoundingClientRect(),dpi=Math.min(2,devicePixelRatio||1);canvas.width=Math.round(rect.width*dpi);canvas.height=Math.round(rect.height*dpi);draw()}
function update(){const model=models[selected];$('#choose').value=selected;$('#title').textContent=overview?models.length+' photo models':model.title;$('#dimensions').textContent=overview?'Room and balcony':model.dimensions_m.map(v=>Number(v.toFixed(2))).join(' × ')+' m · approximate';$('#download').hidden=overview;$('#download').href='glb/'+model.id+'.glb';$('#download').setAttribute('download',model.id+'.glb');$('#download-usdz').hidden=overview||!model.usdz_file;$('#download-usdz').href=model.usdz_file||'#';$('#download-usdz').setAttribute('download',model.id+'.usdz');$('#tiles').hidden=!overview;$('#overview').setAttribute('aria-pressed',String(overview));$('#app').classList.toggle('overview-open',overview);$('#reset').disabled=overview;$('#zoom-in').disabled=overview;$('#zoom-out').disabled=overview}
function reset(){yaw=2.38;pitch=.43;zoom=1;draw()}
function choose(index){selected=index;overview=false;update();reset();resize()}
$('#choose').addEventListener('change',()=>choose(Number($('#choose').value)));$('#overview').addEventListener('click',()=>{overview=!overview;update();resize()});$('#reset').addEventListener('click',reset);$('#zoom-in').addEventListener('click',()=>{zoom=Math.min(3,zoom*1.2);draw()});$('#zoom-out').addEventListener('click',()=>{zoom=Math.max(.5,zoom/1.2);draw()});
canvas.addEventListener('pointerdown',event=>{if(overview)return;canvas.setPointerCapture(event.pointerId);pointers.set(event.pointerId,[event.clientX,event.clientY]);gesture=undefined});canvas.addEventListener('pointermove',event=>{if(!pointers.has(event.pointerId))return;const previous=pointers.get(event.pointerId);pointers.set(event.pointerId,[event.clientX,event.clientY]);if(pointers.size===2){const[a,b]=[...pointers.values()],distance=Math.hypot(a[0]-b[0],a[1]-b[1]);if(gesture)zoom=Math.max(.5,Math.min(3,zoom*distance/gesture));gesture=distance}else{yaw+=(event.clientX-previous[0])*.006;pitch=Math.max(.08,Math.min(1.25,pitch+(event.clientY-previous[1])*.004))}draw()});for(const type of['pointerup','pointercancel','lostpointercapture'])canvas.addEventListener(type,event=>{pointers.delete(event.pointerId);gesture=undefined});canvas.addEventListener('wheel',event=>{if(overview)return;event.preventDefault();zoom=Math.max(.5,Math.min(3,zoom*Math.exp(-event.deltaY*.001)));draw()},{passive:false});canvas.addEventListener('keydown',event=>{if(overview)return;const key=event.key;if(['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','+','=','-','0','Home'].includes(key))event.preventDefault();if(key==='ArrowLeft')yaw-=.13;if(key==='ArrowRight')yaw+=.13;if(key==='ArrowUp')pitch=Math.min(1.25,pitch+.1);if(key==='ArrowDown')pitch=Math.max(.08,pitch-.1);if(key==='+'||key==='=')zoom=Math.min(3,zoom*1.2);if(key==='-')zoom=Math.max(.5,zoom/1.2);if(key==='0'||key==='Home')reset();draw()});new ResizeObserver(resize).observe(stage);update();resize();
</script>
</body>
</html>
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalogue", type=Path, help="Use a previously exported canonical catalogue instead of running Cargo")
    args = parser.parse_args()
    if args.catalogue:
        catalogue = json.loads(args.catalogue.read_text())
    else:
        output = subprocess.run(["cargo", "run", "--quiet", "--offline", "--manifest-path", str(ROOT / "backend/Cargo.toml"), "--example", "export_photo_furniture"], cwd=ROOT, stdout=subprocess.PIPE, text=True)
        if output.returncode:
            raise SystemExit(output.returncode)
        catalogue = json.loads(output.stdout)
    catalogue = compact(catalogue)
    validate_catalogue(catalogue)
    asset_data = [(model, export_glb(model)) for model in catalogue["models"]]
    for _, data in asset_data:
        validate_glb(data)
    (DESTINATION / "glb").mkdir(parents=True, exist_ok=True)
    RESOURCE.parent.mkdir(parents=True, exist_ok=True)
    canonical_json = json.dumps(catalogue, separators=(",", ":"), ensure_ascii=False)
    write_atomically(RESOURCE, canonical_json + "\n")
    manifest = {"version": 1, "style": "InView soft gray", "units": "meters", "up_axis": "Y", "front_axis": "-Z", "dimensions_are_approximate": True, "models": []}
    for model, data in asset_data:
        write_atomically(DESTINATION / "glb" / (model["id"] + ".glb"), data)
        summary = {key: value for key, value in model.items() if key != "meshes"}
        summary.update({"file": "glb/" + model["id"] + ".glb", "mesh_count": len(model["meshes"]), "triangle_count": sum(len(mesh["triangles"]) for mesh in model["meshes"])})
        if (DESTINATION / "usdz" / (model["id"] + ".usdz")).exists():
            summary["usdz_file"] = "usdz/" + model["id"] + ".usdz"
        manifest["models"].append(summary)
    write_atomically(DESTINATION / "catalog.json", json.dumps(manifest, indent=2) + "\n")
    gallery_catalogue = {"version": 1, "models": [{**model, **({"usdz_file": "usdz/" + model["id"] + ".usdz"} if (DESTINATION / "usdz" / (model["id"] + ".usdz")).exists() else {})} for model in catalogue["models"]]}
    gallery_json = json.dumps(gallery_catalogue, separators=(",", ":"), ensure_ascii=False)
    write_atomically(DESTINATION / "gallery.html", GALLERY.replace("__CATALOGUE__", gallery_json.replace("</", "<\\/")))
    triangle_count = sum(summary["triangle_count"] for summary in manifest["models"])
    print(f"Exported and validated {len(asset_data)} models ({triangle_count:,} triangles).")
    print(f"Gallery: {DESTINATION / 'gallery.html'}")
    print(f"App resource: {RESOURCE}")
    bundle = export_bundle(catalogue["models"])
    if bundle:
        count, size = bundle
        print(f"Bundle: {DESTINATION / 'photo-furniture.zip'} ({count} files, {size / 1024 / 1024:.2f} MiB; all CRCs valid)")


if __name__ == "__main__":
    main()
