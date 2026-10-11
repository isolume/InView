# InView

Indoor wheelchair navigation for iPhone. Scan a building with LiDAR, then get step-free directions inside it.

The app opens on a 3D map of Georgia State's Student Center East (Floors 2 and 3). Search for a place, open its details and get directions.

## What it does

- **Scan:** walk a floor with a LiDAR iPhone. RoomPlan builds the map. A vision model (OpenAI or Gemini) spots elevators, ramps and stairs, and LiDAR checks each one. Connected rooms can share one scan, with confirmed doorway crossings handled automatically.
- **Read signs:** on-device OCR labels room, direction, exit and other readable signs with measured XYZ, floor-relative elevation and optional geographic data—no API key required. See [spatial sign capture and export](docs/spatial-signs.md).
- **Review:** keep or drop each find, name places, then save. You get a floor plan, a 3D model and an accessibility report.
- **Navigate:** when a floor has compatible localization data, the app recognizes the saved space and shows AR arrows with spoken directions. Routes avoid stairs, narrow doors (under 81 cm), ramps with missing or excessive slope measurements, and new obstacles. Shared JSON maps support browsing and manually chosen route previews, but have no live positioning. Voice uses ElevenLabs when configured, with a system-voice fallback.
- **Ask:** with a Gemini key, tap the mic and ask where something is.
- **Share:** signed-in users submit maps. Admins review and publish them.

## Setup

You need Xcode 26+, iOS 26, a LiDAR iPhone (Pro / Pro Max) and XcodeGen.

```sh
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # fill it in
xcodegen
open InView.xcodeproj
```

Keys in `Config/Secrets.xcconfig` (git-ignored):

| Key | Needed? | For |
| --- | --- | --- |
| `DEVELOPMENT_TEAM` | Yes, to run on a phone | Code signing |
| `OPENAI_API_KEY` | Recommended | Detecting elevators, ramps, stairs. Without it, mark them by hand |
| `GEMINI_API_KEY` | Optional | **Ask InView**, or detection with `VISION_PROVIDER = gemini` |
| `ELEVENLABS_API_KEY` | Optional | Nicer voice. Falls back to the system voice |
| `MAPBOX_ACCESS_TOKEN` | Optional | Outdoor map around the building (`pk.` token) |
| `INVIEW_BACKEND_URL` | Optional | Server for map sharing and **Find places**. Write as `http:/$()/host:3000` |

Re-run `xcodegen` after adding or removing files. For the photoreal splat layer, also run `xcodebuild -downloadComponent MetalToolchain`.

Build and test without a device:

```sh
xcodebuild -project InView.xcodeproj -scheme InView -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
cd Packages/AccessCore && swift test
```

## Backend (optional)

The Rust server handles accounts, map submissions and admin review. Scanning works without it.

```sh
cargo run --locked --manifest-path backend/Cargo.toml   # Simulator: use http://127.0.0.1:3000
backend/run-local.sh                                    # real phone on the same Wi-Fi
```

More: [backend setup](backend/README.md), [deployment](backend/infra/README.md), [scan protocols](backend/SCANS.md).

## Demo

1. **Scan.** Start at the demo table, facing the way the rider will start. Pan slowly, then walk to the elevator and ramp, pausing a couple of seconds on each. Finish one room before going through a doorway.
2. **Finish and review.** Keep or drop unconfirmed finds, rename places, mark anything staff-operated, then **Save**.
3. **Navigate.** Stand near the table until the app recognizes the room (if not after 15 s, stand on the start spot and tap **Try again**). Tap **Take me to the nearest accessible point**. Drop a chair in the path to show rerouting.

No scan? **Try the navigation demo** runs a fake route, even in Simulator.

Tip: rescan close to demo time, in the same lighting.

## Code map

| What | Where |
| --- | --- |
| Scanning and map building | `InView/Scan/` |
| Vision detection | `InView/Detection/` |
| Map and 3D views | `InView/Map/`, `InView/App/MapScreen.swift` |
| AR navigation | `InView/Navigate/` |
| Voice | `InView/Voice/` |
| Routing, geometry, reports (tested) | `Packages/AccessCore/` |

## Known limits

- Multi-room scans, floor changes and relocalization still need testing on a real device.
- Routes stay on one floor.
- Generated landmarks are browse-only; directions need a measured scan.

More detail: [product guide](docs/product-app.md), [continuous scanning](docs/continuous-scanning.md), [scan performance](docs/scan-performance.md). Team plans: [larp.md](larp.md), [photon.md](photon.md).
