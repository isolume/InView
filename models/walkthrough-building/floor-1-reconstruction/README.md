# Floor 1 reconstruction

Seven recordings are registered in one metric, Y-up coordinate frame. The entire model is displayed as Floor 1. The main floor is at Y = 0, the auditorium and window lobby at Y = 1.58 m, and the separate dining terrace at Y = 1.10 m. The main lobby reaches the raised auditorium lobby by steps or elevator. The food court's sloped corridor serves only its dining terrace.

The source audit covers 103 video segments and 9,936 frames. All referenced video segments are present. Capture `611423DC-EDB2-4FCE-91B1-F47573C20F8B` lacks its paired saved-map folder and some derived exports; its RoomPlan, raw snapshot, video and synchronized depth remain available. The overlapping auditorium recording supplies the authoritative auditorium envelope, so this omission does not block the model. Independent AR archives have not been merged into a shared localization session.

`registration.json` retains the transforms and correspondence checks. `sources/` retains compact native geometry and traces. `structure/`, `visual-evidence.json`, `furniture-evidence.json`, and the measured transition files retain the evidence used to assemble the reconstruction. Large recordings and camera imagery remain in the supplied Downloads folders and are not embedded in the delivered assets.

`reconstruction.json` is the editable visual specification. Completed floors cover occlusion beneath furniture and scanning gaps, with protected openings and explicit elevation transitions. Furniture and cutaway walls are simplified, and continuous floors are levelled to remove accumulated vertical tracking drift. Overlapping auditorium geometry is reconciled rather than drawn twice. The food court surface is continuous and the atrium void remains open.

The specification, navigation validation and navigation source manifest are generated locally and ignored by Git. Compact source geometry and reviewed measurement files remain tracked. Historical UI screenshots and post-build receipts are omitted.

Navigation uses measured floor support, observed passages and actual obstacles. It does not use visual completion as evidence. `navigation-source-manifest.json` records the generated resource and inputs; `navigation-validation.json` records checks on the actual bundled map. Auditorium seating and stage surfaces remain visual-only until their individual transitions are mapped. A map preview is not evidence of physical AR relocalization at the venue.

Validation covers all 84 directed routes between the seven named places across both routing preferences, plus arbitrary points, transitions and expected failures: 380 cases and 1,602,246 route samples. The main connected network contains 98.0% of clear main-floor cells for Fastest and 89.3% for Step-free. A food court seating area has a measured Fastest connection but insufficient evidence for the wider Step-free clearance. Smaller disconnected pockets and sloped corridor interiors cannot be used as arbitrary route endpoints. `navigation-limitations.json` records these gaps; they do not establish physical inaccessibility.

Rebuild the visual model from the retained evidence with Python 3, NumPy and Shapely 2.1 or later, then Blender:

```sh
python3 scripts/prepare-floor-1-model.py
python3 scripts/test-floor-1-model-geometry.py
blender --background --python scripts/build-floor-1-model.py -- \
  --spec models/walkthrough-building/floor-1-reconstruction/reconstruction.json \
  --output models/walkthrough-building/floor-1
python3 scripts/build-floor-1-navigation.py
```

`../floor-1/` is generated locally and contains the USDZ, GLB, editable Blender file, perspective and plan previews, and native mesh validation. The app bundles separate copies of the USDZ and perspective PNG alongside its Floor 1 layout and navigation resources.
