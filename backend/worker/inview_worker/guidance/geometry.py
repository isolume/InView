"""Polyline helpers in the map plane (X/Z) for turn detection and feature anchoring."""
from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np


def as_array(points) -> np.ndarray:
    array = np.asarray(points, dtype=np.float64).reshape(-1, 3)
    if len(array) < 2:
        return array
    # Drop consecutive duplicates; they carry no heading.
    keep = np.r_[True, np.linalg.norm(np.diff(array, axis=0), axis=1) > 1e-6]
    return array[keep]


def cumulative(points: np.ndarray) -> np.ndarray:
    if len(points) < 2:
        return np.zeros(len(points))
    return np.r_[0.0, np.cumsum(np.linalg.norm(np.diff(points, axis=0), axis=1))]


def point_at(points: np.ndarray, cum: np.ndarray, s: float) -> np.ndarray:
    s = float(np.clip(s, 0.0, cum[-1]))
    return np.array([np.interp(s, cum, points[:, axis]) for axis in range(3)])


def resample(points: np.ndarray, step_m: float) -> np.ndarray:
    """Insert samples so no piece is longer than `step_m`, keeping every original vertex (corners stay
    exact). Uniform density makes the Douglas-Peucker tolerance independent of how sparse or dense
    the graph generator's path points were."""
    if len(points) < 2:
        return points.copy()
    out = [points[:1]]
    for a, b in zip(points[:-1], points[1:]):
        pieces = max(1, int(np.ceil(np.linalg.norm(b - a) / step_m)))
        t = np.linspace(0.0, 1.0, pieces + 1)[1:, None]
        out.append(a + (b - a) * t)
    return np.concatenate(out, axis=0)


def simplify(points: np.ndarray, epsilon_m: float) -> np.ndarray:
    """Douglas-Peucker in the X/Z plane via `cv2.approxPolyDP`; returns the indices of kept vertices
    (always including both ends) in path order."""
    if len(points) <= 2:
        return np.arange(len(points))
    # approxPolyDP works in float32; millimetres relative to the start keep precision loss negligible.
    contour = ((points[:, [0, 2]] - points[0, [0, 2]]) * 1000.0).astype(np.float32).reshape(-1, 1, 2)
    kept = cv2.approxPolyDP(contour, epsilon_m * 1000.0, False).reshape(-1, 2)
    flat, indices, cursor = contour.reshape(-1, 2), {0, len(points) - 1}, 0
    for vertex in kept:
        while cursor < len(flat) and not np.array_equal(flat[cursor], vertex):
            cursor += 1
        if cursor < len(flat):
            indices.add(cursor)
    return np.array(sorted(indices), dtype=int)


def heading(vector_xz: np.ndarray) -> np.ndarray | None:
    norm = float(np.linalg.norm(vector_xz))
    return None if norm < 1e-3 else vector_xz / norm


def turn_angle(incoming: np.ndarray, outgoing: np.ndarray) -> tuple[float, bool]:
    """Unsigned angle in degrees and whether it turns right. Same convention as iOS `Maneuver`:
    floor coordinates are (x, z) with +Y up, so a positive cross product is a right turn."""
    dot = float(np.clip(np.dot(incoming, outgoing), -1.0, 1.0))
    cross = float(incoming[0] * outgoing[1] - incoming[1] * outgoing[0])
    return float(np.degrees(np.arccos(dot))), cross > 0


def side_of(direction_xz: np.ndarray, origin_xz: np.ndarray, target_xz: np.ndarray) -> float:
    """Signed lateral offset of `target` from a ray; positive is to the walker's right."""
    offset = target_xz - origin_xz
    return float(direction_xz[0] * offset[1] - direction_xz[1] * offset[0])


@dataclass(frozen=True)
class Projection:
    along_m: float          # arc length from the polyline start to the foot point
    distance_m: float       # planar distance from the point to the polyline
    lateral_m: float        # signed: positive is right of the travel direction
    foot: np.ndarray        # 3D foot point on the polyline


def project(points: np.ndarray, cum: np.ndarray, target_xz) -> Projection | None:
    if len(points) < 2:
        return None
    target = np.asarray(target_xz, dtype=np.float64)
    a, b = points[:-1, [0, 2]], points[1:, [0, 2]]
    ab = b - a
    lengths2 = np.maximum((ab ** 2).sum(axis=1), 1e-12)
    t = np.clip(((target - a) * ab).sum(axis=1) / lengths2, 0.0, 1.0)
    feet = a + ab * t[:, None]
    distances = np.linalg.norm(feet - target, axis=1)
    best = int(np.argmin(distances))
    along = float(cum[best] + t[best] * (cum[best + 1] - cum[best]))
    direction = heading(ab[best])
    lateral = 0.0 if direction is None else side_of(direction, feet[best], target)
    return Projection(along, float(distances[best]), lateral, point_at(points, cum, along))
