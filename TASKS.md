# InView merge tasks

This repo (`actual_inview`) is the submission target. Work from the standalone LiDAR prototype should be merged only when it strengthens the existing RoomPlan + navigation flow without replacing it.

## Merge principles

- Keep RoomPlan as the primary structured scan source for walls, doors, openings, floors, objects, routing, and review.
- Treat raw LiDAR/depth as an evidence layer that augments RoomPlan and backend processing.
- Preserve one shared ARKit coordinate frame per scan session. Do not reset AR tracking between RoomPlan sections and raw LiDAR capture.
- Keep raw captures immutable. Derived maps, scenes, and navigation graphs can be regenerated/versioned.
- Prefer additive schema changes with backward-compatible decoding.

## Product contract

A completed capture must be portable and reloadable. The saved/processed building map must support:

- 2D floor/occupancy/map views.
- 3D whole-building or out-of-room review views.
- ARWorldMap/visual relocalization assets for a later navigation session.
- Searchable destinations and semantic categories.
- Route planning with accessibility constraints.
- Server-side reprocessing without requiring the original scanning device.

The capture must preserve both **structured RoomPlan semantics** and **raw LiDAR evidence**. Neither alone is sufficient: RoomPlan supplies walls/doors/objects; raw depth, imagery, mesh and poses allow backend reconstruction, validation, OpenCV/Open3D processing, and future ML.

## P0 — raw LiDAR + RoomPlan compatibility

- [ ] Define a unified capture asset layout under `Documents/Captures/<scan-id>/` that can hold:
  - `roomplan.json`
  - `capture.json`
  - `scene.json`
  - `worldmap.archive`
  - raw depth/confidence/color/mesh assets
  - an optional streamable archive for backend upload.

Current baseline: `roomplan.json`, `raw-snapshot.json`, `capture.json`, and `worldmap.archive` are staged together under `Documents/Captures/<scan-id>/`.
- [ ] Extend `CaptureBundle.metadata` with explicit raw-LiDAR asset references instead of embedding every large native buffer in JSON.
- [ ] Keep `CaptureBundle.frames` as the portable, size-bounded preview/interchange layer.
- [ ] Add a separate local-only raw asset manifest for full-fidelity backend/ML processing.
- [ ] Ensure all raw depth frames and RoomPlan surfaces use the same `shared_arkit_session` coordinate frame.
- [ ] Add migration/backward-compatibility for existing captures without raw LiDAR assets.

## P0 — ARWorldMap / relocalization compatibility

- [x] Keep the existing `ScanController.saveWorldMap()` flow as the canonical world-map capture path.
- [x] Store the world map in the capture directory as `worldmap.archive` and reference it from `CaptureBundle.metadata.assets.world_map`.
- [x] Provide saved-map localization in navigation: `NavigationController` loads the saved world map and starts ARKit with `initialWorldMap`.
- [x] Show clear relocalization states through the navigation locating panel.
- [x] Never promote a fresh AR session origin to the saved map frame; routing starts only after ARKit reports normal/relocalized tracking.
- [ ] Device-test that relocalized live AR coordinates align with the saved RoomPlan map and route graph.

## P1 — import improvements from standalone LiDAR prototype

- [x] Preserve raw and smoothed depth separately when available in the local native `RawDepthBuffers` sidecar.
- [x] Preserve confidence maps as original UInt8 buffers.
- [x] Preserve adaptive JPEG color keyframes for colorized point clouds / backend texturing.
- [x] Preserve ARKit mesh snapshots with classification.
- [ ] Preserve per-frame phone pose metadata:
  - AR-relative x/y/z
  - GPS latitude/longitude/altitude + accuracy
  - heading
  - barometric relative altitude/pressure
  - throttled BLE beacon RSSI samples
  - throttled connected Wi-Fi SSID/BSSID when available.
- [x] Add an equivalent self-contained `.inviewscan.tar` export without disrupting the RoomPlan lifecycle.
- [ ] Add compression/streaming upload after the backend archive-ingestion endpoint is defined.

## P1 — backend format alignment

- [x] Make the backend receive and validate the self-contained `.inviewscan.tar` package with structured RoomPlan, raw LiDAR sidecars, ARWorldMap archive, and color assets. Sensor metadata and a versioned manifest remain follow-up work.
- [ ] Keep `CaptureBundle` JSON as the portable structured interchange layer; add raw sidecars/combined archive rather than replacing it.
- [ ] Update `backend/SCANS.md` with asset names, coordinate convention, transforms, dimensions, compression, and compatibility versions.
- [ ] Avoid sending large raw binary payloads as base64 JSON unless explicitly needed for a portable fallback.
- [ ] Add backend tests for captures that include RoomPlan + raw LiDAR sidecars.
- [ ] Persist backend output as a versioned building-map package that clients can download and reload for 2D, 3D, navigation, and relocalization.

## P1 — viewer/review integration

- [ ] Keep the existing processed RoomPlan scene and navigation map as the default review mode.
- [x] Add optional raw LiDAR review layers:
  - raw depth points
  - smoothed depth points
  - ARKit mesh overlay
- [x] Add colorized LiDAR point review from adaptive RGB keyframes.
- [ ] Add captured phone trace once per-frame location metadata is merged.
- [ ] Cache heavy review scenes and pause AR capture/session work while the viewer is open.
- [ ] Avoid controls embedded in SceneKit/RealityKit hit-test regions when native SwiftUI controls are sufficient.

## P2 — semantic processing, map products, and routing enrichment

- [ ] Build 2D products: floor outline, occupancy/walkability grid, doors/openings, obstacles, and floor-specific route graph.
- [ ] Build 3D products: cleaned/downsampled mesh or point cloud, surface classifications, and map-frame bounding volumes for out-of-room review.
- [ ] Use raw LiDAR/mesh evidence to validate RoomPlan floors, walls, obstacles, door clearances, and ramp/stair geometry.
- [ ] Extract/verify accessibility categories: elevator, stairs, ramp, automatic/manual door, accessible entrance, restroom, obstruction, and unknown.
- [ ] Add manually editable semantic places so a reliable destination exists even if ML/OCR is uncertain.
- [ ] Add OCR room labels and attach each candidate to the nearest plausible doorway/place; retain confidence and evidence.
- [ ] Evaluate OpenCV for markers, feature matching, OCR geometry, and pose estimation; evaluate Open3D for registration/mesh/point-cloud cleanup. Keep expensive processing backend-side.
- [ ] Add dynamic obstacle observations without baking temporary objects into the permanent map.
- [ ] Add searchable place/category index and accessibility-aware route filters.
- [ ] Add route confidence / localization confidence indicators.

## Known gaps in `actual_inview` compared with the standalone LiDAR prototype

These should be fixed selectively, not by replacing the current scanner:

- Raw depth capture is currently bounded and JSON-oriented; the standalone prototype preserves fuller backend-ready binary depth/confidence/color assets.
- Smoothed depth and color keyframes are not yet preserved as first-class sidecar assets.
- Phone geolocation/BLE/Wi-Fi/barometer metadata is not yet attached to raw capture frames.
- The standalone prototype has a streamable archive format; `actual_inview` currently has a RoomPlan-oriented capture bundle and local raw snapshot.
- The standalone prototype has richer raw/colored point-cloud review modes; `actual_inview` has stronger RoomPlan/navigation review.

## Do not regress

- Do not remove RoomPlan multi-section scanning.
- Do not remove current navigation graph/routing/demo flows.
- Do not replace `CaptureBundle` with the standalone `.lidarpack` format wholesale.
- Do not reset ARKit origin between RoomPlan capture, raw LiDAR sampling, and world-map saving.
- Do not rely on Wi-Fi as precise indoor positioning; use it only as a coarse/fingerprint signal.
