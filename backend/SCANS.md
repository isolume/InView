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
pose graph before the depth is reintegrated. This is an initial mapping
pipeline: it does not texture geometry, automatically recognize floors, or turn the
mesh into reviewed navigation geometry. Device validation remains necessary.
Optional local furniture recognition derives labels and measured object bounds
from the uploaded RGB/depth observations, as described below.

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
`frame_count`, plus optional server `recognition` progress. Send only contiguous sequences. Timestamps must strictly increase
and frame IDs must be unique. Retrying identical manifest/chunk JSON values is
idempotent, including a chunk retry after Finish. Different values for an existing
id/sequence return 409 `stream_conflict`. A client that loses the response can
reload status and resume from `next_sequence`; Finish seals exactly the complete,
nonempty acknowledged prefix and is idempotent for the same count.

Successful create and summary responses advertise `Accept-Encoding: gzip`.
Clients may then send `Content-Encoding: gzip` with `Content-Type: application/json`
on chunk PUT requests, falling back to ordinary JSON for older servers. Compression
is lossless: the same uncompressed JSON values and original RGB/depth observations
are stored and compared for retries. Both compressed and expanded request bodies
have the 4 MiB limit. Invalid/truncated gzip data, bad checksums, additional gzip
members, and trailing data are rejected before any chunk is acknowledged.

Result and scene responses also support negotiated gzip when the request accepts
it and compression makes the response smaller. They include `Vary: Accept-Encoding`;
clients that request ordinary JSON keep receiving it. Derived cache files stay
uncompressed, and the original observations are unchanged.

Writes use a temporary file, file sync, atomic rename, and directory sync before
acknowledgment. Startup recovers contiguous committed chunks one file at a time;
unfinished temporary files are never acknowledged observations. Corrupt committed
files, gaps, or inconsistent finish markers fail recovery explicitly. UUID-only
paths and regular-file/directory checks reject traversal and symlink captures.
Original RGB/depth JSON stays on disk after the compact model is generated.
Finished-stream result and scene JSON are cached atomically beside those originals.
Cache metadata binds them to the source stream/count and reconstruction version and
checks their byte lengths and checksums; missing, outdated, or corrupt derived caches
are rebuilt. Repeated result requests, including requests after a server restart,
reuse these results. Simultaneous result/scene requests for the same scan share one
reconstruction and do not consume additional reconstruction slots while waiting.
Algorithm or wire-format changes must bump the reconstruction cache version.

The current reconstruction triangulates neighboring medium/high-confidence depth
samples from 0.15 to 8 meters, omits missing samples, avoids depth jumps and edges
longer than 0.5 meters, transforms triangles with the supplied rigid camera pose,
and welds observations into nested 2 cm cells. A cell retains its first measured
vertex; duplicate triangle faces are removed. At 250,000 vertices or 500,000 faces,
the mesh is compacted into 4 cm and then 8 cm cells. These counts are soft targets:
after 8 cm compaction, all later observations continue integrating and the mesh
can grow beyond either target. All retained faces are remapped deterministically;
collapsed, duplicate, folded and overlong faces are removed. Measured face normals
are preserved across compactions. Detail reduction can shrink narrow openings;
original camera/depth chunks remain unchanged. Actual cell size and compaction count
are reported in capture metadata, and the scene includes a brief detail warning.
This produces measured geometry without inferring rooms, floors, doorways or
walkability. Supplied object and surface labels are retained by id using their
latest submitted observation.

Before returning the model, a separate display simplifier targets 50,000 triangles.
It prefers topology-preserving simplification with a 5 cm estimated error. Noisy
overlapping depth topology can prevent sufficient reduction; then spatial cleanup
and simplification use a combined estimated error ceiling of 20 cm. The target is
soft: protecting geometry can produce more triangles, without rejecting a scan.
Connected regions are processed separately; substantial closed boundary loops and
region extent anchors are protected. Fragmented boundaries and small features can
lose detail. Retained vertices use original measured positions, while faces may
span simplified neighborhoods. This approximate rendering mesh is not a clearance
or walkability measurement. Observed surface polygons and obstacle bounds are not
simplified by this pass. Capture metadata reports source/display counts, method,
estimated error and protected regions/boundaries under `display_meshes`.

The compact derived capture contains this display mesh at an identity transform,
retained observed labels and reconstruction metadata; it omits the raw keyframes.
Its existing `Scene` uses the same display mesh and source ids, enabling the
native app to validate and archive it through its normal capture/scene path.

Known photo-catalog objects are returned as model keys, measured dimensions and
poses instead of repeating model vertices per object. The app renders its bundled
`photo-furniture-v1` assets, reusing geometry between instances. Coarse parts remain
in the scene as a fallback for viewers without that catalog. Unclassified objects
also use compact box parts rather than dense rounded-envelope meshes. Other
procedural catalog categories retain their supplied model meshes.

### Server furniture recognition

Run `bash recognition/setup.sh` once from `backend/`. It creates a private virtual
environment, downloads the pretrained YOLOE segmentation checkpoint, and caches
the supported catalog prompts. The executable automatically enables recognition
when this runtime exists. Override the interpreter with
`INVIEW_RECOGNITION_PYTHON`, the checkpoint with `INVIEW_RECOGNITION_WEIGHTS`, or
the device with `INVIEW_RECOGNITION_DEVICE`; `INVIEW_RECOGNITION=off` disables it.
The inference process forbids runtime network access and does not install packages
or fetch weights while processing scans.

One persistent worker processes selected committed observations while uploads
continue. It selects the first view, then views separated by two seconds, 0.5 meters
of movement, or 20 degrees of rotation. The original camera pose supplies the image
rotation for upright recognition; masks are mapped back into the sensor-native
depth grid. Masks exclude boundary pixels, and only medium/high-confidence depth
samples contribute to object measurements. Cached masks bind to original frame
identity, calibration dimensions, source checksum and the recognition pipeline.
Restarting or retrying a scan reuses valid detections. The queue retains stream
identifiers and progress, not a duplicate archive of image frames.

After pose optimization, masked depth points are transformed by the corrected
camera poses. Conservative association combines views of the same object while
keeping adjacent objects separate. Upright bounds are estimated from measured
points; category labels never supply missing dimensions. Confident detections from
distinct views use the existing catalog models. Single or ambiguous views retain
measured envelopes. A strong match can label an existing unclassified obstacle
without changing its original measured pose, dimensions or identifier. Unmatched
observations retain their geometry. This is category recognition, not identification
of a particular furniture manufacturer/model or recovery of unseen geometry.

While selected views are still processing, result requests return retryable
503 `recognition_pending`; the native client waits with cancellable backoff for up
to three minutes. A failed worker produces an explicit measured-geometry fallback,
which is not permanently cached as a complete recognized result. Result metadata
reports worker progress, detection fusion and catalog-label matches. Derived result
caches bind to the recognition pipeline so changing weights or disabling recognition
cannot serve a stale model from another configuration.

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

There are no fixed aggregate frame, archive-byte, label, mesh or result-size limits
for continuous scans. Individual observations remain validated: manifest 16 KiB,
chunk 4 MiB, JPEG 512 KiB, RGB 1,048,576 pixels and at most 2,048 pixels per axis,
depth 262,144 samples, and 1,024 objects/surfaces per chunk. An oversized individual
chunk returns 413 `stream_limit`; accepted scans are not truncated. Capacity depends
on available disk and memory. At most two reconstructions run at once; excess requests return
retryable 503 `processing_busy`. At most four result/scene HTTP workers can run or
wait for a shared build; excess requests also receive retryable 503, bounding
same-scan request retries as well. Reconstruction reads one disk chunk at a time
directly into its typed frame, with sparse vertex/face tables instead of
retaining all frames in memory. Each depth pixel is unprojected once per frame;
confidence rules and depth discontinuity checks remain intact. The v5 reconstruction
cache invalidates earlier results without recognition, display reduction and model
references. Large-building scans still need physical
LiDAR-device tests for tracking drift, coverage, heat, upload sizes and recovery.

Use a release build when measuring scans (`cargo run --release`). For a repeatable
local benchmark, supply a synthetic 960×720 JPEG to
`cargo run --release --example stream_performance -- /path/to/synthetic.jpg 120`.
It exercises 120 full-resolution 256×192 depth observations in a private temporary
store, prints ingestion/reconstruction/cache timings, and deletes the store on exit.
It does not read saved captures or contact a server.

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
<<<<<<< HEAD
selecting up to six calibrated depth keyframes within an 8 MiB retained-payload
budget. It does not request or repeatedly copy a second raw mesh reconstruction;
RoomPlan's measured surfaces and objects supply navigation geometry, supplemented
by bounded confirmed ARKit floor and low-barrier planes. High-confidence depth
side measurements can also produce generic small-obstacle objects, using repeated
observations near a measured floor. Their saved, rendered and routing bounds agree;
no furniture identity is inferred. Native depth bytes are copied before one
background worker decodes them; busy samples are skipped.
=======
copies the latest classified mesh snapshot, and keeps up to 48 calibrated depth keyframes spread
over the whole walk (see [Capture format changes](#capture-format-changes)).
For each selected keyframe it retains original raw `sceneDepth`, confidence bytes, and,
when ARKit provides it, original `smoothedSceneDepth` bytes as separate local native buffers.
>>>>>>> origin/feat/navigation-pipeline
These records preserve the shared ARKit frame; no export origin reset is applied.
Overlapping sections use the latest component with the same RoomPlan identifier.
Recovered floor and wall extensions are retained when not wholly covered, and
the routing map and portable scene share the same supplement selection. Long
sections save and continue automatically without resetting the AR session.

<<<<<<< HEAD
The app archives native RoomPlan JSON and selected depth bytes locally before upload.
Local processing has no upload-size limit and does not project a display point cloud
that navigation doesn't render. The network client enforces the 32 MiB limit only
when sending a capture; an oversized upload can still use its complete local map.
Native RoomPlan/semantic data is never silently truncated.
=======
The app archives native RoomPlan JSON, the portable `capture.json`, copied mesh/depth
bytes, and `worldmap.archive` in the same `Documents/Captures/<scan-id>/` directory before
upload. `worldmap.archive` is an Apple-only ARWorldMap relocalization asset and is referenced
from `metadata.assets.world_map`. The current JSON upload does not send binary sidecars yet.
If a bundle exceeds the 32 MiB limit, optional whole depth/mesh layers remain
local and their omission is recorded in metadata. Native RoomPlan/semantic data is
never silently truncated; if that layer alone is too large, upload reports an error.
>>>>>>> origin/feat/navigation-pipeline
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

## RoomPlan semantics read by the worker

The `roomplan` pipeline stage (`worker/inview_worker/stages/roomplan.py`, helpers in
`worker/inview_worker/roomplan/`) reads Apple's native export instead of only the portable records.
Source order: the package's `roomplan.json` (the iPhone's verbatim `JSONEncoder().encode([CapturedRoom])`),
then `capture.json`'s `roomplan_original`, then the portable `surfaces`/`objects` (rectangles only, no
labels or door state). An empty array (`[]`) counts as absent. Accepted shapes: `[CapturedRoom]`, one
`CapturedRoom`, or a `CapturedStructure` (`rooms` plus merged top-level components).

Fields read, per `CapturedRoom`: `identifier`, `story`, `version`, `walls`, `doors`, `windows`,
`openings`, `floors`, `objects`, `sections`. Per surface: `identifier`, `category` (including
`door.isOpen`), `dimensions`, `transform`, `polygonCorners` (surface-local, floors only),
`confidence`, `story`, `parentIdentifier`, `completedEdges`, `curve`. Per object: `identifier`,
`category`, `dimensions`, `transform`, `attributes`, `confidence`, `story`, `parentIdentifier`.
Per section: `label`, `center`, `story`. Unknown or missing keys are tolerated. Malformed components
are counted and skipped. Both Swift Codable spellings are accepted: enums as `{"case": {payload}}` or
bare strings, and `simd_float4x4` as four column arrays or 16 column-major numbers.

Derived product: room polygons in X/Z from the floor corners, or the floor rectangle, or the wall hull
for iOS 16. Each room gets a section label when a section center falls inside its polygon. Doors keep
their open/closed state from the latest section and record which rooms they `connect`. Also derived:
openings, windows with sill height, walls, objects with their attributes and room, and stories. Labels
and states are RoomPlan's own estimates, not verified accessibility data. The iPhone needs no format
change. `roomplan.json` already carries everything above.

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

## Capture format changes: on-device OCR and capture semantics

Both files below are **additive, optional** sidecars inside `.inviewscan.tar`, written with
`CaptureStore.stageSidecar` before the archive is built and inventoried in `package-manifest.json`
(roles `text_observations` and `capture_semantics`). Older packages lack them; readers must treat a
missing file, a missing optional key, or an unknown key as "no evidence", never as an error. Both
use `schema_version: 1`; a breaking change bumps it. JSON keys are sorted; `null` values are omitted.
The Swift models are `TextObservationsDocument` and `CaptureSemantics` in `Packages/AccessCore`.

### `text-observations.json` (on-device OCR)

Apple Vision `VNRecognizeTextRequest` (`.accurate`, language correction, automatic language
detection) runs off the main thread when the capture is finalized, overlapping the local scene
build. It reads high-resolution `<frame-id>.ocr.jpg` stills already in the capture directory first,
then the `<frame-id>.color.jpg` keyframes, bounded to 48 images and 12 s. Lines under 0.3 confidence
or under ~1.5% of the image height are dropped. Any failure skips the file or an image; the capture
continues. An empty `observations` list means OCR ran and found nothing.

```json
{"schema_version": 1, "engine": "apple_vision", "observations": [
  {"frame_id": "depth-3", "image_asset": "depth-3.color.jpg", "image_size_px": [480, 640],
   "image_orientation": "upright_rotated_right_from_sensor",
   "text": "EXIT", "confidence": 1.0, "bbox_norm": [0.25, 0.25, 0.5, 0.25],
   "bbox_sensor_norm": [0.25, 0.25, 0.25, 0.5], "languages": ["en"]}]}
```

- `frame_id` is the depth observation (`package-manifest.json` `observations[].id`) whose pose and
  intrinsics describe the image. `image_asset` is the package file that was read.
- `image_size_px` is `[width, height]` of that **upright** JPEG (the sensor image rotated right).
- `bbox_norm` is `[x, y, w, h]`, normalized to the upright JPEG with a **top-left origin, y down**
  (converted from Vision's bottom-left origin and clipped to `[0, 1]`). Pixel box =
  `bbox_norm * [w, h, w, h]`. Manifest intrinsics describe the landscape sensor image, not the
  JPEG, so never unproject `bbox_norm` directly.
- `image_orientation` (required) names the transform from the calibrated sensor-native image to
  the OCR'd image. iPhone keyframes and stills are always `upright_rotated_right_from_sensor`
  (rotated 90° clockwise): upright pixel `(px, py)` of a `W×H` image is sensor-normalized
  `(u, v) = (py / H, 1 − px / W)` (`geometry.jpeg_to_sensor_uv`). Consumers must reject
  orientations they do not know.
- `bbox_sensor_norm` is the same box already in the sensor-native image (`[u, v, w, h]`, top-left
  origin, normalized): `[y, 1 − x − w, h, w]` of `bbox_norm`. It can be unprojected with the frame's
  intrinsics directly.
- `languages` are BCP 47 guesses from `NLLanguageRecognizer` (most likely first, each ≥ 0.2
  probability), empty for text with fewer than three letters (room numbers, arrows). Vision reports
  no per-line language.
- Observations are sorted by image, then top-to-bottom, left-to-right. The same sign is usually
  read in several frames; deduplication and triangulation are the backend's job.

### `semantics.json` (reviewed capture semantics)

Written before every archive is built (so upload retries carry the current review state) and again
when the volunteer saves the map.

```json
{"schema_version": 1, "coordinate_frame": "shared_arkit_session", "floor_y": -1.2,
 "geographic_reference": {"latitude": 33.75, "longitude": -84.39, "heading_degrees": 12,
                          "horizontal_accuracy_m": 5},
 "access_points": [{"id": "UUID", "kind": "ramp", "name": "South ramp", "position": [1, -1.2, 2],
                    "source": "detected", "confidence": 0.8, "slope_degrees": 6,
                    "requires_assistance": false}],
 "stairs_footprints": [{"source": "roomplan", "center_xz": [2, 1], "size_m": [1, 3], "yaw_radians": 0,
                        "corners_xz": [[2.5, 2.5], "..."], "bottom_y": -1.2, "height_m": 0.8}],
 "roomplan": {"rooms": [{"id": "UUID", "story": 0,
   "sections": [{"label": "kitchen", "center": [1, -1.2, 1], "story": 0}],
   "surfaces": [{"id": "UUID", "kind": "door", "is_open": true, "confidence": "high", "story": 0,
                 "parent_id": "UUID", "map_from_surface": ["16 floats"], "dimensions_m": [0.9, 2, 0],
                 "polygon_corners_m": [["x", "y", "z"]]}]}]},
 "capture": {"app_version": "0.1.0", "app_build": "1", "device_model": "iPhone16,1",
             "system_name": "iOS", "system_version": "18.2", "floor_id": "ground"}}
```

- **Frame:** every position, transform and corner is in the shared ARKit session frame of
  `capture.json` (meters, right-handed, +Y up). `*_xz` are floor-plane `[x, z]` pairs.
  `map_from_surface` is column-major like `capture.json`. `floor_y` is the map's floor height.
- `geographic_reference` (omitted when unknown) places the **scan origin**, not the phone: heading
  is clockwise from true north to local −Z (`BuildingMapReference`). It is the app's filtered GPS fix
  (≤ 20 m, heading accuracy ≤ 20°) or the volunteer's manual placement.
- `access_points` are the map's confirmed elevator/ramp/destination points (repeat-sighted
  detections, volunteer-kept sightings, and manual pins); unconfirmed sightings are excluded.
  `slope_degrees` is the LiDAR-measured ramp incline when known.
- `stairs_footprints`: `source` is `detected` for vision-model stairs RoomPlan missed, else
  `roomplan`.
- `roomplan.rooms` has one entry per RoomPlan section in scan order, with the fields the portable
  `capture.json` projection drops: `sections` (RoomPlan room-type labels `livingRoom`, `bedroom`,
  `bathroom`, `kitchen`, `diningRoom`, `unidentified`), `story`, door `is_open`, `parent_id` (the wall
  a door/window/opening is cut into), `confidence`, and `polygon_corners_m` — RoomPlan's
  surface-local polygon corners **transformed into the session frame** (may be empty for plain
  rectangles). Adjacent sections can repeat a surface `id`; the later section is the latest
  measurement.
- `capture` is provenance: app version/build, hardware identifier, OS, and the capture's `floor_id`.
