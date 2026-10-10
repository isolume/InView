# InView

Volunteers scan a floor once with a LiDAR iPhone; the app spots elevators and ramps with a vision model. After that, anyone in a wheelchair can open the app, which relocalizes into the saved AR map, and follow AR arrows along a step-free route to the nearest accessible point.

## Setup

Requires Xcode 26+, an iPhone with LiDAR (Pro / Pro Max), and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill it in
xcodegen
open InView.xcodeproj
```

`Config/Secrets.xcconfig` is git-ignored. Set:

- `OPENAI_API_KEY`: used for elevator and ramp detection while scanning. Without it, scanning still works, but you pin points by hand.
- `DEVELOPMENT_TEAM`: your Apple team ID, needed to run on the phone. You can also pick the team in Xcode under Signing & Capabilities.
- `OPENAI_MODEL` / `OPENAI_REASONING_EFFORT` (optional): default to `gpt-6.1-sol` / `low`. `gpt-6-luna` with `none` is faster and cheaper.

Re-run `xcodegen` after adding or removing files.

## Demo checklist

1. **Start the scan at the demo table.** Hold still for a second, facing the way the rider will start. That spot is the map's origin, and the app saves a photo of it.
2. **Map a space**: before walking off, slowly pan around the table area so it's well covered. Then walk to the elevator and ramp, holding the phone upright.
   - Pins appear as the model spots things.
   - Use **Pin elevator / Pin ramp** to mark whatever is in the center of the screen.
   - Use **Add section** when RoomPlan struggles with a big area. Keep each section under about 5 minutes.
3. **Finish**. The app saves the AR map (ARWorldMap); if that fails, move around a little and tap **Try again**.
4. Review the map, tap it to add any missed points, and **Save**.
5. **Navigate**: stand near the table and slowly look around until the app recognizes the space. Then tap **Take me to the nearest accessible point**.
   - If it hasn't recognized the space after 15 s, stand exactly on the scan start spot, face the way the photo does, and tap **Start from here**.

Relocalization works best when the lighting matches the scan and the area has texture: posters, furniture, signage. Blank walls are hard to recognize. Rescan close to demo time if the room has changed a lot.

## How it works

| Piece | Where |
| --- | --- |
| RoomPlan scan → 2D footprints (walls, doors, furniture, stairs) | `InView/Scan/MapBuilder.swift` |
| Vision detection + 3D placement by raycast | `InView/Detection/` |
| ARWorldMap save and relocalization | `InView/Scan/ScanController.swift`, `InView/Navigate/NavigationController.swift` |
| Wheelchair routing: occupancy grid with clearance, ADA door widths, A* | `Packages/AccessCore/.../OccupancyGrid.swift`, `RoutePlanner.swift` |
| AR chevrons and destination labels | `InView/Navigate/PathRenderer.swift` |

Routes keep 45 cm clearance from obstacles (90 cm passages). In tight spaces they fall back to 30 cm, then 15 cm, and the UI warns that the route is narrow. Doors under 81 cm (ADA 32") are treated as walls.

## Tests

```sh
cd Packages/AccessCore && swift test
```
