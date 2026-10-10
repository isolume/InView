# InView

Volunteers scan a floor once with a LiDAR iPhone. A vision model (OpenAI by default, Gemini optional) spots and names the elevators, ramps and stairs, and LiDAR checks each find and measures ramp slopes. The app then produces a floor plan, an orbitable 3D model and an accessibility report.

A wheelchair user then opens InView, which recognizes the room from the saved AR map. They follow AR arrows and spoken, captioned directions along a step-free route to the nearest usable elevator or ramp. The route goes around stairs, obstacles LiDAR sees on the way, and ramps steeper than the ADA allows.

The server (Photon iMessage agent, ElevenLabs voice) is a teammate's separate piece of work; this repo's iOS app doesn't call it yet. Team plans: [larp.md](larp.md) and [photon.md](photon.md). `backend/` is a teammate's Rust prototype.

## Setup

Requires Xcode 26+, an iPhone with LiDAR (Pro / Pro Max), and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill it in
xcodegen
open InView.xcodeproj
```

`Config/Secrets.xcconfig` is git-ignored. Set:

- `OPENAI_API_KEY`: elevator, ramp and stairs detection while scanning. Without it, mark things by hand.
- `DEVELOPMENT_TEAM`: your Apple team ID, needed to run on the phone. You can also pick the team in Xcode under Signing & Capabilities.
- `VISION_PROVIDER = gemini` plus `GEMINI_API_KEY` switches detection to Gemini. Nothing else changes.
- Optional: `OPENAI_MODEL` (default `gpt-6.1-sol`), `OPENAI_REASONING_EFFORT` (default `medium`), `GEMINI_MODEL` (default `gemini-3.8-flash`).

Re-run `xcodegen` after adding or removing files. The scheme turns off Metal API Validation, because RealityKit's own shaders trip it in debug runs.

Build without a device, and run the core tests:

```sh
xcodebuild -project InView.xcodeproj -scheme InView -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
cd Packages/AccessCore && swift test
```

The repo uses jj with small conventional commits.

## Demo checklist

1. **Start the scan at the demo table.** Hold still for a second, facing the way the rider will start. That spot is the map's origin, and the app saves a photo of it.
2. **Map a space.** Slowly pan around the table area first, then walk to the elevator and the ramp. Pause on each one for a couple of seconds; frames are only analyzed while the camera is steady.
   - Finds appear as they're spotted.
   - **Elevator / Ramp / Stairs** mark whatever is under the crosshair. For a ramp, aim at its middle so its slope gets measured. For stairs, aim at the bottom step.
   - **Add section** splits a big area. Keep each section under about 5 minutes.
3. **Finish**. If saving the AR map fails, move around a little and tap **Try again**.
4. Review:
   - Check each find's photo.
   - Rename points so they're easy to say.
   - Swipe away false stairs.
   - Turn on **Needs staff** for anything someone has to operate.
   - Flip the map between Plan and 3D, and open the full report.
   - **Save**.
5. **Navigate.** Stand near the table and look around until the app recognizes the space. If it hasn't after 15 s, stand on the scan start spot, face the way the photo does, and tap **Start from here**. Then:
   - Tap **Take me to the nearest accessible point**.
   - Put a chair in the path: it gets a red marker, and the route and voice go around it.

Relocalization works best when the lighting matches the scan and the area has texture: posters, furniture, signage. Rescan close to demo time if the room has changed a lot.

## How it works

### Scanning pipeline

1. RoomPlan scans walls, doors, furniture and stairs. It shares one `ARSession` across sections, so everything is in one coordinate space.
2. `AccessibilityDetector` watches camera motion. It sends a frame to the vision model only when the camera has been steady (≤ 25°/s and ≤ 0.35 m/s for 0.3 s), at most every 1.2 s, with up to 3 requests in flight. Frames are 1536 px JPEGs with OpenAI's high-detail setting.
3. Each find is placed in 3D by raycasting the model's point onto LiDAR surfaces, then checked against geometry:
   - **Stairs** need confidence ≥ 0.8, and `StairsCheck` must see a 18–58° climb.
   - **Ramps** must measure 1.5–15° (`SurfaceFit`).
   - Rejected claims are counted in the scanning status chip.
4. Finds of the same kind merge when they're close: within 2 m for elevators, 2.5 m for ramps, 3 m for stairs. For stairs, the lowest point seen is kept as the bottom step.
5. A find is **confirmed** once it has enough sightings:
   - **Elevators:** 2 frames.
   - **Ramps and stairs:** 2 frames with LiDAR agreeing at least once, or 4 frames if LiDAR never could tell.
   - **Hand marks:** count immediately.
6. Only confirmed finds reach the map. Unconfirmed ones show with a "?" while scanning. Each find keeps the photo it came from, which is shown in review.
7. `MapBuilder` flattens everything into the saved map:
   - It adds camera-spotted stairs that don't overlap RoomPlan's.
   - It snaps elevator pins to the floor in front of the nearest RoomPlan door or opening within 1.5 m (`DoorSnap`).
   - It records each piece of furniture's type and height, for the plan symbols and the 3D model.

### Where things live

| Piece | Where |
| --- | --- |
| RoomPlan scan → footprints (walls, doors, furniture by type, stairs) | `InView/Scan/MapBuilder.swift` |
| Vision detection (OpenAI or Gemini behind `VisionDetector`), placement, LiDAR checks, confirmation, evidence photos | `InView/Detection/` |
| Find outlines over the scanning camera | `InView/Scan/DetectionOverlay.swift` |
| Stairs and ramp geometry checks, door snapping | `Packages/AccessCore/.../StairsCheck.swift`, `SurfaceFit.swift`, `DoorSnap.swift` |
| Floor plan symbols, 3D model (non-AR `ARView` with orbit camera) | `InView/Map/` |
| ARWorldMap save and relocalization | `InView/Scan/ScanController.swift`, `InView/Navigate/NavigationController.swift` |
| Wheelchair routing: clearance grid, ADA door widths, A*, obstacles, steep-ramp fallback | `Packages/AccessCore/.../OccupancyGrid.swift`, `RoutePlanner.swift` |
| LiDAR obstacle detection while navigating (scene depth, every 0.5 s) | `InView/Navigate/ObstacleTracker.swift`, `Packages/AccessCore/.../ObstacleFinder.swift` |
| Turn-by-turn narration (system voice, captions) | `InView/Voice/`, `Packages/AccessCore/.../Maneuver.swift` |
| Accessibility report (score logic in core; UI with stats, door-width bars, slope gauges) | `Packages/AccessCore/.../AccessibilityReport.swift`, `InView/Report/` |
| AR chevrons, point labels, stairs zones and outlines, obstacle markers | `InView/Navigate/PathRenderer.swift` |

### Routing rules

- Routes keep 45 cm clearance from obstacles (90 cm passages). In tight spaces they fall back to 30 cm, then 15 cm, and the UI warns that the route is narrow.
- Doors under 81 cm (ADA 32") are treated as walls.
- Ramps steeper than 1:12 (4.8°) are used only when nothing else is reachable.
- Hooks for the server, unused for now:
  - `RouteConditions.unavailable` excludes points, e.g. elevators reported out of service.
  - `AccessPoint.requiresAssistance` marks staff-operated points for the Photon agent.
  - `VoiceGuide` is the single place where spoken lines are produced.

## Status and known issues (October 10, 2026)

The core logic is unit-tested (32 tests). The app builds, and it has only been tried briefly on an iPhone 17 Pro. Open problems from that testing:

1. **The 3D outline boxes look bad.**
   - **Where:** around finds while scanning (`DetectionOverlay`, a 30 fps `Canvas` that projects box corners), and the red outline box around stairs in navigation (`StairsMarker`).
   - **Wanted instead:** a small tag in the find's color at its location (elevator blue `Theme.accent`, ramp teal, stairs red `Theme.stairs`).
2. **Most elevators and stairs never confirm** (they stay "?"). Likely causes, not yet verified with logging:
   - **Too few frames analyzed:** the steadiness gate, plus slow high-detail, medium-reasoning responses.
   - **Repeat sightings don't merge:** when the raycast misses, `locate` falls back to a point 3 m along the ray.
   - **`StairsCheck` often can't decide:** raycasts miss when tracking is poor, and an undecided check then needs 4 sightings.
3. **Resource pressure.** The device logs show:
   - `World tracking performance is being affected by resource constraints`
   - `[reportTrackingState] Too many bad tracking reports. Ending RoomCaptureSession...`
   - `The delegate of ARSession is retaining 11 ARFrames`
   - `[CAMetalLayer nextDrawable] returning nil because allocation failed`
   - `Gesture: System gesture gate timed out` (the main thread is blocked)

   Likely causes:
   - **Too many RealityKit views alive at once.** The 3D model `ARView` in the home screen's `MapPanel` stays alive under the scan and navigate full-screen covers. Repeated `Registering library … already exists in shader manager` lines point to many RealityKit renderers.
   - **Captured pixel buffers held across async encoding.** `AccessibilityDetector.analyze` passes `frame.capturedImage` into a detached `CIContext` JPEG encode at 1536 px, which competes with ARKit for the GPU. Up to 3 requests can be in flight.
   - **Raycast grids on the main thread for every detection:** 7×7 for slope, 3×13 for stairs.
   - **Navigation does heavy AR work:** it runs scene reconstruction mesh, occlusion, plane detection and scene depth at the same time.
   - **Main-thread loading:** `NavigationController.init` unarchives the `ARWorldMap` and builds three routing grids on the main thread. `MapStore.save` archives the world map on the main thread.
4. **RoomPlan can end a section on its own,** for example when tracking goes bad. `ScanController.sectionProcessed` ignores results unless the phase is `.processing`, so that room is dropped and the UI stays in scanning with a stopped session.
5. **Harmless system noise you can ignore:**
   - CoreMotion plist permission errors
   - `FigCaptureSourceRemote` asserts
   - `DREIsRunningInDeviceRecoveryEnvironment`
   - `VideoLightSpillGenerator`
   - `Attempting to enable an already-enabled session` (RoomPlan restarting the shared session between sections)
   - `ForceClearSceneUnderstandingMeshShadowSingleChannel`
   - `EnvironmentResource with no skybox texture` (the 3D view's default lighting)
6. **Untested on a device:** relocalization reliability, the OpenAI request shape, pin placement accuracy, obstacle rerouting, door snapping. Also, chair backs and headboards in the plan and 3D model sit on an assumed side, because RoomPlan doesn't report which way furniture faces.
