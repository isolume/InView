# Capture → scene (draft)

The first processing path uses ARKit geometry and optional RoomPlan labels together.
It preserves the submitted capture and produces a replaceable scene description.
The `/scans` captures remain in memory and disappear on restart, like the graph store.
The continuous `/streams` path described below durably retains observations on disk.

## Continuous capture prototype

The new path accepts one ARKit session without RoomPlan sections. The phone keeps
tracking and submits selected calibrated depth/RGB keyframes in a fixed map frame.
The backend retains each observation and builds a measured triangle mesh after
Finish. Verified revisits can correct drift through rigid registration and a
pose graph before the depth is reintegrated. This is an initial, bounded mapping
pipeline: it does not texture geometry, recognize objects or floors, or turn the
mesh into reviewed navigation geometry. Device validation remains necessary.

The executable saves streams to `data/streams` relative to its working directory.
Set `INVIEW_STREAM_DIR` to choose a different local directory. Only this stream
store survives restart; `/scans` and `/graphs` retain their existing behavior.
`AppState::default()` uses a private temporary stream store for tests and embedders;
the executable explicitly opens the durable directory. Run only one backend
process against a given directory. The prototype has no authentication; use the
same trusted development-network boundary as the existing endpoints.

| Method | Endpoint | Payload / response |
|--------|----------|--------------------|
| POST | `/streams` | Manifest → summary; 201 new, 200 identical retry |
| GET | `/streams/{id}` | Summary including acknowledged prefix and finished state |
| PUT | `/streams/{id}/chunks/{sequence}` | One observation → summary after durable write |
| POST | `/streams/{id}/finish` | `{ "chunk_count": N }` → sealed summary |
| GET | `/streams/{id}/result` | `{ "capture": derived_bundle, "scene": processed_scene, "alignment": alignment }` |
| GET | `/streams/{id}/scene` | Same processed scene without the derived bundle |

The manifest contains `schema_version: 1`, a UUID `id`, `map_id`, `floor_id`, and
the existing `coordinates` object. A chunk contains zero-based `sequence`, one
existing `frame`, base64 `color_jpeg`, and optional `surfaces` and `objects` arrays.
Those arrays are **measurement delta updates**: submit only new or changed labels
observed with that chunk's frame. Omitting an unchanged label retains its last
measurement and original correction timestamp; omission does not delete it.
Resending a stale accumulated snapshot would falsely assign old labels to a later
camera observation, so clients must retain their last saved label values and emit
an update only when a fresh measurement changes them. A same-id update replaces
the earlier observation and receives the new source frame's correction.
The encoded JPEG is the **unrotated sensor-native** image. Its dimensions must
match `frame.camera.image_width/image_height`, and intrinsics must be scaled to
that image if RGB was resized. Depth covers the same normalized image with the
same aspect ratio. All rigid poses remain in the original ARKit session map frame.
Depth is optical-axis distance; ARKit cameras look along negative z, with image
y-down converted to camera y-up before applying the column-major pose.

Summaries contain `id`, `map_id`, `floor_id`, `next_sequence`, `finished`, and
`frame_count`. Send only contiguous sequences. Timestamps must strictly increase
and frame IDs must be unique. Retrying identical manifest/chunk JSON values is
idempotent, including a chunk retry after Finish. Different values for an existing
id/sequence return 409 `stream_conflict`. A client that loses the response can
reload status and resume from `next_sequence`; Finish seals exactly the complete,
nonempty acknowledged prefix and is idempotent for the same count.

Writes use a temporary file, file sync, atomic rename, and directory sync before
acknowledgment. Startup recovers contiguous committed chunks one file at a time;
unfinished temporary files are never acknowledged observations. Corrupt committed
files, gaps, or inconsistent finish markers fail recovery explicitly. UUID-only
paths and regular-file/directory checks reject traversal and symlink captures.
Original RGB/depth JSON stays on disk after the compact model is generated.

The current reconstruction triangulates neighboring medium/high-confidence depth
samples from 0.15 to 8 meters, omits missing samples, avoids depth jumps and edges
longer than 0.5 meters, transforms triangles with the supplied rigid camera pose,
and welds observations into 2 cm cells. A cell retains its first measured vertex;
duplicate triangle faces are removed. This produces actual measured geometry,
with no guessed holes, rooms, floors, doorways or walkability. Supplied object and
surface labels are retained by id using their latest submitted observation.
The compact derived capture contains the fused mesh at an identity transform,
retained observed labels and reconstruction metadata; it omits the raw keyframes.
Its existing `Scene` uses the same measured mesh and source ids, enabling the
native app to validate and archive it through its normal capture/scene path.

### Loop closure and map corrections

The backend selects at most 64 uniformly spaced graph keyframes, including the
first and final observation. Each contributes up to 512 calibrated camera-local
depth samples and a sensor-native 16×12 RGB thumbnail. Nonadjacent frames separated
by at least four seconds are candidates when their original camera positions are
within 3 meters and their textured thumbnails are sufficiently similar. The best
24 candidates across the entire capture receive measured registration; selecting
globally prevents early rejected matches from exhausting the final revisit budget.

Registration fits a full rigid rotation and translation with trimmed ICP and SVD,
using both the odometry seed and a centroid seed. A match requires at least 60%
symmetric overlap and at most 5.5 cm RMS residual. Cloud covariance and local
surface-normal directional information reject wall-only observations and ambiguous
straight corridors. Blank RGB views and incompatible depth cannot create loops.
This conservative place descriptor does not provide global visual relocalization;
revisits with substantially different appearance, insufficient overlapping surfaces,
or drift beyond the candidate radius can remain uncorrected.

Accepted measured loop edges join rigid odometry edges in an SE(3) pose graph.
The first pose is fixed in the original ARKit map gauge. Damped Gauss-Newton fits
translation and rotation with robust Huber loop weights. Inconsistent loop edges
are removed and the graph is fitted again. Excessive correction or odometry strain
is rejected; captures without verified loops preserve their original poses.
The conservative prototype permits at most 0.75 meters of position correction
per graph frame. Each corrected odometry edge may change translation by at most
2.5 cm plus 15% of that edge's original travel and rotation by at most one degree
plus 15% of its original rotation. These checks reject large path
contractions, including the tested repeated-alcove match during a straight
traversal. Larger drift remains uncorrected rather
than exceeding the prototype's trusted odometry budget.
The result reports each tested constraint's frame IDs, acceptance, reason, thumbnail
distance, overlap, depth residual and measured relative transform, alongside
`initial_cost` and `final_cost` from the retained graph.

`alignment` contains `reference_frame: "original_arkit_session"`, `optimized`,
`frames` with `frame_id`, `timestamp_seconds`, `original_map_from_camera`, and
`optimized_map_from_camera`, plus `constraints`, `initial_cost`, and `final_cost`.
The retained graph frames identify correction support, not every raw observation.
For a graph frame, the rigid correction is `optimized_pose * inverse(original_pose)`.
For raw observations between graph frames, correction translation is interpolated
linearly and correction rotation uses shortest-path quaternion interpolation by
timestamp. Every raw depth frame is reintegrated using that correction. Supplied
surface/object poses receive the corresponding source-frame correction; measured
dimensions and outlines remain unchanged. The compact capture metadata records
`alignment_optimized`, `alignment_refined`, graph frame count and
`correction_interpolation: "rigid_by_timestamp"`.

These corrections can vary across a capture. A saved ARWorldMap does not become
an optimized-map localization model merely because the geometry was corrected.
Review points must use their corresponding frame correction, and live AR guidance
requires consistent localization against the optimized map before being enabled.

Bounds are explicit and never silently truncate geometry: manifest 16 KiB, chunk
4 MiB, JPEG 512 KiB, RGB 1,048,576 pixels and at most 2,048 pixels per axis,
depth 262,144 samples, 10,000 frames,
2 GiB of canonical chunk JSON per stream, 1,024 unique objects and 1,024 unique
surfaces, 250,000 mesh vertices and 500,000 triangles, and 64 MiB for the complete
serialized capture/scene result. Limit errors return 413 `stream_limit` or
`result_too_large`. At most two reconstructions run at once; excess requests return
retryable 503 `processing_busy`. Reconstruction reads one disk chunk at a time,
with bounded sparse vertex/face tables instead of retaining all frames in memory.
Large-building scans still need a more capable reconstruction pipeline and physical
LiDAR-device tests for tracking drift, coverage, heat, upload sizes and recovery.

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
- **Surfaces:** `id`, `kind`, `map_from_surface`, centered `dimensions_m`, and
  optional `polygon_corners` containing 3–128 surface-local XYZ vertices.
  Concave floor outlines survive local and server processing. One dimension may
  be zero for a plane; a 2.5 cm display thickness is added only to zero axes.
  The native renderer merges measured floors without filling their gaps and
  shortens walls unless “Full walls” is selected. Wall openings remain rectangular.
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
`InView/Scan/ScanExporter.swift` exports RoomPlan dimensions/transforms/categories
into these records. Native RoomPlan JSON is archived separately in `roomplan.json`,
rather than duplicated as a large `roomplan_original` tree in every portable capture.
The optional field remains supported when importing other providers' bundles.
`RawScanCapture.swift` polls the same session without replacing its delegate,
selecting up to six calibrated depth keyframes within an 8 MiB retained-payload
budget. It does not request or repeatedly copy a second raw mesh reconstruction;
RoomPlan's measured surfaces and objects supply navigation geometry, supplemented
by bounded confirmed ARKit floor and low-barrier planes. High-confidence depth
side measurements can also produce generic small-obstacle objects, using repeated
observations near a measured floor. Their saved, rendered and routing bounds agree;
no furniture identity is inferred. Native depth bytes are copied before one
background worker decodes them; busy samples are skipped.
These records preserve the shared ARKit frame; no export origin reset is applied.
Overlapping sections use the latest component with the same RoomPlan identifier.
Recovered floor and wall extensions are retained when not wholly covered, and
the routing map and portable scene share the same supplement selection. Long
sections save and continue automatically without resetting the AR session.

The app archives native RoomPlan JSON and selected depth bytes locally before upload.
Local processing has no upload-size limit and does not project a display point cloud
that navigation doesn't render. The network client enforces the 32 MiB limit only
when sending a capture; an oversized upload can still use its complete local map.
Native RoomPlan/semantic data is never silently truncated.
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
