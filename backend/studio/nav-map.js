// Top-down 2D navigation map drawn on a <canvas>. Data is drawn as pixels (never as markup), so
// labels from OCR or uploads cannot inject HTML. Coordinates follow the floor_map grid: +X right,
// +Z down the page, one raster cell centered on each integer grid coordinate.
import {
  CLEAR_WIDTH_COLORS, HAZARD_STYLES, PLACE_STYLES, REGION_STYLES, SIGN_STYLES, UNKNOWN_PLACE, UNKNOWN_REGION,
  UNKNOWN_SIGN, bounds, clearWidthClass, humanize, meters, placeName, styleFor,
} from './nav-model.js';

const SIZE = 720;
const PAD = 26;
const FONT = '-apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif';

export const LAYERS = [
  { id: 'floor', label: 'Floor raster' },
  { id: 'regions', label: 'Regions' },
  { id: 'obstacles', label: 'Obstacles' },
  { id: 'narrow', label: 'Narrow passages' },
  { id: 'doors', label: 'Doors' },
  { id: 'hazards', label: 'Hazards' },
  { id: 'signs', label: 'Signs & text' },
  { id: 'places', label: 'Places' },
  { id: 'graph', label: 'Nav graph' },
  { id: 'route', label: 'Route' },
];

/** Number of drawable items per layer (0 disables the toggle). */
export function layerCounts(model) {
  return {
    floor: model.floor && (model.floor.png || model.floor.outlines.length) ? 1 : 0,
    regions: model.regions.length,
    obstacles: model.floor?.obstacles.length || 0,
    narrow: model.floor?.narrow.length || 0,
    doors: model.doors.length,
    hazards: model.hazards.length,
    signs: model.signs.filter((s) => s.position).length + model.text.filter((t) => t.position).length,
    places: model.places.filter((p) => p.position).length,
    graph: model.graph ? model.graph.nodes.size : 0,
    route: model.routes.routes.filter((r) => r.path.length > 1).length,
  };
}

export function createMapView(canvas) {
  const context = canvas.getContext('2d');
  const view = { model: null, image: null, layers: {}, route: null, lang: 'en', step: null, epoch: 0 };
  const ratio = Math.min(2, Math.max(1, window.devicePixelRatio || 1));
  canvas.width = SIZE * ratio; canvas.height = SIZE * ratio;

  function projection() {
    const { model, image } = view;
    const grid = model.floor?.grid;
    if (grid && image) {
      const scale = Math.min((SIZE - 2 * PAD) / image.width, (SIZE - 2 * PAD) / image.height);
      const ox = (SIZE - image.width * scale) / 2, oy = (SIZE - image.height * scale) / 2;
      const [x0, z0] = grid.origin, cell = grid.resolution;
      return { image: { ox, oy, scale }, perMeter: scale / cell, at: ([x, z]) => [ox + ((x - x0) / cell + 0.5) * scale, oy + ((z - z0) / cell + 0.5) * scale] };
    }
    const box = bounds(model);
    if (!box) return null;
    const spanX = Math.max(box.maxX - box.minX, 1), spanZ = Math.max(box.maxZ - box.minZ, 1);
    const scale = Math.min((SIZE - 2 * PAD) / spanX, (SIZE - 2 * PAD) / spanZ);
    const ox = (SIZE - spanX * scale) / 2 - box.minX * scale, oy = (SIZE - spanZ * scale) / 2 - box.minZ * scale;
    return { image: null, perMeter: scale, at: ([x, z]) => [ox + x * scale, oy + z * scale] };
  }

  function path(points, at, close = false) {
    context.beginPath();
    points.forEach((point, index) => { const [x, y] = at(point); if (index) context.lineTo(x, y); else context.moveTo(x, y); });
    if (close) context.closePath();
  }
  function label(textValue, x, y, { size = 11, weight = 600, color = '#1d1d1f', align = 'center', max = 26 } = {}) {
    if (!textValue) return;
    const value = textValue.length > max ? `${textValue.slice(0, max - 1)}…` : textValue;
    context.font = `${weight} ${size}px ${FONT}`;
    context.textAlign = align; context.textBaseline = 'middle';
    context.lineJoin = 'round'; context.lineWidth = 3.5; context.strokeStyle = 'rgba(255,255,255,.92)';
    context.strokeText(value, x, y);
    context.fillStyle = color; context.fillText(value, x, y);
  }
  function badge(x, y, style, shape = 'circle', radius = 11) {
    context.beginPath();
    if (shape === 'square') context.roundRect(x - radius, y - radius, radius * 2, radius * 2, 4);
    else context.arc(x, y, radius, 0, Math.PI * 2);
    context.fillStyle = style.color; context.fill();
    context.lineWidth = 2; context.strokeStyle = '#fff'; context.stroke();
    const glyph = style.glyph;
    context.font = `700 ${glyph.length > 2 ? 8 : glyph.length > 1 ? 9.5 : 12}px ${FONT}`;
    context.textAlign = 'center'; context.textBaseline = 'middle'; context.fillStyle = '#fff';
    context.fillText(glyph, x, y + 0.5);
  }
  function arrow(x, y, dx, dz, length, color) {
    const norm = Math.hypot(dx, dz) || 1, ux = dx / norm, uy = dz / norm;
    const ex = x + ux * length, ey = y + uy * length;
    context.beginPath(); context.moveTo(x, y); context.lineTo(ex, ey);
    context.strokeStyle = color; context.lineWidth = 2.5; context.stroke();
    context.beginPath(); context.moveTo(ex, ey);
    context.lineTo(ex - ux * 7 - uy * 5, ey - uy * 7 + ux * 5);
    context.lineTo(ex - ux * 7 + uy * 5, ey - uy * 7 - ux * 5);
    context.closePath(); context.fillStyle = color; context.fill();
  }
  function hazardMarker(x, y, severity) {
    const style = HAZARD_STYLES[severity];
    context.beginPath();
    if (severity === 'barrier') {
      for (let i = 0; i < 8; i++) { const a = Math.PI / 8 + i * Math.PI / 4; context.lineTo(x + Math.cos(a) * 11, y + Math.sin(a) * 11); }
    } else { context.moveTo(x, y - 12); context.lineTo(x + 11, y + 8); context.lineTo(x - 11, y + 8); }
    context.closePath(); context.fillStyle = style.color; context.fill();
    context.lineWidth = 2; context.strokeStyle = '#fff'; context.stroke();
    context.fillStyle = '#fff';
    if (severity === 'barrier') context.fillRect(x - 6, y - 1.75, 12, 3.5);
    else { context.font = `800 12px ${FONT}`; context.textAlign = 'center'; context.textBaseline = 'middle'; context.fillText('!', x, y + 1.5); }
  }

  function draw() {
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, SIZE, SIZE);
    context.fillStyle = '#fbfbfc'; context.fillRect(0, 0, SIZE, SIZE);
    const { model, layers } = view;
    if (!model) return;
    const projected = projection();
    if (!projected) { label('No map geometry in this analysis.', SIZE / 2, SIZE / 2, { size: 14, color: '#6e6e73', max: 60 }); return; }
    const { at, perMeter } = projected;
    const on = (id) => layers[id] !== false;
    context.lineCap = 'round'; context.lineJoin = 'round'; context.setLineDash([]);

    if (on('floor') && model.floor) {
      if (projected.image && view.image) {
        const { ox, oy, scale } = projected.image;
        context.imageSmoothingEnabled = false;
        context.drawImage(view.image, ox, oy, view.image.width * scale, view.image.height * scale);
      } else {
        for (const outline of model.floor.outlines) { path(outline, at, true); context.fillStyle = '#ecebe7'; context.fill(); context.strokeStyle = '#b9b7b0'; context.lineWidth = 1.5; context.stroke(); }
      }
    }
    if (on('regions')) {
      for (const region of model.regions) {
        const style = styleFor(REGION_STYLES, region.kind, UNKNOWN_REGION);
        path(region.polygon, at, true);
        context.globalAlpha = .16; context.fillStyle = style.fill; context.fill();
        context.globalAlpha = .9; context.strokeStyle = style.fill; context.lineWidth = 1.5;
        context.setLineDash(region.kind === 'doorway' ? [4, 3] : []); context.stroke();
        context.globalAlpha = 1; context.setLineDash([]);
      }
    }
    if (on('obstacles')) {
      for (const obstacle of model.floor?.obstacles || []) {
        context.save();
        if (obstacle.polygon) path(obstacle.polygon, at, true);
        else {
          const [x, y] = at(obstacle.center);
          context.translate(x, y); context.rotate(obstacle.angle * Math.PI / 180);
          context.beginPath(); context.rect(-obstacle.size[0] * perMeter / 2, -obstacle.size[1] * perMeter / 2, obstacle.size[0] * perMeter, obstacle.size[1] * perMeter);
        }
        context.fillStyle = 'rgba(70,64,60,.28)'; context.fill();
        context.strokeStyle = '#3f3a36'; context.lineWidth = 1.5; context.stroke();
        context.restore();
      }
    }
    if (on('graph') && model.graph) {
      for (const edge of model.graph.unique) {
        const kind = clearWidthClass(edge.width);
        path(edge.points.map(([x, , z]) => [x, z]), at);
        context.strokeStyle = edge.closed ? '#4b5563' : CLEAR_WIDTH_COLORS[kind]; context.lineWidth = edge.transition || edge.closed ? 2 : 3;
        context.setLineDash(edge.closed ? [2, 4] : edge.stepFree === false || edge.transition ? [6, 4] : []);
        context.globalAlpha = .85; context.stroke(); context.globalAlpha = 1;
      }
      context.setLineDash([]);
      for (const node of model.graph.nodes.values()) {
        const [x, y] = at([node.position[0], node.position[2]]);
        context.beginPath(); context.arc(x, y, node.kind === 'door' || node.kind === 'doorway' ? 4.5 : 3.2, 0, Math.PI * 2);
        context.fillStyle = '#263241'; context.fill(); context.lineWidth = 1.5; context.strokeStyle = '#fff'; context.stroke();
      }
    }
    if (on('narrow')) {
      for (const passage of model.floor?.narrow || []) {
        const [x, y] = at(passage.center);
        context.beginPath(); context.arc(x, y, 9, 0, Math.PI * 2);
        context.lineWidth = 2.5; context.strokeStyle = '#d23b3b'; context.stroke();
        context.beginPath(); context.moveTo(x - 5, y); context.lineTo(x + 5, y); context.stroke();
        label(meters(passage.width, 'en', 2), x, y - 17, { size: 10, color: '#a32020' });
      }
    }
    if (on('doors')) {
      for (const door of model.doors) {
        const color = door.unknown ? '#6b7280' : door.passes ? '#2e9d57' : '#e07000';
        if (door.span) {
          path(door.span, at);
          context.lineWidth = Math.max(4, 0.08 * perMeter); context.strokeStyle = color;
          context.setLineDash(door.passes || door.unknown ? [] : [7, 5]); context.stroke(); context.setLineDash([]);
        }
        if (door.center) {
          const [x, y] = at(door.center);
          context.beginPath(); context.arc(x, y, 6, 0, Math.PI * 2); context.fillStyle = '#fff'; context.fill();
          context.lineWidth = 2; context.strokeStyle = color; context.stroke();
          context.font = `800 8px ${FONT}`; context.textAlign = 'center'; context.textBaseline = 'middle'; context.fillStyle = color;
          context.fillText(door.unknown ? '?' : door.passes ? '✓' : '✕', x, y + .5);
        }
      }
    }
    if (on('hazards')) {
      for (const hazard of model.hazards) {
        const style = HAZARD_STYLES[hazard.severity];
        if (hazard.polygon) {
          path(hazard.polygon, at, true);
          context.globalAlpha = .22; context.fillStyle = style.color; context.fill(); context.globalAlpha = 1;
          context.lineWidth = 2; context.strokeStyle = style.color; context.setLineDash([5, 3]); context.stroke(); context.setLineDash([]);
        }
        if (hazard.center) { const [x, y] = at(hazard.center); hazardMarker(x, y, hazard.severity); label(humanize(hazard.kind), x, y + 20, { size: 10, color: style.color }); }
      }
    }
    if (on('route') && view.route?.path.length > 1) {
      const points = view.route.path.map(([x, , z]) => [x, z]);
      path(points, at); context.strokeStyle = '#fff'; context.lineWidth = 9; context.stroke();
      path(points, at); context.strokeStyle = '#0071e3'; context.lineWidth = 5; context.stroke();
      const [sx, sy] = at(points[0]), [ex, ey] = at(points.at(-1));
      context.beginPath(); context.arc(sx, sy, 7, 0, Math.PI * 2); context.fillStyle = '#fff'; context.fill(); context.lineWidth = 3; context.strokeStyle = '#0071e3'; context.stroke();
      context.beginPath(); context.arc(ex, ey, 8, 0, Math.PI * 2); context.fillStyle = '#0071e3'; context.fill(); context.lineWidth = 2.5; context.strokeStyle = '#fff'; context.stroke();
    }
    if (on('signs')) {
      for (const sign of model.signs) {
        if (!sign.position) continue;
        const [x, y] = at([sign.position[0], sign.position[2]]);
        const style = styleFor(SIGN_STYLES, sign.category, UNKNOWN_SIGN);
        for (const [dx, dz] of sign.arrows) arrow(x, y, dx, dz, 26, style.color);
        badge(x, y, style, 'square', 9);
        if (sign.text) label(sign.text, x + 13, y, { size: 10, align: 'left', color: '#20406f', max: 22 });
      }
      for (const item of model.text) {
        if (!item.position) continue;
        const [x, y] = at([item.position[0], item.position[2]]);
        badge(x, y, SIGN_STYLES.text_region, 'square', 7);
        label(item.text, x + 11, y, { size: 9.5, align: 'left', color: '#34507f', max: 20 });
      }
    }
    if (on('regions')) {
      for (const region of model.regions) {
        if (!region.centroid) continue;
        const [x, y] = at(region.centroid);
        const style = styleFor(REGION_STYLES, region.kind, UNKNOWN_REGION);
        label(region.label || style.label, x, y, { size: 11, weight: 700, color: '#2a2f36' });
      }
    }
    if (on('places')) {
      for (const place of model.places) {
        if (!place.position) continue;
        const [x, y] = at([place.position[0], place.position[2]]);
        badge(x, y, styleFor(PLACE_STYLES, place.category, UNKNOWN_PLACE));
        label(placeName(place, view.lang), x, y + 19, { size: 10.5, weight: 650, color: '#1d1d1f', max: 24 });
      }
    }
    if (view.step?.position) {
      const [x, y] = at([view.step.position[0], view.step.position[2]]);
      context.beginPath(); context.arc(x, y, 14, 0, Math.PI * 2);
      context.lineWidth = 3; context.strokeStyle = '#0071e3'; context.setLineDash([3, 3]); context.stroke(); context.setLineDash([]);
    }
    // Scale bar: one round number of meters.
    const target = 120 / perMeter, nice = [0.5, 1, 2, 5, 10, 20, 50, 100].find((m) => m >= target * .6) || 100;
    const length = nice * perMeter;
    context.fillStyle = '#1d1d1f'; context.fillRect(PAD, SIZE - 16, length, 3);
    label(`${nice} m`, PAD + length + 6, SIZE - 14.5, { size: 10, align: 'left', color: '#4a4a50' });
  }

  return {
    /** Replaces the model; decodes the floor PNG (data: URL is allowed by the studio CSP). */
    setModel(model) {
      const epoch = ++view.epoch;
      view.model = model; view.image = null; view.route = null; view.step = null;
      draw();
      if (!model?.floor?.png || !model.floor.grid) return Promise.resolve();
      return new Promise((resolve) => {
        const image = new Image();
        image.onload = () => { if (epoch === view.epoch) { view.image = image; draw(); } resolve(); };
        image.onerror = () => resolve();
        image.src = `data:image/png;base64,${model.floor.png}`;
      });
    },
    setLayers(layers) { view.layers = { ...layers }; draw(); },
    setRoute(route, lang) { view.route = route; view.lang = lang || view.lang; view.step = null; draw(); },
    setLanguage(lang) { view.lang = lang; draw(); },
    setStep(step) { view.step = step; draw(); },
    clear() { view.epoch++; view.model = null; view.image = null; view.route = null; view.step = null; draw(); },
  };
}
