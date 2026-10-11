# InView

GPS stops at the front door. Inside, routes assume you can take the stairs and nobody tells you which door is too narrow or which ramp is too steep until you're already there. InView turns a building into a measured, step-free map, so wheelchair users can find a route that works for them and roll it. Directions are also spoken and signs read aloud for blind and low-vision visitors.

## Who it serves

- **Wheelchair users and anyone avoiding stairs (the primary use case):** step-free routes that skip stairs, doors under 81 cm and ramps without a measured safe slope, built from real LiDAR measurements rather than a building's claims. Routes reroute around new obstacles.
- **Blind and low-vision visitors:** spoken turn-by-turn directions, and signs read aloud with where they are ("Room 204, 12 o'clock, 1 meter"). Works with VoiceOver.
- **Everyone in an emergency:** exits tagged from real exit signs, one tap to the nearest one.
- **Volunteers and building staff:** map a floor by walking it once with a LiDAR iPhone.

## How it works

1. **Map by walking.** RoomPlan measures walls, doors and furniture. A vision model proposes elevators, ramps and stairs, and LiDAR depth confirms each one.
2. **Read the building's signs.** On-device OCR reads room plates and exit signs, LiDAR places them in 3D, and each binds to the door beside it. An optional AI check fixes misreads and reads pictogram-only signs. See [spatial signs](docs/spatial-signs.md).
3. **Find yourself.** The phone recognizes the space from the saved scan, with no QR codes or beacons.
4. **Get there.** AR arrows, a 2D or 3D map, and voice guide you to the door. Anyone can tag a sign they pass, so the map improves with each visit.

The app opens on your saved map, or offers to map a building or run the demo.

## What it does

Scan a building once with a LiDAR iPhone, then get step-free routes that avoid stairs, narrow doors and unsafe ramps, guided by AR arrows, a map and voice. Signs are read aloud, and the nearest exit is one tap away.

## How we built it

- An iOS app on RoomPlan and ARKit LiDAR for scanning, relocalization and AR guidance.
- A vision model proposes elevators, ramps and stairs; LiDAR depth confirms each one.
- On-device OCR reads signs, which LiDAR places in 3D and binds to the nearest door.
- Routing and geometry live in a tested Swift package (`AccessCore`); a Rust server handles accounts and map sharing.
- ElevenLabs for voice, Gemini for voice questions, Mapbox for the outdoor map.

## Challenges we ran into

- Models misread or hallucinate, so every AI detection has to be confirmed by measured depth.
- Placing signs and obstacles accurately in 3D from a handheld phone.
- Recognizing a space from the saved scan with no QR codes or beacons.

## Accomplishments that we're proud of

- A reconstructed Floor 1 with measured, elevation-aware routes.
- Step-free routing based on measured door widths and ramp slopes, not assumptions.
- Works with VoiceOver, so one map serves wheelchair users and blind visitors.

## What we learned

- For wheelchair users, a door's width or a ramp's slope decides whether a route exists, so measured beats assumed.
- AI is good at proposing and bad at certifying; pair it with a physical measurement.

## What's next for InView

- Between-floor directions from published building connections.
- AR guidance on shared maps, not just on the phone that scanned.
- More real-device testing of multi-room scans and relocalization.

## Setup

You need Xcode 26+, iOS 26, a LiDAR iPhone (Pro / Pro Max) and XcodeGen.

```sh
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # fill it in
xcodegen                                                    # re-run after adding or removing files
open InView.xcodeproj
```

| Key in `Config/Secrets.xcconfig` | For |
| --- | --- |
| `DEVELOPMENT_TEAM` | Running on a phone (required) |
| `OPENAI_API_KEY` | Detecting elevators, ramps and stairs, and checking signs. Without it, mark them by hand |
| `GEMINI_API_KEY` | Asking InView by voice (optional) |
| `ELEVENLABS_API_KEY` | A natural voice; falls back to the system voice (optional) |
| `MAPBOX_ACCESS_TOKEN` | Outdoor map around the building (optional) |
| `INVIEW_BACKEND_URL` | Map sharing and place search (optional), written as `http:/$()/host:3000` |

Test without a device:

```sh
xcodebuild -project InView.xcodeproj -scheme InView -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
cd Packages/AccessCore && swift test
```

No scan yet? **Try the navigation demo** runs a sample route, even in Simulator. The optional Rust server handles accounts and map review; see [backend](backend/README.md).

## Code map

| What | Where |
| --- | --- |
| Scanning and map building | `InView/Scan/` |
| Vision detection and sign reading | `InView/Detection/`, `InView/Signs/` |
| Maps and 3D views | `InView/Map/`, `InView/App/MapScreen.swift` |
| AR navigation and voice | `InView/Navigate/`, `InView/Voice/` |
| Routing, geometry, reports (tested) | `Packages/AccessCore/` |
| Server | `backend/` |

## Known limits

- Live guidance needs a floor scanned on the same phone; shared maps can be browsed and previewed but not followed in AR.
- Routes stay on one floor; between-floor directions need published building connections.
- Multi-room scans and relocalization need more testing on real devices.

More: [product guide](docs/product-app.md), [scan performance](docs/scan-performance.md), [team plans](larp.md).
