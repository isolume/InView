#!/usr/bin/env python3
"""Build a standalone, offline preview from the walkthrough building geometry."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "models/walkthrough-building"

HTML = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#e9ede8">
<title>Atrium &amp; lounge · InView</title>
<style>
:root{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif;color:#303934;background:#e9ede8;color-scheme:light;font-synthesis:none}
*{box-sizing:border-box}body{margin:0}button,a{font:inherit;-webkit-tap-highlight-color:transparent;touch-action:manipulation}button{cursor:pointer;border:0;color:inherit}button:focus-visible,a:focus-visible,canvas:focus-visible{outline:3px solid #3573f2;outline-offset:4px}[hidden]{display:none!important}
.app{position:fixed;inset:0;min-height:360px;background:#e9ede8}.stage{position:absolute;inset:76px 0 82px}canvas{display:block;width:100%;height:100%;touch-action:none;cursor:grab}canvas:active{cursor:grabbing}
.header{position:absolute;inset:0 0 auto;display:flex;align-items:center;justify-content:space-between;padding:26px 32px;gap:18px;z-index:2}.title{font-size:24px;letter-spacing:-.8px;font-weight:650;margin:0}.glass{background:#f9fbf8e8;border:1px solid #fff9;box-shadow:0 4px 18px #24352708,0 0 0 1px #6477680a;backdrop-filter:blur(18px)}
.segmented{display:flex;padding:4px;gap:3px;border-radius:100px}.segmented button{font-size:13px;font-weight:600;min-width:65px;height:34px;border-radius:100px;background:transparent;color:#6d7770}.segmented button[aria-pressed=true]{background:white;color:#303934;box-shadow:0 2px 7px #2d443813}
.footer{position:absolute;bottom:27px;left:32px;z-index:2}.downloads{display:flex;gap:8px}.download{display:inline-flex;align-items:center;gap:8px;padding:11px 15px;border-radius:100px;color:#38483d;text-decoration:none;font-size:12px;font-weight:600}.download svg{width:14px;height:14px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}.note{margin:11px 0 0 2px;font-size:11px;color:#7b857d}.controls{position:absolute;right:32px;bottom:28px;display:flex;align-items:center;gap:8px;z-index:2}.controls button{width:42px;height:42px;border-radius:50%;font-size:24px;font-weight:350}.controls svg{height:19px;width:19px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}.hint{position:absolute;left:50%;bottom:36px;transform:translateX(-50%);font-size:11px;color:#8a928c;white-space:nowrap;pointer-events:none}.error{position:absolute;inset:20%;display:grid;place-items:center;text-align:center;font-size:15px;line-height:1.5;color:#69786f}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
@media(max-width:860px){.hint{display:none}.header{padding:24px}.footer{left:24px}.controls{right:24px}}@media(max-width:540px){.header{padding:22px 18px}.title{font-size:21px;letter-spacing:-.6px}.segmented button{min-width:47px;font-size:12px}.stage{top:84px;bottom:145px}.footer{left:18px;bottom:27px}.note{font-size:10px;max-width:205px;line-height:1.5}.download{padding:10px 13px;font-size:11px}.controls{right:18px;bottom:82px;gap:6px}.controls button{height:35px;width:35px;font-size:22px}.controls svg{height:17px;width:17px}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
</style>
</head>
<body>
<main class="app">
<header class="header"><h1 class="title">Atrium &amp; lounge</h1><div class="segmented glass" role="group" aria-label="View"><button type="button" id="three-d" aria-pressed="true">3D</button><button type="button" id="top" aria-pressed="false">Top</button></div></header>
<div class="stage" id="stage"><canvas id="view" tabindex="0" role="img" aria-label="Interactive 3D model of the atrium and lounge" aria-describedby="instructions"></canvas><div class="error" id="error" role="status" hidden></div></div>
<p class="sr-only" id="instructions">Drag to rotate. Shift-drag, right-drag, or drag with two fingers to move. Scroll or pinch to zoom. Arrow keys rotate; Shift and arrow keys move. Plus and minus zoom. Press T for top view, D for 3D, or Home to reset.</p>
<div class="footer"><div class="downloads"><a class="download glass" href="building.glb" download><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2v8m-3-3 3 3 3-3M3 11v3h10v-3"/></svg>GLB model</a><a class="download glass" href="building.usdz" download>USDZ</a></div><p class="note">Approximate layout from your walkthrough</p></div>
<div class="controls" role="group" aria-label="Model controls"><button class="glass" id="reset" type="button" aria-label="Reset view" title="Reset view"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 10a8 8 0 1 1 1 7M4 4v6h6"/></svg></button><button class="glass" id="zoom-out" type="button" aria-label="Zoom out" title="Zoom out">−</button><button class="glass" id="zoom-in" type="button" aria-label="Zoom in" title="Zoom in">+</button></div>
<span class="hint" aria-hidden="true">Drag to rotate · Scroll to zoom · Shift-drag to move</span>
</main>
<script id="scene" type="application/json">__SCENE__</script>
<script>
'use strict';
const scene=JSON.parse(document.querySelector('#scene').textContent),$=s=>document.querySelector(s),canvas=$('#view'),gl=canvas.getContext('webgl',{alpha:true,antialias:true}),pointers=new Map();
const dot=(a,b)=>a.reduce((s,v,i)=>s+v*b[i],0),sub=(a,b)=>a.map((v,i)=>v-b[i]),unit=a=>{const d=Math.hypot(...a)||1;return a.map(v=>v/d)},cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]],clamp=(v,a,b)=>Math.min(b,Math.max(a,v));
const DEFAULT_YAW=__YAW__,DEFAULT_PITCH=__PITCH__,low=scene.bounds.min,high=scene.bounds.max,center=low.map((v,i)=>(v+high[i])/2),extent=low.map((v,i)=>high[i]-v),span=Math.max(...extent),corners=Array.from({length:8},(_,i)=>low.map((v,a)=>i&(1<<a)?high[a]:v));
let yaw=DEFAULT_YAW,pitch=DEFAULT_PITCH,zoom=1,pan=[0,0],topView=false,savedOrbit=[yaw,pitch],gesture,program,meshBuffer,groundBuffer,count=0,groundCount=0,locations;
const lightToward=unit([-.65,1,.5]),fitPoints=[];
const vertexSource=`precision highp float;
attribute vec3 position,normal;
attribute vec4 color;
uniform vec3 center,right,up,toward;
uniform vec2 scale,offset;
uniform float depth;
varying vec3 surfaceNormal;
varying vec4 tint;
void main(){vec3 p=position-center;gl_Position=vec4(dot(p,right)*scale.x+offset.x,dot(p,up)*scale.y+offset.y,-dot(p,toward)/depth,1.0);surfaceNormal=normal;tint=color;}`;
const fragmentSource=`precision highp float;
varying vec3 surfaceNormal;
varying vec4 tint;
uniform vec3 toward,lightToward;
uniform bool ground;
void main(){if(ground){gl_FragColor=tint;return;}vec3 n=normalize(surfaceNormal);if(!gl_FrontFacing)n=-n;float diffuse=max(0.0,dot(n,lightToward));float strength=.80+.17*diffuse+.03*max(0.0,n.y);float shine=pow(max(0.0,dot(n,normalize(lightToward+toward))),30.0)*.012;gl_FragColor=vec4(tint.rgb*strength+shine,1.0);}`;
function showError(message){$('#error').hidden=false;$('#error').textContent=message;}
function shader(type,source){const s=gl.createShader(type);gl.shaderSource(s,source);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw Error(gl.getShaderInfoLog(s)||'Shader compilation failed');return s;}
function makeProgram(vertex,fragment){const p=gl.createProgram();gl.attachShader(p,shader(gl.VERTEX_SHADER,vertex));gl.attachShader(p,shader(gl.FRAGMENT_SHADER,fragment));gl.linkProgram(p);if(!gl.getProgramParameter(p,gl.LINK_STATUS))throw Error(gl.getProgramInfoLog(p)||'Program linking failed');return p;}
function locate(p,attributes,uniforms){const result={};for(const n of attributes)result[n]=gl.getAttribLocation(p,n);for(const n of uniforms)result[n]=gl.getUniformLocation(p,n);return result;}
function buffer(data){const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(data),gl.STATIC_DRAW);return b;}
function bind(b){gl.bindBuffer(gl.ARRAY_BUFFER,b);for(const[n,size,offset]of[['position',3,0],['normal',3,12],['color',4,24]]){gl.enableVertexAttribArray(locations[n]);gl.vertexAttribPointer(locations[n],size,gl.FLOAT,false,40,offset);}}
function hull(points){const sorted=points.sort((a,b)=>a[0]-b[0]||a[1]-b[1]),turn=(a,b,c)=>(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]),lower=[],upper=[];for(const p of sorted){while(lower.length>1&&turn(lower.at(-2),lower.at(-1),p)<=0)lower.pop();lower.push(p);}for(const p of sorted.slice().reverse()){while(upper.length>1&&turn(upper.at(-2),upper.at(-1),p)<=0)upper.pop();upper.push(p);}return lower.slice(0,-1).concat(upper.slice(0,-1));}
function makeGroundShadow(){const shape=hull(fitPoints.map(p=>[p[0],p[2]])),mid=shape.reduce((s,p)=>s.map((v,i)=>v+p[i]),[0,0]).map(v=>v/shape.length),data=[],floor=low[1]-.04;for(let ring=15;ring>=0;ring--){const spread=.07+ring*.028,perimeter=shape.map(p=>{const d=unit([p[0]-mid[0],p[1]-mid[1]]);return[p[0]+d[0]*spread+.08,floor,p[1]+d[1]*spread+.10];});for(let i=1;i<perimeter.length-1;i++)for(const p of[perimeter[0],perimeter[i],perimeter[i+1]])data.push(...p,0,1,0,.25,.31,.27,.0038);}groundCount=data.length/10;groundBuffer=buffer(data);}
function setup(){program=makeProgram(vertexSource,fragmentSource);locations=locate(program,['position','normal','color'],['center','right','up','toward','scale','offset','depth','lightToward','ground']);
 const data=[];for(const mesh of scene.meshes){const color=[1,3,5].map(i=>parseInt(mesh.color.slice(i,i+2),16)/255),meshLow=[Infinity,Infinity,Infinity],meshHigh=[-Infinity,-Infinity,-Infinity];for(const p of mesh.vertices)for(let i=0;i<3;i++){meshLow[i]=Math.min(meshLow[i],p[i]);meshHigh[i]=Math.max(meshHigh[i],p[i]);}for(let i=0;i<8;i++)fitPoints.push(meshLow.map((v,a)=>i&(1<<a)?meshHigh[a]:v));for(const tri of mesh.triangles)for(const i of tri)data.push(...mesh.vertices[i],...mesh.normals[i],...color,1);}meshBuffer=buffer(data);count=data.length/10;makeGroundShadow();
 gl.enable(gl.DEPTH_TEST);gl.depthFunc(gl.LEQUAL);gl.disable(gl.CULL_FACE);gl.enable(gl.BLEND);gl.blendFuncSeparate(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA,gl.ONE,gl.ONE_MINUS_SRC_ALPHA);}
function draw(){if(!program)return;gl.useProgram(program);gl.viewport(0,0,canvas.width,canvas.height);gl.clearColor(0,0,0,0);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);const rect=canvas.getBoundingClientRect();if(rect.width<2||rect.height<2)return;const right=[Math.cos(yaw),0,-Math.sin(yaw)],up=[-Math.sin(yaw)*Math.sin(pitch),Math.cos(pitch),-Math.cos(yaw)*Math.sin(pitch)],toward=[Math.sin(yaw)*Math.cos(pitch),Math.sin(pitch),Math.cos(yaw)*Math.cos(pitch)];let left=Infinity,rightmost=-Infinity,bottom=Infinity,top=-Infinity;for(const corner of fitPoints){const p=sub(corner,center),x=dot(p,right),y=dot(p,up);left=Math.min(left,x);rightmost=Math.max(rightmost,x);bottom=Math.min(bottom,y);top=Math.max(top,y);}const pixels=Math.min(rect.width*.90/Math.max(.1,rightmost-left),rect.height*.96/Math.max(.1,top-bottom))*zoom,scale=[2*pixels/rect.width,2*pixels/rect.height],offset=[-(left+rightmost)*.5*scale[0]+pan[0]*2/rect.width,-(bottom+top)*.5*scale[1]+pan[1]*2/rect.height];const l=locations;gl.uniform3fv(l.center,center);gl.uniform3fv(l.right,right);gl.uniform3fv(l.up,up);gl.uniform3fv(l.toward,toward);gl.uniform2fv(l.scale,scale);gl.uniform2fv(l.offset,offset);gl.uniform1f(l.depth,span*2);gl.uniform3fv(l.lightToward,lightToward);gl.uniform1i(l.ground,1);bind(groundBuffer);gl.depthMask(false);gl.drawArrays(gl.TRIANGLES,0,groundCount);gl.depthMask(true);gl.uniform1i(l.ground,0);bind(meshBuffer);gl.drawArrays(gl.TRIANGLES,0,count);}
function resize(){const rect=canvas.getBoundingClientRect(),dpi=Math.min(2,devicePixelRatio||1);canvas.width=Math.max(1,Math.round(rect.width*dpi));canvas.height=Math.max(1,Math.round(rect.height*dpi));draw();}
function setZoom(value){zoom=clamp(value,.4,4);draw();}
function setView(top){if(top!==topView){if(top){savedOrbit=[yaw,pitch];yaw=0;pitch=Math.PI/2;}else{[yaw,pitch]=savedOrbit;}topView=top;pan=[0,0];}$('#three-d').setAttribute('aria-pressed',String(!topView));$('#top').setAttribute('aria-pressed',String(topView));draw();}
function reset(){zoom=1;pan=[0,0];yaw=topView?0:DEFAULT_YAW;pitch=topView?Math.PI/2:DEFAULT_PITCH;savedOrbit=[DEFAULT_YAW,DEFAULT_PITCH];draw();}
$('#three-d').addEventListener('click',()=>setView(false));$('#top').addEventListener('click',()=>setView(true));$('#reset').addEventListener('click',reset);$('#zoom-in').addEventListener('click',()=>setZoom(zoom*1.2));$('#zoom-out').addEventListener('click',()=>setZoom(zoom/1.2));canvas.addEventListener('contextmenu',e=>e.preventDefault());
canvas.addEventListener('pointerdown',e=>{canvas.setPointerCapture(e.pointerId);pointers.set(e.pointerId,{x:e.clientX,y:e.clientY,pan:e.shiftKey||e.button===2||e.button===1});gesture=undefined;canvas.focus({preventScroll:true});});
canvas.addEventListener('pointermove',e=>{if(!pointers.has(e.pointerId))return;const previous=pointers.get(e.pointerId);pointers.set(e.pointerId,{...previous,x:e.clientX,y:e.clientY});if(pointers.size>=2){const[a,b]=[...pointers.values()],current={distance:Math.hypot(a.x-b.x,a.y-b.y),x:(a.x+b.x)/2,y:(a.y+b.y)/2};if(gesture){zoom=clamp(zoom*current.distance/Math.max(1,gesture.distance),.4,4);pan[0]+=current.x-gesture.x;pan[1]-=current.y-gesture.y;}gesture=current;}else{const dx=e.clientX-previous.x,dy=e.clientY-previous.y;if(previous.pan||e.shiftKey||topView){pan[0]+=dx;pan[1]-=dy;}else{yaw+=dx*.006;pitch=clamp(pitch+dy*.004,.16,1.4);}}draw();});
for(const name of['pointerup','pointercancel','lostpointercapture'])canvas.addEventListener(name,e=>{pointers.delete(e.pointerId);gesture=undefined;});
canvas.addEventListener('wheel',e=>{e.preventDefault();setZoom(zoom*Math.exp(-e.deltaY*.001));},{passive:false});
canvas.addEventListener('keydown',e=>{const k=e.key,handled=['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','+','=','-','0','Home','t','T','d','D'];if(!handled.includes(k))return;e.preventDefault();if(k==='t'||k==='T')setView(true);else if(k==='d'||k==='D')setView(false);else if(k==='+'||k==='=')setZoom(zoom*1.2);else if(k==='-')setZoom(zoom/1.2);else if(k==='0'||k==='Home')reset();else if(e.shiftKey||topView){if(k==='ArrowLeft')pan[0]-=24;if(k==='ArrowRight')pan[0]+=24;if(k==='ArrowUp')pan[1]+=24;if(k==='ArrowDown')pan[1]-=24;}else{if(k==='ArrowLeft')yaw-=.12;if(k==='ArrowRight')yaw+=.12;if(k==='ArrowUp')pitch=clamp(pitch+.08,.16,1.4);if(k==='ArrowDown')pitch=clamp(pitch-.08,.16,1.4);}draw();});
canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();program=null;showError('The preview was interrupted. Reload this page to view the model again.');});
if(!gl)showError('This browser cannot show the 3D preview. You can still download the models.');else{try{setup();new ResizeObserver(resize).observe($('#stage'));resize();}catch(error){console.error(error);program=null;showError('The 3D preview could not start. You can still download the models.');}}
</script>
</body>
</html>
'''


def validate_scene(scene: dict) -> None:
    """Reject malformed input rather than silently displaying missing geometry."""
    if not scene.get("meshes"):
        raise ValueError("The scene has no meshes")
    bounds = scene["bounds"]
    for key in ("min", "max"):
        if len(bounds[key]) != 3 or not all(math.isfinite(v) for v in bounds[key]):
            raise ValueError(f"Invalid scene bounds: {key}")
    if any(lo >= hi for lo, hi in zip(bounds["min"], bounds["max"])):
        raise ValueError("The scene bounds must have positive dimensions")
    for mesh in scene["meshes"]:
        vertices, normals, triangles = mesh["vertices"], mesh["normals"], mesh["triangles"]
        if not vertices or not triangles or len(vertices) != len(normals):
            raise ValueError(f"Missing geometry in {mesh['name']}")
        if not re.fullmatch(r"#[0-9a-fA-F]{6}", mesh["color"]):
            raise ValueError(f"Invalid color in {mesh['name']}")
        for point in vertices + normals:
            if len(point) != 3 or not all(math.isfinite(v) for v in point):
                raise ValueError(f"Invalid position or normal in {mesh['name']}")
        for triangle in triangles:
            if len(triangle) != 3 or any(type(i) is not int or not 0 <= i < len(vertices) for i in triangle):
                raise ValueError(f"Invalid triangle in {mesh['name']}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene", type=Path, default=DESTINATION / "viewer-scene.json")
    parser.add_argument("--output", type=Path, default=DESTINATION / "preview.html")
    parser.add_argument("--yaw", type=float, default=2.5, help="Initial camera yaw in radians")
    parser.add_argument("--pitch", type=float, default=0.72, help="Initial camera elevation in radians")
    args = parser.parse_args()
    if not math.isfinite(args.yaw) or not 0.16 <= args.pitch <= 1.4:
        parser.error("Yaw must be finite and pitch must be between 0.16 and 1.4 radians")
    scene = json.loads(args.scene.read_text())
    validate_scene(scene)
    payload = json.dumps(scene, separators=(",", ":"), ensure_ascii=False).replace("<", "\\u003c").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    html = HTML.replace("__SCENE__", payload).replace("__YAW__", repr(args.yaw)).replace("__PITCH__", repr(args.pitch))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=args.output.parent, prefix=".preview-", suffix=".tmp", delete=False, mode="w") as temporary:
        temporary.write(html)
        temporary_path = Path(temporary.name)
    try:
        temporary_path.chmod(0o644)
        temporary_path.replace(args.output)
    finally:
        temporary_path.unlink(missing_ok=True)
    print(f"Wrote {args.output} ({len(scene['meshes'])} meshes, {args.output.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
