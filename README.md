# InView

Volunteers scan a floor once with a LiDAR iPhone. A vision model (OpenAI by default, Gemini optional) spots and names the elevators, ramps and stairs, and LiDAR checks each find and measures ramp slopes. The app then produces a floor plan, an orbitable 3D model and an accessibility report.

A wheelchair user then opens InView, which recognizes the room from the saved AR map. They follow AR arrows and spoken, captioned directions along a step-free route to the nearest usable elevator or ramp. The route goes around stairs, obstacles LiDAR sees on the way, and ramps steeper than the ADA allows.

Scans are processed and saved on the phone by default. An optional Rust server can process scan geometry into the same 3D scene used by navigation. Photon messaging and ElevenLabs voice remain separate team work; navigation currently uses the system voice. Team plans: [larp.md](larp.md) and [photon.md](photon.md).

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
- `MAPBOX_ACCESS_TOKEN` (optional): a public token beginning with `pk.`, for surrounding maps and building placement. Indoor-only navigation works without it.
- `INVIEW_BACKEND_URL` (optional): a scan processing server. Leave blank for on-device processing; you can also set or clear it in the app’s scan processing settings. Write URLs as `http:/$()/host:3000` in xcconfig.
- `VISION_PROVIDER = gemini` plus `GEMINI_API_KEY` switches detection to Gemini. Nothing else changes.
- Optional: `OPENAI_MODEL` (default `gpt-6.1-sol`), `OPENAI_REASONING_EFFORT` (default `low`; one request is in flight at a time, so latency directly limits how many frames get checked), `GEMINI_MODEL` (default `gemini-3.8-flash`).
- `ELEVENLABS_API_KEY` (optional): spoken turn-by-turn prompts use ElevenLabs when set, and the system voice otherwise. Optional: `ELEVENLABS_VOICE_ID` (default the stock "Rachel" voice) and `ELEVENLABS_MODEL` (default `eleven_turbo_v2_5`, chosen for low latency). Each line is synthesized live and given 2.5 s to return audio; a missing key, a slow network, or any error falls straight back to the system voice so navigation prompts are never delayed or dropped. Synthesized lines are cached in memory, since routes repeat phrases like "Turn right now."

Re-run `xcodegen` after adding or removing files. The scheme turns off Metal API Validation, because RealityKit's own shaders trip it in debug runs.

Build without a device, and run the core tests:

```sh
xcodebuild -project InView.xcodeproj -scheme InView -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
cd Packages/AccessCore && swift test
```

The repo uses jj with small conventional commits.

## Optional scan processing server

With no address configured, finishing a scan creates the 3D map on the phone,
without uploading it to a processing server. Review points and unconfirmed finds,
then save the map for navigation. Server errors also offer **Use local map**.

To use the Rust processing service, start it on the Mac:

```sh
cargo run --manifest-path backend/Cargo.toml
```

Open the gear button in the app and enter the server address. For Simulator, use
`http://127.0.0.1:3000`. For an iPhone, use an address reachable from that device
and bind the service to that interface. For the same Wi-Fi network:

```sh
INVIEW_BIND="$(ipconfig getifaddr en0):3000" cargo run --manifest-path backend/Cargo.toml
```

Allow local network access when iOS asks. Clearing the address returns to local
processing. The backend is a development service without authentication or durable
storage. A processing failure preserves the original capture on the phone for a
retry. Saved navigation geometry can be opened without the processing server.

To reach the backend from a phone off your Mac's Wi-Fi (e.g. at a venue), host it
on a small Vultr instance instead: see [backend/infra](backend/infra) for the
Terraform config and setup steps.

**Try navigation demo** works without a scan or processing server, including in
Simulator. It previews a route from reception through a hallway to a meeting room,
then moves the position marker along that route when **Start demo** is pressed.
It uses the real route planner and never changes the saved map. AR navigation
needs a saved scan and camera tracking on an iPhone.

### Indoor and outdoor map

Mapbox supplies the surrounding map and the building placement editor. The native
**Map options** menu offers **Indoor only** and **Surroundings** within the same
navigation view. A placed building opens with its surroundings by default.
**Place building** lets you move and turn the scan outline into position, using
an address or **Current location** as a starting point. Indoor GPS still needs
manual alignment. Placement is saved on the phone without changing the scan,
AR tracking, or route coordinates.

Address search uses Mapbox permanent geocoding because the chosen position is
saved with the scan. Mapbox requires an account eligible for permanent geocoding;
manual placement and location positioning also work without address search.

Exterior and indoor geometry share one native map renderer. The cutaway follows
individual measured room floors, retaining unmapped wings and gaps between rooms.
The remaining exterior of the selected building is translucent so it cannot hide
the indoor route; neighboring buildings keep their normal appearance. Replacement
requires a usable building outline. When one cannot be obtained, the original
exterior stays intact and the map reports that the cutaway is unavailable. This
prototype uses RoomPlan's rectangular floor measurements, not surveyed room
boundaries. Controls and the navigation sheet are native SwiftUI, with subdued
map colors and simple indoor geometry.

Without a public token, **Preview interior** uses the same Mapbox SDK with a
labeled local example exterior, without downloading outdoor maps.

When the scene contains distinct floor elevations, **Choose floor** exposes the
selected level and hides higher levels. Changing the display floor does not move
the navigation session or put a route on another level; **Show route** returns to
its floor. The navigation demo adds a synthetic upper room to demonstrate a
partially mapped building. Its geographic placement is an example, not a scan of
the real building at that address.

Use **Next room** while scanning to capture connected rooms and hallways in the
same session, then **Finish** to process the combined scan. **Review points** lets
a volunteer name destinations anywhere on the map. Navigation offers those
places alongside elevators and ramps. Overlapping sections use each component's
latest pose in both routing geometry and the 3D view.

This first building prototype covers connected spaces on one floor. Joining
independently captured areas, connecting floors through elevators, and maintaining
tracking across a large building require additional work and device verification.
The floor selector is a display prototype; it does not add routing between stories.

Each capture is archived under Documents/Captures with native RoomPlan JSON,
its portable upload, and the local or server-derived scene. When configured,
vision detection sends selected camera frames to the chosen provider; outdoor
maps use Mapbox. See [backend/SCANS.md](backend/SCANS.md) for the scan format.

## Demo checklist

1. **Start the scan at the demo table.** Hold still for a second, facing the way the rider will start. That spot is the map's origin, and the app saves a photo of it.
2. **Map a space.** Slowly pan around the table area first, then walk to the elevator and the ramp. Pause on each one for a couple of seconds; frames are only analyzed while the camera is steady. Scan one room per section: when you go through a doorway the app offers **Add section**; take it, so RoomPlan keeps the room you just left exactly as scanned.
   - Finds appear as small colored tags as they're spotted: dashed with a "?" until confirmed.
   - **Elevator / Ramp / Stairs** mark whatever is under the crosshair. For a ramp, aim at its middle so its slope gets measured. For stairs, aim at the bottom step.
   - **Next room** splits a big area. Keep each section under about 5 minutes.
3. **Finish**. If saving the AR map fails, move around a little and tap **Try again**.
   - If the scanner stops a section by itself (it says **Scanning stopped**), what it scanned is kept. Move to a spot with more detail in view and tap **Continue scanning**, or **Finish**.
4. Review:
   - Decide on anything under **Unconfirmed – keep?**: tap the photo, then **Keep** or **Drop**.
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

1. RoomPlan scans floors, walls, doors, windows, furniture and stairs. It shares one `ARSession` across sections, so everything is in one coordinate space. RoomPlan models one room per section, and when a section runs on into another room its processed result re-fits to the new room and drops the first; so `ScanController` also records RoomPlan's live updates (`RoomMemory`), and `MapBuilder` puts back whatever the processed room left out, unless it overlaps something kept. A doorway-crossing check suggests starting a new section.
2. `AccessibilityDetector` watches camera motion. It sends a frame to the vision model only when the camera has been steady (≤ 25°/s and ≤ 0.35 m/s for 0.3 s), at most every 1.2 s, and only one request at a time; steady frames that come due while one is in flight are dropped. The frame's pixels are copied out of ARKit's buffer synchronously (`FrameEncoder.snapshot`), then scaled and encoded off the main thread on a CPU Core Image context: a 1024 px JPEG for the model (OpenAI high detail) and a 600 px one kept as the evidence photo. No `ARFrame` or camera buffer is held across the request.
3. Each find is placed in 3D by raycasting the model's point onto LiDAR surfaces. If that misses, a raycast against ARKit's extended floor planes is tried (accepted only ≥ 1 m below the phone and < 6 m out); if that misses too, the detection is dropped rather than guessed, because a guessed spot never merges with the next sighting. Placed finds are checked against geometry:
   - **Stairs** need confidence ≥ 0.8, and `StairsCheck` must see a 18–58° climb over a 2 × 9 raycast strip.
   - **Ramps** must measure 1.5–15° (`SurfaceFit`) over a 4 × 4 raycast grid.
   - Rejected claims are counted in the scanning status chip. The raycasts run on the main actor (ARSession's thread safety isn't documented), with a yield between detections.
4. Finds of the same kind merge when they're close: within 2 m for elevators, 2.5 m for ramps, 3 m for stairs. For stairs, the lowest point seen is kept as the bottom step.
5. A find is **confirmed** once it has enough sightings:
   - **Elevators:** 2 frames, or 1 frame at confidence ≥ 0.85.
   - **Ramps and stairs:** LiDAR agreeing at least once, plus either 2 frames or 1 frame at ≥ 0.85; or 4 frames if LiDAR never could tell.
   - **Hand marks:** count immediately.
6. Confirmed finds go straight onto the map. Unconfirmed ones show as dashed "?" tags while scanning, and review lists them under **Unconfirmed – keep?** with their photo, sighting count, confidence and whether LiDAR could check them; **Keep** adds one through the same `MapBuilder` path as a confirmed find. Each find keeps the photo it came from.
7. `MapBuilder` flattens everything into the saved map:
   - Each room's floor becomes a `.floor` footprint with RoomPlan's polygon outline; windows become `.window` footprints. Both are for drawing; the plan fills floors and the 3D model builds slabs from them (`Polygon.triangulate`).
   - It adds camera-spotted stairs that don't overlap RoomPlan's.
   - It snaps elevator pins to the floor in front of the nearest RoomPlan door or opening within 1.5 m (`DoorSnap`).
   - It records each piece of furniture's type and height, for the plan symbols and the 3D model.

### Where things live

| Piece | Where |
| --- | --- |
| RoomPlan scan → footprints (floors, walls, doors, windows, furniture by type, stairs), live-room recovery | `InView/Scan/MapBuilder.swift` |
| Vision detection (OpenAI or Gemini behind `VisionDetector`), placement, LiDAR checks, confirmation, evidence photos | `InView/Detection/` |
| Find tags over the scanning camera (10 Hz) | `InView/Scan/DetectionOverlay.swift` |
| Stairs and ramp geometry checks, door snapping | `Packages/AccessCore/.../StairsCheck.swift`, `SurfaceFit.swift`, `DoorSnap.swift` |
| Floor plan drawing (`MapPreviewView`, `PlanInk` palette), 3D cutaway model (`VenueModelBuilder`, non-AR `ARView` with orbit camera and generated studio lighting) | `InView/Map/` |
| ARWorldMap save and relocalization | `InView/Scan/ScanController.swift`, `InView/Navigate/NavigationController.swift` |
| Wheelchair routing: clearance grid, ADA door widths, A*, obstacles, steep-ramp fallback | `Packages/AccessCore/.../OccupancyGrid.swift`, `RoutePlanner.swift` |
| Floor polygons: area, ear-clipping triangulation | `Packages/AccessCore/.../Polygon.swift` |
| LiDAR obstacle detection while navigating (scene depth, every 1 s) | `InView/Navigate/ObstacleTracker.swift`, `Packages/AccessCore/.../ObstacleFinder.swift` |
| Turn-by-turn narration (system voice, captions) | `InView/Voice/`, `Packages/AccessCore/.../Maneuver.swift` |
| Accessibility report (score logic in core; UI with stats, door-width bars, slope gauges) | `Packages/AccessCore/.../AccessibilityReport.swift`, `InView/Report/` |
| AR chevrons, point labels, stairs tags, obstacle markers | `InView/Navigate/PathRenderer.swift` |
| Console logging (`detection`, `scan`, `navigation` categories) | `InView/Support/Log.swift` |

### Routing rules

- Routes keep 45 cm clearance from obstacles (90 cm passages). In tight spaces they fall back to 30 cm, then 15 cm, and the UI warns that the route is narrow.
- Doors under 81 cm (ADA 32") are treated as walls.
- While navigating, the route is recomputed after the rider moves 0.4 m, or at once when LiDAR spots a new obstacle; standing still costs no searches.
- Ramps steeper than 1:12 (4.8°) are used only when nothing else is reachable.
- Hooks for future status and messaging services:
  - `RouteConditions.unavailable` excludes points, e.g. elevators reported out of service.
  - `AccessPoint.requiresAssistance` marks staff-operated points for the Photon agent.
  - `VoiceGuide` is the single place where spoken lines are produced.

## Status and known issues (October 10, 2026)

The merged core logic is unit-tested (110 tests), including local scene processing, optional-server clients and floor display annotations. The app builds. It was tried briefly on an iPhone 17 Pro, which turned up the problems below; the fixes for them have **not** been run on a device yet.

1. **Outline boxes replaced by tags.** Scanning shows one small capsule tag per find (`DetectionOverlay`, 10 Hz), and navigation marks stairs with a red "Stairs" billboard over a floor dot (`StairsMarker`). Point markers and chevrons use the kind's color.
2. **Finds that never confirmed.** Fixed by placing finds only where a raycast hits (no more 3 m guesses), letting one high-confidence sighting count once it's on a surface (and LiDAR-checked for ramps and stairs), and sending the rest to review as **Unconfirmed – keep?**. The detector logs every frame, placement, LiDAR verdict and merge, plus a summary when each section ends; on the device run

   ```sh
   log stream --predicate 'subsystem == "<bundle id>" AND category == "detection"' --level info
   ```

   or filter Console.app on the `detection` category. The summary line reports ticks vs steady ticks, frames sent/analyzed/failed/dropped while busy, mean latency, raycast hits/misses, unplaced detections, stairs verdicts and slope measurements, which is enough to see which of the three suspected causes dominates. If latency is still the bottleneck, `OPENAI_REASONING_EFFORT = none` is the next step.
3. **Resource pressure.** The home screen's 3D model `ARView` is taken down while the scan or navigate cover is up, so one RealityKit/AR view exists at a time. Camera frames are copied out of ARKit before any async work and encoded on the CPU at 1024 px, one request in flight. Raycasts per detection went from 88 to 34. Navigation no longer runs scene reconstruction or occlusion (scene depth stays, for obstacles) and checks obstacles once a second. The world map is unarchived, and the routing grids built, off the main thread behind a "Loading map…" state; saving archives it off the main thread too.
4. **RoomPlan ending a section on its own** now keeps the room, re-runs the shared AR session and shows **Scanning stopped** with **Continue scanning** / **Finish**.
5. **A room scanned first was missing after walking on to the rest of the floor.** RoomPlan re-fits a section to the room the volunteer ends up in. Live updates are now remembered and the dropped surfaces and objects recovered (see "How it works"), and the app suggests a new section at each doorway. Recovery is deduplicated against the processed room with 0.3 m slack; if walls still double up on a device, raise `MapBuilder.recoveredSlack`.
6. **The plan and 3D model looked empty.** Both were redrawn: see `MapPreviewView` and `VenueModelBuilder`. Floors and windows only appear in maps scanned after this change; older saved maps draw without them.
7. **Harmless system noise you can ignore:**
   - CoreMotion plist permission errors
   - `FigCaptureSourceRemote` asserts
   - `DREIsRunningInDeviceRecoveryEnvironment`
   - `VideoLightSpillGenerator`
   - `Attempting to enable an already-enabled session` (RoomPlan restarting the shared session between sections)
   - `ForceClearSceneUnderstandingMeshShadowSingleChannel`
   - `EnvironmentResource with no skybox texture` (the 3D view's default lighting)
8. **Untested on a device:** everything in items 1–6 above, RoomPlan's `polygonCorners` frame (assumed local to the floor surface, as `dimensions` are), the generated `EnvironmentResource` lighting, plus relocalization reliability, the OpenAI request shape, pin placement accuracy, obstacle rerouting, door snapping, and whether `CIContext`'s software renderer is honored on iOS (if not, encoding silently uses the GPU again). Also, chair backs and headboards in the plan and 3D model sit on an assumed side, because RoomPlan doesn't report which way furniture faces.
