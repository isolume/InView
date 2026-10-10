# InView: team plan

> **How this file works:** each teammate adds one section using the template at the bottom: your part, what you researched, what you want to build, what you need from others, and your open questions. Add your section **below the last one**, and run `git pull` before you push.

## InView in one paragraph

GPS stops at the front door. **InView** scans the inside of a building with a LiDAR iPhone and turns each scan into a **3D, accessibility-aware map** that anyone can explore and walk through.

The iOS app lets you **orbit** a 3D model of the room and **preview** a route as a first-person walk-through. Then you **navigate** for real with **AR arrows on the floor**, a **2D mini-map**, and voice directions.

The map knows where stairs and narrow doors are. A user who needs a step-free route gets a route that excludes stairs and uses suitable elevators or ramps, including trips between floors. Every new scan adds to a shared map.

Target: **COX Social Good** (main track), plus side prizes: ElevenLabs, Gemini, Tiger Data, and possibly Auth0, Mercedes CV, and Vultr.

**Prize idea under evaluation:** Photon / iMessage, if we can identify an integration that meaningfully improves InView. No implementation has been selected yet.

## Decisions so far

| # | Decision |
|---|----------|
| D1 | **LiDAR only** (Apple RoomPlan) for now. The camera-only path is researched but postponed |
| D2 | **iOS app only** (SwiftUI + RealityKit). No web app |
| D3 | **3D room model you can orbit**: the main "explore" view |
| D4 | **AR arrows** on the floor while navigating |
| D5 | **2D mini-map** during navigation |
| D6 | Visual bar: **Apple Maps-style photoreal 3D**, a room you can fly around and walk through |
| D7 | Faizan owns **front end + front-end design + map creation** |
| D8 | **AR guidance aligns with the scanned point cloud**: route geometry, scan geometry, and localization must agree on coordinates |
| D9 | **Step-free requirements are mandatory**: exclude incompatible connections before routing; report when no verified route exists |
| D10 | **Navigate across floors**: include the full trip and identify the elevator or other connector and destination floor |

---

## Faizan: front end, design, and map creation

### My part
I own **map creation and the iOS front end**:

- The **map creation pipeline**: a RoomPlan scan becomes a walkable area, a navigation graph, and accessibility tags.
- The **iOS front end**: all screens, 3D and AR rendering, the mini-map, and the overall design.

The navigation teammate uses that map to select routes, manage localization and floor changes, and produce shared instructions for the front end and voice.

### What I researched

**1. LiDAR vs. a plain camera**
- **LiDAR (RoomPlan)** gives measured walls, doors with real widths, furniture, and stairs in seconds. This is the most reliable option and what we're building.
- **Camera only is possible.** I read **SING3R-SLAM** (TU Munich + Google, [arXiv 2511.17207](https://arxiv.org/abs/2511.17207), 2026), which rebuilds a room from plain RGB video:
  - about 5 cm camera tracking error and about 4.5 cm reconstruction accuracy on benchmarks
  - a compact 7 MB Gaussian map
  - **but** it needs an RTX 4090, takes about 20+ minutes per room, and doesn't confirm that its output is in real meters
- **Key insight:** ARKit on *any* iPhone tracks position in real meters, because it combines the camera with the motion sensors. So a camera-only version could later lock a reconstruction like that to real meters. That's our "works on any phone" future-work story.

**2. Gaussian splatting**
- A splat represents a scene as millions of small, colored 3D blobs fitted to photos.
- It looks **photoreal** but has **no meaning**: it doesn't know what a door or a floor is. So it's a **visual layer**, never the thing we route on.
- If we train it with the scan's own ARKit camera poses, it lands in **the same coordinates** as our map, and routes line up automatically.

**3. Frameworks**
- **iOS:** RoomPlan (scanning) and RealityKit (3D + AR; Apple has soft-deprecated SceneKit).
- **iOS:** ARKit `ARWorldMap` (lets the phone recognize the room again).
- **iOS:** SwiftUI `Canvas` (mini-map).
- **Map processing (Python):** Shapely (2D floor geometry), NetworkX (graph processing + Dijkstra for the routing MVP), scikit-image (centerlines), Open3D (mesh raycasting).
- **Splats (stretch):** OpenSplat on a Mac or gsplat on a Vultr GPU for training, and a Metal splat renderer (e.g. MetalSplatter) to show it on device.

### What I want to build: the app

**Four modes:**

| Mode | What you see |
|------|--------------|
| **Scan** | RoomPlan scanning UI with live wall, door, and furniture outlines, plus our questions ("Is this an elevator?") |
| **Explore** | The room as a 3D model you orbit, pinch, and pan. Tap a place → "Go here". The route shows as a glowing ribbon on the floor |
| **Walk-through** | First-person fly-through of the route before you go, at 1.6 m eye height (**1.2 m in the wheelchair profile**) |
| **Navigate** | Live camera with **AR arrows** on the floor, a **2D mini-map** in the corner, a next-step card, and voice |

**The 3D map is built in layers**, all sharing the scanned region's coordinate system. Separately scanned regions or floors can have their own coordinates, with explicit map identifiers and alignment when entering each region:

1. **Room shell:** RoomPlan's clean model (walls, doors, furniture). *MVP*
2. **Navigation overlay:** route ribbon, destination pins, sign labels. Stairs are shown in red **with an icon**, and narrow doors in amber. *MVP*
3. **LiDAR mesh:** the raw scanned surface, for realistic detail. *Nice to have*
4. **Photoreal Gaussian splat:** the closest we'll get to the Apple Maps feel. *Stretch*

**Design principles:**
- Calm and clean, Apple Maps-style: one accent color for the route, smooth transitions between modes.
- Accessibility is part of the design, not a settings page:
  - VoiceOver labels everywhere
  - Dynamic Type
  - a haptic at every turn
  - never rely on color alone
- In Navigate, the next instruction and its distance are the biggest thing on screen.

### How a scan becomes a map

```
RoomPlan + ARKit scan ─► floor outline (walls) ─► minus furniture ─► walkable area
                     ─► reviewed walked paths + verified shortcuts ─► graph with 3D paths
                     ─► doors, stairs, ramps, signs, elevator answers ─► route properties
                     ─► geometry + ARWorldMap + coordinate metadata ─► scan bundle
                     ─► graph.json + scan bundle ─► app + routing backend + Tiger Data
```

- **Clearance check from geometry:** shrink the walkable area by half the selected route width to flag narrow passages for review. As baseline references, the ADA standards generally specify **36 in** clear walking width and **32 in** clear door openings, with additional conditions and exceptions. Width alone does not establish wheelchair accessibility; slopes, surfaces, thresholds, and maneuvering space also matter. Store measured properties and keep unverified ones unknown. ([U.S. Access Board standards, §§403–404](https://www.access-board.gov/ada/))
- **Things RoomPlan can't see**, like elevators, ramps, and automatic doors: the person scanning answers a quick question.
- **Save a scan bundle for each mapped region:** point cloud or mesh, RoomPlan model, labeled floor plan, navigation graph, saved `ARWorldMap`, a reference view for localization, and coordinate metadata (`map_id`, `floor_id`, units, axes, origin, export transforms). Preserve the capture session's coordinates or record the exact transforms applied during export.
- **`graph.json`** remains the contract between map creation and navigation. The proposed expanded fields and route response are in the navigation section below; agree on them together in hour 1.
- **Manual path review is the MVP fallback:** place nodes and paths over the scan or labeled floor plan, then verify them in the venue. Automatic path extraction can later produce the same contract.

### What I need from the team

| From | What | Why |
|------|------|-----|
| Whoever has a **LiDAR iPhone** (12 Pro or later Pro model) | The device, or regular test scans | RoomPlan and AR **don't run in the Simulator**. This blocks everything |
| Routing + directions | Agree on the expanded graph and scan bundle in hour 1; return floor-specific 3D surface segments, connector transitions, and shared maneuvers | So the ribbon, arrows, mini-map, and voice all follow the same route |
| AI + voice | Sign text from keyframes (Gemini); voice for each instruction (ElevenLabs) | Sign labels on the map; spoken directions |
| Data | Tables for maps, floors, nodes, edges, connectors, and live positions with map/floor identifiers (Tiger Data) | Saving maps, multi-floor routes, find-a-friend |
| **Vedanta** | Answers to the open questions below | Locks the MVP screens and the design direction |

### My build order
1. RoomPlan + ARKit scan on a real device → USDZ/geometry export + scan bundle, including `ARWorldMap` and coordinate metadata. End the session and prove alignment when reopening navigation. *(The riskiest step, so it goes first.)*
2. Explore: load the room in RealityKit with orbit/pinch/pan controls.
3. Draw the graph + a hard-coded route as a ribbon on the floor.
4. Mini-map (SwiftUI `Canvas`) with a "you are here" dot.
5. Navigate: localize to the saved scan, then show AR arrows, mini-map, and next-step card; pause positional cues during alignment recovery and floor transitions.
6. Walk-through: animate the camera along the route.
7. Connect to the backend: real routes and voice.
8. Polish: transitions, haptics, VoiceOver, accessibility markers.
9. Stretch: photoreal splat layer, then joining several rooms into one floor.

**Fallback:** if saved-map localization is unreliable, align using a known printed image with a recorded position and orientation. A "tap where you are" action can support a manual map and text fallback, but it does not establish the orientation needed for accurate AR. Keep precise AR cues paused until alignment is recovered.

### Risks I see
- **No LiDAR iPhone:** we're blocked. Confirm today.
- **AR arrows drift:** keep the arrows close to the user (the next 3–5 m); pause position-dependent guidance and recover alignment using the saved map or a known image.
- **Splat too slow or too big on device:** it's a stretch layer; the clean RoomPlan model is the MVP look.
- **I'm carrying three jobs:** if we're short on people, the Python map pipeline is the first thing to hand off.

### Open questions (mostly for Vedanta)
1. Which screens are **must** vs. **stretch**:
   - scan
   - review and label
   - hand-edit the map
   - navigate
   - "find something"
   - find a friend
   - accessibility profile
   - sign-in (Auth0)
2. Who's the **primary user** we design for: blind or low-vision users, wheelchair users, anyone new to a building, or the person scanning?
3. Do we keep the name **InView**? What's the visual feel? Figma first or straight to code?

---

## Navigation: routing, localization, and guidance

Planning source: [InView Navigation Planning](chatgpt-conversation://6ac9d70f-5040-83e9-beb5-8a8e479a1b5d). The implementation below is the proposed hackathon approach to validate with the team and at the venue.

### My part

Navigation connects three pieces:

| Piece | Responsibility |
|-------|----------------|
| **Localization** | Find the phone's position and orientation relative to the saved scan |
| **Routing** | Choose connected, eligible passages for the complete trip across floors |
| **Guidance** | Place the AR path, track progress, and advance text, voice, and haptic instructions |

Faizan provides the scan, graph, and front-end rendering. Navigation provides route selection, alignment state, route progress, and maneuvers for those views.

### What I researched

- A point cloud describes geometry; the saved **`ARWorldMap`** supplies ARKit's mapping state for recognizing that space in a later session. Restore it through `initialWorldMap`, then wait for relocalization. ([Apple: saving and loading world data](https://developer.apple.com/documentation/arkit/saving-and-loading-world-data))
- A known printed image can provide position **and orientation** through `ARImageAnchor`. Record its pose during scanning and configure its physical dimensions accurately. A decoded QR identifier alone only identifies the checkpoint. ([Apple: image anchors](https://developer.apple.com/documentation/arkit/arimageanchor), [reference image size](https://developer.apple.com/documentation/arkit/arreferenceimage/physicalsize))
- A building graph can span multiple floors while each surface path retains real **3D coordinates** in its own scanned map. Reviewed corridor paths are enough for the first demo; automatic navmesh generation can follow later.
- **Step-free** and **wheelchair accessible** describe different properties. Track the user's specific requirements and measured route properties; unknown clearance or slope is not verified suitability.

### What I want to build

**1. A shared graph and route contract**

Keep the existing snake_case field style. This expands the earlier `id/x/y/z` and `from/to/length_m` contract:

| Record | Proposed fields |
|--------|-----------------|
| Node | `id, map_id, floor_id, x, y, z, kind, label, confidence`; kinds include paths, doors, signs, destinations, connector landings, and localization landmarks |
| Surface edge | `from, to, map_id, floor_id, kind, path_points, length_m, step_free, availability`, plus measured clearance/slope properties when known |
| Connector edge | `from, to, kind, connector_id, step_free, availability`; endpoints identify the boarding and exit landings and their maps/floors |
| Connector | `id, kind, served_floors`, and the landing node for each served floor |
| Route response | Ordered node IDs, **surface segments**, **transition segments**, and **maneuvers** |

`step_free` has three states: `true`, `false`, or `unknown`. `availability` is `available`, `closed`, or `unknown`; absent measurements remain unknown. These properties replace the single `accessible` flag as the basis for route eligibility.

- **Surface segments** carry `map_id`, `floor_id`, and ordered 3D `path_points` in meters, with ARKit's y-up axes. Corridor paths use the scanned floor elevation; ramps preserve changing heights along their length.
- **Transition segments** carry the connector ID, type, entry/exit nodes, and source/destination floors. An elevator ride has no ground polyline through the shaft.
- **Maneuvers** carry the action, route location, optional landmark, and readable/spoken instruction. The guidance controller calculates the current distance to that action.
- Join elevator landings by **connector identity and served floors**. Similar coordinates or nearby points do not prove a traversable connection. Review shortcuts and smoothing so they preserve walls and clearance.

**2. Route selection that preserves requirements**

Use individual requirements such as `requires_step_free`, optional `minimum_clear_width` and `maximum_slope`, plus presentation preferences such as spoken guidance.

1. Remove incompatible connections before searching: stairs and escalators for step-free users, closed elevators, and passages or ramps that fail selected requirements. Unknown required properties cannot qualify as verified suitability.
2. Run **Dijkstra over the eligible graph for the full trip**, including every floor transition. Choosing the nearest elevator first can miss a better route or an elevator that serves the destination floor.
3. Use one nonnegative cost unit. For the MVP, estimated seconds: surface length divided by configured movement speed; elevator boarding/wait allowance plus ride estimate. Represent a ride between its boarding and destination landings and charge the wait allowance once.
4. If no eligible route remains, show **"No verified step-free route is currently available to Room 204."** Preserve requirements when rerouting after a closure.

**3. Alignment between the live camera and saved scan**

Start navigation by selecting the building and starting region, showing a recognizable reference view, and attempting saved-map relocalization. Track **camera tracking** and **registration to the saved map** separately: motion tracking alone does not prove that the phone is aligned to the building.

Prepare a distinctive printed image at the demo entrance and each elevator landing as an alignment fallback. Use its saved map pose and current session pose to calculate `sessionFromMap`. With `AFromB` meaning a transform from B coordinates into A:

```text
sessionFromMap = sessionFromImage × inverse(mapFromImage)
pointInSession = sessionFromMap × pointInMap
cameraInMap = inverse(sessionFromMap) × cameraInSession
```

Put the scan geometry and route under the **same map root** in RealityKit and apply that alignment to the root. Handle anchor updates and replace the alignment after recovery or a map change. A floor plan can rotate for display as long as its positions can be converted back into the scan's coordinates.

**4. Floor transitions and recovery**

| State | What the user sees and what advances the trip |
|-------|---------------------------------------------|
| Following a surface path | Upcoming ground arrows/ribbon, next maneuver, distance, and mini-map |
| Approaching the elevator | Ground path ends at the boarding position; identify the elevator |
| Waiting or riding | **"Take Elevator A to Floor 2."** Suspend building-relative progress assumptions inside the moving cabin |
| Exiting | Confirm the actual landing/floor and recover alignment to that floor's saved map or image |
| Continuing | Resume ground guidance only after both floor identity and map alignment are established |
| Positioning lost | Preserve the route, pause precise AR cues and position-dependent advancement, and show **"Look toward the elevator sign to restore positioning."** |

A button saying **"I'm on Floor 2"** confirms the stated floor but does not align the phone to its scan. If a checkpoint identifies Floor 3 instead, update the actual location and reroute from there. Ramps can remain continuous surface paths; stairs and other connectors need explicit transition handling appropriate to their geometry.

**5. One route for every guidance mode**

Convert the phone pose into map coordinates, associate it with the current route segment on the correct floor and connected passage, and estimate progress and distance to the next maneuver. Advance at the maneuver; reroute after sustained deviation or an explicit change such as a closed elevator, rather than every small tracking fluctuation.

Use the same maneuver for AR, the mini-map, large text, spoken directions, haptics, and **repeat instruction**. Give one action at a time and use recognizable landmarks, for example **"At reception, turn right toward Elevator A."** Show only the upcoming corridor or turn to limit visual clutter and cues appearing through walls, with a stronger cue at the next turn and a label on the relevant doorway or elevator. The point cloud can be shown during development to check that the scan and route align with the real space.

### What I need from the team

| From | What | Why |
|------|------|-----|
| Faizan / scanning | Scan bundle, labeled floor plans, reviewed 3D paths, coordinate transforms, and known-image poses | Route geometry and camera alignment must match the captured space |
| Venue / map review | Confirm elevator identities, served floors, ramp and doorway properties, and checkpoint locations | Verify the demo's routes and floor transitions |
| Front end | Shared alignment/progress states, floor transition UI, readable instructions, and repeat action | Keep positional cues paused until they are valid |
| AI + voice | Landmark labels and audio for the route's maneuvers | Speak the same directions shown on screen |
| Data | Store map/floor IDs, graph properties, connectors, and availability | Save and reload the complete building route model |

### My build order

**First complete deliverable:** open a fresh AR session, align to a saved corridor scan, follow a path around a corner, take the correct elevator, and resume correctly aligned guidance upstairs. Complete this physical journey before polishing the presentation.

1. **Prove alignment in a fresh session:** scan a corridor with a corner, save geometry and world map, end the session, reopen from a different position, and check several overlays against real locations. Also test the known-image fallback.
2. **Draw one reviewed AR path:** follow the floor around that corner to a doorway, verify wall clearance and turn placement, and advance progress while moving.
3. **Add route selection and filtering:** compare stairs and a verified step-free alternative; confirm stairs are excluded and that closing the only eligible connector returns no route.
4. **Complete a two-floor trip:** route to the correct elevator, show its destination floor, reacquire positioning at the exit, and continue to the destination. Test exiting on the wrong floor.
5. **Connect and polish every guidance mode:** after the complete journey works, add the ground ribbon, doorway labels, speech, haptics, and recovery messages. Keep AR, mini-map, text, speech, haptics, and repeat instruction on the same route; verify recovery pauses instruction advancement.
6. **Expand and polish:** improve automatic path extraction and map coverage after the short physical journey works end to end.

### Risks I see

- **Saved-map relocalization may fail at the venue:** prove it early on a real device and keep known-image alignment available.
- **Coordinates change during export:** preserve original coordinates or record every transform; separate floors must retain their map IDs.
- **Elevator travel breaks location assumptions:** reacquire floor identity and alignment after exiting before resuming AR.
- **Accessibility data is incomplete:** manually verify the demo route's relevant properties and keep unknown values explicit.
- **Automatic mapping takes too long:** reviewed paths support the same routing and AR interface for the MVP.

### Open questions

1. Which building, two floors, destination, and elevator can we scan and physically test for the demo? Can we place known images at the entrance and landings?
2. Which route properties can we verify, and what clearance/slope requirements will the initial profile support?
3. Which teammate owns localization and route progress alongside route selection, and where does the routing engine run?
4. Confirm the graph/route field types, shared state interface, and who updates connector availability before implementation.
5. Is there a strong Photon / iMessage integration that improves navigation or accessibility enough to justify targeting its prize category?

---

## <Name>: <your part>

### My part
### What I researched
### What I want to build
### What I need from the team
### My build order
### Risks I see
### Open questions
