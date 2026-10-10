"""Procedurally rendered ISO 7001 / ISO 7010 / ADA-style pictograms and a shape matcher.

Templates are drawn with OpenCV primitives at import time (no binary assets) as binary masks on a
128 px canvas, symbol = 255. They are simplified silhouettes of the public-information symbols, not
reproductions of any specific artwork. `classify` compares a candidate legend mask against every
template with three complementary OpenCV measures:

- multi-scale normalized cross-correlation (`cv2.matchTemplate`, TM_CCOEFF_NORMED) of the
  aspect-preserving normalized silhouettes,
- Hu-moment shape distance (`cv2.matchShapes`), insensitive to scale and small rotations,
- AKAZE binary features + RANSAC homography inliers (`cv2.AKAZE_create`, `cv2.findHomography`) for
  structured pictograms large enough to carry corners.
"""
from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache

import cv2
import numpy as np

SIZE = 128
NORM = 64          # side of the normalized comparison canvas
MARGIN = 6         # empty border inside the normalized canvas (lets matchTemplate shift)


def _canvas() -> np.ndarray:
    return np.zeros((SIZE, SIZE), np.uint8)


def _poly(canvas: np.ndarray, points, closed=False, thickness=0) -> None:
    pts = np.array(points, np.int32).reshape(-1, 1, 2)
    if thickness:
        cv2.polylines(canvas, [pts], closed, 255, thickness, cv2.LINE_AA)
    else:
        cv2.fillPoly(canvas, [pts], 255, cv2.LINE_AA)


def man() -> np.ndarray:
    c = _canvas()
    cv2.circle(c, (64, 17), 12, 255, -1, cv2.LINE_AA)
    _poly(c, [(46, 34), (82, 34), (88, 40), (88, 76), (80, 76), (80, 50), (78, 50), (78, 120), (67, 120),
              (67, 82), (61, 82), (61, 120), (50, 120), (50, 50), (48, 50), (48, 76), (40, 76), (40, 40)])
    return c


def woman() -> np.ndarray:
    c = _canvas()
    cv2.circle(c, (64, 17), 12, 255, -1, cv2.LINE_AA)
    _poly(c, [(50, 34), (78, 34), (86, 40), (92, 70), (84, 72), (80, 52), (90, 92), (74, 92), (74, 120), (66, 120),
              (66, 92), (62, 92), (62, 120), (54, 120), (54, 92), (38, 92), (48, 52), (44, 72), (36, 70), (42, 40)])
    return c


def all_gender() -> np.ndarray:
    """Half-trousers / half-dress figure used for all-gender restrooms."""
    c = _canvas()
    cv2.circle(c, (64, 17), 12, 255, -1, cv2.LINE_AA)
    _poly(c, [(46, 34), (64, 34), (64, 120), (50, 120), (50, 50), (48, 50), (48, 76), (40, 76), (40, 40)])
    _poly(c, [(64, 34), (78, 34), (86, 40), (92, 70), (84, 72), (80, 52), (90, 92), (74, 92), (74, 120), (66, 120),
              (66, 92), (64, 92)])
    return c


def wheelchair() -> np.ndarray:
    """International Symbol of Access (seated figure facing right)."""
    c = _canvas()
    cv2.circle(c, (46, 15), 11, 255, -1, cv2.LINE_AA)
    cv2.line(c, (44, 32), (46, 70), 255, 14, cv2.LINE_AA)        # torso
    cv2.line(c, (46, 46), (70, 46), 255, 9, cv2.LINE_AA)         # arm
    cv2.line(c, (46, 70), (82, 70), 255, 12, cv2.LINE_AA)        # thigh
    cv2.line(c, (82, 70), (96, 104), 255, 11, cv2.LINE_AA)       # shin
    cv2.line(c, (96, 104), (112, 104), 255, 9, cv2.LINE_AA)      # foot rest
    cv2.ellipse(c, (50, 88), (32, 32), 0, 15, 290, 255, 9, cv2.LINE_AA)  # wheel, open at the seat
    return c


def exit_running_person() -> np.ndarray:
    """ISO 7010 E002-style running person heading right through a doorway."""
    c = _canvas()
    cv2.rectangle(c, (86, 8), (122, 122), 255, 7, cv2.LINE_AA)   # doorway
    cv2.circle(c, (48, 18), 10, 255, -1, cv2.LINE_AA)
    cv2.line(c, (50, 34), (40, 70), 255, 13, cv2.LINE_AA)        # torso
    _poly(c, [(48, 40), (64, 52), (76, 42)], thickness=8)        # front arm
    _poly(c, [(46, 40), (30, 52), (16, 46)], thickness=8)        # back arm
    _poly(c, [(40, 70), (60, 86), (64, 114)], thickness=10)      # front leg
    _poly(c, [(40, 70), (28, 94), (8, 100)], thickness=10)       # back leg
    return c


def elevator() -> np.ndarray:
    c = _canvas()
    cv2.rectangle(c, (16, 6), (112, 122), 255, 7, cv2.LINE_AA)
    _poly(c, [(64, 20), (38, 54), (90, 54)])
    _poly(c, [(38, 74), (90, 74), (64, 108)])
    return c


def stairs() -> np.ndarray:
    """Step profile ascending to the right (direction comes from an accompanying arrow)."""
    c = _canvas()
    _poly(c, [(6, 122), (6, 100), (36, 100), (36, 76), (66, 76), (66, 52), (96, 52), (96, 28), (122, 28), (122, 122)])
    return c


def arrow(direction_deg: float = 0.0) -> np.ndarray:
    """Block arrow; `direction_deg` is counter-clockwise from image right (0 = right, 90 = up)."""
    c = _canvas()
    _poly(c, [(14, 54), (70, 54), (70, 26), (116, 64), (70, 102), (70, 74), (14, 74)])
    if direction_deg:
        rotation = cv2.getRotationMatrix2D((SIZE / 2, SIZE / 2), direction_deg, 1.0)
        c = cv2.warpAffine(c, rotation, (SIZE, SIZE), flags=cv2.INTER_LINEAR)
    return c


def stairs_up() -> np.ndarray:
    c = cv2.resize(stairs(), (96, 96))
    out = _canvas()
    out[30:126, 30:126] = c
    return np.maximum(out, _place(arrow(45), 2, 2, 58))


def stairs_down() -> np.ndarray:
    c = cv2.resize(stairs(), (96, 96))
    out = _canvas()
    out[30:126, 30:126] = c
    return np.maximum(out, _place(arrow(225), 2, 2, 58))


def _place(mask: np.ndarray, x: int, y: int, side: int) -> np.ndarray:
    out = _canvas()
    out[y:y + side, x:x + side] = cv2.resize(mask, (side, side), interpolation=cv2.INTER_AREA)
    return out


def information() -> np.ndarray:
    c = _canvas()
    cv2.circle(c, (64, 22), 13, 255, -1, cv2.LINE_AA)
    _poly(c, [(46, 44), (74, 44), (74, 108), (84, 108), (84, 122), (44, 122), (44, 108), (54, 108), (54, 58), (46, 58)])
    return c


def fire_extinguisher() -> np.ndarray:
    c = _canvas()
    cv2.rectangle(c, (40, 46), (80, 122), 255, -1, cv2.LINE_AA)
    cv2.ellipse(c, (60, 46), (20, 12), 0, 180, 360, 255, -1, cv2.LINE_AA)
    cv2.rectangle(c, (53, 22), (67, 36), 255, -1)                # valve
    _poly(c, [(42, 12), (78, 18), (76, 24), (42, 20)])          # lever
    _poly(c, [(67, 28), (94, 32), (104, 60), (102, 92)], thickness=6)  # hose
    _poly(c, [(96, 90), (110, 90), (106, 104), (100, 104)])     # nozzle
    return c


def first_aid() -> np.ndarray:
    c = _canvas()
    cv2.rectangle(c, (46, 10), (82, 118), 255, -1)
    cv2.rectangle(c, (10, 46), (118, 82), 255, -1)
    return c


# name -> (renderer, PlaceCategory/semantic hint). Arrows are recovered geometrically (arrows.py).
RENDERERS = {
    "wheelchair": wheelchair,
    "man": man,
    "woman": woman,
    "all_gender": all_gender,
    "exit_running_person": exit_running_person,
    "elevator": elevator,
    "stairs": stairs,
    "information": information,
    "fire_extinguisher": fire_extinguisher,
    "first_aid": first_aid,
}
# Mirror-image variants seen in the wild (ISA facing left, running person heading left, stairs).
MIRRORED = {"wheelchair", "exit_running_person", "stairs", "fire_extinguisher"}
# Gallery-only renders (composites with arrows) that resolve to a base template plus an arrow.
EXTRA_RENDERERS = {"stairs_up": stairs_up, "stairs_down": stairs_down}


def render(name: str, mirrored: bool = False) -> np.ndarray:
    renderer = RENDERERS.get(name) or EXTRA_RENDERERS.get(name)
    if renderer is None:
        if name.startswith("arrow_"):
            return arrow(ARROW_ANGLES[name[len("arrow_"):]])
        raise KeyError(name)
    mask = renderer()
    return cv2.flip(mask, 1) if mirrored else mask


ARROW_ANGLES = {"right": 0, "up_right": 45, "up": 90, "up_left": 135, "left": 180, "down_left": 225,
                "down": 270, "down_right": 315}


def normalize(mask: np.ndarray, side: int = NORM, margin: int = MARGIN) -> np.ndarray | None:
    """Tight-crop a binary mask, keep its aspect ratio, and center it on a `side` square."""
    ys, xs = np.nonzero(mask > 127)
    if len(xs) < 8:
        return None
    crop = mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    h, w = crop.shape
    scale = (side - 2 * margin) / max(h, w)
    nh, nw = max(1, round(h * scale)), max(1, round(w * scale))
    resized = cv2.resize(crop, (nw, nh), interpolation=cv2.INTER_AREA)
    out = np.zeros((side, side), np.uint8)
    y0, x0 = (side - nh) // 2, (side - nw) // 2
    out[y0:y0 + nh, x0:x0 + nw] = resized
    return out


@dataclass(frozen=True)
class Template:
    name: str
    mirrored: bool
    norm: np.ndarray              # NORM×NORM normalized silhouette
    aspect: float                 # width / height of the tight bounding box
    keypoints: int
    descriptors: np.ndarray | None
    points: np.ndarray | None     # keypoint coordinates on the 128 px feature canvas


def _aspect(mask: np.ndarray) -> float:
    ys, xs = np.nonzero(mask > 127)
    return float((np.ptp(xs) + 1) / (np.ptp(ys) + 1)) if len(xs) else 1.0


@lru_cache(maxsize=1)
def _akaze():
    return cv2.AKAZE_create(threshold=0.0005)


def _features(norm: np.ndarray):
    canvas = cv2.GaussianBlur(cv2.resize(norm, (2 * NORM, 2 * NORM), interpolation=cv2.INTER_LINEAR), (3, 3), 0)
    keypoints, descriptors = _akaze().detectAndCompute(canvas, None)
    points = np.float32([k.pt for k in keypoints]) if keypoints else None
    return len(keypoints), descriptors, points


@lru_cache(maxsize=1)
def templates() -> tuple[Template, ...]:
    out = []
    for name in sorted(RENDERERS):
        for mirrored in ((False, True) if name in MIRRORED else (False,)):
            mask = render(name, mirrored)
            norm = normalize(mask)
            count, descriptors, points = _features(norm)
            out.append(Template(name, mirrored, norm, _aspect(mask), count, descriptors, points))
    return tuple(out)


def _ncc(candidate: np.ndarray, template: np.ndarray) -> float:
    """Best TM_CCOEFF_NORMED over a few scales and small shifts."""
    best = -1.0
    padded = cv2.copyMakeBorder(candidate, 4, 4, 4, 4, cv2.BORDER_CONSTANT, value=0)
    for scale in (0.88, 0.94, 1.0, 1.06):
        side = max(8, round(NORM * scale))
        if side > padded.shape[0]:
            continue
        scaled = cv2.resize(template, (side, side), interpolation=cv2.INTER_AREA)
        score = cv2.matchTemplate(padded, scaled, cv2.TM_CCOEFF_NORMED)
        best = max(best, float(score.max()))
    return best


def _homography_score(count: int, descriptors, points, template: Template) -> float:
    if descriptors is None or template.descriptors is None or count < 6 or template.keypoints < 6:
        return 0.0
    matcher = cv2.BFMatcher(cv2.NORM_HAMMING)
    pairs = matcher.knnMatch(descriptors, template.descriptors, k=2)
    good = [p[0] for p in pairs if len(p) == 2 and p[0].distance < 0.8 * p[1].distance]
    if len(good) < 6:
        return 0.0
    src = points[[m.queryIdx for m in good]].reshape(-1, 1, 2)
    dst = template.points[[m.trainIdx for m in good]].reshape(-1, 1, 2)
    homography, inliers = cv2.findHomography(src, dst, cv2.RANSAC, 6.0)
    if homography is None or inliers is None:
        return 0.0
    # A plausible sign-to-template warp is close to a similarity: reject strongly projective fits.
    if abs(homography[2, 0]) > 0.01 or abs(homography[2, 1]) > 0.01:
        return 0.0
    return float(inliers.sum()) / max(count, template.keypoints)


@dataclass(frozen=True)
class Match:
    name: str
    score: float
    mirrored: bool
    ncc: float
    hu: float
    features: float


def classify(mask: np.ndarray) -> list[Match]:
    """Scores of `mask` (binary, symbol = 255) against every template, best first (one per name)."""
    norm = normalize(mask)
    if norm is None:
        return []
    aspect = _aspect(mask)
    count, descriptors, points = _features(norm)
    best: dict[str, Match] = {}
    for template in templates():
        ncc = _ncc(norm, template.norm)
        hu_distance = cv2.matchShapes(norm, template.norm, cv2.CONTOURS_MATCH_I2, 0)
        hu = float(np.exp(-4.0 * hu_distance))
        features = _homography_score(count, descriptors, points, template)
        aspect_penalty = min(1.0, abs(np.log(aspect / template.aspect)) / np.log(2))
        # Feature inliers only add evidence: solid, corner-poor symbols (a cross) have few keypoints.
        score = min(1.0, 0.7 * max(ncc, 0.0) + 0.3 * hu + 0.1 * min(1.0, 2 * features)) * (1 - 0.35 * aspect_penalty)
        match = Match(template.name, round(float(score), 4), template.mirrored, round(ncc, 4), round(hu, 4),
                      round(features, 4))
        if template.name not in best or match.score > best[template.name].score:
            best[template.name] = match
    return sorted(best.values(), key=lambda m: (-m.score, m.name))


RESTROOM_FIGURES = ("man", "woman", "all_gender")


def restroom_figure(mask: np.ndarray) -> str | None:
    """Disambiguate the restroom figures by silhouette: trousers vs dress on each side.

    Measures each side's extent from the head axis across the hem band (62–74 % of the figure's
    height) relative to the shoulder half-width (25–45 %). A dress flares to (or beyond) the
    shoulders, trouser legs stay well inside; one of each is the all-gender half-and-half figure.
    """
    norm = normalize(mask, side=128, margin=4)
    if norm is None:
        return None
    # Undo small camera roll: rotate the principal axis back to vertical (figures are upright).
    m = cv2.moments(norm, binaryImage=True)
    if m["m00"] > 0:
        tilt = 0.5 * np.degrees(np.arctan2(2 * m["mu11"], m["mu02"] - m["mu20"]))
        if 0.5 < abs(tilt) < 20:
            center = (m["m10"] / m["m00"], m["m01"] / m["m00"])
            rotation = cv2.getRotationMatrix2D(center, -tilt, 1.0)
            norm = normalize(cv2.warpAffine(norm, rotation, norm.shape[::-1], flags=cv2.INTER_NEAREST), 128, 4)
            if norm is None:
                return None
    ys, xs = np.nonzero(norm > 127)
    top, height = ys.min(), np.ptp(ys) + 1
    head = xs[ys < top + 0.12 * height]
    if not len(head):
        return None
    axis = float(np.median(head))

    def extents(lo: float, hi: float) -> tuple[float, float]:
        rows = (ys >= top + lo * height) & (ys < top + hi * height)
        if not rows.any():
            return 0.0, 0.0
        return float(axis - xs[rows].min()), float(xs[rows].max() - axis)

    shoulder = max(1.0, float(np.mean(extents(0.25, 0.45))))
    left, right = (e / shoulder for e in extents(0.62, 0.74))
    flared = (left > 0.82, right > 0.82)
    if flared[0] and flared[1]:
        return "woman"
    if not flared[0] and not flared[1]:
        return "man"
    return "all_gender" if abs(left - right) > 0.2 else None
