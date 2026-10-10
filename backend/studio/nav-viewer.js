// Navigation viewer panel: stage chips, layer toggles, 2D map, findings and route explorer.
// All analysis text is inserted with textContent / Option(); no data is ever parsed as HTML.
import { LAYERS, createMapView, layerCounts } from './nav-map.js';
import {
  HAZARD_STYLES, directionFor, duration, formatMeasure, humanize, languageLabel, maneuverStyle, meters, normalize, pickLanguage,
  placeName, safeLang,
} from './nav-model.js';

const $ = (id) => document.getElementById(id);
const LAYER_KEY = 'inview-studio-nav-layers';
const MAX_FINDINGS = 250;

function element(tag, className, textValue) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (textValue != null) node.textContent = textValue;
  return node;
}
function loadLayers() {
  try { const saved = JSON.parse(localStorage.getItem(LAYER_KEY) || '{}'); return saved && typeof saved === 'object' ? saved : {}; } catch { return {}; }
}
function saveLayers(layers) {
  try { localStorage.setItem(LAYER_KEY, JSON.stringify(layers)); } catch { /* Storage may be unavailable; toggles still work. */ }
}
const STAGE_GLYPH = { ok: '✓', skipped: '–', failed: '✕', unknown: '?' };

export function createNavViewer({ overlay = null, onLayersChange = () => {} } = {}) {
  const map = createMapView($('analysisCanvas'));
  const view = { model: null, layers: { ...Object.fromEntries(LAYERS.map((layer) => [layer.id, true])), ...loadLayers() }, profile: '', lang: '', route: null, step: -1 };

  function renderStages(stages) {
    const list = $('stageChips');
    list.replaceChildren(...stages.map((stage) => {
      const item = element('li', `stage-chip ${stage.status}`);
      const detail = stage.status === 'failed' ? stage.error || 'Failed without a message'
        : stage.status === 'skipped' ? (stage.missing.length ? `Needs ${stage.missing.join(', ')}` : 'Skipped')
          : stage.status === 'ok' ? `${stage.seconds == null ? '' : `${stage.seconds.toFixed(2)} s`}${stage.provided.length ? ` · ${stage.provided.join(', ')}` : ''}` : 'Unknown status';
      item.append(element('span', 'stage-glyph', STAGE_GLYPH[stage.status]), element('span', 'stage-name', humanize(stage.name)), element('span', 'sr-only', `: ${stage.status}. ${detail}`));
      item.querySelector('.stage-glyph').setAttribute('aria-hidden', 'true');
      if (detail) {
        item.dataset.tip = detail;
        item.tabIndex = 0;
      }
      return item;
    }));
    list.hidden = !stages.length;
  }

  function renderLayers() {
    const counts = layerCounts(view.model);
    const box = $('layerToggles');
    box.replaceChildren(element('legend', 'sr-only', 'Map layers'));
    for (const layer of LAYERS) {
      const label = element('label', 'layer-chip');
      label.dataset.layer = layer.id;
      const input = element('input');
      input.type = 'checkbox';
      input.checked = view.layers[layer.id] !== false;
      input.disabled = !counts[layer.id];
      input.addEventListener('change', () => {
        view.layers[layer.id] = input.checked;
        saveLayers(view.layers);
        map.setLayers(view.layers);
        onLayersChange(view.layers);
      });
      const swatch = element('span', 'layer-swatch'); swatch.setAttribute('aria-hidden', 'true');
      label.append(input, swatch, element('span', '', layer.label));
      if (counts[layer.id] && layer.id !== 'floor') label.append(element('span', 'layer-count', String(counts[layer.id])));
      if (!counts[layer.id]) label.title = 'Not in this analysis';
      box.append(label);
    }
  }

  function renderStats(analysis, model) {
    const summary = analysis.summary || {}, floor = summary.floor_map || {};
    const failing = model.doors.filter((door) => !door.passes && !door.unknown).length;
    const barriers = model.hazards.filter((hazard) => hazard.severity === 'barrier').length;
    const stats = [
      ['WALKABLE', Number.isFinite(floor.walkable_area_m2) ? `${floor.walkable_area_m2} m²` : '—'],
      ['NARROW PASSAGES', String(model.floor?.narrow.length ?? 0)],
      ['DOORS BELOW MINIMUM', `${failing} / ${model.doors.length}`],
      ['HAZARDS · BARRIERS', `${model.hazards.length} · ${barriers}`],
      ['SIGNS + TEXT', `${model.signs.length} + ${model.text.length}`],
      ['PLACES · ROUTES', `${model.places.length} · ${model.routes.routes.length}`],
    ];
    $('analysisStats').replaceChildren(...stats.map(([name, value]) => {
      const card = element('div', 'stat');
      card.append(element('span', 'stat-label', name), element('strong', '', value));
      return card;
    }));
  }

  function renderFindings(model) {
    const findings = [];
    const at = (p) => (p ? ` at (${p.map((v) => v.toFixed(2)).join(', ')})` : '');
    for (const door of model.doors) {
      findings.push([(!door.passes && !door.unknown) || door.issues.length > 0, `${humanize(door.kind)} ${door.unknown ? 'unchecked' : door.passes ? 'passes' : 'fails'}: clear width ${meters(door.width, 'en', 3)} (min ${meters(door.minimum, 'en', 3)})${door.issues.length ? ` · ${door.issues.map(humanize).join(', ')}` : ''}`]);
    }
    for (const hazard of model.hazards) {
      const measure = hazard.measure.map(([key, value]) => formatMeasure(key, value)).join(', ');
      findings.push([hazard.severity === 'barrier', `${HAZARD_STYLES[hazard.severity].label}: ${humanize(hazard.kind)}${measure ? ` · ${measure}` : ''}${hazard.center ? at(hazard.center) : ''}`]);
    }
    for (const passage of model.floor?.narrow || []) findings.push([true, `Narrow passage ${meters(passage.width, 'en', 2)} wide${at(passage.center)}`]);
    for (const sign of model.signs) {
      const details = [sign.contrast != null ? `contrast ${sign.contrast.toFixed(1)}:1` : '', sign.mounting != null ? `mounted ${meters(sign.mounting, 'en', 2)}` : '', sign.languages.length ? sign.languages.join('/') : '', sign.observations ? `seen ${sign.observations}×` : ''].filter(Boolean).join(' · ');
      findings.push([sign.issues.length > 0, `${humanize(sign.category)}${sign.text ? ` “${sign.text}”` : ''}${sign.position ? at(sign.position) : ' (no depth position)'}${details ? ` · ${details}` : ''}${sign.issues.length ? ` · ${sign.issues.map(humanize).join(', ')}` : ''}`]);
    }
    for (const item of model.text) findings.push([false, `Text “${item.text}”${item.language ? ` [${item.language}]` : ''}${item.confidence != null ? ` · ${Math.round(item.confidence * 100)}%` : ''}`]);
    const items = (findings.length ? findings : [[false, 'No findings.']]).slice(0, MAX_FINDINGS).map(([fail, value]) => {
      const item = element('li', fail ? 'fail' : '', value);
      return item;
    });
    if (findings.length > MAX_FINDINGS) items.push(element('li', '', `…and ${findings.length - MAX_FINDINGS} more.`));
    $('analysisFindings').replaceChildren(...items);
  }

  function mapDescription(model) {
    const counts = layerCounts(model);
    const parts = [`${counts.regions} regions`, `${model.doors.length} doors`, `${model.hazards.length} hazards`, `${model.places.length} places`, `${counts.signs} signs or text`, `${model.graph?.nodes.size || 0} graph nodes`];
    $('analysisCanvas').setAttribute('aria-label', `Top-down navigation map with ${parts.join(', ')}. The findings list and route steps describe the same evidence as text.`);
  }

  // --- Route explorer ---------------------------------------------------------------------
  function placeLabel(id) {
    const place = view.model.places.find((item) => item.id === id);
    return place ? placeName(place, view.lang) : humanize(id);
  }
  function profileLabel(name) {
    const info = view.model.routes.profiles[name];
    const label = info && typeof info === 'object' && typeof info.label === 'string' ? info.label : humanize(name);
    return label;
  }
  function renderRouteControls() {
    const { routes } = view.model;
    const profile = $('routeProfile'), language = $('routeLanguage');
    profile.replaceChildren(...routes.profileNames.map((name) => new Option(profileLabel(name), name)));
    if (!routes.profileNames.includes(view.profile)) view.profile = routes.profileNames.includes('wheelchair') ? 'wheelchair' : routes.profileNames[0] || '';
    profile.value = view.profile;
    language.replaceChildren(...routes.languages.map((lang) => {
      const option = new Option(languageLabel(lang), lang);
      if (safeLang(lang)) option.lang = lang;
      return option;
    }));
    if (!routes.languages.includes(view.lang)) view.lang = pickLanguage(routes.languages, navigator.languages || [navigator.language]);
    language.value = view.lang;
    profile.disabled = routes.profileNames.length < 2;
    language.disabled = routes.languages.length < 2;
    $('routeCount').textContent = String(routes.routes.length);
    $('routeControls').hidden = !routes.routes.length;
  }
  function routesForProfile() { return view.model.routes.routes.filter((route) => route.profile === view.profile); }
  function renderRouteList() {
    const items = routesForProfile();
    if (view.route && !items.includes(view.route)) view.route = null;
    if (!view.route && items.length) view.route = items[0];
    $('routeList').replaceChildren(...items.map((route) => {
      const li = element('li');
      const button = element('button', 'route-item');
      button.type = 'button';
      button.setAttribute('aria-pressed', String(route === view.route));
      const title = element('span', 'route-title');
      title.append(element('span', '', placeLabel(route.from)), element('span', 'route-arrow', ' → '), element('span', '', placeLabel(route.to)));
      title.dir = 'auto';
      const meta = element('span', 'route-meta', [meters(route.length, view.lang), duration(route.seconds), route.path.length > 1 ? '' : 'no geometry'].filter(Boolean).join(' · '));
      button.append(title, meta);
      button.addEventListener('click', () => { view.route = route; view.step = -1; renderRouteList(); });
      li.append(button);
      return li;
    }));
    $('routeEmpty').hidden = items.length > 0;
    $('routeEmpty').textContent = view.model.routes.routes.length ? 'No routes for this profile.' : 'No routes in this analysis yet.';
    renderSteps();
    map.setRoute(view.route, view.lang);
    overlay?.setRoute(view.route);
  }
  function renderSteps() {
    const route = view.route;
    $('routeDetail').hidden = !route;
    if (!route) return;
    const lang = view.lang;
    const steps = route.instructions[lang] || [];
    const list = $('routeSteps');
    list.dir = directionFor(lang);
    if (safeLang(lang)) list.lang = lang; else list.removeAttribute('lang');
    $('routeSummary').textContent = `${placeLabel(route.from)} → ${placeLabel(route.to)} · ${profileLabel(route.profile)} · ${meters(route.length, lang)}${route.seconds != null ? ` · ${duration(route.seconds)}` : ''}`;
    $('routeSummary').dir = 'auto';
    list.replaceChildren(...(steps.length ? steps : [{ text: 'No instructions in this language.', distance: null, maneuver: '', position: null, landmark: '' }]).map((step, index) => {
      const li = element('li');
      const button = element('button', 'route-step');
      button.type = 'button';
      button.disabled = !step.position;
      button.setAttribute('aria-pressed', String(index === view.step));
      const style = maneuverStyle(step.maneuver);
      const glyph = element('span', 'maneuver', style.glyph);
      glyph.setAttribute('aria-hidden', 'true');
      if (step.maneuver) glyph.title = style.label;
      const body = element('span', 'step-body');
      body.append(element('span', 'step-text', step.text || style.label));
      if (step.landmark) body.append(element('span', 'step-landmark', step.landmark));
      const distance = element('span', 'step-distance', step.distance == null ? '' : meters(step.distance, lang));
      distance.dir = 'ltr';
      button.append(glyph, body, distance, element('span', 'sr-only', step.maneuver ? ` (${style.label})` : ''));
      button.addEventListener('click', () => {
        view.step = view.step === index ? -1 : index;
        for (const [i, other] of [...list.querySelectorAll('.route-step')].entries()) other.setAttribute('aria-pressed', String(i === view.step));
        map.setStep(view.step >= 0 ? step : null);
      });
      li.append(button);
      return li;
    }));
  }

  $('routeProfile').addEventListener('change', (event) => { view.profile = event.target.value; view.route = null; view.step = -1; renderRouteList(); });
  $('routeLanguage').addEventListener('change', (event) => {
    view.lang = event.target.value; view.step = -1;
    map.setLanguage(view.lang); overlay?.setLanguage(view.lang);
    renderRouteList();
  });

  return {
    layers: () => ({ ...view.layers }),
    /** Renders an analysis document. Returns the normalized model. */
    show(analysis) {
      const model = normalize(analysis);
      view.model = model; view.route = null; view.step = -1;
      renderStages(model.stages);
      renderLayers();
      renderStats(analysis, model);
      renderFindings(model);
      mapDescription(model);
      $('analysisNotice').textContent = model.notices[0] || '';
      $('analysisNotice').hidden = !model.notices.length;
      map.setLayers(view.layers);
      map.setModel(model);
      renderRouteControls();
      overlay?.setModel(model, view.lang);
      $('routeExplorer').hidden = false;
      renderRouteList();
      map.setLanguage(view.lang);
      onLayersChange(view.layers);
      return model;
    },
    clear() {
      view.model = null; view.route = null; view.step = -1;
      map.clear();
      overlay?.setModel(null);
      $('stageChips').replaceChildren(); $('stageChips').hidden = true;
    },
  };
}
