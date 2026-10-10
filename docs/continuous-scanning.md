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
- Connectivity does not block capture. Without a server, samples remain on the
  phone and a compact measured map can be reviewed. No complete depth model is
  reconstructed locally by this path.
- Finish seals the local capture before contacting the server. A failed upload
  remains retryable. **Scan processing → Saved scans** can explicitly resume a
  saved stream and review its model after an app restart. A saved stream normally
  uses its original server; **Send to selected server** explicitly changes that
  binding. Opening the saved-scans list does not send camera data.

Local originals are under `Documents/Captures/<scan UUID>/stream/`. Server
originals use `INVIEW_STREAM_DIR`, defaulting to `data/streams/`. These archives
contain indoor camera images as well as depth measurements. The scan-processing
server setting identifies where those images are sent.

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

The result contains a compact derived capture, its matching scene, original and
optimized keyframe poses, and alignment diagnostics. The app validates these
together and corrects review pins and detected stairs using their observation
times. The raw observations remain separate from the derived model.

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

The prototype caps one capture at 10,000 accepted samples or 2 GiB of chunk data.
An individual chunk is at most 4 MiB. Those limits pause acceptance while keeping
the accepted prefix finishable. Backend reconstruction also bounds keyframes,
registration candidates, mesh size, concurrent workers, and its result size.
The current graph uses at most 64 keyframes, so long scans may lose revisit
opportunities. Supporting arbitrary building sizes needs a submap strategy and
larger-scale localization, not merely higher limits.

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
