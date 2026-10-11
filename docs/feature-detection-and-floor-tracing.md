# Staircases, elevators and live floor tracing

## During a scan

- Sweep the floor first, then pause on the actual doorway or staircase. Take a small step sideways or change viewing angle, and pause again to obtain independent evidence.
- Stair labels show the number of measured visible treads and vertical rise. Orange wireframes bound **sampled visible treads**, not the hidden remainder of a flight.
- A `?` means the feature still needs evidence or human review. Repeated uncertain model replies no longer turn into a confirmed feature automatically.
- **Show/Hide floor trace** toggles the live overhead preview and mint AR floor outlines. The preview combines measured floor polygons with the recorded phone trail and distance. Its final dot marks the last recorded camera position.

Automatic feature recognition still uses the configured OpenAI or Gemini key. OCR signs and floor tracing do not need a key. OCR elevator/stair signs remain separately labeled sign locations; they are not promoted to physical entrances.

## Staircase changes

The vision response now includes a visible-feature rectangle. On-device verification samples up to 637 distinct depth pixels inside that rectangle using the **same copied depth, intrinsics and camera pose as the uploaded image**, even when the model replies much later. It never retains an ARFrame while waiting for the network.

Verification looks for at least three supported horizontal treads, 9–24 cm risers and 16–50 cm tread pitches, alongside a coherent 18–58° envelope. A sloping plane alone is not enough. Ascending and descending flights are supported. Smooth ramps, floor/wall patches, invalid depth and inconsistent steps cannot independently verify stairs. A single step or partially hidden flight stays inconclusive for review; these thresholds are not building-code certification.

Confirmed stairs use their sampled oriented footprint, bottom elevation and visible height in the saved map/semantic export instead of the old universal 1.2 × 1.5 m marker. The strongest observed tread-count measurement is retained rather than combining uncertain views into a guessed whole-flight outline. Manually/review-confirmed stairs without measured extents still use the existing conservative marker footprint.

## Elevator changes

The prompt distinguishes a doorway with a call panel/indicator, a doorway alone, a standalone panel and a direction sign. Sign-only/panel-only claims do not create elevator entrance candidates. Automatic confirmation requires:

1. At least two distinct viewpoints, separated by 0.8 seconds and at least 15 cm of camera movement or 10° of rotation.
2. At least one observation with doorway-plus-panel/indicator evidence, matched-frame depth at the target, and agreement within 20 cm of an independently measured floor.

A confident single frame is no longer enough. Duplicate detections from one image and stationary retries do not increase the confirmation count. The elevator merge radius is reduced from 2 m to 0.65 m to avoid collapsing adjacent doors into one elevator. Doorway-only and missing-depth observations can remain provisional for review. This trades some automatic recall for fewer false entrances; no claim is made that the elevator is operating or wheelchair-accessible merely because it was detected.

## Floor trace provenance

The live view reuses the existing confirmed AR plane outlines, current RoomPlan floors, and bounded `ScanWalkTraceRecorder`. It refreshes at 1 Hz without rebuilding a raw/depth snapshot. Camera tracking gaps and relocalization jumps stay disconnected. Polygon boundaries are preserved individually: the UI does not fill a convex hull between disconnected rooms or synthesize floor underneath the phone trail.

The trail is camera movement, **not** floor geometry, an accessibility assessment, or a navigation route. Plane boundaries are measured estimates and can expand/refine during scanning. Existing export retains observed floor footprints and the walk trace in `raw-snapshot.json`; reviewed floor coverage remains part of the map. Each floor capture has its own local metric coordinate frame and floor identity; geographic positioning still requires a valid geographic map reference.

## Implementation and tests

- `AccessCore/FeatureDepthGeometry.swift`: calibrated depth sampling and independent-view confirmation policy.
- `AccessCore/StairsCheck.swift`: repeated-tread assessment and visible metric bounds.
- `InView/Detection/AccessibilityDetector.swift`: depth/image pairing, temporal evidence and measured footprint adoption.
- `DetectionOverlay`, `ScanWalkPreview`, and `ScanController`: bounded live AR/overhead tracing.

Tests cover captured-pose unprojection, bad depth/confidence, duplicate pixel rejection, ascending/descending flights, steep smooth ramps, measured bounds/elevation, independent viewpoints, and automatic confirmation rules. Existing walk-trace tests cover tracking gaps, disconnected floor coverage and sample budgets. Physical-device field tests are still required for real stairs, reflective elevator doors, occlusion and map drift; simulator/synthetic tests do not establish detection accuracy.
