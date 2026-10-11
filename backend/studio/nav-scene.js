// Navigation overlay for the main Three.js scene: nav graph, hazards, places, signs and the
// selected route, drawn near floor height in the scan's shared ARKit frame. Every object lives in
// a per-layer group so the 2D layer toggles also drive the 3D view; `dispose` frees GPU memory.
import * as THREE from './three.module.js';
import {
  CLEAR_WIDTH_COLORS, HAZARD_STYLES, PLACE_STYLES, SIGN_STYLES, UNKNOWN_PLACE, UNKNOWN_SIGN, bounds,
  clearWidthClass, placeName, styleFor,
} from './nav-model.js';

const OVERLAY_LAYERS = ['graph', 'hazards', 'places', 'signs', 'route'];
const LIFT = 0.035;
const CLOSED_COLOR = '#4b5563';
// Sprites keep a constant on-screen size (fraction of the view height) so labels stay legible.
const BADGE = 0.042;

/** Frees geometries, materials and textures below `parent`, then empties it. */
export function disposeChildren(parent) {
  for (const child of [...parent.children]) {
    child.traverse((node) => {
      node.geometry?.dispose();
      for (const material of node.material ? [].concat(node.material) : []) { material.map?.dispose(); material.dispose(); }
    });
    parent.remove(child);
  }
}

function floorHeight(model) {
  if (Number.isFinite(model.floor?.height)) return model.floor.height;
  if (model.graph?.nodes.size) {
    let height = Infinity;
    for (const node of model.graph.nodes.values()) height = Math.min(height, node.position[1]);
    return height;
  }
  return 0;
}

function badgeTexture(style, square, caption) {
  const canvas = document.createElement('canvas');
  const width = caption ? 512 : 128, height = 128;
  canvas.width = width; canvas.height = height;
  const context = canvas.getContext('2d');
  const r = 46, cx = 64, cy = 64;
  context.beginPath();
  if (square) context.roundRect(cx - r, cy - r, r * 2, r * 2, 16); else context.arc(cx, cy, r, 0, Math.PI * 2);
  context.fillStyle = style.color; context.fill();
  context.lineWidth = 9; context.strokeStyle = '#fff'; context.stroke();
  context.fillStyle = '#fff'; context.textAlign = 'center'; context.textBaseline = 'middle';
  context.font = `700 ${style.glyph.length > 2 ? 34 : style.glyph.length > 1 ? 42 : 54}px -apple-system, sans-serif`;
  context.fillText(style.glyph, cx, cy + 3);
  if (caption) {
    const value = caption.length > 22 ? `${caption.slice(0, 21)}…` : caption;
    context.font = '650 40px -apple-system, sans-serif'; context.textAlign = 'left';
    const textWidth = Math.min(width - 132, context.measureText(value).width);
    context.fillStyle = 'rgba(16,25,35,.78)';
    context.beginPath(); context.roundRect(118, 34, textWidth + 28, 60, 14); context.fill();
    context.fillStyle = '#fff'; context.fillText(value, 132, 66, width - 146);
  }
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  return { texture, aspect: width / height };
}

function sprite(style, square, caption, size) {
  const { texture, aspect } = badgeTexture(style, square, caption);
  const item = new THREE.Sprite(new THREE.SpriteMaterial({ map: texture, depthTest: false, transparent: true, sizeAttenuation: false }));
  item.scale.set(size * aspect, size, 1);
  // Anchor the badge (left square of the texture) on the point, the caption to its right.
  item.center.set(0.5 / aspect, 0.5);
  item.renderOrder = 30;
  return item;
}

function onTop(material, order, object) {
  material.depthTest = false; material.transparent = true;
  object.renderOrder = order;
  return object;
}

function ribbon(points, radius, color) {
  const curve = new THREE.CurvePath();
  for (let i = 1; i < points.length; i++) if (points[i].distanceTo(points[i - 1]) > 1e-4) curve.add(new THREE.LineCurve3(points[i - 1], points[i]));
  if (!curve.curves.length) return null;
  const material = new THREE.MeshBasicMaterial({ color, opacity: .95 });
  return onTop(material, 20, new THREE.Mesh(new THREE.TubeGeometry(curve, Math.min(800, curve.curves.length * 6), radius, 8, false), material));
}

export function createNavOverlay(root, onChange = () => {}) {
  const layers = Object.fromEntries(OVERLAY_LAYERS.map((name) => { const g = new THREE.Group(); g.name = `nav-${name}`; root.add(g); return [name, g]; }));
  let current = { model: null, floorY: 0, size: .3, lang: 'en' };

  function vec([x, y, z], lift = LIFT) { return new THREE.Vector3(x, y + lift, z); }
  function floorVec(x, z) { return new THREE.Vector3(x, current.floorY + LIFT, z); }

  function drawGraph(model) {
    if (!model.graph) return;
    // Solid: step-free or unknown surface edges. Dashed: not step-free, connector transitions or
    // closed. Color always encodes clear width (closed edges are slate), matching the 2D map.
    const solid = { positions: [], colors: [] }, dashed = { positions: [], colors: [] };
    const color = new THREE.Color();
    for (const edge of model.graph.unique) {
      color.set(edge.closed ? CLOSED_COLOR : CLEAR_WIDTH_COLORS[clearWidthClass(edge.width)]);
      const target = edge.stepFree === false || edge.transition || edge.closed ? dashed : solid;
      for (let i = 1; i < edge.points.length; i++) {
        target.positions.push(...vec(edge.points[i - 1]).toArray(), ...vec(edge.points[i]).toArray());
        target.colors.push(color.r, color.g, color.b, color.r, color.g, color.b);
      }
    }
    for (const [batch, isDashed] of [[solid, false], [dashed, true]]) {
      if (!batch.positions.length) continue;
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(batch.positions, 3));
      geometry.setAttribute('color', new THREE.Float32BufferAttribute(batch.colors, 3));
      const material = isDashed
        ? new THREE.LineDashedMaterial({ vertexColors: true, dashSize: .12, gapSize: .08, opacity: .9 })
        : new THREE.LineBasicMaterial({ vertexColors: true, opacity: .9 });
      const lines = new THREE.LineSegments(geometry, material);
      if (isDashed) lines.computeLineDistances();
      layers.graph.add(onTop(material, 12, lines));
    }
    const nodes = [...model.graph.nodes.values()].flatMap((node) => vec(node.position).toArray());
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.Float32BufferAttribute(nodes, 3));
    const material = new THREE.PointsMaterial({ color: '#f4f8fb', size: 6, sizeAttenuation: false });
    layers.graph.add(onTop(material, 13, new THREE.Points(geometry, material)));
  }

  function drawHazards(model) {
    for (const hazard of model.hazards) {
      const style = HAZARD_STYLES[hazard.severity];
      let shape = null;
      if (hazard.polygon) {
        shape = new THREE.Shape(hazard.polygon.map(([x, z]) => new THREE.Vector2(x, -z)));
      }
      const geometry = shape ? new THREE.ShapeGeometry(shape) : new THREE.CircleGeometry(.28, 28);
      const material = new THREE.MeshBasicMaterial({ color: style.color, opacity: .38, side: THREE.DoubleSide });
      const mesh = onTop(material, 14, new THREE.Mesh(geometry, material));
      mesh.rotation.x = -Math.PI / 2;
      const y = hazard.position ? Math.min(hazard.position[1], current.floorY) : current.floorY;
      if (shape) mesh.position.y = y + LIFT * .5;
      else mesh.position.set(hazard.center[0], y + LIFT * .5, hazard.center[1]);
      layers.hazards.add(mesh);
      const marker = sprite(style, false, '', BADGE * .8);
      marker.position.copy(floorVec(hazard.center[0], hazard.center[1])).add(new THREE.Vector3(0, current.size * .5, 0));
      layers.hazards.add(marker);
    }
  }

  function pin(position, item, group) {
    const base = floorVec(position[0], position[2]);
    const top = base.clone().add(new THREE.Vector3(0, Math.max(current.size * 2.2, .5), 0));
    const geometry = new THREE.BufferGeometry().setFromPoints([base, top]);
    const material = new THREE.LineBasicMaterial({ color: '#f4f8fb', opacity: .7 });
    group.add(onTop(material, 15, new THREE.Line(geometry, material)));
    item.position.copy(top);
    group.add(item);
  }

  function drawPlaces(model, lang) {
    for (const place of model.places) {
      if (!place.position) continue;
      pin(place.position, sprite(styleFor(PLACE_STYLES, place.category, UNKNOWN_PLACE), false, placeName(place, lang), BADGE), layers.places);
    }
  }

  function drawSigns(model) {
    for (const sign of model.signs) {
      if (!sign.position) continue;
      // Signs keep their measured mounting position (on the wall), not floor height.
      const item = sprite(styleFor(SIGN_STYLES, sign.category, UNKNOWN_SIGN), true, sign.text, BADGE * .75);
      item.position.set(...sign.position);
      layers.signs.add(item);
    }
  }

  return {
    /** Rebuilds the overlay for a model (or clears it with null). */
    setModel(model, lang = 'en') {
      onChange();
      for (const group of Object.values(layers)) disposeChildren(group);
      current = { model, floorY: 0, size: .3, lang };
      if (!model) return;
      const box = bounds(model);
      const extent = box ? Math.hypot(box.maxX - box.minX, box.maxZ - box.minZ) : 6;
      current.floorY = floorHeight(model);
      current.size = Math.min(.7, Math.max(.16, extent * .03));
      drawGraph(model); drawHazards(model); drawPlaces(model, lang); drawSigns(model);
    },
    setLanguage(lang) {
      if (!current.model || lang === current.lang) return;
      current.lang = lang;
      onChange();
      disposeChildren(layers.places);
      drawPlaces(current.model, lang);
    },
    setRoute(route) {
      onChange();
      disposeChildren(layers.route);
      if (!route || route.path.length < 2) return;
      const points = route.path.map((point) => vec(point, LIFT * 2));
      const tube = ribbon(points, Math.max(.025, current.size * .12), '#3d9bff');
      if (tube) layers.route.add(tube);
      for (const [index, point] of [[0, points[0]], [1, points.at(-1)]]) {
        const geometry = new THREE.SphereGeometry(Math.max(.05, current.size * .25), 18, 12);
        const material = new THREE.MeshBasicMaterial({ color: index ? '#3d9bff' : '#ffffff' });
        const marker = onTop(material, 21, new THREE.Mesh(geometry, material));
        marker.position.copy(point);
        layers.route.add(marker);
      }
    },
    setVisibility(enabled, layerState) {
      onChange();
      root.visible = enabled;
      for (const [name, group] of Object.entries(layers)) group.visible = layerState[name] !== false;
    },
    dispose() { for (const group of Object.values(layers)) disposeChildren(group); current = { model: null, floorY: 0, size: .3, lang: 'en' }; onChange(); },
  };
}
