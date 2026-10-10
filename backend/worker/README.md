# InView OpenCV worker

Processes uploaded scans from the Rust backend and publishes a derived, replaceable analysis
(`PUT /scans/{id}/analysis`). Source captures are never modified. Everything stays in the scan's
shared ARKit frame (meters, Y up; the floor map is the X/Z plane, +Z down the image).

| Pass | Inputs | Output |
|------|--------|--------|
| Floor map | RoomPlan floors/walls/doors/objects, native ARKit mesh, LiDAR depth, camera track | walkable/obstacle raster (PNG), floor outline, free-standing obstacles, passages under 0.915 m |
| Doors | RoomPlan doors/openings + the obstacle raster | nominal vs measured clear width, 0.815 m door / 0.915 m opening minimum, 2.03 m headroom |
| Signs & text | RGB keyframes + depth samples under each detection | exit (red/green) and accessibility (blue) plate candidates, MSER text lines, 3D position; text via Tesseract only if installed |

Results are screening candidates, **not** verified accessible routes or ADA certification.
The pipeline is a set of auto-discovered stages exchanging named products; see
[PIPELINE.md](PIPELINE.md) for the architecture, contract, and rules for adding stages.

## Run

The repository path contains `:`, which breaks `uv run` (it cannot add `.venv/bin` to `PATH`).
Use the virtualenv's interpreter directly:

```sh
cd backend/worker
uv sync --python 3.12
.venv/bin/python -m inview_worker process <scan-id>       # one scan
.venv/bin/python -m inview_worker process --all [--force] # every unprocessed (or every) scan
.venv/bin/python -m inview_worker watch --interval 15     # poll for new uploads
.venv/bin/python -m pytest -q
scripts/e2e.sh 3790                                       # throwaway backend + every stage, then a report
```

`INVIEW_BACKEND_URL` defaults to `http://127.0.0.1:3000`; the token comes from `INVIEW_API_TOKEN`
or `backend/.secrets/api-token`. Use `--no-publish --out analysis.json` to inspect a result
without uploading it. Install `tesseract` (e.g. `brew install tesseract`) to add recognized text.
The Studio shows each scan's analysis under **OpenCV analysis**.

## Synthetic buildings and evaluation

`inview_worker/synthetic/building.py` generates seeded multi-room buildings as real iPhone-format
`.inviewscan.tar` packages plus a separate ground-truth JSON: a corridor with rooms on both sides,
doors of varied widths (some below the 0.815 m clear width, hinged leaves open 90°), a doorless
opening, a connecting door, furniture (RoomPlan objects, including a restroom's toilets and sink), a
sunken lobby reached by a two-riser stair and a ramp (1:10–1:14), and wall signs drawn with OpenCV
(room plates such as "214", "RESTROOM"/"TOILETTES" with pictograms, "EXIT"/"SALIDA", "ELEVATOR"/
"ASCENSOR", a ramp sign, directional arrows). Depth (with LiDAR-like noise and confidence) and
upright portrait JPEG keyframes are ray-cast against the same geometry; observations carry
GPS/heading samples around a known georeference, RoomPlan surfaces carry centimetre measurement
error, and native mesh anchors are included. Ground truth covers spaces and labels, door widths,
sign/text positions and strings, hazards, places, room adjacency, per-profile shortest paths
(wheelchair avoids stairs, doors under 0.815 m and ramps steeper than 1:12) and the georeference.

```sh
.venv/bin/python -m inview_worker.synthetic.building out.inviewscan.tar --seed 3   # + out.inviewscan.tar.truth.json
.venv/bin/python -m inview_worker evaluate --scenarios 3 [--seed N] [--out report.json] [--keep DIR]
```

`evaluate` runs every registered stage offline on each building and prints a metric table (footprint
IoU, door width MAE and pass/fail accuracy, sign/text localization error and OCR character error rate,
region/place/hazard recall and precision, nav-graph adjacency and reachability agreement, route length
ratio, georeference error). Products that the pipeline does not produce yet are listed as missing,
not scored as zero. Generated packages pass the backend's `POST /scan-packages` validation. The
generator assumes each environment sample's `heading_degrees` is the compass bearing of the camera's
viewing direction.
