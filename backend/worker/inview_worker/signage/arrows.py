"""Arrow recognition and direction recovery on a single legend component.

An arrow is a solid shape with a pointed head wider than its shaft. The principal axis (PCA of the
component's pixels) gives the arrow line; the end whose cross-section narrows to a point is the tip,
and the half containing it must be clearly wider than the other half (the head). Convexity defects
confirm the notches where the head meets the shaft. The image direction is reported as a unit vector
(x right, y down), an angle (counter-clockwise from image right) and one of eight names.
"""
from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

NAMES = ("right", "up_right", "up", "up_left", "left", "down_left", "down", "down_right")


@dataclass(frozen=True)
class Arrow:
    direction_px: tuple[float, float]   # unit vector in image coordinates (x right, y down)
    angle_deg: float                    # counter-clockwise from image right, 0..360
    name: str                           # nearest of the 8 compass-style image directions
    score: float
    tip_px: tuple[float, float]


def name_for(angle_deg: float) -> str:
    return NAMES[int(((angle_deg % 360) + 22.5) // 45) % 8]


def detect(mask: np.ndarray) -> Arrow | None:
    """`mask`: binary (255) image containing one component (crop coordinates are kept)."""
    binary = (mask > 0).astype(np.uint8)
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    if not contours:
        return None
    contour = max(contours, key=cv2.contourArea)
    area = cv2.contourArea(contour)
    if area < 60:
        return None
    hull = cv2.convexHull(contour)
    solidity = area / max(cv2.contourArea(hull), 1e-6)
    if not 0.45 <= solidity <= 0.88:
        return None
    hull_idx = cv2.convexHull(contour, returnPoints=False)
    try:
        defects = cv2.convexityDefects(contour, hull_idx)
    except cv2.error:
        return None
    scale = np.sqrt(area)
    deep = [] if defects is None else [d for d in defects[:, 0] if d[3] / 256.0 > 0.12 * scale]
    if not 1 <= len(deep) <= 4:
        return None

    ys, xs = np.nonzero(binary)
    points = np.column_stack((xs, ys)).astype(np.float64)
    center = points.mean(axis=0)
    _, _, vt = np.linalg.svd(points - center, full_matrices=False)
    axis, normal = vt[0], vt[1]
    along, across = (points - center) @ axis, (points - center) @ normal
    lo, hi = along.min(), along.max()
    length = hi - lo
    width_extent = across.max() - across.min()
    if length < 8 or length < 0.9 * width_extent:
        return None

    # Cross-section width profile along the axis (one bin per pixel of length).
    bins = np.clip(np.floor(along - lo).astype(int), 0, int(length))
    profile = np.zeros(int(length) + 1)
    for b in np.unique(bins):
        sel = across[bins == b]
        profile[b] = np.ptp(sel) + 1 if len(sel) else 0.0
    n = len(profile)
    band = max(1, int(round(0.05 * n)))
    lo_end, hi_end = float(profile[:band].mean()), float(profile[-band:].mean())
    if hi_end <= lo_end:
        tip_sign, head_profile, tail_profile = 1.0, profile[n // 2:], profile[:n // 2]
    else:
        tip_sign, head_profile, tail_profile = -1.0, profile[:n - n // 2][::-1], profile[n - n // 2:][::-1]
    # head_profile now runs from the middle towards the tip; tail_profile from the tail end to the middle.
    shaft_width = float(np.median(tail_profile)) if len(tail_profile) else 0.0
    head_width = float(head_profile.max()) if len(head_profile) else 0.0
    tip_width = min(lo_end, hi_end)
    if shaft_width <= 0 or head_width < 1.6 * shaft_width or tip_width > 0.3 * head_width:
        return None
    # The head must taper roughly linearly from its widest cross-section to the tip.
    peak = int(np.argmax(head_profile))
    ramp = head_profile[peak:]
    if len(ramp) < 3:
        return None
    expected = head_width * np.linspace(1.0, 0.0, len(ramp))
    if float(np.mean(np.abs(ramp - expected))) > 0.14 * head_width:
        return None
    # The deepest notches must sit near the head base, i.e. on the tip half.
    notch_along = [float((contour[d[2], 0] - center) @ axis) * tip_sign for d in deep]
    if not any(abs(n_a) < 0.45 * length for n_a in notch_along):
        return None

    direction = axis * tip_sign
    tip = center + direction * (hi if tip_sign > 0 else -lo)
    ratio = head_width / shaft_width
    angle = float(np.degrees(np.arctan2(-direction[1], direction[0])) % 360)
    score = float(np.clip(0.55 + 0.15 * (ratio - 1.6) + 0.3 * (1 - tip_width / head_width), 0, 1))
    return Arrow((round(float(direction[0]), 4), round(float(direction[1]), 4)), round(angle, 1), name_for(angle),
                 round(score, 3), (round(float(tip[0]), 1), round(float(tip[1]), 1)))
