#!/usr/bin/env python3
"""Build an offline, floor-selectable preview of the walkthrough building geometry."""
from __future__ import annotations

import argparse
import json
from itertools import chain
import math
from pathlib import Path
import re
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "models/walkthrough-building/floors-2-3"

HTML = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#e9ede8">
<title>Floors 2 &amp; 3 · InView</title>
<style>
:root{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",sans-serif;color:#303934;background:#e9ede8;color-scheme:light;font-synthesis:none}
*{box-sizing:border-box}body{margin:0}button,a{font:inherit;-webkit-tap-highlight-color:transparent;touch-action:manipulation}button{cursor:pointer;border:0;color:inherit}button:focus-visible,a:focus-visible,canvas:focus-visible{outline:3px solid #3573f2;outline-offset:4px}[hidden]{display:none!important}
.app{position:fixed;inset:0;min-height:360px;background:#e9ede8}.stage{position:absolute;inset:94px 0 82px}canvas{display:block;width:100%;height:100%;touch-action:none;cursor:grab}canvas:active{cursor:grabbing}
.header{position:absolute;inset:0 0 auto;display:flex;align-items:center;justify-content:space-between;padding:26px 32px;gap:18px;z-index:2}.title{font-size:24px;letter-spacing:-.8px;font-weight:650;margin:0}.glass{background:#f9fbf8e8;border:1px solid #fff9;box-shadow:0 4px 18px #24352708,0 0 0 1px #6477680a;backdrop-filter:blur(18px)}
.segmented{display:flex;flex-shrink:0;padding:4px;gap:3px;border-radius:100px}.segmented button{font-size:13px;font-weight:600;min-width:65px;height:34px;border-radius:100px;background:transparent;color:#6d7770}.segmented button:disabled{opacity:.45;cursor:default}.view-choice button{min-width:53px}.segmented button[aria-pressed=true]{background:white;color:#303934;box-shadow:0 2px 7px #2d443813}
.labels{position:absolute;inset:0;pointer-events:none;overflow:hidden}.map-label{position:absolute;display:flex;align-items:center;gap:6px;transform:translate(-50%,-100%);padding:7px 10px;border-radius:100px;background:#fbfdf9f2;color:#455149;font-size:12px;line-height:1.2;font-weight:600;white-space:nowrap;opacity:.94;box-shadow:0 2px 10px #34453312;border:1px solid #ffffffb3}.map-label::before{content:"";width:6px;height:6px;border-radius:50%;background:#809888;flex:none}.floor-choice{margin-left:auto}.floor-choice button{padding:0 17px}.separation{position:absolute;right:32px;top:83px;padding:3px}.separation button{height:28px;font-size:11px;min-width:69px;padding:0 11px}.app.both .stage{top:126px}.footer{position:absolute;bottom:27px;left:32px;z-index:2}.downloads{display:flex;gap:8px}.download{display:inline-flex;align-items:center;gap:8px;padding:11px 15px;border-radius:100px;color:#38483d;text-decoration:none;font-size:12px;font-weight:600}.download svg{width:14px;height:14px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}.note{margin:11px 0 0 2px;font-size:11px;color:#7b857d}.controls{position:absolute;right:32px;bottom:28px;display:flex;align-items:center;gap:8px;z-index:2}.controls button{width:42px;height:42px;border-radius:50%;font-size:24px;font-weight:350}.controls svg{height:19px;width:19px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}.hint{position:absolute;left:50%;bottom:36px;transform:translateX(-50%);font-size:11px;color:#8a928c;white-space:nowrap;pointer-events:none}.error{position:absolute;inset:20%;display:grid;place-items:center;text-align:center;font-size:15px;line-height:1.5;color:#69786f}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
@media(max-width:860px){.hint{display:none}.header{padding:24px;gap:10px}.floor-choice button{padding:0 12px;min-width:58px}.separation{right:24px}.footer{left:24px}.controls{right:24px}}@media(max-width:760px){.header{padding:20px 18px;display:grid;grid-template-columns:1fr auto;gap:12px}.floor-choice{grid-column:1/3;grid-row:2;margin:0 auto}.view-choice{grid-column:2;grid-row:1}.floor-choice button{padding:0 17px;min-width:70px}.separation{position:static;grid-column:1/3;grid-row:3;margin:0 auto}.app.both .stage{top:177px}.map-label{font-size:11px;padding:6px 8px;gap:5px}.view-choice button{min-width:43px}.title{font-size:21px;letter-spacing:-.6px}.segmented button{min-width:47px;font-size:12px}.stage{top:136px;bottom:133px}.footer{left:18px;bottom:27px}.note{font-size:10px;max-width:205px;line-height:1.5}.download{padding:10px 13px;font-size:11px}.controls{right:18px;bottom:82px;gap:6px}.controls button{height:35px;width:35px;font-size:22px}.controls svg{height:17px;width:17px}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
</style>
</head>
<body>
<main class="app">
<header class="header"><h1 class="title">Floors 2 &amp; 3</h1><div class="segmented glass floor-choice" role="group" aria-label="Floor"><button type="button" id="floor-2" aria-pressed="true">Floor 2</button><button type="button" id="floor-3" aria-pressed="false">Floor 3</button><button type="button" id="both" aria-pressed="false">Both floors</button></div><div class="segmented glass view-choice" role="group" aria-label="View"><button type="button" id="three-d" aria-pressed="true">3D</button><button type="button" id="top" aria-pressed="false">Top</button><button type="button" id="label-toggle" aria-pressed="true" title="Show room labels">Labels</button></div><div class="segmented glass separation" id="separation" role="group" aria-label="Floor arrangement" hidden><button type="button" id="stacked" aria-pressed="false">Stacked</button><button type="button" id="separated" aria-pressed="true">Separated</button></div></header>
<div class="stage" id="stage"><canvas id="view" tabindex="0" role="img" aria-label="Interactive 3D model of floor 2" aria-describedby="instructions"></canvas><div class="labels" id="labels" role="group" aria-label="Room labels"></div><div class="error" id="error" role="status" hidden></div></div>
<p class="sr-only" id="instructions">Drag to rotate. Shift-drag, right-drag, or drag with two fingers to move. Scroll or pinch to zoom. Arrow keys rotate; Shift and arrow keys move. Plus and minus zoom. Press T for top view, D for 3D, or Home to reset. Press 2 or 3 to select a floor, or B for both floors.</p>
<div class="footer"><div class="downloads"><a class="download glass" id="download-glb" href="floor-2.glb" download="floor-2.glb" aria-label="Download floor 2 as GLB"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2v8m-3-3 3 3 3-3M3 11v3h10v-3"/></svg>GLB model</a><a class="download glass" id="download-usdz" href="floor-2.usdz" download="floor-2.usdz" aria-label="Download floor 2 as USDZ">USDZ</a></div><p class="note">Approximate layout from your walkthrough</p></div>
<div class="controls" role="group" aria-label="Model controls"><button class="glass" id="reset" type="button" aria-label="Reset view" title="Reset view"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 10a8 8 0 1 1 1 7M4 4v6h6"/></svg></button><button class="glass" id="zoom-out" type="button" aria-label="Zoom out" title="Zoom out">−</button><button class="glass" id="zoom-in" type="button" aria-label="Zoom in" title="Zoom in">+</button></div>
<span class="hint" aria-hidden="true">Drag to rotate · Scroll to zoom · Shift-drag to move</span>
</main>
<script id="scene" type="application/json">__SCENE__</script>
<script>
'use strict';
const $=s=>document.querySelector(s),sceneNode=$('#scene'),scene=JSON.parse(sceneNode.textContent),canvas=$('#view'),gl=canvas.getContext('webgl',{alpha:true,antialias:true}),pointers=new Map();
sceneNode.textContent='';
const dot=(a,b)=>a[0]*b[0]+a[1]*b[1]+a[2]*b[2],unit=a=>{const d=Math.hypot(...a)||1;return a.map(v=>v/d)},clamp=(v,a,b)=>Math.min(b,Math.max(a,v));
const DEFAULT_YAW=__YAW__,DEFAULT_PITCH=__PITCH__,SEPARATION=__SEPARATION__,floors=new Map();
let yaw=DEFAULT_YAW,pitch=DEFAULT_PITCH,zoom=1,pan=[0,0],topView=false,savedOrbit=[yaw,pitch],gesture,program,locations,selectedFloor=2,separated=true,viewCenter=[0,0,0],viewSpan=1,visibleFloors=[],showLabels=true;
const labelEntries=[];
const lightToward=unit([-.65,1,.5]);
const vertexSource=`precision highp float;
attribute vec3 position,normal;
attribute vec4 color;
uniform vec3 center,right,up,toward;
uniform vec2 scale,offset;
uniform float depth,modelOffset;
varying vec3 surfaceNormal;
varying vec4 tint;
void main(){vec3 p=position+vec3(0.0,modelOffset,0.0)-center;gl_Position=vec4(dot(p,right)*scale.x+offset.x,dot(p,up)*scale.y+offset.y,-dot(p,toward)/depth,1.0);surfaceNormal=normal;tint=color;}`;
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
function buffer(data){const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);gl.bufferData(gl.ARRAY_BUFFER,data,gl.STATIC_DRAW);return b;}
function bind(b){gl.bindBuffer(gl.ARRAY_BUFFER,b);for(const[n,size,offset]of[['position',3,0],['normal',3,12],['color',4,24]]){gl.enableVertexAttribArray(locations[n]);gl.vertexAttribPointer(locations[n],size,gl.FLOAT,false,40,offset);}}
function slabEdges(rectangles){if(!rectangles.length)return[];const snap=v=>Math.round(v*10000)/10000,xs=[...new Set(rectangles.flatMap(r=>[snap(r.minX),snap(r.maxX)]))].sort((a,b)=>a-b),zs=[...new Set(rectangles.flatMap(r=>[snap(r.minZ),snap(r.maxZ)]))].sort((a,b)=>a-b),width=xs.length-1,height=zs.length-1,cells=new Uint8Array(width*height),edges=[];for(let z=0;z<height;z++)for(let x=0;x<width;x++){const mx=(xs[x]+xs[x+1])*.5,mz=(zs[z]+zs[z+1])*.5;cells[z*width+x]=Number(rectangles.some(r=>mx>=r.minX-.0001&&mx<=r.maxX+.0001&&mz>=r.minZ-.0001&&mz<=r.maxZ+.0001));}for(let z=0;z<height;z++)for(let x=0;x<width;x++){if(!cells[z*width+x])continue;const x0=xs[x],x1=xs[x+1],z0=zs[z],z1=zs[z+1];if(x===0||!cells[z*width+x-1])edges.push({a:[x0,z0],b:[x0,z1],out:[-1,0]});if(x===width-1||!cells[z*width+x+1])edges.push({a:[x1,z1],b:[x1,z0],out:[1,0]});if(z===0||!cells[(z-1)*width+x])edges.push({a:[x1,z0],b:[x0,z0],out:[0,-1]});if(z===height-1||!cells[(z+1)*width+x])edges.push({a:[x0,z1],b:[x1,z1],out:[0,1]});}return edges;}
function makeGroundShadow(floor){const edges=slabEdges(floor.slabs),data=new Float32Array(edges.length*6*10),height=floor.slabs.reduce((lowest,r)=>Math.min(lowest,r.bottom),floor.elevation)-.035;let cursor=0;for(const edge of edges){const points=[{p:edge.a,d:.015,alpha:.055},{p:edge.b,d:.015,alpha:.055},{p:edge.b,d:.25,alpha:0},{p:edge.a,d:.25,alpha:0}];for(const i of[0,1,2,0,2,3]){const v=points[i];data[cursor++]=v.p[0]+edge.out[0]*v.d;data[cursor++]=height;data[cursor++]=v.p[1]+edge.out[1]*v.d;data[cursor++]=0;data[cursor++]=1;data[cursor++]=0;data[cursor++]=.25;data[cursor++]=.31;data[cursor++]=.27;data[cursor++]=v.alpha;}}floor.groundCount=data.length/10;floor.groundBuffer=buffer(data);}
function buildFloor(metadata){const meshes=scene.meshes.filter(m=>m.floor===metadata.id),triangleCount=meshes.reduce((n,m)=>n+m.triangles.length,0),data=new Float32Array(triangleCount*3*10),floor={id:metadata.id,title:metadata.title,elevation:metadata.elevation,low:[Infinity,Infinity,Infinity],high:[-Infinity,-Infinity,-Infinity],fitPoints:[],slabs:[],count:triangleCount*3,offset:0};let cursor=0;
 for(const mesh of meshes){const color=[1,3,5].map(i=>parseInt(mesh.color.slice(i,i+2),16)/255),meshLow=[Infinity,Infinity,Infinity],meshHigh=[-Infinity,-Infinity,-Infinity];for(const p of mesh.vertices)for(let i=0;i<3;i++){meshLow[i]=Math.min(meshLow[i],p[i]);meshHigh[i]=Math.max(meshHigh[i],p[i]);}for(let i=0;i<3;i++){floor.low[i]=Math.min(floor.low[i],meshLow[i]);floor.high[i]=Math.max(floor.high[i],meshHigh[i]);}for(let i=0;i<8;i++)floor.fitPoints.push(meshLow.map((v,a)=>i&(1<<a)?meshHigh[a]:v));if(Math.abs(meshHigh[1]-metadata.elevation)<=.04001&&meshHigh[1]-meshLow[1]<=.30001&&meshHigh[0]-meshLow[0]>.5&&meshHigh[2]-meshLow[2]>.5)floor.slabs.push({minX:meshLow[0],maxX:meshHigh[0],minZ:meshLow[2],maxZ:meshHigh[2],bottom:meshLow[1]});
  for(const triangle of mesh.triangles)for(const index of triangle){const p=mesh.vertices[index],n=mesh.normals[index];data[cursor++]=p[0];data[cursor++]=p[1];data[cursor++]=p[2];data[cursor++]=n[0];data[cursor++]=n[1];data[cursor++]=n[2];data[cursor++]=color[0];data[cursor++]=color[1];data[cursor++]=color[2];data[cursor++]=1;}}
 floor.meshBuffer=buffer(data);makeGroundShadow(floor);floors.set(floor.id,floor);}
function setup(){program=makeProgram(vertexSource,fragmentSource);locations=locate(program,['position','normal','color'],['center','right','up','toward','scale','offset','depth','modelOffset','lightToward','ground']);for(const metadata of scene.floors)buildFloor(metadata);scene.meshes=[];
 gl.enable(gl.DEPTH_TEST);gl.depthFunc(gl.LEQUAL);gl.disable(gl.CULL_FACE);gl.enable(gl.BLEND);gl.blendFuncSeparate(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA,gl.ONE,gl.ONE_MINUS_SRC_ALPHA);updateSelection();}
function updateSelection(){visibleFloors=selectedFloor==='both'?[floors.get(2),floors.get(3)]:[floors.get(selectedFloor)];const low=[Infinity,Infinity,Infinity],high=[-Infinity,-Infinity,-Infinity];for(const floor of visibleFloors){floor.offset=selectedFloor==='both'&&separated&&floor.id===3?SEPARATION:0;for(let i=0;i<3;i++){const shift=i===1?floor.offset:0;low[i]=Math.min(low[i],floor.low[i]+shift);high[i]=Math.max(high[i],floor.high[i]+shift);}}viewCenter=low.map((v,i)=>(v+high[i])/2);viewSpan=Math.max(...low.map((v,i)=>high[i]-v));draw();}
function draw(){if(!program||!visibleFloors.length)return;gl.useProgram(program);gl.viewport(0,0,canvas.width,canvas.height);gl.clearColor(0,0,0,0);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);const rect=canvas.getBoundingClientRect();if(rect.width<2||rect.height<2)return;const right=[Math.cos(yaw),0,-Math.sin(yaw)],up=[-Math.sin(yaw)*Math.sin(pitch),Math.cos(pitch),-Math.cos(yaw)*Math.sin(pitch)],toward=[Math.sin(yaw)*Math.cos(pitch),Math.sin(pitch),Math.cos(yaw)*Math.cos(pitch)];let left=Infinity,rightmost=-Infinity,bottom=Infinity,top=-Infinity;for(const floor of visibleFloors)for(const corner of floor.fitPoints){const x=corner[0]-viewCenter[0],y=corner[1]+floor.offset-viewCenter[1],z=corner[2]-viewCenter[2],screenX=x*right[0]+y*right[1]+z*right[2],screenY=x*up[0]+y*up[1]+z*up[2];left=Math.min(left,screenX);rightmost=Math.max(rightmost,screenX);bottom=Math.min(bottom,screenY);top=Math.max(top,screenY);}const pixels=Math.min(rect.width*.90/Math.max(.1,rightmost-left),rect.height*.96/Math.max(.1,top-bottom))*zoom,scale=[2*pixels/rect.width,2*pixels/rect.height],offset=[-(left+rightmost)*.5*scale[0]+pan[0]*2/rect.width,-(bottom+top)*.5*scale[1]+pan[1]*2/rect.height];const l=locations;gl.uniform3fv(l.center,viewCenter);gl.uniform3fv(l.right,right);gl.uniform3fv(l.up,up);gl.uniform3fv(l.toward,toward);gl.uniform2fv(l.scale,scale);gl.uniform2fv(l.offset,offset);gl.uniform1f(l.depth,viewSpan*2);gl.uniform3fv(l.lightToward,lightToward);
 // Only the lowest visible floor casts a ground shadow, avoiding a floating shadow sheet between levels.
 const groundFloor=visibleFloors[0];if(!topView&&groundFloor.groundCount){gl.uniform1i(l.ground,1);gl.uniform1f(l.modelOffset,groundFloor.offset);bind(groundFloor.groundBuffer);gl.depthMask(false);gl.drawArrays(gl.TRIANGLES,0,groundFloor.groundCount);gl.depthMask(true);}gl.uniform1i(l.ground,0);for(const floor of visibleFloors){gl.uniform1f(l.modelOffset,floor.offset);bind(floor.meshBuffer);gl.drawArrays(gl.TRIANGLES,0,floor.count);}renderLabels({right,up,scale,offset,width:rect.width,height:rect.height});}
function buildLabels(){for(const label of scene.labels||[]){const element=document.createElement('span');element.className='map-label';element.textContent=label.title;element.hidden=true;$('#labels').append(element);labelEntries.push({...label,element});}}
function renderLabels(frame){const candidates=[];for(const label of labelEntries){const visible=showLabels&&selectedFloor!=='both'&&label.floor===selectedFloor;label.element.hidden=!visible;if(visible)candidates.push(label);}if(!candidates.length)return;const floor=floors.get(selectedFloor),dimensions=candidates.map(label=>[label.element.offsetWidth,label.element.offsetHeight]),occupied=[],margin=9,gap=8;for(let i=0;i<candidates.length;i++){const label=candidates[i],p=[label.position[0]-viewCenter[0],label.position[1]+floor.offset-viewCenter[1],label.position[2]-viewCenter[2]],x=(dot(p,frame.right)*frame.scale[0]+frame.offset[0]+1)*frame.width*.5,y=(1-dot(p,frame.up)*frame.scale[1]-frame.offset[1])*frame.height*.5,w=dimensions[i][0],h=dimensions[i][1],rect={left:x-w*.5,right:x+w*.5,top:y-h,bottom:y};const clipped=rect.left<margin||rect.top<margin||rect.right>frame.width-margin||rect.bottom>frame.height-margin,overlaps=occupied.some(r=>rect.left<r.right+gap&&rect.right>r.left-gap&&rect.top<r.bottom+gap&&rect.bottom>r.top-gap);if(clipped||overlaps){label.element.hidden=true;continue;}label.element.style.left=x+'px';label.element.style.top=y+'px';occupied.push(rect);}}
function toggleLabels(){if(selectedFloor==='both')return;showLabels=!showLabels;updateControls();draw();}
function updateControls(){for(const choice of[2,3,'both'])$('#'+(choice==='both'?'both':'floor-'+choice)).setAttribute('aria-pressed',String(selectedFloor===choice));$('#separation').hidden=selectedFloor!=='both';$('.app').classList.toggle('both',selectedFloor==='both');$('#stacked').setAttribute('aria-pressed',String(!separated));$('#separated').setAttribute('aria-pressed',String(separated));const basename=selectedFloor==='both'?'building':'floor-'+selectedFloor,label=selectedFloor==='both'?'both floors':'floor '+selectedFloor;for(const format of['glb','usdz']){const link=$('#download-'+format);link.href=basename+'.'+format;link.download=basename+'.'+format;link.setAttribute('aria-label','Download '+label+' as '+format.toUpperCase());}canvas.setAttribute('aria-label','Interactive 3D model of '+label);const labelsButton=$('#label-toggle');labelsButton.hidden=!labelEntries.length;labelsButton.disabled=selectedFloor==='both';labelsButton.setAttribute('aria-pressed',String(showLabels));labelsButton.title=selectedFloor==='both'?'Select one floor to show labels':showLabels?'Hide room labels':'Show room labels';}
function chooseFloor(choice){selectedFloor=choice;zoom=1;pan=[0,0];updateControls();if(program)updateSelection();resize();}
function chooseArrangement(value){separated=value;zoom=1;pan=[0,0];updateControls();if(program)updateSelection();}
function resize(){const rect=canvas.getBoundingClientRect(),dpi=Math.min(2,devicePixelRatio||1);canvas.width=Math.max(1,Math.round(rect.width*dpi));canvas.height=Math.max(1,Math.round(rect.height*dpi));draw();}
function setZoom(value){zoom=clamp(value,.4,4);draw();}
function setView(top){if(top!==topView){if(top){savedOrbit=[yaw,pitch];yaw=0;pitch=Math.PI/2;}else{[yaw,pitch]=savedOrbit;}topView=top;pan=[0,0];}$('#three-d').setAttribute('aria-pressed',String(!topView));$('#top').setAttribute('aria-pressed',String(topView));draw();}
function reset(){zoom=1;pan=[0,0];yaw=topView?0:DEFAULT_YAW;pitch=topView?Math.PI/2:DEFAULT_PITCH;savedOrbit=[DEFAULT_YAW,DEFAULT_PITCH];draw();}
for(const choice of[2,3,'both'])$('#'+(choice==='both'?'both':'floor-'+choice)).addEventListener('click',()=>chooseFloor(choice));$('#stacked').addEventListener('click',()=>chooseArrangement(false));$('#separated').addEventListener('click',()=>chooseArrangement(true));
$('#label-toggle').addEventListener('click',toggleLabels);
$('#three-d').addEventListener('click',()=>setView(false));$('#top').addEventListener('click',()=>setView(true));$('#reset').addEventListener('click',reset);$('#zoom-in').addEventListener('click',()=>setZoom(zoom*1.2));$('#zoom-out').addEventListener('click',()=>setZoom(zoom/1.2));canvas.addEventListener('contextmenu',e=>e.preventDefault());
canvas.addEventListener('pointerdown',e=>{canvas.setPointerCapture(e.pointerId);pointers.set(e.pointerId,{x:e.clientX,y:e.clientY,pan:e.shiftKey||e.button===2||e.button===1});gesture=undefined;canvas.focus({preventScroll:true});});
canvas.addEventListener('pointermove',e=>{if(!pointers.has(e.pointerId))return;const previous=pointers.get(e.pointerId);pointers.set(e.pointerId,{...previous,x:e.clientX,y:e.clientY});if(pointers.size>=2){const[a,b]=[...pointers.values()],current={distance:Math.hypot(a.x-b.x,a.y-b.y),x:(a.x+b.x)/2,y:(a.y+b.y)/2};if(gesture){zoom=clamp(zoom*current.distance/Math.max(1,gesture.distance),.4,4);pan[0]+=current.x-gesture.x;pan[1]-=current.y-gesture.y;}gesture=current;}else{const dx=e.clientX-previous.x,dy=e.clientY-previous.y;if(previous.pan||e.shiftKey||topView){pan[0]+=dx;pan[1]-=dy;}else{yaw+=dx*.006;pitch=clamp(pitch+dy*.004,.16,1.4);}}draw();});
for(const name of['pointerup','pointercancel','lostpointercapture'])canvas.addEventListener(name,e=>{pointers.delete(e.pointerId);gesture=undefined;});
canvas.addEventListener('wheel',e=>{e.preventDefault();setZoom(zoom*Math.exp(-e.deltaY*.001));},{passive:false});
canvas.addEventListener('keydown',e=>{const k=e.key,handled=['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','+','=','-','0','Home','t','T','d','D','2','3','b','B'];if(!handled.includes(k))return;e.preventDefault();if(k==='2'||k==='3')chooseFloor(Number(k));else if(k==='b'||k==='B')chooseFloor('both');else if(k==='t'||k==='T')setView(true);else if(k==='d'||k==='D')setView(false);else if(k==='+'||k==='=')setZoom(zoom*1.2);else if(k==='-')setZoom(zoom/1.2);else if(k==='0'||k==='Home')reset();else if(e.shiftKey||topView){if(k==='ArrowLeft')pan[0]-=24;if(k==='ArrowRight')pan[0]+=24;if(k==='ArrowUp')pan[1]+=24;if(k==='ArrowDown')pan[1]-=24;}else{if(k==='ArrowLeft')yaw-=.12;if(k==='ArrowRight')yaw+=.12;if(k==='ArrowUp')pitch=clamp(pitch+.08,.16,1.4);if(k==='ArrowDown')pitch=clamp(pitch-.08,.16,1.4);}draw();});
canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();program=null;showError('The preview was interrupted. Reload this page to view the model again.');});
buildLabels();updateControls();
if(!gl)showError('This browser cannot show the 3D preview. You can still download the models.');else{try{setup();new ResizeObserver(resize).observe($('#stage'));resize();}catch(error){console.error(error);program=null;showError('The 3D preview could not start. You can still download the models.');}}
</script>
</body>
</html>
'''


def validate_scene(scene: dict) -> None:
    """Reject malformed input rather than silently displaying missing geometry."""
    if not scene.get("meshes"):
        raise ValueError("The scene has no meshes")
    floors = scene.get("floors", [])
    if len(floors) != 2 or {f.get("id") for f in floors} != {2, 3}:
        raise ValueError("Scene floors must contain exactly IDs 2 and 3")
    for floor in floors:
        if type(floor["id"]) is not int or not isinstance(floor.get("title"), str) or not floor["title"].strip():
            raise ValueError("Each floor needs an integer ID and title")
        if type(floor.get("elevation")) not in (int, float) or not math.isfinite(floor["elevation"]):
            raise ValueError("Each floor needs a finite world-space elevation")
    labels = scene.get("labels", [])
    if not isinstance(labels, list):
        raise ValueError("Scene labels must be a list")
    for label in labels:
        if type(label.get("floor")) is not int or label["floor"] not in (2, 3):
            raise ValueError("Each label must belong to floor 2 or 3")
        if not isinstance(label.get("title"), str) or not label["title"].strip():
            raise ValueError("Each label needs a title")
        position = label.get("position", [])
        if len(position) != 3 or not all(type(v) in (int, float) and math.isfinite(v) for v in position):
            raise ValueError("Each label needs a finite world-space position")
    counts = {2: 0, 3: 0}
    bounds = scene["bounds"]
    for key in ("min", "max"):
        if len(bounds[key]) != 3 or not all(math.isfinite(v) for v in bounds[key]):
            raise ValueError(f"Invalid scene bounds: {key}")
    if any(lo >= hi for lo, hi in zip(bounds["min"], bounds["max"])):
        raise ValueError("The scene bounds must have positive dimensions")
    for mesh in scene["meshes"]:
        if type(mesh.get("floor")) is not int or mesh["floor"] not in counts:
            raise ValueError(f"Invalid floor in {mesh.get('name', 'unnamed mesh')}")
        counts[mesh["floor"]] += 1
        vertices, normals, triangles = mesh["vertices"], mesh["normals"], mesh["triangles"]
        if not vertices or not triangles or len(vertices) != len(normals):
            raise ValueError(f"Missing geometry in {mesh['name']}")
        if not re.fullmatch(r"#[0-9a-fA-F]{6}", mesh["color"]):
            raise ValueError(f"Invalid color in {mesh['name']}")
        for point in chain(vertices, normals):
            if len(point) != 3 or not all(math.isfinite(v) for v in point):
                raise ValueError(f"Invalid position or normal in {mesh['name']}")
        for triangle in triangles:
            if len(triangle) != 3 or any(type(i) is not int or not 0 <= i < len(vertices) for i in triangle):
                raise ValueError(f"Invalid triangle in {mesh['name']}")

    if not all(counts.values()):
        raise ValueError("Both floors must contain geometry")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene", type=Path, default=DESTINATION / "viewer-scene.json")
    parser.add_argument("--output", type=Path, default=DESTINATION / "preview.html")
    parser.add_argument("--yaw", type=float, default=2.5, help="Initial camera yaw in radians")
    parser.add_argument("--pitch", type=float, default=0.72, help="Initial camera elevation in radians")
    parser.add_argument("--separation", type=float, help="Extra preview-only elevation for floor 3 in separated mode")
    args = parser.parse_args()
    if not math.isfinite(args.yaw) or not 0.16 <= args.pitch <= 1.4:
        parser.error("Yaw must be finite and pitch must be between 0.16 and 1.4 radians")
    if args.separation is not None and (not math.isfinite(args.separation) or args.separation <= 0):
        parser.error("Separation must be a positive finite distance")
    scene = json.loads(args.scene.read_text())
    validate_scene(scene)
    bounds = scene["bounds"]
    separation = args.separation if args.separation is not None else max(6.0, max(bounds["max"][axis] - bounds["min"][axis] for axis in (0, 2)) * 0.55)
    payload = json.dumps(scene, separators=(",", ":"), ensure_ascii=False).replace("<", "\\u003c").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    html = HTML.replace("__SCENE__", payload).replace("__YAW__", repr(args.yaw)).replace("__PITCH__", repr(args.pitch)).replace("__SEPARATION__", repr(separation))
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
