# InView

Volunteers scan a floor once with a LiDAR iPhone. Gemini spots and names the elevators and ramps, LiDAR measures each ramp's slope, and the app produces an accessibility report card.

A wheelchair user then opens InView, which recognizes the room from the saved AR map. They follow AR arrows and spoken, captioned directions along a step-free route to the nearest usable elevator or ramp. The route goes around obstacles LiDAR sees on the way and around ramps steeper than the ADA allows.

The server (Photon agent, ElevenLabs) is a separate piece of work. Team plans: [larp.md](larp.md) and [photon.md](photon.md).

## Setup

Requires Xcode 26+, an iPhone with LiDAR (Pro / Pro Max), and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill it in
xcodegen
open InView.xcodeproj
```

`Config/Secrets.xcconfig` is git-ignored. Set:

- `GEMINI_API_KEY`: elevator and ramp detection and naming while scanning. Without it, pin points by hand.
- `DEVELOPMENT_TEAM`: your Apple team ID, needed to run on the phone. You can also pick the team in Xcode under Signing & Capabilities.
- `GEMINI_MODEL` (optional): defaults to `gemini-3.8-flash`.

Re-run `xcodegen` after adding or removing files.

## Demo checklist

1. **Start the scan at the demo table.** Hold still for a second, facing the way the rider will start. That spot is the map's origin, and the app saves a photo of it.
2. **Map a space.** Slowly pan around the table area first, then walk to the elevator and the ramp.
   - Pins pop up as Gemini spots things.
   - **Pin elevator / Pin ramp** marks whatever is in the center of the screen. For a ramp, aim at its middle so its slope gets measured.
   - **Add section** splits a big area. Keep each section under about 5 minutes.
3. **Finish**. If saving the AR map fails, move around a little and tap **Try again**.
4. Review:
   - Rename points so they're easy to say.
   - Turn on **Needs staff** for anything someone has to operate.
   - Check the report card.
   - **Save**.
5. **Navigate.** Stand near the table and look around until the app recognizes the space. If it hasn't after 15 s, stand on the scan start spot, face the way the photo does, and tap **Start from here**. Then:
   - Tap **Take me to the nearest accessible point**.
   - Put a chair in the path: it gets a red marker, and the route and voice go around it.

Relocalization works best when the lighting matches the scan and the area has texture: posters, furniture, signage. Rescan close to demo time if the room has changed a lot.

## How it works

| Piece | Where |
| --- | --- |
| RoomPlan scan → 2D footprints (walls, doors, furniture, stairs) | `InView/Scan/MapBuilder.swift` |
| Gemini detection, naming, and 3D placement by raycast; ramp slope by plane fit | `InView/Detection/`, `Packages/AccessCore/.../SurfaceFit.swift` |
| ARWorldMap save and relocalization | `InView/Scan/ScanController.swift`, `InView/Navigate/NavigationController.swift` |
| Wheelchair routing: clearance grid, ADA door widths, A*, obstacles, steep-ramp fallback | `Packages/AccessCore/.../OccupancyGrid.swift`, `RoutePlanner.swift` |
| LiDAR obstacle detection while navigating | `InView/Navigate/ObstacleTracker.swift`, `Packages/AccessCore/.../ObstacleFinder.swift` |
| Turn-by-turn narration (system voice, with captions) | `InView/Voice/`, `Packages/AccessCore/.../Maneuver.swift` |
| Accessibility report card | `Packages/AccessCore/.../AccessibilityReport.swift`, `InView/Report/` |
| AR chevrons, labels and obstacle markers | `InView/Navigate/PathRenderer.swift` |

Routing rules:
- Routes keep 45 cm clearance from obstacles (90 cm passages). In tight spaces they fall back to 30 cm, then 15 cm, and the UI warns that the route is narrow.
- Doors under 81 cm (ADA 32") are treated as walls.
- Ramps steeper than 1:12 (4.8°) are used only when nothing else is reachable.
- `RouteConditions.unavailable` can exclude points, e.g. elevators reported out of service, once the server provides that.

## Tests

```sh
cd Packages/AccessCore && swift test
```
