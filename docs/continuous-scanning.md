# Continuous scanning

The `streaming` branch defaults to a continuous ARKit scanner. Choose a floor,
walk through the space, and tap **Finish**. The camera session does not start
RoomPlan or stop at room boundaries. **Scan processing → Continuous scanning**
can be turned off to compare with the existing RoomPlan scanner.

This is a prototype capture and reconstruction path. It has compiled for the
Simulator; a long physical LiDAR scan is still needed to establish capture quality,
tracking behavior, memory, heat, and the accuracy of detected loop closures.

## Capture and transport

- One shared AR session supplies camera tracking, scene depth, and compact floor
  and obstacle measurements. Full on-device mesh reconstruction stays disabled.
- At most one keyframe is copied, encoded, and written at a time. Camera images
  remain in the depth sensor's orientation. JPEG dimensions and camera calibration
  are scaled together; depth uses the same normalized image coordinates.
- Samples are selected at most twice per second when the phone has moved 10 cm,
  turned 10 degrees, or held a view for three seconds. Tracking must be normal and
  current. This is continuous coverage with selected samples, not an archive of
  every camera frame.
- Each accepted RGB/depth sample is atomically saved before upload. A separate
  worker sends one immutable numbered chunk at a time. Retrying a lost response
  cannot create a duplicate frame. Original chunks remain available for reupload.
- **Captured surfaces** highlights saved measurements in green directly over the
  camera view. Tap it to hide or show coverage. Highlights use the surface currently
  visible, so a nearer object hides captured geometry behind it; uncertain depth
  and lost tracking hide the affected highlights. Green means captured on this
  phone, not fully scanned or finished processing. The bounded preview can refresh
  older highlights as an area is captured again; saved scan data is retained.
- Uploads use lossless gzip when the server advertises support. The phone retains
  the original JSON and measurements; older servers continue receiving ordinary
  JSON. The uploader reuses the established stream between samples and reconciles
  again on explicit retry or Finish.
- Connectivity does not block capture. Without a server, samples remain on the
  phone and a compact measured map can be reviewed. No complete depth model is
  reconstructed locally by this path.
- Finish seals the local capture before contacting the server. A failed upload
  remains retryable. **Scan processing → Saved scans** can explicitly resume a
  saved stream and review its model after an app restart. A saved stream normally
  uses its original server; **Send to selected server** explicitly changes that
  binding. Opening the saved-scans list does not send camera data.
- Upload progress reports acknowledged samples, then switches to building the
  model after the server receives the full capture. Preparing and saving are
  separate stages. A growing upload backlog does not mean reconstruction has
  started.

Continuous mode retains one separate depth observation for the compact local
fallback, alongside measured floor and obstacle coverage. The full synchronized
camera/depth history remains in the stream archive. Finish does not export a
second full depth history. The RoomPlan comparison path retains its existing
bounded depth archive.

Local originals are under `Documents/Captures/<scan UUID>/stream/`. Server
originals use `INVIEW_STREAM_DIR`, defaulting to `data/streams/`. These archives
contain indoor camera images as well as depth measurements. The scan-processing
server setting identifies where those images are sent.

**Saved scans → View scan data** opens the original depth measurements as an
orbitable point cloud, with **Depth** and **Color** appearances. It works offline
and does not resume uploads. **Map options → Scan data** opens the same view while
reviewing a continuous scan or its saved model. This is a sampled preview of the
original camera poses, so it may differ from the backend's corrected model. It
reads one saved chunk at a time, selects up to 24 views across the whole walk,
and displays at most 90,000 points. Opening it never changes the saved map,
capture, or upload progress.

Use the share button in **Scan data** to export all saved observations for offline
reconstruction. Export is optional and runs only when requested; it adds no work
to Finish. The TAR contains the original sensor-oriented JPEGs, packed
little-endian float32 depth and confidence files, and a versioned observation
index with calibration, original camera poses, timestamps, and observed labels.
It reads and releases one validated chunk at a time. Missing depth is encoded as
the canonical float32 NaN `0x7fc00000`. These are portable representations of the
saved measurements, rather than byte-exact native ARKit buffers with row padding.
The export preserves the source archive and its upload checkpoint. Closing the
view cancels preparation; temporary share files are removed after dismissal.

This adapts the calibrated inventory and binary sidecar ideas from PR #1 without
adding its separate RoomPlan package upload or location collection. Normal
tracking observations remain accepted even when world mapping is limited;
requiring a fully mapped environment would create gaps while exploring a building.

## Reconstruction and drift correction

The backend keeps a bounded set of reconstruction keyframes, proposes nonadjacent
revisit candidates, and verifies candidates against image and measured depth
evidence. Verified constraints are added to a pose graph alongside the supplied
camera trajectory. Optimization fixes the first camera pose so geographic placement
keeps the same reference origin.

After optimization, the backend rereads the saved chunks one at a time and rebuilds
the measured mesh. Camera-pose corrections are interpolated by sample timestamp,
using linear translation and shortest-path quaternion interpolation. Supplied
floor, barrier, and obstacle poses receive the same corrections. Object dimensions
and local measured polygons are preserved. A weak or absent loop match leaves
the supplied trajectory unchanged; it does not imply that trajectory has no drift.

The first reconstruction triangulates supported depth neighborhoods, excludes
confidence holes and depth discontinuities, welds nearby vertices, and removes
duplicate faces. It is not volumetric TSDF fusion, automatic room segmentation,
or textured reconstruction. Camera images are retained for registration and later
processing. Mesh triangles never become assumed walkable floors.

Large meshes automatically compact nearby measured vertices from 2 cm to 4 cm
and then 8 cm cells. All later samples continue integrating; vertex and triangle
counts trigger compaction rather than rejecting the scan. This reduces detail and
can shrink narrow openings, so the model reports when compaction was needed.
Full original measurements stay saved for later processing.

The server then reduces the display mesh toward a soft target of 50,000 triangles,
using topology-preserving simplification first and spatial cleanup when overlapping
depth prevents useful reduction. Estimated display error can reach 20 cm; small
features and fragmented openings can lose detail. Connected regions, substantial
closed boundary loops and extent anchors receive protection. Original observations,
measured floor polygons and obstacle bounds remain separate from this display pass.
Source/display counts and estimated error are reported in reconstruction metadata.
Both halves of the returned capture/scene use the same reduced mesh. Result and
scene responses use lossless gzip when the client accepts it and it saves bytes.
Known photo-catalog furniture is sent as model keys and measured placements; the
app reuses its bundled models instead of downloading another copy for each object.

Local server recognition can identify supported furniture categories from selected
RGB views. It runs during upload, caches object masks, and fits measured object
bounds using depth and the corrected poses. Distinct views confirm model placement;
single or ambiguous views keep measured shapes. An existing unclassified obstacle
can gain a category while retaining its measured geometry. Run
`bash recognition/setup.sh` from `backend/` once to install the inference runtime.
Inference stays on the scan server and does not send images to another service.
If recognition is catching up, the app waits with cancellable backoff; if the worker
fails, the model reports a measured-geometry fallback. Floor recognition and
reviewed navigation geometry remain separate work.

The result contains a compact derived capture, its matching scene, original and
optimized keyframe poses, and alignment diagnostics. The app validates these
together and corrects review pins and detected stairs using their observation
times. The raw observations remain separate from the derived model.
Finished result and scene responses are cached on the server with source and
version checks. Retrying an interrupted response reuses the finished model rather
than starting reconstruction again. Result requests use a three-minute request
timeout and remain cancellable. Concurrent requests for the same capture
share its work; response requests and active builders remain bounded.

New review destinations can be placed after the backend result is ready, or after
explicitly choosing **Use local map**. Choosing the local map fixes that review's
coordinates and ends backend retries for that review. The retained stream can
still be processed from **Saved scans**, where its model is previewed separately
without replacing an already saved map or its destinations.

## Navigation and limits

A pose correction that varies along a scan cannot be installed as one transform
on the saved `ARWorldMap`. A materially corrected map therefore remains available
for review and saving, but live AR navigation is disabled until localization
against the corrected model is implemented. An uncorrected model continues to use
the existing relocalization path; absence of a verified loop is not an accuracy
certification.

If localization takes too long, **Try again** restarts with the saved AR world
map. Routing remains unavailable until ARKit recognizes that coordinate system;
standing at the starting spot alone does not establish alignment.

Continuous capture has no default total sample, archive, mesh or result-size cap.
Capacity depends on available disk and memory. An individual chunk is at most
4 MiB, and each sample is validated before acknowledgement. Tests or other callers
can still choose an explicit smaller local capture budget. Backend reconstruction
bounds graph keyframes, registration candidates and concurrent workers.
The current graph uses at most 64 keyframes, so long scans may lose revisit
opportunities. Whole-building drift correction and live guidance still benefit
from a submap strategy and localization against the corrected model.

Sections are not part of this scanner's user flow. Tracking loss, storage limits,
memory warnings, critical heat, and moving to a different floor can still pause
capture. Continuing a paused scan keeps its AR coordinate system; changing floors
starts a separate capture.

## Local validation

Run `swift test --package-path Packages/AccessCore` and `cargo test` in `backend/`.
The streaming tests cover durable samples, retries, interrupted transport,
reopened queues, server rollback, capture limits, calibration, and pose-correction
interpolation. Backend tests exercise measured depth geometry and synthetic loop
closure; synthetic results do not replace physical corridor testing.

For a phone test, run the backend with `INVIEW_BIND=0.0.0.0:3000`, set the phone's
scan-processing address to the Mac's local network address, and scan a textured
loop with the floor and surrounding surfaces in view. Inspect both the rebuilt
model and returned alignment diagnostics, then repeat with a straight corridor
and a deliberately interrupted connection. The prototype backend has no
authentication; keep this development test on a trusted local network.
