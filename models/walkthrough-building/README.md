# Atrium & lounge

A roofless, Apple Maps-inspired model of the section shown in `IMG_5436.MOV`. It reuses InView's custom furniture with pale walls, muted upholstery, warm neutral floors, softened edges, and simplified railings.

The lounge opens onto a straight upper-floor balcony. The balcony leads toward double doors at one end and two lifts with adjacent stairs at the other. The open atrium includes a quiet suggestion of the seating below and the opposite glazed wall.

## Files

- `preview.html` — interactive offline preview. Drag to rotate, scroll to zoom, Shift-drag to move, or choose Top.
- `preview.png` — rendered cutaway view.
- `floor-plan.png` — overhead view.
- `building.glb` — model for 3D viewers and game engines; meters, Y up.
- `building.usdz` — native Apple preview model; meters, Y up.
- `building.blend` — editable source, including the preview camera and studio lighting; meters, Z up.
- `layout.json` — furniture placements and the observed versus estimated layout details.
- `validation.json` — native export checks and geometry counts.
- `glb-validation.json` — independent GLB structure, normals, triangle, and bounds checks.
- `viewer-scene.json` — geometry used by the offline preview.

The GLB and USDZ contain the building and furnishings only. The studio floor, lights, and camera are confined to the Blender source and rendered previews. No video frames, photographs, people, or signage text are embedded in the models.

## Approximation

This is a visual reconstruction of the filmed section, not a measured floor plan or a model of the entire building. Dimensions, wall extents, furniture counts and placements, and unseen stair continuations are estimated. Wall and glazing heights are deliberately cut down to expose the interior. The upward stair stops at a partial landing; the next floor is not modeled. The lower atrium floor is contextual and does not establish its full footprint.

Use captured measurements for navigation, clearance, or accessibility decisions. This asset has not been connected to InView's navigation or scan data.

## Rebuild

From the repository root, with Blender 4.5 and Python 3:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 --python scripts/build-walkthrough-building.py -- --samples 32
python3 scripts/build-walkthrough-viewer.py
```

The original furniture catalogue remains the source for furniture shapes. The build exports GLB and USDZ, validates the native package, writes the viewer geometry, saves the Blender scene, and renders the cutaway and overhead views.
