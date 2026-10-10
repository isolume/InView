"""OCR orchestration: choose engines (DNN → Tesseract → regions only), read images, build the product."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Callable

import cv2
import numpy as np

from ..geometry import matrix
from ..inputs import Frame
from . import models
from .detect import DbDetector, Detector, MserDetector, Region
from .imaging import rectify
from .language import detect_language, detect_script
from .observations import VISION_ASSET, Observation, fuse, parse_vision
from .placement import place
from .recognize import CrnnRecognizer, Reading, Recognizer, TesseractRecognizer

OCR_STILL_SUFFIX = ".ocr.jpg"
CJK_SCRIPTS = {"Hani", "Jpan", "Kore", "Kana", "Hang"}


@dataclass
class OcrConfig:
    recognizers: tuple[str, ...] = ("crnn_ch", "crnn_cn")   # keys of models.RECOGNIZERS
    min_confidence: float = 0.5
    max_regions: int = 60
    long_sides: tuple[int, ...] = (736, 1280)
    use_clahe: bool = True
    tesseract: bool = True
    fuse_iou: float = 0.3

    @classmethod
    def from_dict(cls, values: dict[str, Any] | None) -> "OcrConfig":
        values = dict(values or {})
        known = {k: values[k] for k in cls.__dataclass_fields__ if k in values}
        for key in ("recognizers", "long_sides"):
            if key in known:
                known[key] = tuple(known[key])
        return cls(**known)


@dataclass
class OcrEngine:
    detector: Detector
    recognizers: list[Recognizer]
    config: OcrConfig = field(default_factory=OcrConfig)
    notices: list[str] = field(default_factory=list)

    @property
    def engine_names(self) -> list[str]:
        return [getattr(r, "name", r.engine) for r in self.recognizers]

    @classmethod
    def build(cls, store: models.ModelStore, config: OcrConfig | None = None,
              tesseract: TesseractRecognizer | None = None) -> "OcrEngine":
        """Best available engine. Missing DNN models fall back to MSER + Tesseract, else regions only."""
        config = config or OcrConfig()
        notices = []
        detector_path = store.path("detector_db")
        detector: Detector
        if detector_path:
            detector = DbDetector(str(detector_path), config.long_sides, config.use_clahe)
        else:
            detector = MserDetector()
        recognizers: list[Recognizer] = []
        wanted = [key for key in config.recognizers if key in models.RECOGNIZERS]
        charset_path = store.path("crnn_charsets") if wanted else None
        charsets = models.parse_charsets(charset_path.read_text(encoding="utf-8")) if charset_path else {}
        for key in wanted:
            charset_name, grayscale = models.RECOGNIZERS[key]
            path = store.path(key) if charset_name in charsets else None
            if path:
                recognizers.append(CrnnRecognizer(str(path), charsets[charset_name], grayscale, key))
        missing = sorted(k for k in ["detector_db", *wanted] if k in store.errors)
        if missing:
            notices.append("OCR models unavailable (" + ", ".join(f"{k}: {store.errors[k]}" for k in missing)
                           + f"); set INVIEW_MODEL_DIR or allow downloads to {store.root}.")
        if not recognizers and config.tesseract:
            tesseract = tesseract or TesseractRecognizer()
            if tesseract.available:
                recognizers.append(tesseract)
        if not recognizers:
            notices.append("No text recognizer is available (OpenCV DNN models missing and Tesseract not "
                           "installed): text regions are reported without readings.")
        elif detector.name == "mser":
            notices.append("OpenCV DNN text detector unavailable: using the MSER fallback detector.")
        return cls(detector, recognizers, config, notices)

    def _choose(self, readings: list[Reading]) -> Reading | None:
        """Prefer a CJK reading from a CJK-capable model when it is nearly as confident; else the best."""
        usable = [r for r in readings if r.confidence >= self.config.min_confidence and re.search(r"\w", r.text)]
        if not usable:
            return None
        best = max(usable, key=lambda r: (r.confidence, len(r.text)))
        cjk = [r for r in usable if detect_script(r.text) in CJK_SCRIPTS]
        if cjk and detect_script(best.text) not in CJK_SCRIPTS:
            top = max(cjk, key=lambda r: r.confidence)
            if top.confidence >= best.confidence - 0.05:
                return top
        return best

    def read(self, bgr: np.ndarray) -> list[tuple[Region, Reading | None]]:
        """Detect text lines, rectify each quad, and recognise it. Without a recognizer every region
        is returned with `None`; with one, unreadable/low-confidence regions are dropped."""
        regions = self.detector.detect(bgr)[: self.config.max_regions]
        results = []
        for region in regions:
            if not self.recognizers:
                results.append((region, None))
                continue
            crop = rectify(bgr, region.quad)
            reading = self._choose([r for rec in self.recognizers if (r := rec.recognize(crop)) is not None])
            if reading is not None:
                results.append((region, reading))
        return results


@dataclass
class ImageJob:
    frame_id: str
    image_asset: str
    kind: str                     # keyframe | ocr_still


def _ocr_stills(observation: dict) -> list[str]:
    found = []
    for value in observation.values():
        candidates = value.values() if isinstance(value, dict) else [value]
        found += [c for c in candidates if isinstance(c, str) and c.endswith(OCR_STILL_SUFFIX)]
    return sorted(set(found))


def image_jobs(frames: list[Frame], manifest: dict | None) -> list[ImageJob]:
    """One image per frame: the high-resolution OCR still when the manifest lists one, else the keyframe.

    Stills are found on manifest observations (any field ending in `.ocr.jpg`) and in the asset list
    (`<frame>.ocr.jpg`, or the frame whose RGB asset shares the prefix).
    """
    stills: dict[str, str] = {}
    observations = [o for o in (manifest or {}).get("observations", []) if isinstance(o, dict) and o.get("id")]
    for observation in observations:
        for path in _ocr_stills(observation):
            stills.setdefault(str(observation["id"]), path)
    prefixes = {}
    for observation in observations:
        rgb = observation.get("rgb_asset")
        if isinstance(rgb, str):
            prefixes[rgb.split(".", 1)[0]] = str(observation["id"])
    for frame in frames:
        if frame.color_asset:
            prefixes.setdefault(frame.color_asset.split(".", 1)[0], frame.id)
    listed = set(stills.values())
    for asset in (manifest or {}).get("assets", []):
        path = asset.get("path") if isinstance(asset, dict) else None
        if isinstance(path, str) and path.endswith(OCR_STILL_SUFFIX) and path not in listed:
            stem = path[: -len(OCR_STILL_SUFFIX)]
            stills.setdefault(prefixes.get(stem, prefixes.get(stem.split(".", 1)[0], stem)), path)
    jobs, seen = [], set()
    for frame in frames:
        if frame.id in stills:
            jobs.append(ImageJob(frame.id, stills[frame.id], "ocr_still"))
        elif frame.color_asset:
            jobs.append(ImageJob(frame.id, frame.color_asset, "keyframe"))
        seen.add(frame.id)
    jobs += [ImageJob(fid, path, "ocr_still") for fid, path in sorted(stills.items()) if fid not in seen]
    return jobs


def _decode(data: bytes | None) -> np.ndarray | None:
    return cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR) if data else None


def camera_positions(manifest: dict | None) -> dict[str, np.ndarray]:
    cameras = {}
    for observation in (manifest or {}).get("observations", []):
        try:
            cameras[str(observation["id"])] = matrix(observation["map_from_camera"])[:3, 3]
        except (KeyError, TypeError, ValueError):
            continue
    return cameras


def to_json(observation: Observation, index: int, frame_points: np.ndarray | None,
            camera: np.ndarray | None) -> dict[str, Any]:
    width, height = observation.image_size
    script = detect_script(observation.text) if observation.text else None
    placement = place(observation.quad, frame_points, width, height, camera) if frame_points is not None else None
    bl, tl, tr, br = observation.quad
    entry: dict[str, Any] = {
        "id": f"text-{observation.frame_id}-{index:03d}",
        "text": observation.text,
        "confidence": round(float(observation.confidence), 4),
        "language": detect_language(observation.text, script, observation.languages) if observation.text else None,
        "script": script,
        "engine": observation.engine,
        "detector": observation.detector,
        "frame_id": observation.frame_id,
        "image_asset": observation.image_asset,
        "image_size_px": [int(width), int(height)],
        "bbox_px": observation.bbox_px,
        "quad_px": [[round(float(x), 1), round(float(y), 1)] for x, y in (tl, tr, br, bl)],
        "position_m": placement.position_m if placement else None,
        "normal_m": placement.normal_m if placement else None,
        "depth_samples": placement.samples if placement else 0,
        "readings": observation.readings,
    }
    if observation.languages:
        entry["languages"] = observation.languages
    return entry


def analyze(frames: list[Frame], manifest: dict | None, read_image: Callable[[str], np.ndarray | None],
            read_asset: Callable[[str], bytes | None], engine: OcrEngine,
            fallback_cameras: np.ndarray | None = None) -> tuple[list[dict], dict[str, Any], list[str]]:
    """Run OCR over every frame's best image, ingest Apple Vision readings, fuse, place in 3D."""
    notices = list(engine.notices)
    jobs = image_jobs(frames, manifest)
    detected: list[Observation] = []
    examined, sizes = {"keyframe": 0, "ocr_still": 0}, {}
    for job in jobs:
        # Stills are large and read once: decode them directly instead of through the image cache.
        image = read_image(job.image_asset) if job.kind == "keyframe" else _decode(read_asset(job.image_asset))
        if image is None:
            continue
        examined[job.kind] += 1
        height, width = image.shape[:2]
        sizes[job.image_asset] = (width, height)
        for region, reading in engine.read(image):
            if reading is None:
                detected.append(Observation(job.frame_id, job.image_asset, (width, height), region.quad, "",
                                            region.score, "opencv_mser" if region.detector == "mser" else "opencv_dnn",
                                            region.detector))
            else:
                detected.append(Observation(job.frame_id, job.image_asset, (width, height), region.quad, reading.text,
                                            reading.confidence, reading.engine, region.detector, reading.model))
    vision, skipped = parse_vision(read_asset(VISION_ASSET))
    if skipped:
        notices.append(f"Skipped {skipped} malformed Apple Vision text observation(s) in {VISION_ASSET}.")
    fused_list, fused = fuse(detected, vision, engine.config.fuse_iou)
    if not jobs and not vision:
        notices.append("No RGB keyframes, OCR stills or Apple Vision observations were available, so no text was read.")

    points = {frame.id: frame.points for frame in frames if len(frame.points)}
    cameras = camera_positions(manifest)
    fallback = None
    if fallback_cameras is not None and len(fallback_cameras):
        fallback = np.asarray(fallback_cameras, np.float64).reshape(-1, 3).mean(axis=0)
    ordered = sorted(fused_list, key=lambda o: (o.frame_id, round(float(o.quad[:, 1].min()), 1),
                                                round(float(o.quad[:, 0].min()), 1), o.engine, o.text))
    results, counters = [], {}
    for observation in ordered:
        index = counters.get(observation.frame_id, 0)
        counters[observation.frame_id] = index + 1
        results.append(to_json(observation, index, points.get(observation.frame_id),
                               cameras.get(observation.frame_id, fallback)))
    engines = sorted({reading["engine"] for item in results for reading in item["readings"]})
    summary = {
        "keyframes_examined": examined["keyframe"],
        "ocr_stills_examined": examined["ocr_still"],
        "detector": engine.detector.name,
        "recognizers": engine.engine_names,
        "observations": len(results),
        "with_text": sum(bool(item["text"]) for item in results),
        "placed_in_3d": sum(item["position_m"] is not None for item in results),
        "apple_vision_observations": len(vision),
        "fused_with_apple_vision": fused,
        "engines": engines,
        "scripts": sorted({item["script"] for item in results if item["script"]}),
        "languages": sorted({item["language"] for item in results if item["language"]}),
    }
    return results, summary, notices
