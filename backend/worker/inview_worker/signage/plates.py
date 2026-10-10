"""Sign plate and text-line candidates in an upright keyframe.

- Colored plates: HSV ranges for safety/wayfinding colors (exit red/green, accessibility/information
  blue), filled, near-rectangular, carrying a light or dark legend.
- Neutral plates: convex quadrilaterals (Canny + `approxPolyDP`) whose interior splits cleanly into a
  uniform background and a contrasting legend (white/black/grey wayfinding signs).
- Text lines: MSER character blobs joined horizontally.
- Optional Tesseract OCR when the binary is installed.
"""
from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass, field

import cv2
import numpy as np

PLATE_COLORS = {
    # name: (list of (H low, H high), min S, min V, legacy semantic hint)
    "red": ([(0, 10), (170, 180)], 120, 90, "exit_sign_candidate"),
    "green": ([(40, 85)], 100, 80, "exit_sign_candidate"),
    "blue": ([(95, 130)], 120, 70, "accessibility_sign_candidate"),
}
MAX_DETECTIONS = 25


@dataclass
class Detection:
    kind: str
    bbox: tuple[int, int, int, int]  # x, y, w, h in upright JPEG pixels
    score: float
    color: str | None = None
    text: str | None = None
    region: np.ndarray | None = field(default=None, repr=False)  # plate mask inside bbox (uint8)


def iou(a, b) -> float:
    ax2, ay2, bx2, by2 = a[0] + a[2], a[1] + a[3], b[0] + b[2], b[1] + b[3]
    w, h = max(0, min(ax2, bx2) - max(a[0], b[0])), max(0, min(ay2, by2) - max(a[1], b[1]))
    union = a[2] * a[3] + b[2] * b[3] - w * h
    return w * h / union if union else 0.0


def overlap_fraction(inner, outer) -> float:
    """Share of `inner`'s area that lies inside `outer`."""
    w = max(0, min(inner[0] + inner[2], outer[0] + outer[2]) - max(inner[0], outer[0]))
    h = max(0, min(inner[1] + inner[3], outer[1] + outer[3]) - max(inner[1], outer[1]))
    return w * h / max(inner[2] * inner[3], 1)


def _region(contour: np.ndarray, bbox) -> np.ndarray:
    x, y, w, h = bbox
    region = np.zeros((h, w), np.uint8)
    cv2.drawContours(region, [contour - np.array([x, y])], -1, 255, -1)
    # Shrink away from the plate edge so borders and anti-aliasing do not count as legend.
    k = max(1, int(round(0.03 * min(w, h))))
    return cv2.erode(region, np.ones((2 * k + 1, 2 * k + 1), np.uint8))


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
    return sorted(found, key=lambda d: (d.bbox[1], d.bbox[0]))


def color_plates(bgr: np.ndarray) -> list[Detection]:
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    height, width = hsv.shape[:2]
    found = []
    for color, (ranges, s_min, v_min, hint) in PLATE_COLORS.items():
        mask = np.zeros((height, width), np.uint8)
        for low, high in ranges:
            mask |= cv2.inRange(hsv, (low, s_min, v_min), (high, 255, 255))
        raw = mask.copy()
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
            region = _region(contour, (x, y, w, h))
            # A plate is mostly one solid color (busy textures only reach the mask after closing).
            if region.any() and (raw[y:y + h, x:x + w][region > 0] > 0).mean() < 0.4:
                continue
            # A sign carries a legend or pictogram: white/light or dark marks inside the plate.
            plate = hsv[y:y + h, x:x + w]
            legend = ((plate[..., 1] < 70) & (plate[..., 2] > 170)) | (plate[..., 2] < 60)
            if legend.mean() < 0.02:
                continue
            found.append(Detection(hint, (x, y, w, h), round(min(1.0, area / (0.02 * width * height)), 3), color,
                                   region=region))
    return found


def neutral_plates(bgr: np.ndarray, exclude: list[Detection] = ()) -> list[Detection]:
    """Uniform convex quadrilaterals with a contrasting legend (light or dark plates)."""
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    height, width = gray.shape
    edges = cv2.Canny(cv2.GaussianBlur(gray, (5, 5), 0), 40, 120)
    edges = cv2.dilate(edges, np.ones((3, 3), np.uint8))
    contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    found: list[Detection] = []
    for contour in sorted(contours, key=cv2.contourArea, reverse=True):
        area = cv2.contourArea(contour)
        if area < 0.004 * width * height or area > 0.5 * width * height:
            continue
        quad = cv2.approxPolyDP(contour, 0.03 * cv2.arcLength(contour, True), True)
        if len(quad) != 4 or not cv2.isContourConvex(quad):
            continue
        (_, _), (rw, rh), _ = cv2.minAreaRect(quad)
        if min(rw, rh) < 16 or max(rw, rh) / min(rw, rh) > 4:
            continue
        bbox = cv2.boundingRect(quad)
        if any(iou(bbox, d.bbox) > 0.3 or overlap_fraction(bbox, d.bbox) > 0.6 for d in (*exclude, *found)):
            continue
        x, y, w, h = bbox
        region = _region(quad, bbox)
        pixels = gray[y:y + h, x:x + w][region > 0]
        if len(pixels) < 100:
            continue
        threshold, _ = cv2.threshold(pixels.reshape(-1, 1), 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        light = pixels > threshold
        minority = min(light.mean(), 1 - light.mean())
        separation = abs(float(pixels[light].mean()) - float(pixels[~light].mean())) if 0 < light.mean() < 1 else 0.0
        background = pixels[light] if light.mean() >= 0.5 else pixels[~light]
        if not 0.03 <= minority <= 0.45 or separation < 45 or float(background.std()) > 22:
            continue
        found.append(Detection("sign_candidate", bbox, round(min(1.0, area / (0.02 * width * height)) * 0.8, 3),
                               "light" if np.median(background) > 127 else "dark", region=region))
    return found


def sign_plates(bgr: np.ndarray) -> list[Detection]:
    colored = color_plates(bgr)
    return colored + neutral_plates(bgr, colored)


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


def detect(bgr: np.ndarray, ocr: bool = True) -> list[Detection]:
    plates = sign_plates(bgr)
    texts = [t for t in text_regions(cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY))
             if not any(iou(t.bbox, p.bbox) > 0.5 or overlap_fraction(t.bbox, p.bbox) > 0.8 for p in plates)]
    detections = sorted(plates + texts, key=lambda d: (-d.score, d.bbox))[:MAX_DETECTIONS]
    if ocr:
        for detection in detections:
            detection.text = recognize(bgr, detection.bbox)
    return detections
