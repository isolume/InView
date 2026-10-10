# AccessNav

Volunteers scan a floor once with a LiDAR iPhone; the app spots elevators and ramps with a vision model. After that, anyone in a wheelchair can open the app, point it at the check-in sign, and follow AR arrows along a step-free route to the nearest accessible point.

## Setup

Requires Xcode 26+, an iPhone with LiDAR (Pro / Pro Max), and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill it in
xcodegen
open AccessNav.xcodeproj
```

`Config/Secrets.xcconfig` is git-ignored. Set:

- `OPENAI_API_KEY`: used for elevator and ramp detection while scanning. Without it, scanning still works, but you pin points by hand.
- `DEVELOPMENT_TEAM`: your Apple team ID, needed to run on the phone. You can also pick the team in Xcode under Signing & Capabilities.
- `OPENAI_MODEL` / `OPENAI_REASONING_EFFORT` (optional): default to `gpt-6.1-sol` / `low`. `gpt-6-luna` with `none` is faster and cheaper.

Re-run `xcodegen` after adding or removing files.

## Demo checklist

1. Print `print/check-in-marker.pdf` at 100% scale and check that the pattern is **18 cm** wide.
2. Tape it to the demo table, flat or upright. **Don't move it after scanning**, because the whole map is stored relative to it.
3. **Map a space**: walk the route from the table to the elevator and ramp, holding the phone upright.
   - Pins appear as the model spots things.
   - Use **Pin elevator / Pin ramp** to mark whatever is in the center of the screen.
   - Use **Add section** when RoomPlan struggles with a big area.
4. **Finish**, then walk back and point the camera at the marker to check in.
5. Review the map, tap it to add any missed points, and **Save**.
6. **Navigate**: point the camera at the marker, then tap **Take me to the nearest accessible point**.

## How it works

| Piece | Where |
| --- | --- |
| RoomPlan scan → 2D footprints (walls, doors, furniture, stairs) | `AccessNav/Scan/MapBuilder.swift` |
| Vision detection + 3D placement by raycast | `AccessNav/Detection/` |
| Marker → gravity-aligned venue frame | `Packages/AccessCore/.../VenueFrame.swift` |
| Wheelchair routing: occupancy grid with clearance, ADA door widths, A* | `Packages/AccessCore/.../OccupancyGrid.swift`, `RoutePlanner.swift` |
| AR chevrons and destination labels | `AccessNav/Navigate/PathRenderer.swift` |

Routes keep 45 cm clearance from obstacles (90 cm passages). In tight spaces they fall back to 30 cm, then 15 cm, and the UI warns that the route is narrow. Doors under 81 cm (ADA 32") are treated as walls.

## Tests

```sh
cd Packages/AccessCore && swift test
```

## Regenerating the marker

```sh
swift scripts/make-marker.swift AccessNav/Resources/marker.png print/check-in-marker.pdf
```
