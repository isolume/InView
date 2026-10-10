#!/usr/bin/env python3
"""Persistent local YOLOE segmentation worker; stdout is JSON-lines protocol only."""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import sys

from core import (MAX_COLOR_PIXELS, MAX_REQUEST_BYTES, MINIMUM_SCORE, PROMPTS,
                  decode_request, detections_from_masks)

BASE = Path(__file__).resolve().parent
DEFAULT_CACHE = BASE / "cache"
DEFAULT_MODEL = "yoloe-26s-seg.pt"


def deny_runtime_network(event, _args):
    if event in {"socket.connect", "socket.getaddrinfo", "socket.gethostbyname",
                 "socket.gethostbyaddr"}:
        raise OSError("Recognition runtime network access is disabled.")


def configure_environment(cache, setup=False):
    cache.mkdir(parents=True, exist_ok=True)
    for name, subdir in (("YOLO_CONFIG_DIR", "ultralytics"), ("TORCH_HOME", "torch"),
                         ("HF_HOME", "huggingface"), ("MPLCONFIGDIR", "matplotlib"),
                         ("XDG_CACHE_HOME", "xdg")):
        os.environ[name] = str(cache / subdir)
    os.environ["YOLO_AUTOINSTALL"] = "false"
    os.environ["YOLO_VERBOSE"] = "false"
    os.environ["DO_NOT_TRACK"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    if not setup:
        os.environ["YOLO_OFFLINE"] = "true"
        os.environ["HF_HUB_OFFLINE"] = "1"
        sys.addaudithook(deny_runtime_network)
    # Ultralytics' text encoder download uses the working directory.
    os.chdir(cache)


def load_sensor_jpeg(jpeg):
    import numpy as np
    from PIL import Image

    try:
        with Image.open(io.BytesIO(jpeg)) as image:
            if image.format != "JPEG" or image.width * image.height > MAX_COLOR_PIXELS:
                raise ValueError("Invalid recognition JPEG dimensions.")
            # Do not use exif_transpose, OpenCV's automatic orientation, or pass a
            # PIL image to YOLO (its loader transposes EXIF). NumPy BGR stays native.
            rgb = np.asarray(image.convert("RGB"))
            return np.ascontiguousarray(rgb[:, :, ::-1])
    except ValueError:
        raise
    except Exception:
        raise ValueError("Unable to decode recognition JPEG.") from None


class Recognizer:
    def __init__(self, cache, weights, device="cpu", setup=False):
        configure_environment(cache, setup)
        if not setup and not weights.is_file():
            raise ValueError("Recognition weights are missing; run recognition/setup.sh.")
        from ultralytics import YOLOE, settings
        from ultralytics.utils.torch_utils import select_device

        settings.update({"sync": False, "weights_dir": str(cache)})
        # Reject unavailable/malformed devices during startup, so the service
        # does not retry a permanent configuration error for every scan frame.
        self.device = select_device(device, verbose=False)
        self.model = YOLOE(str(weights))
        # The profile name binds prompts and checkpoint bytes; changing either
        # requires an explicit setup run instead of silently reusing stale labels.
        digest = hashlib.sha256()
        with weights.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        digest.update(json.dumps(PROMPTS).encode())
        profile = cache / ("catalog-" + digest.hexdigest()[:24] + ".npz")
        if profile.is_file():
            self.model.load_prompt_embeddings(profile)
        elif setup:
            self.model.set_classes([prompt for prompt, _ in PROMPTS])
            self.model.save_prompt_embeddings(profile)
        else:
            raise ValueError("Recognition prompts are missing; run recognition/setup.sh.")
        names = self.model.names
        names = list(names.values()) if isinstance(names, dict) else list(names)
        if names != [prompt for prompt, _ in PROMPTS]:
            raise ValueError("Recognition prompt profile does not match the catalog.")

    def predict(self, jpeg, depth_width, depth_height, image_rotation_degrees=0):
        import numpy as np
        image = load_sensor_jpeg(jpeg)
        if image_rotation_degrees:
            image = np.ascontiguousarray(np.rot90(image, -(image_rotation_degrees // 90)))
        results = self.model.predict(image, device=self.device, conf=MINIMUM_SCORE,
                                     max_det=16, retina_masks=True, imgsz=640,
                                     verbose=False, save=False, stream=False)
        predictions = []
        result = results[0]
        if result.masks is None or result.boxes is None:
            return []
        masks = result.masks.data.cpu().numpy()
        classes = result.boxes.cls.cpu().tolist()
        scores = result.boxes.conf.cpu().tolist()
        if masks.shape[1:] != image.shape[:2]:
            raise ValueError("Recognition masks do not match sensor image dimensions.")
        if len(masks) != len(classes) or len(masks) != len(scores):
            raise ValueError("Recognition masks do not match detections.")
        for class_id, score, mask in zip(classes, scores, masks):
            predictions.append((int(class_id), score, mask))
        return detections_from_masks(predictions, depth_width, depth_height, image_rotation_degrees)

    def warmup(self):
        import numpy as np
        self.model.predict(np.zeros((640, 640, 3), dtype=np.uint8), device=self.device,
                           retina_masks=True, conf=MINIMUM_SCORE, max_det=16,
                           verbose=False, save=False)


def serve(recognizer, source, output, startup_error=None):
    """A bad frame returns an error without discarding the loaded model/process."""
    while True:
        line = source.readline(MAX_REQUEST_BYTES + 1)
        if not line:
            return
        request_id = ""
        try:
            if len(line) > MAX_REQUEST_BYTES:
                # Drain just this oversized request, preserving framing for the next.
                while line and not line.endswith("\n"):
                    line = source.readline(MAX_REQUEST_BYTES + 1)
                raise ValueError("Recognition request exceeds the frame size limit.")
            value = json.loads(line)
            if isinstance(value, dict) and isinstance(value.get("request_id"), str):
                request_id = value["request_id"][:256]
            request_id, jpeg, width, height, rotation = decode_request(value)
            if startup_error:
                raise ValueError(startup_error)
            try:
                detections = recognizer.predict(jpeg, width, height, rotation)
            except Exception:
                # Library errors can contain source bytes or local paths; expose
                # only our generic error while keeping the persistent worker alive.
                raise RuntimeError("Inference failed.") from None
            response = {"request_id": request_id, "detections": detections}
        except (ValueError, json.JSONDecodeError) as error:
            response = {"request_id": request_id, "error": str(error)}
        except Exception:
            response = {"request_id": request_id, "error": "Local recognition inference failed."}
            print("Recognition inference failed; frame skipped.", file=sys.stderr, flush=True)
        if startup_error:
            response["fatal"] = True
        output.write(json.dumps(response, separators=(",", ":"), allow_nan=False) + "\n")
        output.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--setup", action="store_true", help="Download public weights and warm up.")
    args = parser.parse_args()
    cache = Path(os.environ.get("INVIEW_RECOGNITION_CACHE", DEFAULT_CACHE)).resolve()
    weights = Path(os.environ.get("INVIEW_RECOGNITION_WEIGHTS", cache / DEFAULT_MODEL)).resolve()
    device = os.environ.get("INVIEW_RECOGNITION_DEVICE", "cpu")
    # Reserve the original stdout exclusively for the protocol. Redirect even
    # native library stdout/third-party loggers before importing inference code.
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    with contextlib.redirect_stdout(sys.stderr):
        try:
            recognizer = Recognizer(cache, weights, device, setup=args.setup)
            if args.setup:
                recognizer.warmup()
                print("Local recognition weights and catalog prompts are ready.", file=sys.stderr)
                return 0
        except Exception:
            message = "Local recognition is unavailable; run recognition/setup.sh and check the configured device."
            print(message, file=sys.stderr, flush=True)
            if args.setup:
                return 1
            serve(None, sys.stdin, protocol, startup_error=message)
            return 0
        serve(recognizer, sys.stdin, protocol)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
