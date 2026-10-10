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
retain their existing limits. `GET /scans/{id}` returns the original JSON semantically unchanged; JSON whitespace,
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
copies the latest mesh snapshot, and selects up to six calibrated depth keyframes.
These records preserve the shared ARKit frame; no export origin reset is applied.
Overlapping sections use the latest component with the same RoomPlan identifier.

The app archives native RoomPlan JSON and copied mesh/depth bytes locally before
upload. If a bundle exceeds the 32 MiB limit, optional whole depth/mesh layers remain
local and their omission is recorded in metadata. Native RoomPlan/semantic data is
never silently truncated; if that layer alone is too large, upload reports an error.
The saved active capture identifies its cached scene, so a failed new scan cannot
replace a previously saved room view. Network failures support retry; the saved
source can restore the backend's in-memory capture after a restart.

`color_asset` and other asset references are opaque strings. This API does not fetch,
decode, upload, or durably store image/world-map/USDZ binaries. RGB coloring is not
implemented. The current 32 MiB request limit is suitable for small prototype bundles;
large captures need a separate binary-asset storage/upload design.

Apple supports a [custom ARSession with RoomPlan](https://developer.apple.com/videos/play/wwdc2023/10192/),
and demonstrates [depth-to-point-cloud processing](https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth).
The adapter builds against the iOS SDK; physical capture and relocalization still
need verification on the actual LiDAR device before expanding recognition or storage.
