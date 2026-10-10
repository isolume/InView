"""OCR for wayfinding: OpenCV DNN text detection/recognition, Apple Vision fusion, 3D placement.

- `models`: pinned, checksummed OpenCV-zoo model downloads into a local cache.
- `detect` / `recognize`: DB text detector and CRNN recognizers (MSER / Tesseract fallbacks).
- `imaging`: CLAHE, denoising, quad ordering and perspective rectification, line splitting.
- `observations`: Apple Vision ingest and IoU fusion; `placement`: depth position + plane normal.
- `engine`: orchestration used by `stages/text.py`.
"""
from .engine import OcrConfig, OcrEngine, analyze, image_jobs
from .models import MODELS, ModelStore

__all__ = ["MODELS", "ModelStore", "OcrConfig", "OcrEngine", "analyze", "image_jobs"]
