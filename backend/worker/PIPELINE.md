# Navigation pipeline: architecture and product contract

The worker turns one uploaded scan into everything a person needs to navigate the space. It is a
set of independent **stages** that exchange named **products**. `inview_worker/contracts.py` is the
source of truth for names, shapes, and thresholds; this document explains the rules.

## Architecture

```
backend API ──gather()──▶ ScanInputs ─┐
package files (manifest, assets) ─────┼─▶ ScanContext ──runner──▶ stages (topological order)
                                      │                             │ products (json + data)
                                      └─────────────────────────────▼
                                         analysis document ──PUT /scans/{id}/analysis──▶ backend
                                                                    └─▶ publishers (e.g. graphs)
```

- **Stage** (`core/stage.py`): `name`, `requires` (must exist or the stage is skipped), `optional`
  (used when present; affects ordering only), `provides`, and `run(ctx) -> StageResult`.
- **Product**: `json` is published in the analysis; `data` stays in-process (rasters, graphs).
- **Discovery** (`core/registry.py`): every module in `inview_worker/stages/` and
  `inview_worker/publishers/` is imported automatically. Add a stage by adding a file with an
  `@register`-decorated `Stage` subclass; add a publisher with `@publisher`. Do not edit `core/`,
  `pipeline.py`, or `cli.py` to wire a stage in.
- **Runner** (`core/runner.py`): orders stages by their declared inputs, isolates failures (one stage's
  exception is recorded in `analysis.stages[name]` and never stops the others), rejects undeclared
  products, records timings, merges per-stage `summary[name]` and notices.
- **ScanContext** (`core/context.py`): `inputs` (RoomPlan surfaces/objects, mesh, depth points, frames
  with sensor-native u/v, camera positions), `manifest()`, `asset(name)` (any package file, e.g.
  `roomplan.json`, `camera-track.json`), `image(name)` (cached, read-only BGR), upstream
  `json(name)` / `data(name)`, and `config`.
- **Offline**: `synthetic.offline.context_from_archive(bytes)` builds a context from an
  `.inviewscan.tar` without a backend; `tests/conftest.py` exposes `synthetic_archive`/`synthetic_ctx`.

## Rules for stages

1. Pure helpers live in a package (`inview_worker/<pkg>/`); the stage module is a thin adapter.
2. Consume upstream products **optionally** whenever possible and degrade gracefully (a JSON-only
   upload has no keyframes or manifest; a demo scan has no mesh). Test with hand-built fixtures that
   follow this contract, not with another unit's code.
3. Deterministic output: stable IDs (derive from source IDs or sorted order), no randomness without a
   fixed seed, sorted lists.
4. Tests never use the network. Model downloads are mocked; real downloads are cached and checksummed.
5. Screening language only: never claim certified accessibility.

## Coordinates and units

Shared ARKit frame of the scan: meters, right-handed, +Y up. Map products use the X/Z plane
(`*_xz_m = [x, z]`, +Z points down in rendered images). 3D positions are `*_m = [x, y, z]`. Slopes are
rise/run. RGB keyframes are upright JPEGs rotated right from the sensor; convert pixels to the depth
samples' sensor-native u/v with `geometry.jpeg_to_sensor_uv`. Camera intrinsics in the manifest
describe the landscape sensor image, not the JPEG.

## Products

| Product | Producer | JSON shape |
|---|---|---|
| `floor_map` | `stages/floor_map.py` | grid, floor height, outlines, obstacles, narrow passages, PNG; `data`: `FloorMap` rasters (`floor`, `obstacle`, `walked`, `walkable`, `narrow`, `grid`) |
| `doors` | `stages/doors.py` | `[{id, kind, center_xz_m, span_xz_m, nominal_width_m, height_m, measured_clear_width_m, required_min_clear_width_m, meets_clear_width, meets_headroom, issues, method}]` |
| `signs` | `stages/signs.py` | `Sign` list (see contracts.py; current stage emits the earlier candidate shape until the signage unit lands) |
| `roomplan` | RoomPlan semantics | `RoomplanProduct` |
| `regions` | region segmentation | `Region` list |
| `height_map`, `hazards` | terrain | `data`: elevation raster aligned with `floor_map.grid`; `Hazard` list |
| `text` | OCR | `TextObservation` list |
| `places` | places | `Place` list (`access_point_kind` maps onto iOS `AccessPoint.Kind`) |
| `nav_graph` | navigation graph | backend `Graph` v1 JSON, `id = "<scan_id>-nav"`, bidirectional surface edges, extras only in `metadata` |
| `routes` | routing | `{profiles, routes: [Route]}` with `instructions` per language |
| `georef`, `geojson` | geo | `GeoReference`; GeoJSON FeatureCollection |

`PlaceCategory` and accessibility `Thresholds` (ADA 2010 references) are defined in `contracts.py`.

## Running

```sh
cd backend/worker && uv sync --python 3.12      # never `uv run` (the repo path contains ':')
.venv/bin/python -m pytest -q
scripts/e2e.sh 3790                              # real backend + API + all stages, then a report
.venv/bin/python -m inview_worker report out/*.analysis.json
```
