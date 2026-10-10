# Photo furniture

Fourteen furniture and balcony assets based on the supplied room and balcony photos, rendered in InView's soft gray, rounded style. The large and small drum tables share one model family.

Dimensions are approximate estimates in meters, in width × height × depth order. Back surfaces, internal construction, and other unseen details are inferred. These are display models; captured measurements remain the source of navigation and clearance information. Photo filenames record the references, and the photos themselves are not copied into this folder.

- `photo-furniture.zip`: the complete model and preview set, preserving gallery links.
- `gallery.html`: self-contained interactive preview; open directly in a browser.
- `glb/*.glb`: individual GLB 2.0 models, centered with Y up and front toward −Z.
- `usdz/*.usdz`: native Apple preview models.
- `previews/contact-sheet.png`: all models at a glance, with individual PNGs alongside.
- `catalog.json`: titles, model keys, estimated dimensions, references, and asset paths.
- `../../Packages/AccessCore/Sources/AccessCore/Resources/photo-furniture.json`: canonical meshes used by the app, generated from the same Rust geometry.

Regenerate from the repository root with Python 3 and Cargo:

```sh
python3 scripts/export-photo-furniture.py
```

The exporter validates mesh coordinates, normals, triangle indices, and GLB buffer/accessor bounds before writing assets. No additional Python packages or internet resources are required for the GLB models and gallery.

With Blender installed, regenerate native previews and USDZ files, then refresh the gallery download links:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python-exit-code 1 --python scripts/render-photo-furniture.py -- --samples 16
python3 scripts/export-photo-furniture.py
```

The exporter also refreshes `photo-furniture.zip` once all native files and previews are present. Add `--resume` after `--samples 16` to reuse completed native files and previews. Native archive validation is recorded in `usdz/validation.json`.
