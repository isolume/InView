# InView

InView opens directly to the Floor 2 map of Student Center East at Georgia State University, with search, place details and directions in one native bottom sheet. Expanded walkthrough models are the primary visuals for Floors 2 and 3. Floor 1 explicitly shows that no map is available.

The two floor models share an approximate fit to the supplied Floor 2 scan's elevator landmarks, at about 1.24672 scale. They include estimated areas beyond the partial LiDAR coverage; **Building details** explains those limits. Generated landmarks can be searched and opened, with directions still unavailable. **Floor scan** appears only when that floor has a matching measured map, and route start selection and previews automatically show it. Generated landmarks never enter the routing map. **Map appearance → Adjust placement** provides shared local controls for the models.

Signed-in users can submit floor maps for authorized spaces through the account menu. Admins review original submissions, edit destination labels, types, staff assistance and pin positions, request changes and publish immutable map versions in the web workspace. The app loads published maps from the configured service. See [the product app guide](docs/product-app.md) for setup, current coverage and verification limits. Native visual checks passed for both floor models, place details, scan route previews and clearing routes when changing floors.

Volunteers scan a floor with a LiDAR iPhone. A vision model (OpenAI by default, Gemini optional) spots and names the elevators, ramps and stairs, and LiDAR checks each find and measures ramp slopes. The app produces a floor plan, an orbitable 3D model and an accessibility report.

When a floor has compatible localization data, **View in AR** recognizes the saved space and offers AR arrows and spoken, captioned directions. Shared JSON maps, including the supplied Floor 2 scan, support browsing and manually chosen route previews but have no live positioning. Routes exclude stairs, insufficient clearance and ramps whose required slope measurements are missing or too steep.

RoomPlan builds and saves maps on the phone. One scan can cover connected rooms, with confirmed doorway crossings handled automatically and Apple's native structure builder assembling the result. Navigation uses ElevenLabs when configured, with a system-voice fallback. Photon messaging remains separate team work. Team plans: [larp.md](larp.md) and [photon.md](photon.md).

## Setup

Requires Xcode 26+, iOS 26 (the UI uses Liquid Glass), an iPhone with LiDAR (Pro / Pro Max), and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

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
- `INVIEW_BACKEND_URL` (optional): the server used by **Find places** during review. Maps are built on-device with this blank; set or clear the address in **Scanning** settings. Write URLs as `http:/$()/host:3000` in xcconfig.
- `VISION_PROVIDER = gemini` plus `GEMINI_API_KEY` switches detection to Gemini. Nothing else changes.
- `GEMINI_API_KEY` also turns on **Ask InView**. Tap the microphone in the search bar, or type a question that matches no place. Gemini answers using only the places InView has mapped, with ElevenLabs reading the answer aloud. A room that isn't mapped, such as Room 204, gets that answer and a nearby place that might help. **Show on map** opens the place it names. Without the key, the microphone is hidden. Speech recognition runs on Apple's recognizer and asks for microphone and speech permission on first use.
- Optional: `OPENAI_MODEL` (default `gpt-6.1-sol`), `OPENAI_REASONING_EFFORT` (default `low`; one request is in flight at a time, so latency directly limits how many frames get checked), `GEMINI_MODEL` (default `gemini-3.8-flash`).
- `ELEVENLABS_API_KEY` (optional): spoken turn-by-turn prompts use ElevenLabs when set, and the system voice otherwise. Optional: `ELEVENLABS_VOICE_ID` (default the stock "Rachel" voice) and `ELEVENLABS_MODEL` (default `eleven_turbo_v2_5`, chosen for low latency). Each line is synthesized live and given 2.5 s to return audio; a missing key, a slow network, or any error falls back to the system voice. Prompts play in order; urgent prompts cancel older speech. Synthesized lines are cached in memory, since routes repeat phrases like "Turn right now."

Re-run `xcodegen` after adding or removing files. The scheme turns off Metal API Validation, because RealityKit's own shaders trip it in debug runs.

Building the photoreal splat layer needs Apple's Metal Toolchain (MetalSplatter compiles `.metal` shaders):

```sh
xcodebuild -downloadComponent MetalToolchain
```

Build without a device, and run the core tests:

```sh
xcodebuild -project InView.xcodeproj -scheme InView -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
cd Packages/AccessCore && swift test
```

The repo uses jj with small conventional commits.

## Maps and scanning

Choose a floor, scan the space, then tap **Finish** to review and save the map.
New scans use RoomPlan and finish on the phone. During review, **Find places**
can send selected scan evidence to an optional processing server; every suggestion
requires an individual Keep or Drop. **Scanning → Saved scans**
opens saved models and exports original captures. Earlier stream captures remain
available for local evidence viewing and export; they are not deleted or uploaded.

The Rust backend now also provides accounts, floor-map submissions, admin review
and published maps. Capture still runs on the phone; contribution uploads the
derived floor map, not raw camera or LiDAR archives. Processing uses a separate
credential from account sessions. Generated graphs remain drafts until an
administrator reviews and publishes a snapshot for public directions.
**Scanning → Detailed scan** optionally records bounded surface detail and photo
colors; **Map appearance → Scan detail** displays it alongside the structural map.
It is off by default pending long-scan device checks. Streaming and reconstruction
protocols are described in [backend/SCANS.md](backend/SCANS.md).

To run the server for Simulator on the Mac:

```sh
cargo run --locked --manifest-path backend/Cargo.toml
```

Enter `http://127.0.0.1:3000` in **Scanning → Find places**. The default loopback
bind allows development without a processing token.

To run the server on the Mac for a real phone on the same Wi-Fi:

```sh
backend/run-local.sh
```

It binds every interface with the token from `Config/Secrets.xcconfig`
(`INVIEW_BACKEND_TOKEN`) and prints the address to put in `INVIEW_LOCAL_BACKEND_URL`
there. Rebuild once; the app then carries both servers. `INVIEW_USE_LOCAL_BACKEND = YES`
makes the Mac the default, and **Scanning → Use the Mac server** switches either way
on the phone without a rebuild. Tokens travel over plain HTTP only to private-network
addresses (10/8, 172.16/12, 192.168/16, `.local`); any other server needs HTTPS, as the
hosted deployment provides. The processing token is stored in the phone's Keychain,
separately from account sessions.

The executable persists original scans, analyses and graphs in `INVIEW_SCAN_DIR`
(default `data/scans`), streams in `INVIEW_STREAM_DIR` (default `data/streams`),
and account/submission data in `INVIEW_PRODUCT_DIR` (default `data/product`).
Building reference-frame endpoints also require PostgreSQL. See
[backend setup](backend/README.md) and [Vultr deployment](backend/infra/README.md)
for configuration.

The app opens onto Student Center East's Floor 2 model in 3D; Floor 3 has its own
model, while Floor 1 has no bundled map. Generated landmarks support browsing;
measured elevators, ramps and destinations support route previews on their actual
floor scan. A sheet at the bottom supports search and place details.
**Contribute a scan**, account access, submissions, saved local
maps and settings live in the profile menu. The camera turns on when a user starts
a scan or enters supported AR guidance. Drag to move the map,
pinch to zoom, twist to rotate and drag two fingers to tilt. A map shared from another
phone can be explored and used for a manually chosen route preview. Live guidance
needs the matching AR map saved with the scan.

**Try the navigation demo** works without a scan, including in
Simulator. It previews a route from reception through a hallway to a meeting room,
then moves the position marker along that route when **Start demo** is pressed.
It uses the real route planner and never changes the saved map. AR navigation
needs a saved scan and camera tracking on an iPhone.

### Indoor and outdoor renderer

Mapbox supplies the existing surrounding-map renderer and building placement
editor. The Student Center experience currently uses the indoor renderer, because
the supplied scan has no geographic placement. The geographic components remain
available for later integration with a verified building outline. Geographic
placement is separate from the generated model's visual alignment to the scan.

Address search uses Mapbox permanent geocoding because the chosen position is
saved with the scan. Mapbox requires an account eligible for permanent geocoding;
manual placement and location positioning also work without address search.

Exterior and indoor geometry share one native map renderer. The cutaway follows
individual measured room floors, retaining unmapped wings and gaps between rooms.
The remaining exterior is cut down to the selected level so it cannot hide
the indoor route; neighboring buildings keep their normal appearance. Replacement
requires a usable building outline. When one cannot be obtained, the original
exterior stays intact and the map reports that the cutaway is unavailable. This
prototype uses measured RoomPlan and ARKit floor outlines, not surveyed room
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

Before scanning, choose the building and starting floor. Relative elevation changes
pause capture during travel and suggest a floor once the phone reaches a stable
landing. Confirm or correct the floor in **New floor detected**, or use the floor
button to change it manually. Switching saves the previous floor and starts a
fresh scan on the next one. Each floor keeps its own map, reference photo,
localization data and matching capture; the saved-floor menu in the map sheet chooses
which floor to view and navigate.

Scanning keeps one shared AR coordinate system while RoomPlan captures connected
rooms. A stable door or opening, reliable tracking, and sustained movement through
the measured passage trigger an automatic room handoff. Room size, distance
walked, and elapsed time never trigger a handoff, so a large room is not split
by the former 7 m or two-minute limits. RoomPlan, heat, storage, or tracking limits
can still pause capture explicitly. See [continuous scanning](docs/continuous-scanning.md)
for the flow, retained originals, and device checks.

Review and navigation show a separate finished map: measured floor outlines,
clean wall cutaways, catalog furniture, and named places. Framing follows the
actual floor polygons and visible geometry; near walls retain a 50 cm cutaway in
3D. Gaps and unmapped areas stay open. Preparation runs off the UI thread and
resets when the floor changes. This presentation keeps the capture's coordinates
and leaves routing coverage, obstacles, and saved scan evidence unchanged.
Earlier raw depth meshes receive a supported floor/wall display without becoming
assumed navigation coverage.

At **Finish**, completed rooms are assembled by Apple's `StructureBuilder` before
map and scene construction. Discarded live measurements stay in the original
archive rather than being reinserted into the finished room geometry. A failed
assembly preserves the originals and leaves the previously saved map selected.
**Review points** lets a volunteer name destinations anywhere on the map;
navigation offers those places alongside elevators and ramps.

Scanning supports separate floors within a building. Navigation still routes
within the selected floor. Joining independently captured areas, connecting
floors through elevators, and maintaining tracking across a large building
require additional work and device verification. Automatic floor suggestions
and scan recovery after stairs or elevator travel still need a physical-device
check; sensor estimates do not determine a building's actual floor numbering.

Each RoomPlan room's original capture is archived before `RoomBuilder` processes
it. Completed rooms, the assembled structure, a bounded raw depth snapshot, and
the derived capture/scene remain under `Documents/Captures/<scan UUID>/` for
export from **Scanning → Saved scans**. With **Detailed scan** enabled, a bounded
set of posed camera photos is saved locally for splat training. Existing stream
archives retain their original camera/depth observations.
When configured, accessibility detection still sends selected camera frames to
the chosen vision provider; outdoor maps use Mapbox.

## Demo checklist

1. **Start the scan at the demo table.** Choose the building and current floor, then hold still for a second, facing the way the rider will start. That spot is the map's origin, and the app saves a photo of it.
2. **Map a space.** Slowly pan around the table area first, then walk to the elevator and the ramp. Pause on each one for a couple of seconds; frames are only analyzed while the camera is steady. Scan the whole room before moving through a doorway. A confirmed door or opening crossing automatically saves that room and continues with the same coordinates.
   - Finds appear as small colored tags as they're spotted: dashed with a "?" until confirmed.
   - **Elevator / Ramp / Stairs** mark whatever is under the crosshair. For a ramp, aim at its middle so its slope gets measured. For stairs, aim at the bottom step.
   - A large room keeps scanning regardless of its span or the time spent inside it. Walking past a doorway, looking through it, or briefly stepping across and back should not trigger a room handoff.
3. **Finish**. If saving the AR map fails, move around a little and tap **Try again**.
   - If RoomPlan or the device stops capture, completed rooms are kept and the app shows a pause. Improve tracking or let the phone cool down, then use **Continue scanning**; **Finish** processes completed rooms. This does not promise unlimited room size.
4. Review:
   - Decide on anything under **Unconfirmed – keep?**: tap the photo, then **Keep** or **Drop**.
   - Check each find's photo.
   - Rename points so they're easy to say.
   - Swipe away false stairs.
   - Turn on **Needs staff** for anything someone has to operate.
   - Flip the map between Plan and 3D, and open the full report.
   - **Save**.
5. **Navigate.** Stand near the table and look around until the app recognizes the space. If it hasn't after 15 s, stand on the scan start spot, face the way the photo does, and tap **Try again**. Routing stays unavailable until the app recognizes the saved space. Then:
   - Tap **Take me to the nearest accessible point**.
   - Put a chair in the path: it gets a red marker, and the route and voice go around it.

Relocalization works best when the lighting matches the scan and the area has texture: posters, furniture, signage. Rescan close to demo time if the room has changed a lot.

## Photoreal splat

**Detailed scan** also saves posed camera photos for training a Gaussian splat, the
photoreal look of Apple Maps. The splat is only a visual layer: routes are still
planned on the measured map. Its camera poses are ARKit's, so a trained splat lands
in the map's own coordinates and the route lines up with it. Don't pass `--center`
to OpenSplat: the default keeps ARKit coordinates.

While scanning, `SplatCapture` saves a photo whenever the phone has moved 12 cm or
turned 9° (up to 300, at three-quarter resolution). When the scan is saved, it writes
nerfstudio's `transforms.json` and a LiDAR point cloud (`sparse_pc.ply`) to start
training from. They are in `Documents/Captures/<scan id>/splat/`, which shows in the
Files app and in Finder (iPhone → Files → InView). To train on a Mac with
[OpenSplat](https://github.com/pierotofy/OpenSplat):

```sh
opensplat path/to/splat -n 2000 -o venue.ply
```

The existing splat renderer can load files in either of these locations; its
import controls are not exposed in the new Student Center map experience yet:

- `Documents/venue-splat.{ply,splat,spz}`.
- Copy it into that scan's `splat` folder via Files or Finder. The newest splat there
  (other than `sparse_pc.ply`) is what the map loads.

`SplatLayer` draws it under the route and pins with [MetalSplatter](https://github.com/scier/MetalSplatter).
The renderer uses a matching perspective camera; ceilings above the cutaway
height are left out so the floor stays visible from above.

## How it works

### Scanning pipeline

1. RoomPlan scans floors, walls, doors, openings, windows, furniture and stairs in a shared `ARSession`. `RoomTransitionDetector` requires stable portal measurements, normal tracking, a crossing inside the passage, and sustained clearance on the other side before a room handoff; there is no size, distance, or time rollover. The session delegate archives each `CapturedRoomData` before a background `RoomBuilder` task, with built-in preview processing disabled. At Finish, `StructureBuilder` assembles multiple completed rooms; one room uses its native result directly. Finite geometry and the shared coordinate envelope are checked before publishing. `RoomMemory` and bounded depth remain original evidence, not recovered walls or furniture in the canonical structure. Confirmed ARKit floor measurements can supply exact uncovered floor regions.
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
   - Each room's floor becomes a `.floor` footprint with its measured polygon outline; windows become `.window` footprints. Floor unions preserve concave gaps in the plan, 3D scene, and routing grid. New scans require measured floor coverage; a distant pin does not create walkable space.
   - It adds camera-spotted stairs that don't overlap RoomPlan's.
   - It snaps elevator pins to the floor in front of the nearest RoomPlan door or opening within 1.5 m (`DoorSnap`).
   - It records each piece of furniture's type and measured placement. `LocalSceneBuilder` uses the existing bundled furniture catalog for the 3D view, with neutral measured shapes for unsupported categories.

### Where things live

| Piece | Where |
| --- | --- |
| RoomPlan rooms → native structure → footprints and local scene | `InView/Scan/ScanController.swift`, `ScanExporter.swift`, `MapBuilder.swift` |
| Confirmed door/opening crossings without time or distance rollover | `Packages/AccessCore/.../RoomTransitionDetector.swift` |
| Vision detection (OpenAI or Gemini behind `VisionDetector`), placement, LiDAR checks, confirmation, evidence photos | `InView/Detection/` |
| Find tags over the scanning camera (10 Hz) | `InView/Scan/DetectionOverlay.swift` |
| Stairs and ramp geometry checks, door snapping | `Packages/AccessCore/.../StairsCheck.swift`, `SurfaceFit.swift`, `DoorSnap.swift` |
| Floor plan drawing (`MapPreviewView`, `PlanInk` palette), 3D cutaway model (`VenueModelBuilder`, non-AR `ARView` with orbit camera and generated studio lighting) | `InView/Map/` |
| The app's one screen: map, sheet, AR, places | `InView/App/MapScreen.swift`, `InView/Map/MapPlace.swift` |
| 3D floor straight from a saved map (rooms set on the map's floor) | `Packages/AccessCore/.../VenueScene.swift` |
| 3D room map: SceneKit cutaway, Maps-style gestures, place pins with label collision | `InView/Map/RoomMapCanvas.swift` |
| Posed photos for Gaussian splat training | `InView/Scan/SplatCapture.swift` |
| Photoreal splat on the 3D map | `InView/Map/SplatLayer.swift`, `InView/Support/SplatStore.swift` |
| ARWorldMap save and relocalization | `InView/Scan/ScanController.swift`, `InView/Navigate/NavigationController.swift` |
| Wheelchair routing: clearance grid, ADA door widths, A*, obstacles, steep-ramp fallback | `Packages/AccessCore/.../OccupancyGrid.swift`, `RoutePlanner.swift` |
| Floor polygons: area, ear-clipping triangulation | `Packages/AccessCore/.../Polygon.swift` |
| LiDAR obstacle detection while navigating (scene depth, every 1 s) | `InView/Navigate/ObstacleTracker.swift`, `Packages/AccessCore/.../ObstacleFinder.swift` |
| Turn-by-turn narration (ElevenLabs with system-voice fallback, captions) | `InView/Voice/`, `Packages/AccessCore/.../Maneuver.swift` |
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

The core logic is unit-tested, including room-transition confirmation, local scene processing, retained optional-server clients, floor polygons, cutaway boundaries and scan resource limits. The new RoomPlan handoff and native structure assembly need physical LiDAR validation, especially a large room followed by adjoining rooms. Earlier scan performance and manual section completion checks on an iPhone 15 Pro Max do not establish the new flow's quality. See [continuous scanning](docs/continuous-scanning.md) for current checks.

1. **Outline boxes replaced by tags.** Scanning shows one small capsule tag per find (`DetectionOverlay`, 10 Hz), and navigation marks stairs with a red "Stairs" billboard over a floor dot (`StairsMarker`). Point markers and chevrons use the kind's color.
2. **Finds that never confirmed.** Fixed by placing finds only where a raycast hits (no more 3 m guesses), letting one high-confidence sighting count once it's on a surface (and LiDAR-checked for ramps and stairs), and sending the rest to review as **Unconfirmed – keep?**. The detector logs every frame, placement, LiDAR verdict and merge, plus a summary when each section ends; on the device run

   ```sh
   log stream --predicate 'subsystem == "<bundle id>" AND category == "detection"' --level info
   ```

   or filter Console.app on the `detection` category. The summary line reports ticks vs steady ticks, frames sent/analyzed/failed/dropped while busy, mean latency, raycast hits/misses, unplaced detections, stairs verdicts and slope measurements, which is enough to see which of the three suspected causes dominates. If latency is still the bottleneck, `OPENAI_REASONING_EFFORT = none` is the next step.
3. **Resource pressure.** The home screen's 3D model `ARView` is taken down while the scan or navigate cover is up, so one RealityKit/AR view exists at a time. Camera frames are copied out of ARKit before any async work and encoded on the CPU at 1024 px, one request in flight. Raycasts per detection went from 88 to 34. Navigation no longer runs scene reconstruction or occlusion (scene depth stays, for obstacles) and checks obstacles once a second. The world map is unarchived, and the routing grids built, off the main thread behind a "Loading map…" state; saving archives it off the main thread too.
4. **RoomPlan ending a room on its own** processes the partial result and shows an explicit pause with **Continue scanning** / **Finish**. If room processing fails, its original input and previous completed rooms remain available. A critically hot phone pauses until it cools. The app never silently starts another room because of size or time.
5. **Keeping adjoining rooms intact.** Confirmed door/opening crossings finalize rooms, and Apple's `StructureBuilder` supplies the canonical multi-room geometry. The former 7 m/two-minute rollover and reinsertion of discarded live room components are removed. Native assembly failures preserve original captures instead of publishing a concatenated fallback. This still needs a physical multi-room scan.
6. **The plan and 3D model looked empty.** Both were redrawn: see `MapPreviewView` and `VenueModelBuilder`. Floors and windows only appear in maps scanned after this change; older saved maps draw without them.
7. **Growing scans.** Capture no longer copies every raw mesh anchor repeatedly. RoomPlan supplies map geometry, while optional depth keyframes use a bounded background worker. Live tags query nearby finds and project at most 16; the header shows counts rather than an ever-growing list. RoomPlan's miniature model is disabled, and its camera view is released before map construction. Native archives are saved once, separate from the compact navigation capture; local processing has no upload-size limit. Accessibility reports reuse entrance searches across destinations. See [scan performance measurements](docs/scan-performance.md).
8. **Harmless system noise you can ignore:**
   - CoreMotion plist permission errors
   - `FigCaptureSourceRemote` asserts
   - `DREIsRunningInDeviceRecoveryEnvironment`
   - `VideoLightSpillGenerator`
   - `Attempting to enable an already-enabled session` (RoomPlan restarting the shared session between sections)
   - `ForceClearSceneUnderstandingMeshShadowSingleChannel`
   - `EnvironmentResource with no skybox texture` (the 3D view's default lighting)
9. **Still to verify on a device:** large-room capture without arbitrary splits, doorway handoffs and revisits, native structure alignment, floor changes, interruptions/resume, and finished-map framing. RoomPlan's `polygonCorners` frame (assumed local to the floor surface, as `dimensions` are), relocalization reliability, the OpenAI request shape, pin placement, obstacle rerouting, door snapping, lighting, and CPU image encoding also need device checks. Furniture facing remains an estimate where RoomPlan does not report a front side. Earlier manual section → Finish checks do not validate this integration.
