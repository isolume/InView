# Floors 2 and 3

A roofless model with pale walls, muted furniture and softened edges. Floor 2 now follows the earlier lounge scan and the new scan outside the lounge, registered at their shared balcony corner. Floor 3 remains the estimated reconstruction from `IMG_5439.MOV`. The original two-floor video model is preserved in `../floors-2-3-video.zip`.

Floor 2 shows the scanned lounge furniture, balcony, elevator doors and measured turns and recesses along the exterior corridor toward the restrooms. Unscanned branches are not placed into the revised scan structure. Floor 3 includes the lift lobby, long window-side lounge, mural corridor, glazed suite fronts, restroom passage, bench landing, and stair descent.

## View and download

Open `preview.html` for the interactive model. Choose Floor 2, Floor 3, or Both floors; rotate, zoom, pan, or switch to Top. Both floors can be stacked or separated. Separation affects the preview only. Downloads follow the selected floor.

| File | Contents |
| --- | --- |
| `building.glb` and `building.usdz` | Both floors at their estimated relative elevations |
| `floor-2.glb` and `floor-2.usdz` | Floor 2 only |
| `floor-3.glb` and `floor-3.usdz` | Floor 3 only, retaining its elevation |
| `building.blend` | Editable scene with a collection for each floor |
| `preview.png` | Separated view of both floors |
| `floor-2.png` and `floor-3.png` | Individual cutaway views |
| `floor-2-plan.png` and `floor-3-plan.png` | Overhead views |
| `layout.json` | Scan provenance, furniture placements, video evidence and estimates |
| `illustration-floors.json` | Original floor regions plus the new native floor envelope, for display only |
| `validation.json` and `glb-validation.json` | Export and geometry checks |
| `viewer-scene.json` | Geometry for the offline preview |

## Approximation

This covers supplied scan structure on Floor 2 and filmed areas on Floor 3, not the complete floors. Floor 2 walls, door widths and furniture placements follow the scans; furniture silhouettes and cutaway heights are styled. The scan registration preserves scale and agrees at its fitted endpoints within 4.45 cm, with independent wall checks within 8.85 cm. Original files, the exact transform and merge decisions are in `../floor-2-evidence/`.

Floor 2's new native floor envelope is shown as a visual base but remains unreviewed for routing; its three broader observed floor additions are omitted. The app's original 12 measured routing floor regions remain unchanged. The walk trace is review evidence, not a walkable floor. No new live AR localization is established.

Floor 3 dimensions, spacing, height and the relationship between levels remain estimated. Its standalone GLB, USDZ and PNG assets are unchanged. The video cuts between floors around 2:51–2:52; the ascent is not shown. A floor 3 plaque later establishes the upper level.

Closed rooms and unfilmed wings have no invented interiors. Wall and glazing heights are shortened to expose the furniture. Split stair flights belong to their adjacent floor. Video frames, people, photographic artwork, and personal belongings are not embedded.

The visual model never supplies routing coverage or clearance decisions. The bundled Floor 2 map uses the registered completed structure while retaining its earlier routing floors and elevator points.

## Rebuild

Rebuild the current scan-based Floor 2 from the repository root with Blender 4.5, Swift, and Python 3 with NumPy. Pillow is needed only for the evidence plan previews.

```sh
python3 scripts/merge-student-center-floor-2.py --no-render
swift build --package-path Packages/AccessCore
swiftc "$PWD/scripts/build-student-center-illustration-floors.swift" -I Packages/AccessCore/.build/debug -L Packages/AccessCore/.build/debug -lAccessCore -module-cache-path /private/tmp/inview-scene-module-cache -o /private/tmp/build-student-center-illustration-floors
PACKAGE_RESOURCE_BUNDLE_PATH="$PWD/Packages/AccessCore/.build/debug" /private/tmp/build-student-center-illustration-floors
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 --python scripts/build-scanned-floor-2.py -- --samples 24
python3 scripts/build-walkthrough-floor-viewer.py
python3 scripts/validate-floor-models.py
```

The build reads the preserved video-model archive for Floor 3, reuses the furniture catalogue and exports only the updated Floor 2 and combined models. `illustration-floors.json` is the exact native-floor subtraction from the original measured floor regions; it is never copied into the routing map. Exports and viewer geometry use Y up; the Blender source uses Z up. The existing app registration maps Floor 2's authored coordinates back to actual scan meters. Floor 2 is at zero and Floor 3 is at an estimated 4 meters. Studio lighting and background are confined to the Blender source and previews.
