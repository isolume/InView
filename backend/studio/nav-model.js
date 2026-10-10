// Pure, DOM-free helpers that turn an analysis document into safe, normalized navigation data.
// Every product is optional and every field is untrusted: unknown categories fall back to neutral
// styles, malformed coordinates are dropped, and nothing here touches the DOM or Three.js.

export const CLEAR_WIDTH = { route: 0.915, door: 0.815 };

const finite = (value) => typeof value === 'number' && Number.isFinite(value);
const list = (value) => (Array.isArray(value) ? value : []);
const object = (value) => (value && typeof value === 'object' && !Array.isArray(value) ? value : null);
const text = (value) => (typeof value === 'string' ? value : value == null ? '' : String(value));

/** [x, z] from an `*_xz_m` pair, or null. */
export function xz(value) {
  return Array.isArray(value) && value.length >= 2 && finite(value[0]) && finite(value[1]) ? [value[0], value[1]] : null;
}
/** [x, y, z] from an `*_m` triple, or null. */
export function xyz(value) {
  return Array.isArray(value) && value.length >= 3 && value.slice(0, 3).every(finite) ? [value[0], value[1], value[2]] : null;
}
/** {x,y,z} object (Graph v1 points) as [x, y, z], or null. */
export function point3(value) {
  const item = object(value);
  return item && finite(item.x) && finite(item.y) && finite(item.z) ? [item.x, item.y, item.z] : null;
}
function polygon(value) {
  const points = list(value).map(xz).filter(Boolean);
  return points.length >= 3 ? points : null;
}

/** Human label from a snake_case identifier. */
export function humanize(value) {
  const words = text(value).replace(/[_-]+/g, ' ').trim();
  return words ? words[0].toUpperCase() + words.slice(1) : 'Unknown';
}

// --- Category styles ------------------------------------------------------------------------
// Glyphs are short, font-safe strings drawn on canvas; color is never the only cue (shape + glyph).

export const REGION_STYLES = {
  room: { fill: '#5b8def', label: 'Room' },
  corridor: { fill: '#2fa58a', label: 'Corridor' },
  open_area: { fill: '#c08a2c', label: 'Open area' },
  doorway: { fill: '#9b59c9', label: 'Doorway' },
};
export const UNKNOWN_REGION = { fill: '#8a8f98', label: 'Region' };

export const PLACE_STYLES = {
  entrance: { glyph: 'IN', color: '#1f7a4d', label: 'Entrance' },
  exit: { glyph: 'OUT', color: '#1f7a4d', label: 'Exit' },
  emergency_exit: { glyph: 'EX', color: '#c62828', label: 'Emergency exit' },
  restroom: { glyph: 'WC', color: '#2a62c9', label: 'Restroom' },
  accessible_restroom: { glyph: '♿', color: '#2a62c9', label: 'Accessible restroom' },
  elevator: { glyph: '⇅', color: '#5a43b5', label: 'Elevator' },
  stairs: { glyph: 'ST', color: '#8a5a12', label: 'Stairs' },
  escalator: { glyph: 'ES', color: '#8a5a12', label: 'Escalator' },
  ramp: { glyph: '◢', color: '#5a43b5', label: 'Ramp' },
  door: { glyph: 'D', color: '#4a5562', label: 'Door' },
  room: { glyph: 'R', color: '#4a5562', label: 'Room' },
  corridor: { glyph: 'C', color: '#4a5562', label: 'Corridor' },
  information: { glyph: 'i', color: '#0a66c2', label: 'Information' },
  reception: { glyph: 'RE', color: '#0a66c2', label: 'Reception' },
  seating: { glyph: 'SE', color: '#6b5b3e', label: 'Seating' },
  water_fountain: { glyph: 'H₂O', color: '#0a7ea4', label: 'Water fountain' },
  fire_extinguisher: { glyph: 'FX', color: '#c62828', label: 'Fire extinguisher' },
  first_aid: { glyph: '+', color: '#c62828', label: 'First aid' },
  landmark: { glyph: '★', color: '#a5521b', label: 'Landmark' },
};
export const UNKNOWN_PLACE = { glyph: '?', color: '#6b7280', label: 'Place' };

export const SIGN_STYLES = {
  ...PLACE_STYLES,
  directional: { glyph: '➜', color: '#0a66c2', label: 'Directional sign' },
  informational: { glyph: 'i', color: '#0a66c2', label: 'Information sign' },
  text_region: { glyph: 'T', color: '#4f6fc4', label: 'Text' },
  exit_sign: { glyph: 'EX', color: '#1f7a4d', label: 'Exit sign' },
  exit_sign_candidate: { glyph: 'EX', color: '#1f7a4d', label: 'Exit sign candidate' },
  accessibility_sign_candidate: { glyph: '♿', color: '#2a62c9', label: 'Accessibility sign candidate' },
};
export const UNKNOWN_SIGN = { glyph: 'S', color: '#0a66c2', label: 'Sign' };

export const HAZARD_STYLES = {
  barrier: { color: '#c62828', glyph: '✕', label: 'Barrier' },
  warning: { color: '#c77700', glyph: '!', label: 'Warning' },
};

export const MANEUVERS = {
  depart: { glyph: '●', label: 'Depart' },
  straight: { glyph: '↑', label: 'Continue straight' },
  continue: { glyph: '↑', label: 'Continue' },
  left: { glyph: '←', label: 'Turn left' },
  right: { glyph: '→', label: 'Turn right' },
  slight_left: { glyph: '↖', label: 'Bear left' },
  slight_right: { glyph: '↗', label: 'Bear right' },
  sharp_left: { glyph: '↙', label: 'Sharp left' },
  sharp_right: { glyph: '↘', label: 'Sharp right' },
  u_turn: { glyph: '↶', label: 'Turn around' },
  uturn: { glyph: '↶', label: 'Turn around' },
  door: { glyph: '⊓', label: 'Go through door' },
  elevator: { glyph: '⇅', label: 'Take elevator' },
  stairs: { glyph: '⌇', label: 'Take stairs' },
  arrive: { glyph: '◎', label: 'Arrive' },
};
export const UNKNOWN_MANEUVER = { glyph: '•', label: 'Step' };

export const styleFor = (table, key, fallback) => (Object.prototype.hasOwnProperty.call(table, key) ? table[key] : fallback);
export const maneuverStyle = (name) => styleFor(MANEUVERS, text(name).toLowerCase(), UNKNOWN_MANEUVER);

/** Edge color by measured clear width; unknown width is neutral, never "pass". */
export function clearWidthClass(width) {
  if (!finite(width)) return 'unknown';
  if (width >= CLEAR_WIDTH.route) return 'ok';
  if (width >= CLEAR_WIDTH.door) return 'tight';
  return 'narrow';
}
export const CLEAR_WIDTH_COLORS = { ok: '#2e9d57', tight: '#d08a00', narrow: '#d23b3b', unknown: '#8b95a1' };

// --- Languages ----------------------------------------------------------------------------

const RTL = new Set(['ar', 'arc', 'ckb', 'dv', 'fa', 'he', 'iw', 'ks', 'ps', 'sd', 'syr', 'ug', 'ur', 'yi']);
const RTL_SCRIPTS = new Set(['arab', 'hebr', 'syrc', 'thaa', 'nkoo', 'adlm', 'rohg']);
/** Text direction for a BCP-47 tag (script subtag wins over language). */
export function directionFor(tag) {
  const parts = text(tag).toLowerCase().split(/[-_]/);
  const script = parts.find((part, index) => index > 0 && part.length === 4);
  if (script) return RTL_SCRIPTS.has(script) ? 'rtl' : 'ltr';
  return RTL.has(parts[0]) ? 'rtl' : 'ltr';
}
/** A safe value for the HTML `lang` attribute, or ''. */
export function safeLang(tag) {
  const value = text(tag);
  return /^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$/.test(value) ? value : '';
}
/** "Arabic · العربية" style label; falls back to the raw tag. */
export function languageLabel(tag, uiLocale = 'en') {
  const lang = safeLang(tag);
  if (!lang) return text(tag) || 'Unknown';
  let english = '', native = '';
  try { english = new Intl.DisplayNames([uiLocale], { type: 'language' }).of(lang) || ''; } catch { /* Older engines. */ }
  try { native = new Intl.DisplayNames([lang], { type: 'language' }).of(lang) || ''; } catch { /* Unknown tag. */ }
  if (english && native && english !== native) return `${english} · ${native}`;
  return english || native || lang;
}
/** Picks the best language for a viewer: exact, then primary-subtag match, then English, then first. */
export function pickLanguage(available, preferred = []) {
  if (!available.length) return '';
  for (const want of preferred) {
    const exact = available.find((item) => item.toLowerCase() === text(want).toLowerCase());
    if (exact) return exact;
    const primary = text(want).toLowerCase().split('-')[0];
    const loose = available.find((item) => item.toLowerCase().split('-')[0] === primary);
    if (loose) return loose;
  }
  return available.find((item) => item.toLowerCase().startsWith('en')) || available[0];
}

// --- Normalization ------------------------------------------------------------------------

const STAGE_STATUSES = new Set(['ok', 'skipped', 'failed']);
function stages(raw) {
  const entries = Object.entries(object(raw) || {});
  return entries.map(([name, info]) => {
    const item = object(info) || {};
    const status = STAGE_STATUSES.has(item.status) ? item.status : 'unknown';
    return {
      name,
      status,
      seconds: finite(item.seconds) ? item.seconds : null,
      error: item.error ? text(item.error) : '',
      missing: list(item.missing).map(text),
      provided: list(item.provided).map(text),
    };
  }).sort((a, b) => a.name.localeCompare(b.name));
}

function graph(raw) {
  const source = object(raw);
  if (!source) return null;
  const nodes = new Map();
  for (const node of list(source.nodes)) {
    const item = object(node);
    if (!item || item.id == null || !finite(item.x) || !finite(item.y) || !finite(item.z)) continue;
    const kinds = object(object(source.metadata)?.node_kinds) || {};
    const id = text(item.id);
    const kind = Object.prototype.hasOwnProperty.call(kinds, id) && typeof kinds[id] === 'string' ? kinds[id] : '';
    nodes.set(id, { id, position: [item.x, item.y, item.z], label: text(item.label), kind });
  }
  const edges = [];
  for (const edge of list(source.edges)) {
    const item = object(edge);
    if (!item) continue;
    const from = nodes.get(text(item.from)), to = nodes.get(text(item.to));
    if (!from || !to) continue;
    const segment = object(item.segment) || {};
    const path = list(segment.path_points).map(point3).filter(Boolean);
    edges.push({
      id: text(item.id),
      from: from.id,
      to: to.id,
      width: finite(item.minimum_clear_width_m) ? item.minimum_clear_width_m : null,
      stepFree: typeof item.step_free === 'boolean' ? item.step_free : null,
      closed: item.availability === 'closed',
      transition: segment.type === 'transition',
      connector: text(segment.kind),
      points: path.length >= 2 ? path : [from.position, to.position],
    });
  }
  // Bidirectional edges are published once per direction. Draw each undirected connection once,
  // keeping the most conservative evidence of either direction so no barrier is hidden.
  const merged = new Map();
  for (const edge of edges) {
    const key = [edge.from, edge.to].sort().join('\u0000');
    const prior = merged.get(key);
    if (!prior) { merged.set(key, { ...edge }); continue; }
    prior.width = prior.width == null || edge.width == null ? prior.width ?? edge.width : Math.min(prior.width, edge.width);
    prior.stepFree = prior.stepFree === false || edge.stepFree === false ? false : prior.stepFree === true && edge.stepFree === true ? true : null;
    prior.closed = prior.closed || edge.closed;
  }
  const unique = [...merged.values()];
  return nodes.size ? { nodes, edges, unique } : null;
}

function names(raw) {
  const out = {};
  for (const [lang, value] of Object.entries(object(raw) || {})) if (typeof value === 'string' && value) out[lang] = value;
  return out;
}

function routes(raw, graphData) {
  const source = object(raw) || {};
  const profiles = object(source.profiles) || {};
  const items = list(source.routes).map((route, index) => {
    const item = object(route);
    if (!item) return null;
    const instructions = {};
    for (const [lang, steps] of Object.entries(object(item.instructions) || {})) {
      instructions[lang] = list(steps).map((step) => {
        const s = object(step) || {};
        return { text: text(s.text), distance: finite(s.distance_m) ? s.distance_m : null, maneuver: text(s.maneuver), position: xyz(s.position_m), landmark: text(s.landmark) };
      });
    }
    const nodeIds = list(item.node_ids).map(text);
    return {
      key: `${index}`,
      from: text(item.from_place),
      to: text(item.to_place),
      profile: text(item.profile) || 'default',
      nodeIds,
      length: finite(item.length_m) ? item.length_m : null,
      seconds: finite(item.estimated_seconds) ? item.estimated_seconds : null,
      instructions,
      path: routePath(nodeIds, graphData),
    };
  }).filter(Boolean);
  const profileNames = [...new Set([...Object.keys(profiles), ...items.map((route) => route.profile)])];
  const languages = [...new Set(items.flatMap((route) => Object.keys(route.instructions)))].sort();
  return { profiles, profileNames, routes: items, languages };
}

/** 3D polyline for a route: follows edge geometry between consecutive nodes when available. */
export function routePath(nodeIds, graphData) {
  if (!graphData) return [];
  const byPair = new Map();
  for (const edge of graphData.edges) byPair.set(`${edge.from}\u0000${edge.to}`, edge);
  const points = [];
  for (let i = 0; i < nodeIds.length; i++) {
    const node = graphData.nodes.get(nodeIds[i]);
    if (!node) continue;
    if (i === 0 || !points.length) { points.push(node.position); continue; }
    const forward = byPair.get(`${nodeIds[i - 1]}\u0000${nodeIds[i]}`);
    const backward = forward ? null : byPair.get(`${nodeIds[i]}\u0000${nodeIds[i - 1]}`);
    const along = forward ? forward.points : backward ? [...backward.points].reverse() : [node.position];
    for (const point of along.slice(forward || backward ? 1 : 0)) points.push(point);
  }
  return points;
}

/** Normalizes the whole analysis document; any product may be missing or malformed. */
export function normalize(analysis) {
  const source = object(analysis) || {};
  const floor = object(source.floor_map);
  const grid = object(floor?.grid);
  const gridOk = grid && xz(grid.origin_xz_m) && finite(grid.resolution_m) && grid.resolution_m > 0 && finite(grid.width) && finite(grid.height);
  const graphData = graph(source.nav_graph);
  const signs = list(source.signs).map((sign, index) => {
    const item = object(sign) || {};
    const category = text(item.category || item.kind) || 'unknown';
    return {
      id: text(item.id) || `sign-${index}`,
      category,
      text: text(item.text),
      position: xyz(item.position_m),
      arrows: list(item.arrows).map((arrow) => xz(object(arrow)?.direction_xz)).filter(Boolean),
      contrast: finite(item.contrast_ratio) ? item.contrast_ratio : null,
      mounting: finite(item.mounting_height_m) ? item.mounting_height_m : null,
      languages: list(item.languages).map(text),
      pictograms: list(item.pictograms).map(text),
      issues: list(item.issues).map(text),
      observations: finite(item.observation_count) ? item.observation_count : list(item.observations).length || null,
    };
  });
  return {
    stages: stages(source.stages),
    floor: floor ? {
      grid: gridOk ? { origin: xz(grid.origin_xz_m), resolution: grid.resolution_m, width: grid.width, height: grid.height } : null,
      height: finite(floor.floor_height_m) ? floor.floor_height_m : null,
      png: typeof floor.image_png_base64 === 'string' && /^[A-Za-z0-9+/=\s]+$/.test(floor.image_png_base64) ? floor.image_png_base64 : '',
      outlines: list(floor.outlines).map((outline) => polygon(object(outline)?.polygon_xz_m)).filter(Boolean),
      obstacles: list(floor.obstacles).map((obstacle) => {
        const item = object(obstacle) || {};
        const center = xz(item.center_xz_m);
        if (!center) return null;
        const size = xz(item.size_m) || [0.2, 0.2];
        return { center, size, angle: finite(item.angle_deg) ? item.angle_deg : 0, polygon: polygon(item.polygon_xz_m) };
      }).filter(Boolean),
      narrow: list(floor.narrow_passages).map((passage) => {
        const item = object(passage) || {};
        const center = xz(item.center_xz_m);
        return center ? { center, width: finite(item.min_clear_width_m) ? item.min_clear_width_m : null } : null;
      }).filter(Boolean),
    } : null,
    regions: list(source.regions).map((region, index) => {
      const item = object(region) || {};
      const poly = polygon(item.polygon_xz_m);
      if (!poly) return null;
      return { id: text(item.id) || `region-${index}`, kind: text(item.kind) || 'unknown', polygon: poly, centroid: xz(item.centroid_xz_m) || centroid(poly), area: finite(item.area_m2) ? item.area_m2 : null, label: text(item.label) };
    }).filter(Boolean),
    doors: list(source.doors).map((door, index) => {
      const item = object(door) || {};
      const span = list(item.span_xz_m).map(xz).filter(Boolean);
      const center = xz(item.center_xz_m) || (span.length === 2 ? [(span[0][0] + span[1][0]) / 2, (span[0][1] + span[1][1]) / 2] : null);
      if (!center && span.length < 2) return null;
      const width = finite(item.measured_clear_width_m) ? item.measured_clear_width_m : finite(item.nominal_width_m) ? item.nominal_width_m : null;
      return { id: text(item.id) || `door-${index}`, kind: text(item.kind) || 'door', span: span.length >= 2 ? span.slice(0, 2) : null, center, width, minimum: finite(item.required_min_clear_width_m) ? item.required_min_clear_width_m : CLEAR_WIDTH.door, passes: item.meets_clear_width === true, unknown: typeof item.meets_clear_width !== 'boolean', issues: list(item.issues).map(text) };
    }).filter(Boolean),
    hazards: list(source.hazards).map((hazard, index) => {
      const item = object(hazard) || {};
      const position = xyz(item.position_m), poly = polygon(item.polygon_xz_m);
      if (!position && !poly) return null;
      const measure = Object.entries(object(item.measure) || {}).filter(([, value]) => finite(value));
      return { id: text(item.id) || `hazard-${index}`, kind: text(item.kind) || 'hazard', severity: item.severity === 'barrier' ? 'barrier' : 'warning', position, polygon: poly, center: position ? [position[0], position[2]] : centroid(poly), measure };
    }).filter(Boolean),
    signs,
    text: list(source.text).map((observation, index) => {
      const item = object(observation) || {};
      return { id: text(item.id) || `text-${index}`, text: text(item.text), confidence: finite(item.confidence) ? item.confidence : null, language: text(item.language), position: xyz(item.position_m) };
    }).filter((item) => item.text),
    places: list(source.places).map((place, index) => {
      const item = object(place) || {};
      return { id: text(item.id) || `place-${index}`, category: text(item.category) || 'unknown', name: text(item.name), names: names(item.names), position: xyz(item.position_m), confidence: finite(item.confidence) ? item.confidence : null };
    }),
    graph: graphData,
    routes: routes(source.routes, graphData),
    notices: list(source.notices).map(text).filter(Boolean),
  };
}

export function centroid(points) {
  if (!points?.length) return null;
  let x = 0, z = 0;
  for (const [px, pz] of points) { x += px; z += pz; }
  return [x / points.length, z / points.length];
}

/** Place display name in a language, falling back to the default name, then the id. */
export function placeName(place, lang) {
  if (!place) return '';
  const primary = text(lang).split('-')[0];
  const own = (key) => (Object.prototype.hasOwnProperty.call(place.names, key) ? place.names[key] : '');
  return own(lang) || own(primary) || place.name || (place.category !== 'unknown' ? humanize(place.category) : '') || place.id;
}

/** X/Z bounds over every drawable thing, for maps without a floor raster. */
export function bounds(model) {
  const points = [];
  const add = (p) => { if (p) points.push(p); };
  for (const outline of model.floor?.outlines || []) outline.forEach(add);
  for (const region of model.regions) region.polygon.forEach(add);
  for (const door of model.doors) { add(door.center); door.span?.forEach(add); }
  for (const hazard of model.hazards) { add(hazard.center); hazard.polygon?.forEach(add); }
  for (const item of [...model.signs, ...model.places, ...model.text]) if (item.position) add([item.position[0], item.position[2]]);
  if (model.graph) for (const node of model.graph.nodes.values()) add([node.position[0], node.position[2]]);
  for (const item of model.floor?.narrow || []) add(item.center);
  for (const item of model.floor?.obstacles || []) add(item.center);
  if (!points.length) return null;
  let minX = Infinity, maxX = -Infinity, minZ = Infinity, maxZ = -Infinity;
  for (const [x, z] of points) { minX = Math.min(minX, x); maxX = Math.max(maxX, x); minZ = Math.min(minZ, z); maxZ = Math.max(maxZ, z); }
  return { minX, maxX, minZ, maxZ };
}

/** Formats meters for a locale ("12.4 m"); unknown stays an em dash. */
export function meters(value, lang = 'en', digits = 1) {
  if (!finite(value)) return '—';
  let formatted;
  try { formatted = new Intl.NumberFormat(safeLang(lang) || 'en', { maximumFractionDigits: digits }).format(value); } catch { formatted = value.toFixed(digits); }
  return `${formatted} m`;
}
export function duration(seconds) {
  if (!finite(seconds)) return '';
  return seconds < 90 ? `~${Math.round(seconds)} s` : `~${Math.round(seconds / 60)} min`;
}

/** "Rise 0.17 m" / "Slope 1:10" from a hazard measure entry (`rise_m`, `slope`, ...). */
export function formatMeasure(key, value) {
  const name = text(key);
  if (/(^|_)slope$/.test(name) && value > 0) return `${humanize(name)} 1:${Math.round(1 / value * 10) / 10}`;
  const unit = name.match(/_(m|deg|s)$/);
  const rounded = Math.round(value * 1000) / 1000;
  if (!unit) return `${humanize(name)} ${rounded}`;
  return `${humanize(name.slice(0, -unit[0].length))} ${rounded} ${unit[1] === 'deg' ? '°' : unit[1]}`;
}
