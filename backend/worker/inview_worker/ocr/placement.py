"""Place text in 3D: depth samples under its quad give a position; an SVD plane fit gives a normal."""
from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from .imaging import expand_quad


@dataclass
class Placement:
    position_m: list[float] | None
    normal_m: list[float] | None
    samples: int
    plane_rms_m: float | None = None


def sample_pixels(points: np.ndarray, width: int, height: int) -> np.ndarray:
    """Upright-JPEG pixel coordinates of depth samples: the inverse of `geometry.jpeg_to_sensor_uv`."""
    u, v = points[:, 3], points[:, 4]
    return np.column_stack(((1.0 - v) * width, u * height))


def _inside(pixels: np.ndarray, quad: np.ndarray) -> np.ndarray:
    lo, hi = quad.min(axis=0), quad.max(axis=0)
    candidate = np.nonzero((pixels[:, 0] >= lo[0]) & (pixels[:, 0] <= hi[0])
                           & (pixels[:, 1] >= lo[1]) & (pixels[:, 1] <= hi[1]))[0]
    contour = quad.reshape(-1, 1, 2).astype(np.float32)
    keep = [i for i in candidate if cv2.pointPolygonTest(contour, (float(pixels[i, 0]), float(pixels[i, 1])), False) >= 0]
    return np.asarray(keep, dtype=int)


def fit_plane(xyz: np.ndarray) -> tuple[np.ndarray, np.ndarray, float] | None:
    """Least-squares plane by SVD with up to two rounds of MAD outlier rejection: (centroid, normal, rms)."""
    if len(xyz) < 4:
        return None
    for attempt in range(3):
        centroid = xyz.mean(axis=0)
        _, singular, vt = np.linalg.svd(xyz - centroid, full_matrices=False)
        if singular[1] < 1e-6 or singular[1] < 1e-3 * singular[0]:  # collinear samples: no plane
            return None
        normal = vt[2]
        if attempt == 2:
            break
        residual = np.abs((xyz - centroid) @ normal)
        inliers = residual <= max(3.0 * 1.4826 * float(np.median(residual)), 0.01)
        if inliers.all() or inliers.sum() < 4:
            break
        xyz = xyz[inliers]
    rms = float(np.sqrt(np.mean(((xyz - centroid) @ normal) ** 2)))
    return centroid, normal, rms


def place(quad: np.ndarray, points: np.ndarray, width: int, height: int,
          camera_m: np.ndarray | None = None, min_plane_samples: int = 8) -> Placement:
    """Median position of the samples under `quad` (nearest sample if none fall inside) and the
    normal of a plane fitted to the samples under a grown quad, oriented towards the camera."""
    if points is None or not len(points):
        return Placement(None, None, 0)
    pixels = sample_pixels(points, width, height)
    inside = _inside(pixels, quad)
    if len(inside):
        position = np.median(points[inside, :3], axis=0)
    else:
        center = quad.mean(axis=0)
        distance = np.hypot(pixels[:, 0] - center[0], pixels[:, 1] - center[1])
        if distance.min() > 0.03 * max(width, height):
            return Placement(None, None, 0)
        position = points[int(np.argmin(distance)), :3]
    support, grow = inside, 0.0
    while len(support) < min_plane_samples and grow < 1.5:  # walls are planar around their signs
        grow += 0.25
        support = _inside(pixels, expand_quad(quad, grow, grow * 2))
    normal_out, rms = None, None
    plane = fit_plane(points[support, :3]) if len(support) >= 4 else None
    if plane is not None:
        _, normal, rms = plane
        toward = (camera_m - position) if camera_m is not None else None
        if toward is not None and np.dot(normal, toward) < 0:
            normal = -normal
        elif toward is None and normal[np.argmax(np.abs(normal))] < 0:
            normal = -normal
        normal_out = [round(float(c), 3) for c in normal / np.linalg.norm(normal)]
    return Placement([round(float(c), 3) for c in position], normal_out, int(len(inside)),
                     None if rms is None else round(rms, 4))
