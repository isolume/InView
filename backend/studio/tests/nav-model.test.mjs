// Unit tests for the DOM-free navigation model: `node --test backend/studio/tests/`.
import assert from 'node:assert/strict';
import test from 'node:test';
import {
  bounds, clearWidthClass, directionFor, formatMeasure, maneuverStyle, normalize, pickLanguage, placeName, routePath, safeLang,
} from '../nav-model.js';

const graph = {
  schema_version: 1,
  id: 'demo-nav',
  nodes: [
    { id: 'a', map_id: 'm', floor_id: 'f', x: 0, y: 0, z: 0 },
    { id: 'b', map_id: 'm', floor_id: 'f', x: 2, y: 0, z: 0, label: 'Door' },
    { id: 'c', map_id: 'm', floor_id: 'f', x: 2, y: 0, z: 3 },
  ],
  edges: [
    { id: 'ab', from: 'a', to: 'b', minimum_clear_width_m: 1.2, step_free: true, segment: { type: 'surface', path_points: [{ x: 0, y: 0, z: 0 }, { x: 1, y: 0, z: 0.5 }, { x: 2, y: 0, z: 0 }] } },
    { id: 'ba', from: 'b', to: 'a', minimum_clear_width_m: 1.2, step_free: true, segment: { type: 'surface', path_points: [{ x: 2, y: 0, z: 0 }, { x: 1, y: 0, z: 0.5 }, { x: 0, y: 0, z: 0 }] } },
    { id: 'cb', from: 'c', to: 'b', minimum_clear_width_m: 0.85, segment: { type: 'surface', path_points: [{ x: 2, y: 0, z: 3 }, { x: 2, y: 0, z: 0 }] } },
    { id: 'dangling', from: 'c', to: 'zzz', segment: { type: 'surface', path_points: [] } },
  ],
  metadata: { node_kinds: { b: 'door' } },
};

test('every product is optional', () => {
  const model = normalize({});
  assert.deepEqual(model.stages, []);
  assert.equal(model.floor, null);
  assert.equal(model.graph, null);
  assert.deepEqual(model.routes.routes, []);
  assert.equal(bounds(model), null);
  assert.doesNotThrow(() => normalize(null));
  assert.doesNotThrow(() => normalize({ doors: 'nope', signs: [null, 3], nav_graph: [], routes: { routes: [null] }, places: [{}] }));
});

test('malformed coordinates are dropped, unknown categories kept', () => {
  const model = normalize({
    regions: [{ id: 'r', kind: 'atrium', polygon_xz_m: [[0, 0], [1, 0], [1, 1]] }, { polygon_xz_m: [[0, 0], ['x', 1]] }],
    hazards: [{ id: 'h', kind: 'step', severity: 'catastrophic', position_m: [1, 0, 1] }, { id: 'bad', position_m: [NaN, 0, 0] }],
    places: [{ id: 'p', category: 'teleporter', position_m: [0, 0, 0] }],
  });
  assert.equal(model.regions.length, 1);
  assert.equal(model.regions[0].kind, 'atrium');
  assert.deepEqual(model.regions[0].centroid, [2 / 3, 1 / 3]);
  assert.equal(model.hazards.length, 1);
  assert.equal(model.hazards[0].severity, 'warning');
  assert.equal(placeName(model.places[0], 'en'), 'Teleporter');
});

test('graph drops dangling edges and dedupes bidirectional ones', () => {
  const model = normalize({ nav_graph: graph });
  assert.equal(model.graph.nodes.size, 3);
  assert.equal(model.graph.edges.length, 3);
  assert.equal(model.graph.unique.length, 2);
  assert.equal(model.graph.nodes.get('b').kind, 'door');
});

test('route path follows edge geometry in either direction', () => {
  const model = normalize({ nav_graph: graph });
  assert.deepEqual(routePath(['a', 'b', 'c'], model.graph), [[0, 0, 0], [1, 0, 0.5], [2, 0, 0], [2, 0, 3]]);
  assert.deepEqual(routePath(['missing', 'a'], model.graph), [[0, 0, 0]]);
  assert.deepEqual(routePath(['a'], null), []);
});

test('routes collect profiles and languages', () => {
  const model = normalize({
    nav_graph: graph,
    routes: {
      profiles: { wheelchair: { min_clear_width_m: 0.915 } },
      routes: [{ from_place: 'p1', to_place: 'p2', profile: 'ambulatory', node_ids: ['a', 'b'], length_m: 2.3, instructions: { en: [{ text: 'Go', maneuver: 'depart', distance_m: 2 }], ar: [] } }],
    },
  });
  assert.deepEqual(model.routes.profileNames, ['wheelchair', 'ambulatory']);
  assert.deepEqual(model.routes.languages, ['ar', 'en']);
  assert.equal(model.routes.routes[0].path.length, 3);
});

test('language helpers', () => {
  assert.equal(directionFor('ar'), 'rtl');
  assert.equal(directionFor('ar-EG'), 'rtl');
  assert.equal(directionFor('he'), 'rtl');
  assert.equal(directionFor('az-Arab'), 'rtl');
  assert.equal(directionFor('en'), 'ltr');
  assert.equal(directionFor('ku-Latn'), 'ltr');
  assert.equal(safeLang('en-US'), 'en-US');
  assert.equal(safeLang('"><x'), '');
  assert.equal(pickLanguage(['ar', 'en', 'es'], ['es-MX']), 'es');
  assert.equal(pickLanguage(['ar', 'fr'], ['de']), 'ar');
  assert.equal(pickLanguage(['ar', 'en'], []), 'en');
  const place = { id: 'x', category: 'restroom', name: 'Restroom', names: { ar: 'دورة المياه' } };
  assert.equal(placeName(place, 'ar-SA'), 'دورة المياه');
  assert.equal(placeName(place, 'fr'), 'Restroom');
});

test('clear width classes never call unknown widths a pass', () => {
  assert.equal(clearWidthClass(1), 'ok');
  assert.equal(clearWidthClass(0.85), 'tight');
  assert.equal(clearWidthClass(0.5), 'narrow');
  assert.equal(clearWidthClass(null), 'unknown');
  assert.equal(maneuverStyle('LEFT').glyph, '←');
  assert.equal(maneuverStyle('constructor').glyph, '•');
});

test('hazard measures keep their units', () => {
  assert.equal(formatMeasure('rise_m', 0.17), 'Rise 0.17 m');
  assert.equal(formatMeasure('slope', 0.1), 'Slope 1:10');
  assert.equal(formatMeasure('angle_deg', 4.5), 'Angle 4.5 °');
  assert.equal(formatMeasure('count', 3), 'Count 3');
});

test('merged edges keep the most conservative direction', () => {
  const g = structuredClone(graph);
  g.edges[1].step_free = false;
  g.edges[1].minimum_clear_width_m = 0.7;
  g.edges[1].availability = 'closed';
  const edge = normalize({ nav_graph: g }).graph.unique.find((item) => item.id === 'ab');
  assert.equal(edge.stepFree, false);
  assert.equal(edge.width, 0.7);
  assert.equal(edge.closed, true);
});
