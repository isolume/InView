# InView OpenCV worker

Processes uploaded scans from the Rust backend and publishes a derived, replaceable analysis
(`PUT /scans/{id}/analysis`). Source captures are never modified. Everything stays in the scan's
shared ARKit frame (meters, Y up; the floor map is the X/Z plane, +Z down the image).

| Pass | Inputs | Output |
|------|--------|--------|
| Floor map | RoomPlan floors/walls/doors/objects, native ARKit mesh, LiDAR depth, camera track | walkable/obstacle raster (PNG), floor outline, free-standing obstacles, passages under 0.915 m |
| Doors | RoomPlan doors/openings + the obstacle raster | nominal vs measured clear width, 0.815 m door / 0.915 m opening minimum, 2.03 m headroom |
| Signs & text | RGB keyframes + depth samples under each detection | exit (red/green) and accessibility (blue) plate candidates, MSER text lines, 3D position; text via Tesseract only if installed |
| Text (OCR) | RGB keyframes / OCR stills, Apple Vision `text-observations.json`, depth samples | OpenCV DNN text readings fused with Apple Vision, script/language, 3D position and surface normal |

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

## OCR models (`text` stage)

The `text` stage (`inview_worker/ocr/`) reads every frame's best image (the high-resolution
`*.ocr.jpg` still when the manifest lists one, else the keyframe) with OpenCV DNN: the PP-OCRv3
DB text detector (multi-scale + CLAHE, rotated NMS) and CRNN-CTC recognizers on
perspective-rectified line crops. It fuses the result with Apple Vision readings from
`text-observations.json` when the package has them, and places each reading in 3D (median depth
under the box, SVD plane normal).

| Model | Use | Size |
|---|---|---|
| `text_detection_en_ppocrv3_2023may.onnx` | DB text-line detector | 2.4 MB |
| `text_recognition_CRNN_CH_2021sep.onnx` | Latin digits/letters/symbols, case-sensitive (default) | 65 MB |
| `text_recognition_CRNN_CN_2021nov.onnx` | 3944 Chinese + Latin characters (default) | 73 MB |
| `text_recognition_CRNN_EN_2021sep.onnx` | lowercase alphanumerics, lighter (opt-in) | 34 MB |
| `crnn.py` (saved as `text_recognition_crnn_reference.py`) | CRNN charsets | 19 KB |

Files are downloaded on first use from the OpenCV-zoo Hugging Face repositories at pinned commits,
checked against pinned SHA-256 checksums (`ocr/models.py`), and written atomically into
`INVIEW_MODEL_DIR` (default `~/.cache/inview-worker/models`). For offline machines, copy the files
there in advance. `INVIEW_MODEL_DOWNLOAD=0` disables downloads; under pytest they are disabled
unless `INVIEW_MODEL_DOWNLOAD=1`. Without the models the stage falls back to MSER detection plus
Tesseract (if installed), and otherwise reports text regions without readings, with a notice.
Per-scan overrides go in `ctx.config["ocr"]` (`recognizers`, `min_confidence`, `long_sides`,
`model_dir`, `download`, ...; see `OcrConfig`).
