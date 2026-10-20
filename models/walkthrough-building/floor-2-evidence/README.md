# Floor 2 scan evidence

The original Floor 2 map is preserved byte-for-byte in `original-floor-2.json`. The four user-supplied files are preserved byte-for-byte under `E3CF408C-680C-4ECF-B9EB-F09117308BD3/`. `manifest.json` records their SHA-256 hashes, registration residuals and every merge decision.

Only the original map, four scan files and this guide are tracked. Run the merge script below to recreate the manifest, registration, projected geometry, merged map and optional PNG review plans; these outputs are ignored by Git.

The new scan was taken outside the main lounge, starting at the far end of the balcony opposite the elevators and finishing near the restrooms. Two adjoining measured walls establish a rigid registration to the earlier scan: a 19.596 m wall matches the earlier 19.619 m wall, and its 5.266 m return matches the earlier 5.216 m return. The fit has 3.17 cm endpoint RMS error and 4.45 cm maximum error. Two held-out wall stubs agree within 8.85 cm of the original wall centerlines.

The registration rotates the scan by 59.571186615570014 degrees, translates X/Z by `(15.206638123073265, 0.0752186592439541)` meters, and translates Y by `-0.3268485` meters. It preserves measured scale. Exact computed values and the transform convention are in `registration.json`.

`merged-floor-2.json` preserves the original 77 footprints and both elevator points. It adds 19 completed walls, one door and one opening. Two overlapping walls and one overlapping door retain the original measurement instead. The sink and television are visual evidence; their undersides exceed MapBuilder's 0.7 m obstacle cutoff above the native floor, so neither is introduced as a routing obstacle.

The original 12 measured routing floor regions remain unchanged. All four new floor polygons are projected correctly into the original map frame and archived in `registered-projection.json`. They are withheld from routing: the native RoomPlan floor and the three observed additions include broad areas whose complete support was not verified. Raw wall observations establish the alignment only; raw walls, objects, depth and walk trace are never promoted into the candidate's routing geometry.

`canonical-capture.json` is the registered structural capture, with original surface and object IDs, unchanged dimensions and local polygon corners, and corrected poses. Its metadata distinguishes the one completed native floor from `observed-0`, `observed-1` and `observed-2`. A structural display may use the native floor as a display-only unreviewed outline. Observed floor additions remain evidence only. Sensor frames are omitted from this derived copy and remain exact in the original archive.

Reproduce the candidate and PNG review plans:

```sh
/Users/nerd/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/merge-student-center-floor-2.py
```

The script writes only this evidence directory; it does not replace app resources or either floor's visual assets. `--no-render` runs the same merge and validation without Pillow. `--import-downloads` is only needed for an initial archive and verifies already archived copies rather than overwriting them. The before/after PNGs share one scale and show additional completed measurements in green.
