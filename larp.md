# InView: team plan

> **How this file works:** each teammate adds one section using the template at the bottom: your part, what you researched, what you want to build, what you need from others, and your open questions. Add your section **below the last one**, and run `git pull` before you push.

## InView in one paragraph

GPS stops at the front door. **InView** scans the inside of a building with a LiDAR iPhone and turns each scan into a **3D, accessibility-aware map** that anyone can explore and walk through.

The iOS app lets you **orbit** a 3D model of the room and **preview** a route as a first-person walk-through. Then you **navigate** for real with **AR arrows on the floor**, a **2D mini-map**, and voice directions.

The map knows where stairs and narrow doors are and prefers elevators for people who need them. Every new scan adds to a shared map.

Target: **COX Social Good** (main track), plus side prizes: ElevenLabs, Gemini, Tiger Data, and possibly Auth0, Mercedes CV, and Vultr.

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

---

## Faizan: front end, design, and map creation

### My part
I own everything from **the scan to the pixels on screen**:
- The **map creation pipeline**: a RoomPlan scan becomes a walkable area, a navigation graph, and accessibility tags.
- The **iOS front end**: all screens, 3D and AR rendering, the mini-map, and the overall design.

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
- **Map processing (Python):** Shapely (2D floor geometry), NetworkX (graph + A*), scikit-image (centerlines), Open3D (mesh raycasting).
- **Splats (stretch):** OpenSplat on a Mac or gsplat on a Vultr GPU for training, and a Metal splat renderer (e.g. MetalSplatter) to show it on device.

### What I want to build: the app

**Four modes:**

| Mode | What you see |
|------|--------------|
| **Scan** | RoomPlan scanning UI with live wall, door, and furniture outlines, plus our questions ("Is this an elevator?") |
| **Explore** | The room as a 3D model you orbit, pinch, and pan. Tap a place → "Go here". The route shows as a glowing ribbon on the floor |
| **Walk-through** | First-person fly-through of the route before you go, at 1.6 m eye height (**1.2 m in the wheelchair profile**) |
| **Navigate** | Live camera with **AR arrows** on the floor, a **2D mini-map** in the corner, a next-step card, and voice |

**The 3D map is built in layers**, all sharing one coordinate system:
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
RoomPlan scan ─► floor outline (walls) ─► minus furniture ─► walkable area
             ─► walked path + shortcut edges ─► navigation graph (nodes + edges, meters)
             ─► doors (measured width), stairs, signs, elevator answers ─► accessibility tags
             ─► graph.json ─► app + routing backend + Tiger Data
```

- **Wheelchair check from geometry:** an accessible route needs **36 in (0.914 m)** of clear width, and a door needs **32 in (0.813 m)** (ADA). If I shrink the walkable area by half the route width, any passage that disappears is too narrow, and its edges get tagged `accessible: false`.
- **Things RoomPlan can't see**, like elevators, ramps, and automatic doors: the person scanning answers a quick question.
- **`graph.json`** is the contract between my part and everyone else's:
  - nodes: `id, x, y, z, kind (path|door|stairs|elevator|sign|poi), label, accessible, confidence`
  - edges: `from, to, length_m, accessible`
  - units are meters, using ARKit's coordinate system with y up

### What I need from the team

| From | What | Why |
|------|------|-----|
| Whoever has a **LiDAR iPhone** (12 Pro or later Pro model) | The device, or regular test scans | RoomPlan and AR **don't run in the Simulator**. This blocks everything |
| Routing + directions | Agree on `graph.json` in hour 1; return routes as a list of node IDs + instructions | So the ribbon, arrows, and voice all follow the same route |
| AI + voice | Sign text from keyframes (Gemini); voice for each instruction (ElevenLabs) | Sign labels on the map; spoken directions |
| Data | Tables for maps, nodes, edges, and live positions (Tiger Data) | Saving maps, find-a-friend |
| **Vedanta** | Answers to the open questions below | Locks the MVP screens and the design direction |

### My build order
1. RoomPlan scan on a real device → USDZ export + scan bundle. *(The riskiest step, so it goes first.)*
2. Explore: load the room in RealityKit with orbit/pinch/pan controls.
3. Draw the graph + a hard-coded route as a ribbon on the floor.
4. Mini-map (SwiftUI `Canvas`) with a "you are here" dot.
5. Navigate: reload the room map, AR arrows along the route, mini-map, next-step card.
6. Walk-through: animate the camera along the route.
7. Connect to the backend: real routes and voice.
8. Polish: transitions, haptics, VoiceOver, accessibility markers.
9. Stretch: photoreal splat layer, then joining several rooms into one floor.

**Fallback:** if the phone can't reliably recognize the room by mid-event, Navigate switches to "tap where you are" and tracks the user from there.

### Risks I see
- **No LiDAR iPhone:** we're blocked. Confirm today.
- **AR arrows drift:** keep the arrows close to the user (the next 3–5 m), with tap-to-relocate as a fallback.
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

## <Name>: <your part>

### My part
### What I researched
### What I want to build
### What I need from the team
### My build order
### Risks I see
### Open questions
