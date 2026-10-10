import * as THREE from './three.module.js';
import { OrbitControls } from './OrbitControls.js';

const $ = (id) => document.getElementById(id);
const state = { scans: [], selected: null, original: null, scene: null, buildings: [], building: null, buildingsAvailable: true, mode: 'room', nativeMode: 'smoothed', nativeUnavailable: false, nativePreview: null, nativeMesh: null, nativeEpoch: 0, meshMode: 'original', meshEpoch: 0, generation: 0 };
const sceneCanvas = $('sceneCanvas');
let renderer, camera, controls, display;
const content = new THREE.Group();
const group = { room: new THREE.Group(), depth: new THREE.Group(), mesh: new THREE.Group(), path: new THREE.Group() };
const grid = new THREE.GridHelper(20, 40, 0x6a8d9c, 0x314957);
grid.material.transparent = true;
grid.material.opacity = 0.23;
grid.visible = false;
const world = new THREE.Scene();
world.background = new THREE.Color('#101923');
world.add(grid, content, group.path);
content.add(group.room, group.depth, group.mesh);
world.add(new THREE.HemisphereLight(0xffffff, 0x7894aa, 1.25));
const sun = new THREE.DirectionalLight(0xffffff, 1.35);
sun.position.set(4, 7, 5);
world.add(sun);

try {
  renderer = new THREE.WebGLRenderer({ canvas: sceneCanvas, antialias: true, powerPreference: 'high-performance' });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.04;
  camera = new THREE.PerspectiveCamera(52, 1, 0.02, 1000);
  camera.position.set(3, 2.5, 4);
  controls = new OrbitControls(camera, sceneCanvas);
  controls.enableDamping = true;
  controls.dampingFactor = .08;
  controls.minDistance = .12;
  controls.maxDistance = 160;
  controls.screenSpacePanning = true;
  const resize = () => {
    const width = sceneCanvas.clientWidth, height = sceneCanvas.clientHeight;
    if (!width || !height) return;
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
  };
  new ResizeObserver(resize).observe(sceneCanvas);
  const frame = () => { requestAnimationFrame(frame); if (document.hidden) return; controls.update(); renderer.render(world, camera); };
  requestAnimationFrame(frame);
} catch (error) {
  sceneCanvas.hidden = true;
  $('viewFeedback').textContent = 'A WebGL-capable browser is needed for the 3D review. Your capture library is still available.';
}

const tokenKey = 'inview-studio-token';
let authPending = null;
function getToken() { return sessionStorage.getItem(tokenKey); }
function authPrompt(invalid = false) {
  if (authPending) return authPending;
  const dialog = $('authDialog');
  $('authToken').value = '';
  $('authError').hidden = !invalid;
  dialog.showModal();
  $('authToken').focus();
  authPending = new Promise((resolve) => {
    const finish = (value) => {
      if (value) sessionStorage.setItem(tokenKey, value);
      authPending = null;
      $('authForm').removeEventListener('submit', submit);
      $('authCancel').removeEventListener('click', cancel);
      dialog.removeEventListener('cancel', cancel);
      if (dialog.open) dialog.close();
      resolve(value);
    };
    const submit = (event) => { event.preventDefault(); finish($('authToken').value.trim()); };
    const cancel = (event) => { event.preventDefault(); finish(null); };
    $('authForm').addEventListener('submit', submit);
    $('authCancel').addEventListener('click', cancel);
    dialog.addEventListener('cancel', cancel);
  });
  return authPending;
}
async function api(path, options = {}) {
  for (let attempts = 0; attempts < 3; attempts++) {
    const usedToken = getToken();
    const headers = { ...(options.headers || {}) };
    if (usedToken) headers.Authorization = `Bearer ${usedToken}`;
    const response = await fetch(path, { ...options, headers, cache: 'no-store' });
    if (response.status === 401) {
      if (usedToken !== getToken()) continue;
      sessionStorage.removeItem(tokenKey);
      const entered = await authPrompt(attempts > 0);
      if (!entered) throw new Error('Unlock the studio to see captures.');
      sessionStorage.setItem(tokenKey, entered);
      continue;
    }
    if (!response.ok) {
      let message = `Server returned ${response.status}.`;
      try { const body = await response.json(); message = body.error?.message || message; } catch { /* HTTP status is sufficient. */ }
      const error = new Error(message);
      error.status = response.status;
      throw error;
    }
    return response.json();
  }
  sessionStorage.removeItem(tokenKey);
  throw new Error('The access token was not accepted.');
}
function notice(message, failed = false) {
  $('pageSubtitle').textContent = message;
  $('sceneState').textContent = failed ? 'REVIEW UNAVAILABLE' : 'SPATIAL PREVIEW';
  $('pageSubtitle').style.color = failed ? '#b6343c' : '';
}
function openLibrary() { $('sidebar').classList.add('open'); $('mobileScrim').hidden = false; $('openLibrary').setAttribute('aria-expanded', 'true'); }
function closeLibrary() { $('sidebar').classList.remove('open'); $('mobileScrim').hidden = true; $('openLibrary').setAttribute('aria-expanded', 'false'); }
$('openLibrary').addEventListener('click', openLibrary);
$('closeLibrary').addEventListener('click', closeLibrary);
$('mobileScrim').addEventListener('click', closeLibrary);
$('refreshScans').addEventListener('click', () => refresh().catch(showError));
$('lockButton').addEventListener('click', () => { sessionStorage.removeItem(tokenKey); location.reload(); });
$('resetView').addEventListener('click', () => resetCamera());
sceneCanvas.addEventListener('keydown', (event) => { if (event.key.toLowerCase() === 'r') { resetCamera(); event.preventDefault(); } });
$('pathToggle').addEventListener('change', () => { group.path.visible = $('pathToggle').checked; });

function scanLabel(scan) { return scan.id.replace(/[-_]/g, ' ').trim() || 'Untitled capture'; }
function renderLibrary() {
  $('scanCount').textContent = String(state.scans.length);
  $('scanList').replaceChildren();
  if (!state.scans.length) { const p = document.createElement('p'); p.className = 'list-placeholder'; p.textContent = 'No captures yet. Upload a scan from the InView iPhone app.'; $('scanList').append(p); return; }
  for (const scan of state.scans) {
    const button = document.createElement('button');
    button.type = 'button'; button.className = 'scan-item'; button.setAttribute('role', 'listitem');
    button.setAttribute('aria-current', String(state.selected === scan.id));
    const glyph = document.createElement('span'); glyph.className = 'scan-glyph'; glyph.setAttribute('aria-hidden', 'true');
    glyph.innerHTML = '<svg viewBox="0 0 24 24" fill="none"><path d="m12 2 9 5-9 5-9-5 9-5Zm-9 5v10l9 5 9-5V7M12 12v10"/></svg>';
    const copy = document.createElement('span'); copy.className = 'scan-item-copy';
    const label = document.createElement('strong'); label.textContent = scanLabel(scan); label.title = scan.id;
    const sub = document.createElement('small'); sub.textContent = `${scan.floor_id} · ${scan.frame_count} depth frames`;
    copy.append(label, sub); button.append(glyph, copy);
    button.addEventListener('click', () => { closeLibrary(); selectScan(scan.id).catch(showError); });
    $('scanList').append(button);
  }
}
function formatCount(number) { return new Intl.NumberFormat().format(number || 0); }
function clearGroup(parent) {
  for (const child of [...parent.children]) {
    child.traverse((node) => { node.geometry?.dispose(); const materials = node.material ? [].concat(node.material) : []; for (const material of materials) material.dispose(); });
    parent.remove(child);
  }
}
function transform(values) { return new THREE.Matrix4().fromArray(values); }
function color(value, fallback) {
  return typeof value === 'string' && /^#[0-9a-f]{6}$/i.test(value) ? value : fallback;
}
function indexedGeometry(vertices, triangles, normals) {
  if (!Array.isArray(vertices) || !Array.isArray(triangles) || !vertices.length || !triangles.length) return null;
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(vertices.flat(), 3));
  // Keep the preview bounded; the immutable capture retains all source triangles.
  geometry.setIndex(triangles.slice(0, 300000).flat());
  if (Array.isArray(normals) && normals.length === vertices.length) geometry.setAttribute('normal', new THREE.Float32BufferAttribute(normals.flat(), 3));
  else geometry.computeVertexNormals();
  return geometry;
}
function material(hex, opacity = 1) { return new THREE.MeshStandardMaterial({ color: hex, roughness: .94, metalness: 0, transparent: opacity < 1, opacity, side: THREE.DoubleSide, depthWrite: opacity === 1 }); }
function drawRoom(scene) {
  for (const surface of scene.surfaces || []) {
    if (surface.kind === 'opening') continue;
    const size = surface.render_dimensions_m?.map((v) => Math.max(.025, v));
    if (!size || size.some((v) => !Number.isFinite(v))) continue;
    const geometry = new THREE.BoxGeometry(...size);
    const isWall = surface.kind === 'wall';
    const mesh = new THREE.Mesh(geometry, material(isWall ? '#d8e1e4' : surface.kind === 'floor' ? '#cbd9d6' : '#cbd6de', isWall ? .38 : .78));
    mesh.applyMatrix4(transform(surface.map_from_surface));
    group.room.add(mesh);
  }
  for (const object of scene.objects || []) {
    const matrix = transform(object.map_from_object);
    if (object.model_meshes?.length) {
      for (const part of object.model_meshes) {
        const geometry = indexedGeometry(part.vertices, part.triangles, part.normals);
        if (!geometry) continue;
        const mesh = new THREE.Mesh(geometry, material(color(part.color, '#dddeda')));
        mesh.applyMatrix4(matrix);
        group.room.add(mesh);
      }
    } else {
      for (const part of object.parts || []) {
        const geometry = new THREE.BoxGeometry(...part.dimensions_m.map((v) => Math.max(.01, v)));
        geometry.translate(...part.center);
        const mesh = new THREE.Mesh(geometry, material(color(part.color, '#dddeda')));
        mesh.applyMatrix4(matrix);
        group.room.add(mesh);
      }
    }
  }
}
function drawDepth(scene) {
  const points = scene.point_cloud || [];
  if (!points.length) return;
  const coords = new Float32Array(points.length * 3);
  for (let i = 0; i < points.length; i++) coords.set(points[i].position, i * 3);
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.BufferAttribute(coords, 3));
  group.depth.add(new THREE.Points(geometry, new THREE.PointsMaterial({ color: '#8de2dd', size: .026, sizeAttenuation: true, transparent: true, opacity: .91 })));
}
async function keyframePixels(scanID, filename) {
  const path = `/scans/${encodeURIComponent(scanID)}/color/${encodeURIComponent(filename)}`;
  const response = await fetch(path, { headers: { Authorization: `Bearer ${getToken()}` }, cache: 'no-store' });
  if (!response.ok) return null;
  const bitmap = await createImageBitmap(await response.blob());
  const canvas = document.createElement('canvas');
  canvas.width = bitmap.width; canvas.height = bitmap.height;
  const context = canvas.getContext('2d', { willReadFrequently: true });
  context.drawImage(bitmap, 0, 0); bitmap.close();
  return context.getImageData(0, 0, canvas.width, canvas.height);
}
async function showNative(preview, generation, epoch) {
  const selected = state.selected;
  const count = preview.frames.reduce((n, frame) => n + frame.points.length, 0);
  const xyz = new Float32Array(count * 3);
  const rgb = new Float32Array(count * 3);
  const tint = new THREE.Color('#8de2dd');
  const pixelColor = new THREE.Color();
  let index = 0, colored = 0;
  for (const frame of preview.frames) {
    let pixels = null;
    if (state.nativeMode === 'color' && frame.colorAsset) {
      try { pixels = await keyframePixels(selected, frame.colorAsset); } catch { /* Retain the uncolored evidence. */ }
    }
    if (generation !== state.generation || epoch !== state.nativeEpoch) return;
    for (const point of frame.points) {
      xyz.set(point.slice(0, 3), index * 3);
      let pointColor = tint;
      if (pixels) {
        // The iPhone saves an upright JPEG rotated right from sensor-native landscape.
        const x = Math.max(0, Math.min(pixels.width - 1, Math.floor((1 - point[4]) * pixels.width)));
        const y = Math.max(0, Math.min(pixels.height - 1, Math.floor(point[3] * pixels.height)));
        const offset = (y * pixels.width + x) * 4;
        pointColor = pixelColor.setRGB(pixels.data[offset] / 255, pixels.data[offset + 1] / 255, pixels.data[offset + 2] / 255, THREE.SRGBColorSpace);
        colored++;
      }
      rgb.set([pointColor.r, pointColor.g, pointColor.b], index * 3);
      index++;
    }
  }
  clearGroup(group.depth);
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.BufferAttribute(xyz, 3));
  geometry.setAttribute('color', new THREE.BufferAttribute(rgb, 3));
  group.depth.add(new THREE.Points(geometry, new THREE.PointsMaterial({ vertexColors: true, size: .025, sizeAttenuation: true, transparent: true, opacity: .96 })));
  state.nativePreview = preview;
  $('nativeControls').hidden = state.mode !== 'depth';
  const hasColor = preview.frames.some((frame) => frame.colorAsset);
  if (!hasColor && state.nativeMode === 'color') state.nativeMode = 'smoothed';
  document.querySelector('[data-native="color"]').disabled = !hasColor;
  for (const button of document.querySelectorAll('[data-native]')) {
    const active = button.dataset.native === state.nativeMode;
    button.classList.toggle('selected', active);
    button.setAttribute('aria-pressed', String(active));
  }
  const smoothCount = preview.frames.filter((frame) => frame.usedSmoothed).length;
  $('nativeInfo').textContent = `${formatCount(count)} points · ${preview.frames.length} keyframe${preview.frames.length === 1 ? '' : 's'}`;
  if (state.mode === 'depth') {
    $('sceneCaption').textContent = state.nativeMode === 'color' && colored ? `Image-colored depth · ${formatCount(colored)} photographed points` : `${smoothCount ? 'Smoothed' : 'Raw'} ARKit depth · Native iPhone buffers`;
    $('viewFeedback').textContent = `${formatCount(count)} measured points from original row-strided ${smoothCount ? 'smoothed' : 'raw'} depth. ${colored ? `${formatCount(colored)} points have color from their own camera keyframe.` : 'Uncolored samples are intentionally shown in teal.'} This is spatial evidence, not a verified route.`;
  }
}
async function loadNative() {
  if (!state.selected || !state.scene || state.nativeUnavailable || !renderer) return;
  const generation = state.generation, epoch = ++state.nativeEpoch;
  const mode = state.nativeMode === 'raw' ? 'raw' : 'smoothed';
  try {
    const preview = await api(`/scans/${encodeURIComponent(state.selected)}/raw-preview?mode=${mode}&max_points=100000`);
    if (generation !== state.generation || epoch !== state.nativeEpoch) return;
    await showNative(preview, generation, epoch);
  } catch (error) {
    if (generation !== state.generation || epoch !== state.nativeEpoch) return;
    if (error.status === 422) {
      state.nativeUnavailable = true;
      $('nativeControls').hidden = true;
      clearGroup(group.depth);
      drawDepth(state.scene);
      $('viewFeedback').textContent = 'No native LiDAR sidecar is available for this capture. Showing the bounded, confidence-filtered portable depth preview instead.';
    } else $('viewFeedback').textContent = `Native depth is temporarily unavailable: ${error.message}`;
  }
}
function smoothGeometry(geometry) {
  const vertices = geometry.getAttribute('position');
  const indices = geometry.getIndex();
  if (!indices || vertices.count < 4) return;
  const count = vertices.count, sums = new Float32Array(count * 3), degree = new Uint32Array(count);
  const edges = new Map(), boundary = new Uint8Array(count);
  const edge = (a, b) => {
    const key = Math.min(a, b) * count + Math.max(a, b);
    const stored = edges.get(key);
    if (stored) stored.count++;
    else edges.set(key, { a, b, count: 1 });
    for (let axis = 0; axis < 3; axis++) {
      sums[a * 3 + axis] += vertices.array[b * 3 + axis];
      sums[b * 3 + axis] += vertices.array[a * 3 + axis];
    }
    degree[a]++; degree[b]++;
  };
  for (let i = 0; i < indices.count; i += 3) {
    const a = indices.getX(i), b = indices.getX(i + 1), c = indices.getX(i + 2);
    edge(a, b); edge(b, c); edge(c, a);
  }
  for (const item of edges.values()) if (item.count === 1) { boundary[item.a] = 1; boundary[item.b] = 1; }
  for (let i = 0; i < count; i++) if (!boundary[i] && degree[i]) {
    for (let axis = 0; axis < 3; axis++) {
      const at = i * 3 + axis;
      vertices.array[at] += .27 * (sums[at] / degree[i] - vertices.array[at]);
    }
  }
  vertices.needsUpdate = true;
  geometry.computeVertexNormals();
}
function drawMesh(scene, appearance = 'original') {
  clearGroup(group.mesh);
  for (const source of state.nativeMesh?.meshes || scene.meshes || []) {
    const geometry = indexedGeometry(source.vertices, source.triangles);
    if (!geometry) continue;
    if (appearance !== 'original') smoothGeometry(geometry);
    group.mesh.add(new THREE.Mesh(geometry, material('#a1bcc4', .86)));
  }
}
async function meshEvidence(preview, original, selected) {
  const evidence = [];
  for (const frame of preview.frames) {
    if (!frame.colorAsset) continue;
    const calibration = original.frames?.find((item) => item.id === frame.id);
    if (!calibration?.camera || !Array.isArray(calibration.map_from_camera)) continue;
    let pixels;
    try { pixels = await keyframePixels(selected, frame.colorAsset); } catch { continue; }
    if (!pixels) continue;
    const inverse = transform(calibration.map_from_camera).invert();
    const depth = new Float32Array(frame.width * frame.height);
    const local = new THREE.Vector3();
    for (const point of frame.points) {
      local.set(point[0], point[1], point[2]).applyMatrix4(inverse);
      const x = Math.min(frame.width - 1, Math.floor(point[3] * frame.width));
      const y = Math.min(frame.height - 1, Math.floor(point[4] * frame.height));
      depth[y * frame.width + x] = -local.z;
    }
    evidence.push({ frame, calibration: calibration.camera, pixels, inverse, depth });
  }
  return evidence;
}
function colorMeshGeometry(geometry, evidence) {
  const positions = geometry.getAttribute('position');
  const colors = new Float32Array(positions.count * 3);
  const best = new Float32Array(positions.count).fill(Infinity);
  const neutral = new THREE.Color('#6b8196');
  const tint = new THREE.Color(), worldPoint = new THREE.Vector3(), local = new THREE.Vector3();
  for (let i = 0; i < positions.count; i++) colors.set([neutral.r, neutral.g, neutral.b], i * 3);
  let matched = 0;
  for (const { frame, calibration, pixels, inverse, depth } of evidence) {
    const radius = Math.min(5, Math.ceil(frame.sampleStride / 2));
    for (let i = 0; i < positions.count; i++) {
      worldPoint.fromBufferAttribute(positions, i);
      local.copy(worldPoint).applyMatrix4(inverse);
      const d = -local.z;
      if (d < .1 || d > 8) continue;
      const u = (calibration.fx * local.x / d + calibration.cx) / calibration.image_width;
      const v = (calibration.fy * -local.y / d + calibration.cy) / calibration.image_height;
      if (u < 0 || u >= 1 || v < 0 || v >= 1) continue;
      const px = Math.floor(u * frame.width), py = Math.floor(v * frame.height);
      let score = Infinity;
      for (let dy = -radius; dy <= radius; dy++) for (let dx = -radius; dx <= radius; dx++) {
        const x = px + dx, y = py + dy;
        if (x < 0 || x >= frame.width || y < 0 || y >= frame.height) continue;
        const measured = depth[y * frame.width + x];
        if (measured <= .1) continue;
        const difference = Math.abs(measured - d);
        if (difference < .18 + .06 * d) score = Math.min(score, difference + (dx * dx + dy * dy) * .006);
      }
      score += ((u - .5) ** 2 + (v - .5) ** 2) * .12;
      if (score >= best[i]) continue;
      const x = Math.max(0, Math.min(pixels.width - 1, Math.floor((1 - v) * pixels.width)));
      const y = Math.max(0, Math.min(pixels.height - 1, Math.floor(u * pixels.height)));
      const offset = (y * pixels.width + x) * 4;
      tint.setRGB(pixels.data[offset] / 255, pixels.data[offset + 1] / 255, pixels.data[offset + 2] / 255, THREE.SRGBColorSpace);
      if (best[i] === Infinity) matched++;
      best[i] = score;
      colors.set([tint.r, tint.g, tint.b], i * 3);
    }
  }
  geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  return matched;
}
async function setMeshAppearance(appearance) {
  state.meshMode = appearance;
  const generation = state.generation, epoch = ++state.meshEpoch, selected = state.selected;
  for (const button of document.querySelectorAll('[data-mesh]')) {
    const active = button.dataset.mesh === appearance;
    button.classList.toggle('selected', active);
    button.setAttribute('aria-pressed', String(active));
  }
  if (!state.scene || !renderer) return;
  if (appearance !== 'color') {
    drawMesh(state.scene, appearance);
    $('meshInfo').textContent = appearance === 'smooth' ? 'One-pass smoothing · Open edges preserved' : 'Original ARKit triangles';
    $('viewFeedback').textContent = appearance === 'smooth' ? 'A light preview-only smoothing pass keeps mesh boundaries in place. Original triangles are unchanged in the scan archive.' : 'Original ARKit mesh faces, without smoothing or fabricated floor clearance.';
    $('sceneCaption').textContent = appearance === 'smooth' ? 'Smoothed ARKit mesh · Preview only' : 'ARKit mesh · Unverified spatial evidence';
    return;
  }
  $('meshInfo').textContent = 'Projecting captured camera keyframes…';
  try {
    const preview = state.nativePreview?.mode === 'smoothed' ? state.nativePreview : await api(`/scans/${encodeURIComponent(selected)}/raw-preview?mode=smoothed&max_points=150000`);
    const evidence = await meshEvidence(preview, state.original, selected);
    if (generation !== state.generation || epoch !== state.meshEpoch || state.mode !== 'mesh') return;
    if (!evidence.length) throw new Error('No calibrated color keyframes are available for this mesh.');
    drawMesh(state.scene, 'smooth');
    let matches = 0;
    for (const mesh of group.mesh.children) {
      matches += colorMeshGeometry(mesh.geometry, evidence);
      mesh.material.dispose();
      mesh.material = new THREE.MeshStandardMaterial({ color: '#fff', roughness: .96, metalness: 0, side: THREE.DoubleSide, vertexColors: true });
    }
    $('meshInfo').textContent = matches ? `${formatCount(matches)} photographed vertices` : 'No verified color matches';
    $('sceneCaption').textContent = matches ? `Image-colored mesh · ${formatCount(matches)} matched vertices` : 'Mesh color unavailable · Neutral geometry';
    $('viewFeedback').textContent = matches ? 'Vertex colors are projected only where a calibrated keyframe agrees with captured depth. Unmatched surfaces remain neutral; this is not a texture reconstruction.' : 'Camera keyframes did not agree with mesh depth. This mesh remains neutral instead of guessing colors.';
  } catch (error) {
    if (generation !== state.generation || epoch !== state.meshEpoch) return;
    drawMesh(state.scene, 'original');
    $('meshInfo').textContent = 'Camera color unavailable';
    $('viewFeedback').textContent = error.message;
    $('sceneCaption').textContent = 'ARKit mesh · Original geometry';
  }
}
function drawPath(original) {
  const poses = (original.frames || []).map((frame) => frame.map_from_camera).filter((matrix) => Array.isArray(matrix) && matrix.length === 16);
  if (!poses.length) return;
  const path = poses.map((matrix) => new THREE.Vector3(matrix[12], matrix[13], matrix[14]));
  if (path.length > 1) group.path.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(path), new THREE.LineBasicMaterial({ color: '#72b7ff', transparent: true, opacity: .8 })));
  for (const position of [path[0], path.at(-1)]) {
    const marker = new THREE.Mesh(new THREE.SphereGeometry(.045, 12, 10), new THREE.MeshBasicMaterial({ color: '#76c5ff' }));
    marker.position.copy(position); group.path.add(marker);
  }
}
function resetCamera() {
  if (!renderer || !display) return;
  const { center, extent } = display;
  controls.target.copy(center);
  camera.position.copy(center).add(new THREE.Vector3(extent * 1.2, extent * .9, extent * 1.25));
  camera.near = Math.max(.005, extent / 2000);
  camera.far = Math.max(300, extent * 90);
  camera.updateProjectionMatrix();
  controls.update();
}
function setMode(mode) {
  state.mode = mode;
  for (const button of document.querySelectorAll('[data-mode]')) {
    const active = button.dataset.mode === mode;
    button.classList.toggle('selected', active);
    button.setAttribute('aria-pressed', String(active));
  }
  group.room.visible = mode === 'room'; group.depth.visible = mode === 'depth'; group.mesh.visible = mode === 'mesh';
  $('sceneCaption').textContent = mode === 'room' ? 'Room model · Display geometry, not surveyed clearance' : mode === 'depth' ? 'Depth sample · Confidence-filtered, not a complete scan' : 'ARKit mesh · Unverified spatial evidence';
  $('viewFeedback').textContent = mode === 'depth' ? 'Checking for native iPhone depth buffers. Portable depth remains available if the sidecar is missing.' : mode === 'mesh' ? 'ARKit mesh faces are shown as captured. This is not a verified floor plan or accessible route.' : 'Display furniture uses supplied labels. Measured obstacle bounds—not the models—must be reviewed for navigation.';
  $('nativeControls').hidden = mode !== 'depth' || !state.nativePreview;
  $('meshControls').hidden = mode !== 'mesh';
  if (mode === 'mesh') setMeshAppearance(state.meshMode);
  if (mode === 'depth') {
    if (!state.nativeUnavailable) loadNative();
    else $('viewFeedback').textContent = 'Native LiDAR sidecars are unavailable for this capture. Showing the bounded portable depth preview.';
  }
}
for (const button of document.querySelectorAll('[data-mode]')) button.addEventListener('click', () => { if (!button.disabled) setMode(button.dataset.mode); });
for (const button of document.querySelectorAll('[data-native]')) button.addEventListener('click', () => {
  if (button.disabled || button.dataset.native === state.nativeMode) return;
  state.nativeMode = button.dataset.native;
  loadNative();
});
for (const button of document.querySelectorAll('[data-mesh]')) button.addEventListener('click', () => {
  if (!button.disabled && button.dataset.mesh !== state.meshMode) setMeshAppearance(button.dataset.mesh);
});
function buildScene(scene, original) {
  for (const parent of [group.room, group.depth, group.mesh, group.path]) clearGroup(parent);
  drawRoom(scene); drawDepth(scene); drawMesh(scene); drawPath(original);
  group.path.visible = $('pathToggle').checked;
  const bounds = new THREE.Box3().setFromObject(content);
  if (bounds.isEmpty()) bounds.expandByPoint(new THREE.Vector3());
  const center = bounds.getCenter(new THREE.Vector3());
  const extent = Math.max(1, bounds.getSize(new THREE.Vector3()).length());
  display = { center, extent };
  grid.scale.setScalar(Math.max(.3, extent / 9));
  grid.position.set(center.x, bounds.min.y - .03, center.z);
  grid.visible = true;
  resetCamera();
  const available = {
    room: group.room.children.length || group.mesh.children.length,
    depth: group.depth.children.length,
    mesh: group.mesh.children.length,
  };
  for (const button of document.querySelectorAll('[data-mode]')) button.disabled = !available[button.dataset.mode];
  if (!available.room) group.room.add(...group.mesh.children.map((child) => { const copy = child.clone(); copy.geometry = child.geometry.clone(); copy.material = child.material.clone(); return copy; }));
  const mode = available[state.mode] ? state.mode : available.room ? 'room' : available.depth ? 'depth' : 'mesh';
  setMode(mode);
}
async function loadNativeMesh(id, generation) {
  try {
    const preview = await api(`/scans/${encodeURIComponent(id)}/native-mesh`);
    if (generation !== state.generation || !preview.meshes?.length) return;
    state.nativeMesh = preview;
    $('meshStat').textContent = formatCount(preview.meshes.length);
    if (renderer && state.scene) buildScene(state.scene, state.original);
    $('meshInfo').textContent = `${formatCount(preview.triangleCount)} native ARKit triangles`;
  } catch (error) {
    if (generation === state.generation && error.status !== 422) $('viewFeedback').textContent = `Native mesh unavailable: ${error.message}`;
  }
}
async function selectScan(id) {
  const generation = ++state.generation;
  const scan = state.scans.find((item) => item.id === id);
  if (!scan) return;
  state.selected = id; state.original = null; state.scene = null; display = null;
  state.nativeEpoch++; state.nativeMode = 'smoothed'; state.nativeUnavailable = false; state.nativePreview = null; state.nativeMesh = null;
  state.meshEpoch++; state.meshMode = 'original';
  $('nativeControls').hidden = true; $('meshControls').hidden = true;
  $('sceneLoading').hidden = false; $('emptyState').hidden = true;
  renderLibrary();
  const period = document.createElement('span'); period.className = 'title-period'; period.textContent = '.';
  $('pageTitle').replaceChildren(document.createTextNode(scanLabel(scan)), period);
  $('captureID').textContent = scan.id;
  $('meshStat').textContent = formatCount(scan.mesh_count);
  $('frameStat').textContent = formatCount(scan.frame_count);
  $('objectStat').textContent = formatCount(scan.object_count + scan.surface_count);
  $('createBuilding').disabled = !state.buildingsAvailable;
  notice('Loading the measured capture…');
  updateBuilding();
  loadAnalysis(id, generation);
  try {
    const encoded = encodeURIComponent(id);
    const [original, scene] = await Promise.all([api(`/scans/${encoded}`), api(`/scans/${encoded}/scene`)]);
    if (generation !== state.generation) return;
    state.original = original; state.scene = scene;
    if (renderer) buildScene(scene, original);
    $('sceneLoading').hidden = true;
    notice(`${scan.floor_id} · ${scan.mesh_count} mesh anchors · ${scan.frame_count} depth frames`);
    if (!scene.meshes?.length) loadNativeMesh(id, generation);
  } catch (error) { if (generation === state.generation) { $('sceneLoading').hidden = true; showError(error); } }
}
function showError(error) { notice(error?.message || 'The workspace could not be loaded.', true); $('sceneLoading').hidden = true; }
async function refresh() {
  const [scans, buildings] = await Promise.all([api('/scans'), api('/api/buildings').catch((error) => { if (error.status === 503) { state.buildingsAvailable = false; return []; } throw error; })]);
  state.scans = scans; state.buildings = buildings;
  renderLibrary(); renderBuildings();
  if (state.selected && scans.some((scan) => scan.id === state.selected)) return;
  if (scans.length) await selectScan(scans[0].id);
  else notice('Your library is ready. Upload a capture from the iPhone app to begin.');
}
function renderBuildings() {
  const select = $('buildingSelect'), current = select.value;
  select.replaceChildren(new Option('No building selected', ''));
  for (const building of state.buildings) select.add(new Option(building.name, building.id));
  if (state.buildings.some((building) => building.id === current)) select.value = current;
  else if (state.buildings.length) select.value = state.buildings[0].id;
  updateBuilding();
}
function updateBuilding() {
  state.building = state.buildings.find((building) => building.id === $('buildingSelect').value) || null;
  const current = state.building;
  const aligned = current?.captureIds?.includes(state.selected);
  $('alignScan').disabled = !state.selected || !current || aligned;
  $('buildingStatus').textContent = !state.buildingsAvailable ? 'Building maps need a database connection.' : current ? `${current.scanCount} capture${current.scanCount === 1 ? '' : 's'} · Version ${current.version}${aligned ? ' · This scan is in the building frame' : ' · This scan is not aligned'}` : 'Choose a capture to create a building reference.';
  loadOverview(current);
}
const overviewColors = ['#2f7fd6', '#e0803a', '#3aa676', '#a45bd1', '#d64f6a', '#6c8a9b'];
let overviewEpoch = 0, overviewKey = '';
async function loadOverview(building) {
  const key = building ? `${building.id}@${building.version}` : '';
  if (key === overviewKey) return;
  const epoch = ++overviewEpoch; overviewKey = key;
  if (!building) { $('buildingOverview').hidden = true; return; }
  try {
    const overview = await api(`/api/buildings/${encodeURIComponent(building.id)}/overview?version=${building.version}`);
    if (epoch === overviewEpoch) drawOverview(overview);
  } catch (error) { if (epoch === overviewEpoch) { overviewKey = ''; $('buildingOverview').hidden = true; notice(error.message, true); } }
}
function drawOverview(overview) {
  const canvas = $('overviewCanvas'), context = canvas.getContext('2d'), items = overview.observations || [];
  const points = items.flatMap((item) => [...item.pathXZ, ...item.surfaceSamplesXZ]);
  $('buildingOverview').hidden = false;
  context.clearRect(0, 0, canvas.width, canvas.height);
  if (!points.length) { $('overviewCaption').textContent = 'No aligned capture geometry is available on this server yet.'; return; }
  const xs = points.map((p) => p[0]), zs = points.map((p) => p[1]);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minZ = Math.min(...zs), maxZ = Math.max(...zs), pad = 18;
  const scale = Math.min((canvas.width - 2 * pad) / Math.max(maxX - minX, .5), (canvas.height - 2 * pad) / Math.max(maxZ - minZ, .5));
  const ox = (canvas.width - (maxX - minX) * scale) / 2, oz = (canvas.height - (maxZ - minZ) * scale) / 2;
  const at = ([x, z]) => [ox + (x - minX) * scale, oz + (z - minZ) * scale]; // +Z points down the page.
  items.forEach((item, index) => {
    const color = overviewColors[index % overviewColors.length];
    context.fillStyle = color; context.globalAlpha = .28;
    for (const sample of item.surfaceSamplesXZ) { const [x, y] = at(sample); context.fillRect(x - 1, y - 1, 2, 2); }
    context.globalAlpha = 1; context.strokeStyle = color; context.lineWidth = item.status === 'reference' ? 2.5 : 1.75;
    context.setLineDash(item.status === 'provisional' ? [5, 4] : []);
    context.beginPath();
    item.pathXZ.forEach((point, i) => { const [x, y] = at(point); i ? context.lineTo(x, y) : context.moveTo(x, y); });
    context.stroke();
  });
  context.setLineDash([]);
  const span = `${(maxX - minX).toFixed(1)} × ${(maxZ - minZ).toFixed(1)} m`;
  $('overviewCaption').textContent = `Top-down X/Z · ${span} · Solid reference, dashed provisional · Observations, not walkable space`;
}
$('buildingSelect').addEventListener('change', updateBuilding);
$('createBuilding').addEventListener('click', () => { $('createError').hidden = true; $('buildingName').value = ''; $('createDialog').showModal(); $('buildingName').focus(); });
$('createCancel').addEventListener('click', () => $('createDialog').close());
$('createForm').addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!state.selected) return;
  const button = $('createForm').querySelector('[type=submit]'); button.disabled = true;
  try {
    const building = await api('/api/buildings', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: $('buildingName').value.trim(), referenceCaptureId: state.selected }) });
    state.buildings = await api('/api/buildings'); renderBuildings(); $('buildingSelect').value = building.id; updateBuilding(); $('createDialog').close();
  } catch (error) { $('createError').textContent = error.message; $('createError').hidden = false; }
  finally { button.disabled = false; }
});
const pairs = $('controlPairs');
for (let index = 0; index < 3; index++) {
  const row = document.createElement('div'); row.className = 'point-pair';
  for (const side of ['scan', 'building']) {
    const input = document.createElement('input'); input.type = 'text'; input.required = true; input.dataset.side = side; input.dataset.index = String(index);
    input.setAttribute('aria-label', `Landmark ${index + 1} in ${side} coordinates, X Y Z meters`); input.placeholder = 'x, y, z'; input.inputMode = 'decimal';
    row.append(input);
  }
  pairs.append(row);
}
$('alignScan').addEventListener('click', () => { $('alignError').hidden = true; for (const input of pairs.querySelectorAll('input')) input.value = ''; $('alignDialog').showModal(); });
$('alignCancel').addEventListener('click', () => $('alignDialog').close());
function vector(input) {
  const parts = input.value.split(',').map((n) => n.trim());
  if (parts.length !== 3 || parts.some((part) => !part || !Number.isFinite(Number(part)))) throw new Error('Each landmark needs three finite coordinates, separated by commas.');
  return parts.map(Number);
}
$('alignForm').addEventListener('submit', async (event) => {
  event.preventDefault();
  const button = $('alignForm').querySelector('[type=submit]'); button.disabled = true;
  try {
    const building = state.building;
    if (!state.selected || !building) throw new Error('Choose a building and a separate scan first.');
    const points = Array.from({ length: 3 }, (_, index) => ({ scan: vector(pairs.querySelector(`[data-side=scan][data-index="${index}"]`)), building: vector(pairs.querySelector(`[data-side=building][data-index="${index}"]`)) }));
    await api(`/api/buildings/${encodeURIComponent(building.id)}/alignments`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ captureId: state.selected, expectedVersion: building.version, method: 'control_points', pairs: points }) });
    state.buildings = await api('/api/buildings'); renderBuildings(); $('buildingSelect').value = building.id; updateBuilding(); $('alignDialog').close();
  } catch (error) { $('alignError').textContent = error.message; $('alignError').hidden = false; }
  finally { button.disabled = false; }
});

async function loadAnalysis(id, generation) {
  $('analysisBody').hidden = true; $('analysisEmpty').hidden = false;
  $('analysisCaption').textContent = 'Checking for processed evidence…';
  let analysis;
  try { analysis = await api(`/scans/${encodeURIComponent(id)}/analysis`); }
  catch (error) {
    if (generation !== state.generation) return;
    $('analysisCaption').textContent = error.status === 404 ? 'Not processed yet' : error.message;
    return;
  }
  if (generation !== state.generation) return;
  const summary = analysis.summary || {}, floor = summary.floor_map || {}, doors = summary.doors || {}, signs = summary.signs || {};
  $('analysisCaption').textContent = `${analysis.worker?.name || 'worker'} ${analysis.worker?.version || ''} · OpenCV ${analysis.worker?.opencv || '?'} · ${new Date(analysis.generated_at).toLocaleString()}`;
  const stats = [['WALKABLE', floor.walkable_area_m2 == null ? '—' : `${floor.walkable_area_m2} m²`], ['NARROW PASSAGES', floor.narrow_passages ?? 0], ['DOORS BELOW MINIMUM', `${doors.below_min_width ?? 0} / ${doors.checked ?? 0}`], ['SIGN + TEXT CANDIDATES', `${signs.sign_candidates ?? 0} + ${signs.text_regions ?? 0}`]];
  $('analysisStats').replaceChildren(...stats.map(([label, value]) => {
    const card = document.createElement('div'); card.className = 'stat';
    const name = document.createElement('span'); name.className = 'stat-label'; name.textContent = label;
    const number = document.createElement('strong'); number.textContent = String(value);
    card.append(name, number); return card;
  }));
  const findings = [];
  for (const door of analysis.doors || []) findings.push([!door.meets_clear_width || door.issues.length, `${door.kind} ${door.meets_clear_width ? 'passes' : 'fails'}: clear width ${door.measured_clear_width_m ?? door.nominal_width_m} m (min ${door.required_min_clear_width_m} m)${door.issues.length ? ' · ' + door.issues.join(', ') : ''}`]);
  for (const passage of analysis.floor_map?.narrow_passages || []) findings.push([true, `Narrow passage ${passage.min_clear_width_m} m wide near (${passage.center_xz_m.join(', ')})`]);
  for (const sign of analysis.signs || []) findings.push([false, `${sign.kind.replaceAll('_', ' ')}${sign.text ? ` “${sign.text}”` : ''}${sign.position_m ? ` at (${sign.position_m.join(', ')}) m` : ' (no depth position)'} · seen ${sign.observation_count}×`]);
  $('analysisFindings').replaceChildren(...(findings.length ? findings : [[false, 'No findings.']]).map(([fail, text]) => {
    const item = document.createElement('li'); if (fail) item.className = 'fail'; item.textContent = text; return item;
  }));
  $('analysisNotice').textContent = (analysis.notices || [])[0] || '';
  $('analysisEmpty').hidden = true; $('analysisBody').hidden = false;
  drawAnalysis(analysis);
}
function drawAnalysis(analysis) {
  const canvas = $('analysisCanvas'), context = canvas.getContext('2d'), map = analysis.floor_map;
  context.clearRect(0, 0, canvas.width, canvas.height);
  if (!map) { context.fillStyle = '#8a8a92'; context.font = '14px -apple-system, sans-serif'; context.fillText('No floor map for this scan.', 24, 40); return; }
  const image = new Image();
  image.onload = () => {
    const scale = Math.min(canvas.width / image.width, canvas.height / image.height);
    const ox = (canvas.width - image.width * scale) / 2, oy = (canvas.height - image.height * scale) / 2;
    context.imageSmoothingEnabled = false;
    context.drawImage(image, ox, oy, image.width * scale, image.height * scale);
    const { origin_xz_m: [x0, z0], resolution_m: resolution } = map.grid;
    const toCanvas = ([x, z]) => [ox + (x - x0) / resolution * scale, oy + (z - z0) / resolution * scale];
    context.lineCap = 'round';
    for (const door of analysis.doors || []) {
      const [[ax, ay], [bx, by]] = door.span_xz_m.map(toCanvas);
      context.beginPath(); context.moveTo(ax, ay); context.lineTo(bx, by);
      context.lineWidth = Math.max(3, 0.08 / resolution * scale); context.strokeStyle = door.meets_clear_width ? '#3caa46' : '#f58c1e'; context.stroke();
    }
    for (const sign of analysis.signs || []) {
      if (!sign.position_m) continue;
      const x = ox + (sign.position_m[0] - x0) / resolution * scale, y = oy + (sign.position_m[2] - z0) / resolution * scale;
      context.beginPath(); context.arc(x, y, 6, 0, Math.PI * 2);
      context.fillStyle = sign.kind === 'text_region' ? '#5b8def' : '#0071e3'; context.fill();
      context.lineWidth = 2; context.strokeStyle = '#fff'; context.stroke();
    }
  };
  image.src = `data:image/png;base64,${map.image_png_base64}`;
}

refresh().catch(showError);
