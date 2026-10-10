# InView OpenCV worker

Processes uploaded scans from the Rust backend and publishes a derived, replaceable analysis
(`PUT /scans/{id}/analysis`). Source captures are never modified. Everything stays in the scan's
shared ARKit frame (meters, Y up; the floor map is the X/Z plane, +Z down the image).

| Pass | Inputs | Output |
|------|--------|--------|
| Floor map | RoomPlan floors/walls/doors/objects, native ARKit mesh, LiDAR depth, camera track | walkable/obstacle raster (PNG), floor outline, free-standing obstacles, passages under 0.915 m |
| Doors | RoomPlan doors/openings + the obstacle raster | nominal vs measured clear width, 0.815 m door / 0.915 m opening minimum, 2.03 m headroom |
| Signs & text | RGB keyframes + depth samples under each detection (+ optional `floor_map`, `text`) | colored and neutral sign plates; procedurally rendered ISO 7001/7010-style pictograms (Hu moments, multi-scale NCC, AKAZE + homography); arrow direction mapped onto the floor plan; braille dot lattice; WCAG contrast; mounting height vs ADA 703.4.1; legibility (703.5.5); languages/scripts; category; 3D dedupe. `python -m inview_worker.signage.gallery` prints a confusion report over rendered signs |

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
