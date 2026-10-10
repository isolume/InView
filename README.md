# AccessNav

Volunteers scan a floor once with a LiDAR iPhone; the app spots elevators and ramps with a vision model. Riders can choose a named destination across connected rooms, or find the nearest elevator or ramp. The standard 3D map and AR arrows share the same position and step-free route in the saved scan.

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

## Building scan processing

The app exports RoomPlan scans to the Rust service and uses the returned 3D scene
in navigation. The standard map and AR camera share the same route and position
in the original scan coordinates. Furniture provides scenery and obstacle context;
it has no browsing flow or labels. The native toolbar switches between Map and AR,
and the standard map supports 2D/3D, orbit, zoom, and recenter.

Start the backend on the Mac:

```sh
cargo run --manifest-path backend/Cargo.toml
```

The Simulator uses `http://127.0.0.1:3000` by default. For an iPhone on the same
Wi-Fi, bind the service to the Mac's Wi-Fi address instead:

```sh
INVIEW_BIND="$(ipconfig getifaddr en0):3000" cargo run --manifest-path backend/Cargo.toml
```

In the app, open the gear button and enter `http://<Mac Wi-Fi address>:3000`.
Allow local network access when iOS asks. You can also supply `INVIEW_BACKEND_URL`
in your ignored `Config/Secrets.xcconfig`; use `http:/$()/host:3000` so xcconfig
doesn't interpret the URL's double slash as a comment. The backend is a local
development service without authentication or durable storage.

Finish a scan, wait for **Building map…**, then review the 3D navigation map.
**Review points** opens the editable floor plan and accessible points before saving.
A processing failure keeps the original scan on the phone; set the server address
and retry. Saved geometry opens offline, and navigation can recover a missing
scene by reuploading the saved source after a backend restart.

**Try navigation demo** works without a scan or backend, including in Simulator.
It previews a route from reception through a hallway to a meeting room, then moves
the position marker along that route when **Start demo** is pressed. It uses the
same occupancy grid and route planner as real navigation. AR navigation needs a
saved scan and camera tracking on an iPhone. The demo never changes the saved map.
The bundled scene is generated from `backend/examples/demo-living-room.json` and
`GET /scans/demo-room/scene`; it is never substituted for a real scan.

Use **Next room** while scanning to capture connected rooms and hallways in the
same session, then **Finish** to process the combined scan. **Review points** lets
a volunteer name destinations anywhere on the map. Navigation offers those
places alongside elevators and ramps. Overlapping sections use each component's
latest pose in both routing geometry and the 3D view.

This first building prototype covers connected spaces on one floor. Joining
independently captured areas, connecting floors through elevators, and maintaining
tracking across a large building require additional work and device verification.

Each capture is archived under Documents/Captures with native RoomPlan JSON,
copied mesh/depth buffers, its portable upload, and the derived scene. Depth uses
up to six selected keyframes; this is not a recording of the entire sensor stream.
The current 32 MiB JSON upload limit can leave optional mesh/depth layers local,
with the omission recorded in capture metadata. Large binary uploads and automatic
object recognition remain future work. See [backend/SCANS.md](backend/SCANS.md).

## Demo checklist

1. **Start the scan at the demo table.** Hold still for a second, facing the way the rider will start. That spot is the map's origin, and the app saves a photo of it.
2. **Map a building**: before walking off, slowly pan around the table area so it's well covered. Then walk to the elevator and ramp, holding the phone upright.
   - Pins appear as the model spots things.
   - Use **Pin elevator / Pin ramp** to mark whatever is in the center of the screen.
   - Use **Next room** when RoomPlan struggles with a big area. Keep each section under about 5 minutes.
3. **Finish**. The app saves the AR map (ARWorldMap); if that fails, move around a little and tap **Try again**.
4. Review the 3D map, use **Review points** to add or name destinations, and **Save map**.
5. **Navigate**: stand near the table and slowly look around until the app recognizes the space. Choose a destination, or the nearest elevator or ramp, then tap **Go**.
   - If it hasn't recognized the space after 15 s, stand exactly on the scan start spot, face the way the photo does, and tap **Start from here**.

Relocalization works best when the lighting matches the scan and the area has texture: posters, furniture, signage. Blank walls are hard to recognize. Rescan close to demo time if the room has changed a lot.

## How it works

| Piece | Where |
| --- | --- |
| RoomPlan scan → 2D footprints (walls, doors, furniture, stairs) | `AccessNav/Scan/MapBuilder.swift` |
| Vision detection + 3D placement by raycast | `AccessNav/Detection/` |
| ARWorldMap save and relocalization | `AccessNav/Scan/ScanController.swift`, `AccessNav/Navigate/NavigationController.swift` |
| Shared-session mesh/depth snapshots and RoomPlan upload | `AccessNav/Scan/RawScanCapture.swift`, `ScanExporter.swift` |
| Rust processing client and wire types | `Packages/AccessCore/.../BackendClient.swift`, `CaptureBundle.swift`, `ProcessedScene.swift` |
| Native isometric room rendering and map cards | `AccessNav/Navigate/NavigateView.swift`, `AccessNav/Map/RoomMapCanvas.swift` |
| Wheelchair routing: occupancy grid with clearance, ADA door widths, A* | `Packages/AccessCore/.../OccupancyGrid.swift`, `RoutePlanner.swift` |
| AR chevrons and destination labels | `AccessNav/Navigate/PathRenderer.swift` |

Routes keep 45 cm clearance from obstacles (90 cm passages). In tight spaces they fall back to 30 cm, then 15 cm, and the UI warns that the route is narrow. Doors under 81 cm (ADA 32") are treated as walls.

## Tests

```sh
cd Packages/AccessCore && swift test
```
