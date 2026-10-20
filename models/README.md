# Model sources

This folder retains the evidence needed to rebuild the models. Generated exports, HTML viewers, renders, delivery archives and validation output are created locally and ignored by Git. The app uses its separate bundled assets in `InView/Resources/StudentCenter` and the furniture catalog in `Packages/AccessCore`.

| Retained source | Purpose |
| --- | --- |
| `walkthrough-building/floor-1-reconstruction/` | Compact scan geometry, registration, reviewed structures, furnishings and navigation measurements |
| `walkthrough-building/floor-2-evidence/` | Four original scan files and the preceding measured map |
| `walkthrough-building/floor-2-reconstruction/` | Reviewed structure, depth support, furnishings, registration and source provenance |
| `walkthrough-building/floors-2-3-video.zip` | Required baseline scene, layout, viewer geometry and four unchanged Floor 3 exports |

The baseline archive contains only the seven members read by the rebuild and validation scripts. Its retained members preserve their original bytes; redundant exports and archived HTML have been removed. Keep this archive: the Floor 2 builders use it to preserve Floor 3.

Compact scan evidence remains tracked even where an extraction step originally created it. Those extraction steps depend on external recordings or reviewed measurements and cannot be reproduced from the repository alone.

## Rebuild

Run from the repository root. Floor preparation requires Python with NumPy and Shapely 2.1 or later; native exports require Blender 4.5. Review the output before replacing bundled app resources.

The navigation builders write bundled navigation resources; the Blender and viewer scripts write local model outputs.

```sh
python3 scripts/prepare-floor-1-model.py
python3 scripts/test-floor-1-model-geometry.py
blender --background --factory-startup --python-exit-code 1 --python scripts/build-floor-1-model.py -- --samples 24
python3 scripts/build-floor-1-navigation.py

python3 scripts/merge-student-center-floor-2.py --no-render
python3 scripts/prepare-video-lidar-floor-2.py
blender --background --factory-startup --python-exit-code 1 --python scripts/build-video-lidar-floor-2.py -- --samples 24
python3 scripts/build-walkthrough-floor-viewer.py
python3 scripts/validate-floor-models.py
```

`build-floor-2-navigation.py` separately rebuilds Floor 2 navigation and updates its localization metadata. The legacy Floor 2 builder additionally needs `illustration-floors.json`, generated with `scripts/build-student-center-illustration-floors.swift` after the evidence merge.

See the retained subfolder READMEs for furniture exports, legacy walkthrough previews and asset-copy commands. Historical UI screenshots and post-build receipts are omitted; rerun the relevant checks when changing model sources.
