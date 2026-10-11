# InView

GPS stops at the front door. Inside, signs are written for people who can see them and routes assume you can take the stairs. InView turns a building into a map you can hear, follow and roll through, so blind and disabled visitors can find their own way.

## Who it serves

- **Blind and low-vision visitors:** spoken turn-by-turn directions, and signs read aloud with where they are ("Room 204, 12 o'clock, 1 meter"). Works with VoiceOver.
- **Wheelchair users and anyone avoiding stairs:** step-free routes that skip stairs, doors under 81 cm and ramps without a measured safe slope, and reroute around new obstacles.
- **Everyone in an emergency:** exits tagged from real exit signs, one tap to the nearest one.
- **Volunteers and building staff:** map a floor by walking it once with a LiDAR iPhone.

## How it works

1. **Map by walking.** RoomPlan measures walls, doors and furniture. A vision model proposes elevators, ramps and stairs, and LiDAR depth confirms each one.
2. **Read the building's signs.** On-device OCR reads room plates and exit signs, LiDAR places them in 3D, and each binds to the door beside it. An optional AI check fixes misreads and reads pictogram-only signs. See [spatial signs](docs/spatial-signs.md).
3. **Find yourself.** The phone recognizes the space from the saved scan, with no QR codes or beacons.
4. **Get there.** AR arrows, a 2D or 3D map, and voice guide you to the door. Anyone can tag a sign they pass, so the map improves with each visit.

The app opens on a 3D map of Georgia State's Student Center East (Floors 2 and 3).

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
