"""Read one sign plate: legend split, pictograms, arrows, text lines and braille."""
from __future__ import annotations

from dataclasses import dataclass, field, replace

import cv2
import numpy as np

from . import arrows as arrow_mod
from . import braille as braille_mod
from . import legend as legend_mod
from . import pictograms
from .plates import Detection

PICTOGRAM_ACCEPT = 0.74
PICTOGRAM_MARGIN = 0.03
# Templates that share a meaning (all restroom figures) only need to beat each other narrowly.
FAMILIES = ({"man", "woman", "all_gender"},)


def _family(name: str) -> frozenset:
    return next((frozenset(f) for f in FAMILIES if name in f), frozenset({name}))


@dataclass
class Reading:
    contrast_ratio: float | None = None
    legend_bgr: tuple[int, int, int] | None = None
    background_bgr: tuple[int, int, int] | None = None
    polarity: str | None = None
    pictograms: list[dict] = field(default_factory=list)   # {name, score, bbox_px, mirrored, ...}
    arrows: list[dict] = field(default_factory=list)       # {image_direction, angle_deg, direction_px, bbox_px, score}
    text_lines: list[dict] = field(default_factory=list)   # {bbox_px, char_height_px, characters}
    braille: dict | None = None

    @property
    def has_content(self) -> bool:
        return bool(self.pictograms or self.arrows or self.text_lines or self.braille)


def _offset(bbox, dx: int, dy: int) -> list[int]:
    return [int(bbox[0] + dx), int(bbox[1] + dy), int(bbox[2]), int(bbox[3])]


def _mask_of(labels: np.ndarray, parts) -> tuple[np.ndarray, tuple[int, int, int, int]]:
    x, y, w, h = legend_mod.union_bbox(p.bbox for p in parts)
    sub = labels[y:y + h, x:x + w]
    mask = np.isin(sub, [p.label for p in parts]).astype(np.uint8) * 255
    return mask, (x, y, w, h)


def _best_pictogram(mask: np.ndarray):
    matches = pictograms.classify(mask)
    if not matches:
        return None
    best = matches[0]
    family = _family(best.name)
    rival = next((m.score for m in matches[1:] if m.name not in family), 0.0)
    sibling = next((m.score for m in matches[1:] if m.name in family), 0.0)
    if best.score < PICTOGRAM_ACCEPT or best.score - rival < PICTOGRAM_MARGIN:
        return None
    if best.name in pictograms.RESTROOM_FIGURES:
        figure = pictograms.restroom_figure(mask)
        if figure is not None:
            return replace(best, name=figure)
    if best.score - sibling < 0.005:
        return None
    return best


def _text_lines(parts: list[legend_mod.Component], plate_min: int) -> list[list[legend_mod.Component]]:
    chars = [p for p in parts if p.bbox[3] >= max(6, 0.06 * plate_min) and 0.08 <= p.bbox[2] / p.bbox[3] <= 2.5]
    parent = list(range(len(chars)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, a in enumerate(chars):
        for j in range(i + 1, len(chars)):
            b = chars[j]
            ha, hb = a.bbox[3], b.bbox[3]
            overlap = min(a.y2, b.y2) - max(a.bbox[1], b.bbox[1])
            gap = max(a.bbox[0], b.bbox[0]) - min(a.x2, b.x2)
            if overlap >= 0.5 * min(ha, hb) and 0.5 <= ha / hb <= 2.0 and gap <= 1.0 * max(ha, hb):
                parent[find(i)] = find(j)
    lines: dict[int, list] = {}
    for i, c in enumerate(chars):
        lines.setdefault(find(i), []).append(c)
    return sorted((sorted(line, key=lambda c: c.bbox[0]) for line in lines.values() if len(line) >= 2),
                  key=lambda line: (min(c.bbox[1] for c in line), min(c.bbox[0] for c in line)))


def read(bgr: np.ndarray, detection: Detection) -> Reading:
    x, y, w, h = detection.bbox
    crop = bgr[y:y + h, x:x + w]
    reading = Reading()
    if crop.size == 0 or min(w, h) < 12:
        return reading
    region = detection.region if detection.region is not None and detection.region.shape == crop.shape[:2] else None
    legend = legend_mod.split(crop, region)
    if legend is None:
        return reading
    reading.contrast_ratio, reading.polarity = legend.contrast_ratio, legend.polarity
    reading.legend_bgr, reading.background_bgr = legend.legend_bgr, legend.background_bgr
    plate_min = min(w, h)
    labels, parts = legend_mod.components(legend.mask, max(6, int(0.0008 * w * h)))
    # Drop frame-like borders and slivers of the plate edge / surrounding wall: legend glyphs sit
    # inside the plate and do not touch the boundary of the (eroded) plate region.
    inside = region if region is not None else np.full((h, w), 255, np.uint8)
    band = cv2.subtract(inside, cv2.erode(inside, np.ones((3, 3), np.uint8)))
    band[[0, -1], :], band[:, [0, -1]] = 255, 255
    touching = set(np.unique(labels[band > 0]).tolist())
    parts = [p for p in parts if p.label not in touching and not (p.bbox[2] > 0.9 * w and p.bbox[3] > 0.9 * h)]

    gray = cv2.cvtColor(np.ascontiguousarray(crop), cv2.COLOR_BGR2GRAY)
    reading.braille = braille_mod.detect(gray)
    if reading.braille:
        bx, by, bw, bh = reading.braille["bbox_px"]
        parts = [p for p in parts if not (bx <= p.centroid[0] <= bx + bw and by <= p.centroid[1] <= by + bh)]
        reading.braille["bbox_px"] = _offset(reading.braille["bbox_px"], x, y)

    remaining = []
    for part in parts:
        if max(part.bbox[2], part.bbox[3]) >= max(20, 0.15 * plate_min):
            mask = (labels[part.bbox[1]:part.y2, part.bbox[0]:part.x2] == part.label).astype(np.uint8) * 255
            found = arrow_mod.detect(mask)
            if found is not None:
                reading.arrows.append({"image_direction": found.name, "angle_deg": found.angle_deg,
                                       "direction_px": list(found.direction_px), "score": found.score,
                                       "bbox_px": _offset(part.bbox, x, y)})
                continue
        remaining.append(part)

    used: set[int] = set()
    for group_parts in sorted(legend_mod.group(remaining), key=lambda g: -sum(p.area for p in g)):
        gx, gy, gw, gh = legend_mod.union_bbox(p.bbox for p in group_parts)
        if max(gw, gh) < max(16, 0.28 * plate_min):
            continue
        candidates = [group_parts]
        total = sum(p.area for p in group_parts)
        if len(group_parts) > 1:
            candidates += [[p] for p in group_parts if p.area >= 0.3 * total]
        best, best_parts = None, None
        for parts_set in candidates:
            mask, _ = _mask_of(labels, parts_set)
            match = _best_pictogram(mask)
            if match is not None and (best is None or match.score > best.score):
                best, best_parts = match, parts_set
        if best is None:
            continue
        _, bbox = _mask_of(labels, best_parts)
        used.update(p.label for p in best_parts)
        reading.pictograms.append({"name": best.name, "score": best.score, "mirrored": best.mirrored,
                                   "bbox_px": _offset(bbox, x, y),
                                   "method": {"ncc": best.ncc, "hu_similarity": best.hu, "akaze_inliers": best.features}})

    leftovers = [p for p in remaining if p.label not in used]
    for line in _text_lines(leftovers, plate_min):
        heights = [c.bbox[3] for c in line]
        reading.text_lines.append({"bbox_px": _offset(legend_mod.union_bbox(c.bbox for c in line), x, y),
                                   "char_height_px": float(np.median(heights)), "characters": len(line)})
    # Information "i" or a lone letter shaped like a template inside a word is text, not a pictogram.
    for pictogram in list(reading.pictograms):
        if pictogram["name"] in {"information", "first_aid"} and any(
                _inline(pictogram["bbox_px"], line["bbox_px"]) for line in reading.text_lines):
            reading.pictograms.remove(pictogram)
    reading.pictograms.sort(key=lambda p: (p["bbox_px"][0], p["bbox_px"][1]))
    reading.arrows.sort(key=lambda a: (a["bbox_px"][0], a["bbox_px"][1]))
    return reading


def _inline(box, line) -> bool:
    overlap = min(box[1] + box[3], line[1] + line[3]) - max(box[1], line[1])
    gap = max(box[0], line[0]) - min(box[0] + box[2], line[0] + line[2])
    return overlap > 0.6 * min(box[3], line[3]) and gap < 0.5 * line[3] and 0.6 < box[3] / max(line[3], 1) < 1.5
