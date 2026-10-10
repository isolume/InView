"""Sign and text candidates in RGB keyframes, placed in 3D with calibrated depth samples.

OpenCV finds colored sign plates (exit red/green, accessibility blue) and text-like MSER
character lines. Recognition uses Tesseract only when it is installed; otherwise regions are
reported without text. Candidates need human or model verification before becoming places.
"""
from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass
from typing import Callable

import cv2
import numpy as np

from .geometry import jpeg_to_sensor_uv
from .inputs import Frame

PLATE_COLORS = {
    # name: (list of (H low, H high), min S, min V, semantic hint)
    "red": ([(0, 10), (170, 180)], 120, 90, "exit_sign_candidate"),
    "green": ([(40, 85)], 100, 80, "exit_sign_candidate"),
    "blue": ([(95, 130)], 120, 70, "accessibility_sign_candidate"),
}
MERGE_DISTANCE_M = 0.6


@dataclass
class Detection:
    kind: str
    bbox: tuple[int, int, int, int]  # x, y, w, h in upright JPEG pixels
    score: float
    color: str | None = None
    text: str | None = None


def _iou(a, b) -> float:
    ax2, ay2, bx2, by2 = a[0] + a[2], a[1] + a[3], b[0] + b[2], b[1] + b[3]
    w, h = max(0, min(ax2, bx2) - max(a[0], b[0])), max(0, min(ay2, by2) - max(a[1], b[1]))
    union = a[2] * a[3] + b[2] * b[3] - w * h
    return w * h / union if union else 0.0


def text_regions(gray: np.ndarray) -> list[Detection]:
    height, width = gray.shape
    mser = cv2.MSER_create(5, 30, int(0.02 * width * height))
    _, boxes = mser.detectRegions(gray)
    chars = [b for b in boxes if 0.008 * height <= b[3] <= 0.15 * height and 0.1 <= b[2] / b[3] <= 2.5]
    if len(chars) < 3:
        return []
    mask = np.zeros_like(gray)
    for x, y, w, h in chars:
        mask[y:y + h, x:x + w] = 255
    char_height = int(np.median([b[3] for b in chars]))
    joined = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_RECT, (max(3, int(0.8 * char_height)), 1)))
    contours, _ = cv2.findContours(joined, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    centers = np.array([[x + w / 2, y + h / 2] for x, y, w, h in chars])
    found = []
    for contour in contours:
        x, y, w, h = cv2.boundingRect(contour)
        inside = ((centers[:, 0] >= x) & (centers[:, 0] <= x + w) & (centers[:, 1] >= y) & (centers[:, 1] <= y + h)).sum()
        if inside < 3 or w < 1.5 * h or h > 0.2 * height:
            continue
        contrast = float(gray[y:y + h, x:x + w].std())
        if contrast < 20:
            continue
        found.append(Detection("text_region", (x, y, w, h), round(min(1.0, inside / 10) * min(1.0, contrast / 64), 3)))
    return found


def sign_plates(bgr: np.ndarray) -> list[Detection]:
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    height, width = hsv.shape[:2]
    found = []
    for color, (ranges, s_min, v_min, hint) in PLATE_COLORS.items():
        mask = np.zeros((height, width), np.uint8)
        for low, high in ranges:
            mask |= cv2.inRange(hsv, (low, s_min, v_min), (high, 255, 255))
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        for contour in contours:
            area = cv2.contourArea(contour)
            if area < 0.002 * width * height:
                continue
            (_, _), (rw, rh), _ = cv2.minAreaRect(contour)
            if min(rw, rh) == 0 or area / (rw * rh) < 0.7 or max(rw, rh) / min(rw, rh) > 4:
                continue
            x, y, w, h = cv2.boundingRect(contour)
            # A sign carries a legend or pictogram: white/light or dark marks inside the plate.
            plate = hsv[y:y + h, x:x + w]
            legend = ((plate[..., 1] < 70) & (plate[..., 2] > 170)) | (plate[..., 2] < 60)
            if legend.mean() < 0.02:
                continue
            found.append(Detection(hint, (x, y, w, h), round(min(1.0, area / (0.02 * width * height)), 3), color))
    return found


def recognize(bgr: np.ndarray, bbox) -> str | None:
    executable = shutil.which("tesseract")
    if not executable:
        return None
    x, y, w, h = bbox
    crop = cv2.cvtColor(bgr[max(0, y - 4):y + h + 4, max(0, x - 4):x + w + 4], cv2.COLOR_BGR2GRAY)
    crop = cv2.resize(crop, None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)
    ok, png = cv2.imencode(".png", crop)
    if not ok:
        return None
    try:
        output = subprocess.run([executable, "stdin", "stdout", "--psm", "7"], input=png.tobytes(),
                                capture_output=True, timeout=15, check=False).stdout.decode(errors="ignore")
    except (OSError, subprocess.TimeoutExpired):
        return None
    text = " ".join(output.split())
    return text if sum(c.isalnum() for c in text) >= 2 else None


def detect(bgr: np.ndarray) -> list[Detection]:
    plates = sign_plates(bgr)
    texts = [t for t in text_regions(cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY))
             if not any(_iou(t.bbox, p.bbox) > 0.5 for p in plates)]
    detections = sorted(plates + texts, key=lambda d: d.score, reverse=True)[:25]
    for detection in detections:
        detection.text = recognize(bgr, detection.bbox)
    return detections


def locate(detection: Detection, frame: Frame, width: int, height: int) -> list[float] | None:
    """Median depth position of the samples under the detection's box (sensor-native u/v)."""
    if not len(frame.points):
        return None
    x, y, w, h = detection.bbox
    u0, v1 = jpeg_to_sensor_uv(x, y, width, height)
    u1, v0 = jpeg_to_sensor_uv(x + w, y + h, width, height)
    u, v = frame.points[:, 3], frame.points[:, 4]
    inside = (u >= u0) & (u <= u1) & (v >= v0) & (v <= v1)
    if not inside.any():
        cu, cv = jpeg_to_sensor_uv(x + w / 2, y + h / 2, width, height)
        distance = np.hypot(u - cu, v - cv)
        if distance.min() > 0.03:
            return None
        inside = distance == distance.min()
    return [round(float(c), 3) for c in np.median(frame.points[inside, :3], axis=0)]


def analyze(frames: list[Frame], read_image: Callable[[str], np.ndarray | None]) -> tuple[list[dict], int]:
    """Returns merged candidates and the number of keyframes examined."""
    candidates, examined = [], 0
    for frame in frames:
        if not frame.color_asset:
            continue
        image = read_image(frame.color_asset)
        if image is None:
            continue
        examined += 1
        height, width = image.shape[:2]
        for detection in detect(image):
            candidates.append({
                "kind": detection.kind, "color": detection.color, "text": detection.text,
                "score": detection.score, "position_m": locate(detection, frame, width, height),
                "observations": [{"frame_id": frame.id, "color_asset": frame.color_asset,
                                  "bbox_xywh_px": list(map(int, detection.bbox)), "image_size_px": [width, height]}],
            })
    merged: list[dict] = []
    for candidate in sorted(candidates, key=lambda c: c["score"], reverse=True):
        twin = next((m for m in merged if m["kind"] == candidate["kind"] and m["position_m"] and candidate["position_m"]
                     and np.linalg.norm(np.subtract(m["position_m"], candidate["position_m"])) < MERGE_DISTANCE_M), None)
        if twin is None:
            merged.append(candidate)
            continue
        twin["observations"] += candidate["observations"]
        if candidate["text"] and len(candidate["text"]) > len(twin["text"] or ""):
            twin["text"] = candidate["text"]
    for item in merged:
        item["observation_count"] = len(item["observations"])
    return merged, examined
