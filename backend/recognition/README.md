The worker runs YOLOE locally and retains one loaded model across frame requests.
It returns category confidence and conservative depth-pixel samples; Rust measures
and merges observations using the original depth and optimized camera poses.

Run `./recognition/setup.sh` from `backend/` once. It uses Python 3.12+ in
`recognition/.venv`, installs pinned dependencies, downloads the public
`yoloe-26s-seg.pt` checkpoint/text encoder, caches catalog prompts, and warms
inference on a blank synthetic image. Runtime requests use local files only.
The setup can take several minutes and requires a few GB of disk space.

Launch `recognition/.venv/bin/python -u recognition/worker.py` and send one JSON
object per stdin line:

```json
{"request_id":"frame-1","color_jpeg":"<base64 JPEG>","depth_width":256,"depth_height":192}
```

Each stdout line contains the same `request_id` and either `detections` or `error`.
Startup failures additionally return `fatal: true`; ordinary frame errors remain
recoverable within the same persistent process.
A detection has `category`, `score`, and `depth_indices`. Indices are row-major in
the supplied depth grid, unique and sorted; score is at least 0.45. At most 16
detections and 2048 pixels per detection are returned. Masks use sensor-native
JPEG orientation and normalized pixel centers, with one depth-pixel erosion to
reduce background contamination. Errors do not discard the loaded worker.
An optional `image_rotation_degrees` value (clockwise 0, 90, 180, or 270; default
0) turns the RGB image upright for inference. Mask coordinates are mapped back to
the original sensor grid before depth sampling, preserving calibration. EXIF
orientation is ignored. Runtime network access and library analytics are disabled.

`INVIEW_RECOGNITION_SETUP_PYTHON` chooses the setup interpreter.
`INVIEW_RECOGNITION_DEVICE` selects `cpu` (default), `mps`, or a CUDA device.
`INVIEW_RECOGNITION_WEIGHTS` selects a local text-prompt YOLOE segmentation
checkpoint; run setup again after changing it.
`INVIEW_RECOGNITION_CACHE` relocates the ignored model/configuration cache.
Dependencies, cache, prompts, and diagnostic logs must not be committed.

Run `recognition/.venv/bin/python -m unittest discover -s recognition/tests -v`.
The mask/protocol regressions also run with a standard Python interpreter without
Torch; the JPEG orientation regression additionally uses Pillow and NumPy.
After setup, prefix the test command with `INVIEW_RECOGNITION_SMOKE=1` to exercise
the real persistent model on synthetic JPEGs, including error recovery and rotation.

Model/API reference: [Ultralytics YOLOE](https://docs.ultralytics.com/models/yoloe).
Ultralytics distributes this stack under its
[AGPL-3.0 or enterprise licensing options](https://www.ultralytics.com/license).
