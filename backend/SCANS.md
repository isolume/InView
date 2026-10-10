# Capture → scene (draft)

The first processing path uses ARKit geometry and optional RoomPlan labels together.
It preserves the submitted capture and produces a replaceable scene description.
All captures remain in memory and disappear on restart, like the graph store.

## What works now

- Import a JSON scan bundle containing meshes, depth frames, room surfaces, and/or
  detected object bounds. None of these input layers is mandatory individually.
- Retain the original JSON values, including unknown fields such as a native
  RoomPlan export, object attributes, asset references, or capture metadata.
- Apply mesh-anchor transforms to produce map-space vertices without smoothing.
- Unproject selected depth samples using camera intrinsics and poses. Filter by
  supplied confidence and cap the displayed point count across all frames.
- Place simple neutral furniture, storage, bed, sink, plant, and rug meshes within supplied object bounds.
  Unknown types or insufficient confidence use measured box fallbacks.
- Retain oriented measured obstacle boxes separately from the model parts.
- Inspect the result in a full-screen local map preview. No external JS or model assets
  are downloaded. Version 3 models use simple furniture silhouettes,
  vertex normals, and neutral materials. They remain replaceable templates.

This is normalization and model placement, not a completed reconstruction pipeline.
Depth frames are sampled into a cloud, not fused, registered again, or segmented.
Raw-only captures produce raw geometry; furniture is not invented from the mesh.
Importing or processing scans never creates navigation graphs or accessible routes.

## API

`POST /scans` accepts [examples/scan.json](examples/scan.json), returns HTTP 201 and
a summary, and rejects a reused scan ID with HTTP 409 `scan_exists`. Captures are
immutable within this service instance. Use another ID for a correction or rescan.
`POST /scans` accepts up to 32 MiB for multiroom captures; other prototype endpoints
retain their existing limits. `POST /scan-packages` accepts an uncompressed `.inviewscan.tar`
up to 256 MiB (at most 4096 entries, 64 MiB each). Every TAR entry must be a regular file at `<scan-id>/<filename>`, entry names
must be unique, and `capture.json` must validate and name the same scan ID. Binary sidecars are
retained immutably in the process-local scan store and are never extracted to the filesystem.
If present, `package-manifest.json` is parsed and validated against the capture and sidecars; it
is retained with the package for reconstruction, OCR, and VLM workers.
`GET /scans/{id}` returns the original JSON semantically unchanged; JSON whitespace,
key order, and numerical spelling are not preserved byte-for-byte.

`GET /scans/{id}/scene` processes with the default options. A fresh scene is derived
from the same source on each call. `POST /scans/{id}/process` accepts options:

```json
{
  "minimum_object_confidence": "medium",
  "minimum_depth_confidence": 1,
  "max_points": 20000
}
```

Object confidence is `unknown`, `low`, `medium`, or `high`. Depth confidence uses
ARKit's `0` (low), `1` (medium), `2` (high). Unknown depth confidence cannot meet
the default threshold; explicit `minimum_depth_confidence: null` allows it.
`max_points` ranges from 1 to 100000. Unknown option keys are rejected.

The returned scene includes source/map/floor IDs, processing version/options,
surfaces, objects with local model meshes and measured obstacle boxes, map-space
mesh vertices, sampled depth points with source-frame IDs, and processing warnings.
`GET /scans/{id}/preview` opens the development viewer using the default scene.

Processing version 2 adds `objects[].model_meshes`: each has a name, object-local
vertices and normals, triangle indices, and a color. The legacy cuboid `parts`
remain for compatibility. The native app prefers these meshes and renders a true
orthographic isometric view with lighting, wall cutaway, and doorway cutouts.
Version 3 replaces the furniture templates and adds storage, bed, sink, plant, and
rug display models. The app accepts earlier scenes as well. The native map uses system toolbars and sheets with a Map/AR switch. Furniture
is scenery with no item labels or browsing. Position, route, and destination carry
the navigation emphasis; surfaces and furniture use quiet neutral materials.
Display styling does not change measured obstacles.

## Portable capture conventions

The envelope has draft `schema_version: 1`, `id`, `map_id`, `floor_id`, and:

```json
"coordinates": { "units": "meters", "up_axis": "y", "handedness": "right" }
```

One bundle refers to one map and floor. Separately captured regions use separate
bundles. Their identifiers alone do not align them; alignment remains explicit.

All `map_from_*` transforms have 16 **column-major** entries, like ARKit's matrices.
They transform local points into the declared map frame. Translation occupies
entries 12–14. Only rigid rotations and translations are accepted; scale, shear,
reflection, nonfinite numbers, and projective matrices are rejected. All layers
must share the declared frame. A camera pose is `map_from_camera`, not a view
matrix that transforms in the reverse direction.

- **Meshes:** `id`, `map_from_anchor`, local `vertices` as `[x,y,z]`, and zero-based
  `triangles`. Optional `classifications` has one label per triangle. Mesh labels
  are retained; no object instances are inferred from them yet.
- **Objects:** `id`, `category`, optional `confidence`, `map_from_object`, and
  positive `dimensions_m: [width,height,depth]`. The local origin is the center of
  the measured box. Generic furniture faces local `-z`; exporters must align their
  source orientation accordingly. Additional source attributes remain in the raw
  capture and are not yet used to choose model variants.
- **Surfaces:** `id`, `kind`, `map_from_surface`, and centered `dimensions_m`.
  This initial shell representation is rectangular; one axis may be zero for a
  plane. A 2.5 cm display thickness is added only to zero-thickness axes. Source
  dimensions remain unchanged. The preview shortens walls unless “Full walls” is
  selected. The native renderer cuts aligned rectangular openings into walls;
  arbitrary wall/floor polygons are not implemented.
- **Frames:** `id`, nonnegative `timestamp_seconds`, `pixel_orientation:
  "sensor_native"`, `map_from_camera`, `camera`, `depth`, and optional `color_asset`.
  `camera` has `image_width`, `image_height`, `fx`, `fy`, `cx`, `cy`. Intrinsics refer
  to the original unrotated camera image. `depth` has `width`, `height`, row-major
  `values_m`, and optional per-pixel `confidence`. Depth covers the full image with
  the same aspect ratio; intrinsics are scaled to its resolution. Portrait display
  rotation or cropped buffers need an explicit exporter conversion.

Depth is distance along the camera's optical axis, not Euclidean distance along
each ray. Null or zero samples are missing. Camera image coordinates have x right
and y down; ARKit camera coordinates have x right, y up, and forward along `-z`.
The processor converts this convention before applying `map_from_camera`.

The normalized scene retains the measured box's eight transformed corners and its
map-space axis-aligned bounds. Both are geometric estimates, not certified clearance
or passability. Styling never substitutes for reviewed navigation geometry.

## iPhone handoff

This envelope is **not** Apple's native `CapturedRoom` JSON. The app adapter in
`AccessNav/Scan/ScanExporter.swift` exports RoomPlan dimensions/transforms/categories
into these records and retains the native export in `roomplan_original`.
`RawScanCapture.swift` polls the same session without replacing its delegate,
copies the latest classified mesh snapshot, and keeps up to 48 calibrated depth keyframes spread
over the whole walk (see [Capture format changes](#capture-format-changes)).
For each selected keyframe it retains original raw `sceneDepth`, confidence bytes, and,
when ARKit provides it, original `smoothedSceneDepth` bytes as separate local native buffers.
These records preserve the shared ARKit frame; no export origin reset is applied.
Overlapping sections use the latest component with the same RoomPlan identifier.

The app archives native RoomPlan JSON, the portable `capture.json`, copied mesh/depth
bytes, and `worldmap.archive` in the same `Documents/Captures/<scan-id>/` directory before
upload. `worldmap.archive` is an Apple-only ARWorldMap relocalization asset and is referenced
from `metadata.assets.world_map`. The current JSON upload does not send binary sidecars yet.
If a bundle exceeds the 32 MiB limit, optional whole depth/mesh layers remain
local and their omission is recorded in metadata. Native RoomPlan/semantic data is
never silently truncated; if that layer alone is too large, upload reports an error.
The saved active capture identifies its cached scene, so a failed new scan cannot
replace a previously saved room view. Network failures support retry; the saved
source can restore the backend's in-memory capture after a restart.

`color_asset` and other asset references are opaque strings. The native raw snapshot now retains
bounded adaptive JPEG keyframes paired with calibrated depth-frame IDs; sidecar files use
`<frame-id>.color.jpg` and are listed in `metadata.assets.color_keyframes`. The local LiDAR
review can render these as colorized points. The JSON endpoint intentionally does not send
binary sidecars. `POST /scan-packages` receives the TAR sidecars with their portable capture.
`GET /scans/{id}/raw-preview`, `/native-mesh`, and `/color/{file}` decode them: they read the
manifest-indexed binary sidecars (`packageFormat: "binary_sidecars"`) and fall back to the base64
buffers in `raw-snapshot.json` for packages made before sidecars existed
(`"legacy_raw_snapshot"`). Up to 64 depth observations and 2048 mesh anchors are previewed.

The iOS capture store produces `<scan-id>.inviewscan.tar`: a sequential TAR containing that
scan's `capture.json`, `package-manifest.json`, RoomPlan original, binary depth/confidence/mesh
sidecars, JPEG color keyframes, derived scene when available, and `worldmap.archive`.
`raw-snapshot.json` stays on the phone: it duplicates every sidecar as base64. Captures saved
before sidecars existed have them written from that snapshot when the archive is built. The app
prefers the archive endpoint and falls back to the size-bounded JSON endpoint when the backend
lacks it (404/405) or the package exceeds the archive limit (413, or over 256 MiB locally).

`package-manifest.json` is the versioned AI/reconstruction handoff. It inventories every sidecar
with path, role, media type, and byte length; declares the shared right-handed, meter, y-up ARKit
frame; and lists each selected observation — built from the complete raw capture, so it remains
valid when `capture.json` omits portable frames for size — with its frame ID, timestamp, `map_from_camera`, RGB
asset (when available), camera intrinsics, raw/smoothed depth sidecar filenames, confidence sidecar,
buffer layout, and optional coarse location context (`environment`, including the iPhone's
`recorded_at_unix_seconds`). It also indexes each classified mesh anchor's exact vertex, index, normal, and
classification sidecars with their native offsets, strides, formats, and anchor transform. Workers
must use that pose/calibration metadata to align OCR/VLM image findings with RoomPlan, depth, mesh,
and routing geometry; Wi-Fi/BLE or image pixels alone must never establish map coordinates.

Apple supports a [custom ARSession with RoomPlan](https://developer.apple.com/videos/play/wwdc2023/10192/),
and demonstrates [depth-to-point-cloud processing](https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth).
The adapter builds against the iOS SDK; physical capture and relocalization still
need verification on the actual LiDAR device before expanding recognition or storage.

## Capture format changes

All changes below are **additive and optional**: older packages (no track, no stills, 32 FIFO
keyframes) still decode, and older backends ignore the new files and fields.

### Coverage-preserving depth keyframes (iOS)

What changed: `RawScanCapture` keeps up to **48** depth keyframes (was 32) and, when over budget,
evicts the keyframe whose removal least reduces pose-space coverage — the one with the closest
neighbour, measured as camera travel in metres plus 1.03 m per radian of view-direction change —
instead of the oldest. Frames carrying an OCR still are evicted only if every frame carries one;
colour keyframes get a 0.3 m retention bonus. `.smoothedSceneDepth` is now requested explicitly, so
`smoothed_asset` sidecars are actually present. Metadata (`capture.json` →
`metadata.raw_capture`) adds `depth_retention_policy: "pose_space_coverage_v1"`,
`smoothed_scene_depth_requested`, `ocr_still_*` counts/budget, and `camera_track_*` counts.

Why: FIFO eviction silently dropped the first rooms of long walks, leaving the floor-map, door
and sign workers with depth/colour evidence for only the last ~40–60 s of the scan.

Budget: 48 × (≈432 KiB native depth + ≈60 KiB colour) ≈ 24 MiB of sidecars; `capture.json`
remains ≤ 32 MiB because `ScanExporter` drops whole optional layers past that limit.

### `camera-track.json` (asset role `camera_track`)

A dense ARKit pose track sampled at ≈10 Hz from the same session (bounded to 18 000 poses; on
overflow every other pose is dropped and `sample_interval_seconds` doubles):

```json
{"schema_version": 1, "clock": "arkit_uptime_seconds",
 "unix_offset_seconds": 1791000000.25, "sample_interval_seconds": 0.1,
 "poses": [{"t": 100.3, "m": [16 column-major map_from_camera entries],
            "tracking": "normal | limited:<initializing|excessive_motion|insufficient_features|relocalizing|other> | not_available",
            "mapping": "not_available | limited | extending | mapped"}]}
```

`t` uses the same clock as observation `timestamp_seconds`; `t + unix_offset_seconds` is the
iPhone wall clock (fixing the mismatch between ARKit times and the wall-clock
`environment.recorded_at_unix_seconds`). `StoredScan::camera_track()` and
`GET /scans/{id}/camera-track` now prefer this sidecar: poses with `not_available`,
`limited:initializing` (near-origin) or `limited:relocalizing` (jumping) tracking, non-rigid
matrices, or non-increasing `t` are dropped (other limited poses are kept and labelled), `unix_seconds` is derived from the offset,
and each pose carries `tracking`/`mapping`. The response's `source` is `camera_track_sidecar`,
`package_manifest`, or `portable_frames`; a malformed sidecar falls back to the manifest. Building
pose observations now record `tracking_state` from the dense track, thinned to one pose per
0.5 s and inserted in a single batched statement.

Why: the sparse keyframe poses (one per ≥0.45 m) are too coarse for walked-path evidence,
doorway traversal and dwell detection, and they carry no tracking quality.

### OCR stills `<frame-id>.ocr.jpg` (asset role `ocr_still`)

Upright portrait JPEGs at ≈1920 px long side, quality 0.85, captured when the camera is steady
(< 0.3 rad/s and < 0.6 m/s over 0.3 s of the dense track) and has moved ≥ 1.5 m or turned ≥ 30°
since the last still; at most 32 stills / 60 MB, with pose-space coverage replacement at the caps.
Each still shares a depth keyframe (a due, steady still may add one), so its manifest observation
adds:

```json
"ocr_asset": "<frame-id>.ocr.jpg",
"ocr_image": {"width": 1440, "height": 1920, "orientation": "rotated_90_cw_from_sensor"}
```

The still is the sensor image rotated 90° clockwise and uniformly scaled; a still pixel `(x, y)`
maps to the calibrated sensor image (`image` intrinsics) as
`u = y / ocr_image.height · image.width`, `v = (1 − x / ocr_image.width) · image.height`. The
backend rejects an `ocr_asset` that is not in the package and an out-of-range `ocr_image` size.
Stills are served by `GET /scans/{id}/assets/{file}`.

Why: 640 px colour keyframes are too small to read most signs, room numbers and door labels; OCR
needs sharp, high-resolution pixels tied to a pose and depth so text can be placed in the map frame.

Package budget (worst case): capture.json 32 + depth 24 + OCR 60 + mesh ≈ 60 + world map ≈ 30 +
RoomPlan ≈ 5 ≈ 211 MiB, inside the 256 MiB package limit (4096 entries, 64 MiB per file).

### Info.plist

`NSMotionUsageDescription` is declared in `project.yml` (the capture context already uses
`CMAltimeter`).
