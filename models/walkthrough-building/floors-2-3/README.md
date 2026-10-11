# Floors 2 and 3

A roofless, Apple Maps-inspired reconstruction of the areas visible in `IMG_5439.MOV`, with the earlier lounge details from `IMG_5436.MOV`. Pale walls, muted furniture, softened edges, and simplified railings match the original model. The earlier atrium model is preserved in the parent folder.

Floor 2 includes the carpeted lounge and its internal passage, atrium balcony, two lifts, main stair, modular seating concourse, windowed desk area, gallery branch, and restroom passage. Floor 3 includes the lift lobby, long window-side lounge, mural corridor, glazed suite fronts, restroom passage, bench landing, and stair descent.

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
| `layout.json` | Furniture placements, video evidence, and estimates |
| `validation.json` and `glb-validation.json` | Export and geometry checks |
| `viewer-scene.json` | Geometry for the offline preview |

## Approximation

This covers the filmed areas, not the complete floors. All dimensions, furniture spacing, floor heights, and the alignment between levels are estimated. The video cuts between floors around 2:51–2:52; the ascent is not shown. A floor 3 plaque later establishes the upper level. The gallery is modeled as a branch because its footage may retrace the same route. Corridor turns and connections remain approximate.

Closed rooms and unfilmed wings have no invented interiors. Wall and glazing heights are shortened to expose the furniture. Split stair flights belong to their adjacent floor. Video frames, people, photographic artwork, and personal belongings are not embedded.

Use measured geometry before relying on this for navigation or clearances. The model is separate from InView's navigation and scan data.

## Rebuild

From the repository root with Blender 4.5 and Python 3:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 --python scripts/build-walkthrough-floors.py -- --samples 24
python3 scripts/build-walkthrough-floor-viewer.py
```

The build reuses the original furniture catalogue and building primitives. Exports and viewer geometry use meters with Y up; the Blender source uses meters with Z up. Floor 2 is at zero and floor 3 is at an estimated 4 meters. Studio lighting and the background are confined to the Blender source and rendered previews.
