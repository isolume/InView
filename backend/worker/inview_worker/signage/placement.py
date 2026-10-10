"""Placing image detections in the shared ARKit frame with the frame's calibrated depth samples.

Each depth sample carries its world xyz and sensor-native u/v, so the samples under (and around) a
sign define a local affine map from upright-JPEG pixels to world coordinates: world ≈ A·[px, py, 1].
Its columns are the world displacement per image pixel to the right and down, i.e. the sign plane's
in-plane axes as seen by the camera. That turns an arrow's image direction into a map direction and
pixel heights into meters, without needing the camera pose or intrinsics.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from ..geometry import jpeg_to_sensor_uv
from ..inputs import Frame

MIN_SAMPLES = 6


def locate(bbox, frame: Frame, width: int, height: int) -> list[float] | None:
    """Median depth position of the samples under the box (upright JPEG pixels x, y, w, h)."""
    if not len(frame.points):
        return None
    x, y, w, h = bbox
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


def sample_pixels(frame: Frame, width: int, height: int) -> np.ndarray:
    """Upright-JPEG pixel coordinates (px, py) of every depth sample (inverse of jpeg_to_sensor_uv)."""
    u, v = frame.points[:, 3], frame.points[:, 4]
    return np.column_stack(((1.0 - v) * width, u * height))


@dataclass(frozen=True)
class LocalFrame:
    """Affine pixel -> world map around a detection plus the fitted plane."""
    affine: np.ndarray        # 3 × 3: world = affine @ [px, py, 1]
    normal: np.ndarray        # unit plane normal pointing towards the camera
    residual_m: float         # RMS plane-fit residual
    samples: int

    def world(self, px: float, py: float) -> np.ndarray:
        return self.affine @ np.array([px, py, 1.0])

    @property
    def right(self) -> np.ndarray:
        return self.affine[:, 0]

    @property
    def down(self) -> np.ndarray:
        return self.affine[:, 1]

    def meters_per_px_vertical(self) -> float:
        return float(np.linalg.norm(self.down))

    def meters_per_px_horizontal(self) -> float:
        return float(np.linalg.norm(self.right))


def local_frame(bbox, frame: Frame, width: int, height: int, pad: float = 0.25) -> LocalFrame | None:
    """Least-squares affine fit on samples inside the (padded) box, or its nearest neighbors."""
    if len(frame.points) < MIN_SAMPLES:
        return None
    x, y, w, h = bbox
    pixels = sample_pixels(frame, width, height)
    px, py = pixels[:, 0], pixels[:, 1]
    inside = ((px >= x - pad * w) & (px <= x + w * (1 + pad)) & (py >= y - pad * h) & (py <= y + h * (1 + pad)))
    if inside.sum() < MIN_SAMPLES:
        distance = np.hypot(px - (x + w / 2), py - (y + h / 2))
        nearest = np.argsort(distance, kind="stable")[:12]
        if len(nearest) < MIN_SAMPLES or distance[nearest[-1]] > max(w, h) + 0.05 * max(width, height):
            return None
        inside = np.zeros(len(px), bool)
        inside[nearest] = True
    design = np.column_stack((px[inside], py[inside], np.ones(int(inside.sum()))))
    if np.std(design[:, 0]) < 1.0 or np.std(design[:, 1]) < 1.0:
        return None
    world = frame.points[inside, :3]
    solution, *_ = np.linalg.lstsq(design, world, rcond=None)
    affine = solution.T                     # 3 × 3
    right, down = affine[:, 0], affine[:, 1]
    normal = np.cross(right, -down)         # right × up points towards the viewer
    norm = np.linalg.norm(normal)
    if norm < 1e-12:
        return None
    centered = world - world.mean(axis=0)
    residual = float(np.sqrt(np.mean((centered @ (normal / norm)) ** 2)))
    return LocalFrame(affine, normal / norm, residual, int(inside.sum()))


def _unit_xz(vector: np.ndarray) -> np.ndarray | None:
    xz = np.array([vector[0], vector[2]], np.float64)
    n = np.linalg.norm(xz)
    return xz / n if n > 1e-9 else None


def height_range(local: LocalFrame, bbox) -> tuple[float, float]:
    """Lowest and highest world Y over a box's corners (works for any camera roll)."""
    x, y, w, h = bbox
    heights = [float(local.world(px, py)[1]) for px in (x, x + w) for py in (y, y + h)]
    return min(heights), max(heights)


def map_direction(local: LocalFrame, direction_px: tuple[float, float]) -> tuple[list[float] | None, str]:
    """Map an arrow's image direction to a unit X/Z vector and a wayfinding meaning.

    The image direction is first carried onto the sign plane in 3D (affine columns), so camera roll
    (portrait or landscape keyframes) does not matter. Signage convention: an arrow pointing up the
    wall means "ahead" (the direction the viewer faces when reading the sign), sideways arrows point
    along the plane, and a downward arrow means "here" or "down" (stairs), so only its sideways part
    is mapped. On a horizontal plane (ceiling/floor) the in-plane direction is used as is.
    """
    world = local.right * direction_px[0] + local.down * direction_px[1]
    norm = np.linalg.norm(world)
    if norm < 1e-12:
        return None, "unknown"
    world = world / norm
    up = float(world[1])
    horizontal = np.array([world[0], world[2]])
    forward_xz = _unit_xz(-local.normal)
    if forward_xz is None or abs(local.normal[1]) > 0.9:  # horizontal sign: arrow lies in the map plane
        unit = _unit_xz(world)
        return ([round(float(c), 3) for c in unit] if unit is not None else None), "along_plane"
    # Viewer's right when facing the sign: forward x up (+Y) projected on X/Z.
    right_xz = np.array([-forward_xz[1], forward_xz[0]])
    side = float(horizontal @ right_xz)
    meaning = "left" if side < -0.38 else ("right" if side > 0.38 else "")
    if up < -0.38 and abs(side) <= 0.38:
        return None, "down_or_here"
    vector = right_xz * side
    if up > 0.38:
        vector = vector + forward_xz * up
        meaning = "ahead" + (f"_{meaning}" if meaning else "")
    elif up < -0.38:
        meaning = f"down_{meaning}"
    n = np.linalg.norm(vector)
    if n < 1e-9:
        return None, meaning or "unknown"
    return [round(float(c), 3) for c in vector / n], meaning
