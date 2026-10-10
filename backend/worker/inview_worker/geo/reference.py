"""Robust building reference (`georef`) from the capture's GPS, compass and barometer samples.

Each depth observation in the package manifest may carry an `environment` sample recorded with its
camera pose. The iPhone (`ScanController.applyGeographicContext`) places the building from its single
best fix; here every distinct reading contributes:

1. Filter like the app: horizontal accuracy <= 20 m and heading accuracy <= 20 deg (missing = unusable).
   Frames repeat the phone's cached fix/heading, so each distinct reading counts once, tied to the
   first frame that carried it; reported accuracies never drop below half the best single reading.
2. Heading: the compass measures the device, not the scan's -Z axis, so each reading is corrected by the
   camera's yaw in the local frame (the iPhone assumes zero yaw, exact only near the session start).
   Then an accuracy-weighted circular (unit-vector) mean with MAD outlier rejection.
3. Position: a fix belongs to the camera of its first frame, so it is shifted to the ARKit origin with the robust
   heading (the same `coordinate(for: -camera_xz)` math as the app), outliers are rejected by MAD of
   their distance to the median, and inliers are averaged with 1/sigma^2 weights.
4. Barometric relative altitude clusters into level hints when several samples exist.

A `semantics.json` `geographic_reference` from the phone (possibly placed by hand) wins when present;
the sensor estimate is then reported as a cross-check.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from ..geometry import matrix
from .projection import GeoError, LocalProjection, MAX_LATITUDE, offset_m, wrap_degrees

MAX_HORIZONTAL_ACCURACY_M = 20.0     # ScanController.applyGeographicContext
MAX_HEADING_ACCURACY_DEG = 20.0
MAX_VERTICAL_ACCURACY_M = 30.0
MAD_SCALE = 1.4826                   # MAD -> standard deviation for normally distributed errors
OUTLIER_SIGMAS = 3.0
MIN_POSITION_GATE_M = 3.0
MIN_HEADING_GATE_DEG = 10.0
LEVEL_GAP_M = 1.5                    # vertical gap that separates two floors' samples
FLOOR_HEIGHT_RANGE_M = (3.0, 4.5)    # typical storey heights
NOMINAL_FLOOR_HEIGHT_M = 3.75
LEVEL_BIN_M = 0.25                   # barometric altitude histogram resolution
CORRELATION_FLOOR = 0.5              # reported accuracy >= this fraction of the best single reading


@dataclass(frozen=True)
class GeoSample:
    observation_id: str
    latitude: float | None = None
    longitude: float | None = None
    horizontal_accuracy_m: float | None = None
    heading_degrees: float | None = None
    heading_accuracy_degrees: float | None = None
    altitude_m: float | None = None
    vertical_accuracy_m: float | None = None
    relative_altitude_m: float | None = None
    recorded_at_unix_seconds: float | None = None
    camera_m: tuple[float, float, float] | None = None      # camera position in the local frame
    yaw_degrees: float | None = None                        # compass reference direction, cw from local -Z


def _number(value) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def device_yaw_degrees(map_from_camera: np.ndarray) -> float | None:
    """Direction Core Location's heading refers to, clockwise from local -Z, in degrees.

    Held upright (scanning, camera within 45 deg of the horizon) the heading follows the back camera
    (camera -Z); held flat it follows the top of the device. ARKit's camera +X runs along the long
    axis from the front camera toward the bottom of the device, so the top is camera -X.
    None for a degenerate pose.
    """
    rotation = map_from_camera[:3, :3]
    forward, top = -rotation[:, 2], -rotation[:, 0]
    axis = forward if math.hypot(forward[0], forward[2]) >= math.sqrt(0.5) else top
    if math.hypot(axis[0], axis[2]) < 0.2:
        return None
    return math.degrees(math.atan2(axis[0], -axis[2]))


def samples_from_manifest(manifest: dict | None) -> list[GeoSample]:
    samples = []
    for index, observation in enumerate((manifest or {}).get("observations") or []):
        environment = (observation.get("raw_depth") or {}).get("environment") or observation.get("environment")
        if not isinstance(environment, dict):
            continue
        camera, yaw = None, None
        pose = observation.get("map_from_camera")
        if isinstance(pose, list) and len(pose) == 16:
            m = matrix(pose)
            if np.all(np.isfinite(m)):
                camera, yaw = tuple(float(v) for v in m[:3, 3]), device_yaw_degrees(m)
        samples.append(GeoSample(
            observation_id=str(observation.get("id", index)),
            latitude=_number(environment.get("latitude")),
            longitude=_number(environment.get("longitude")),
            horizontal_accuracy_m=_number(environment.get("horizontal_accuracy_m")),
            heading_degrees=_number(environment.get("heading_degrees")),
            heading_accuracy_degrees=_number(environment.get("heading_accuracy_degrees")),
            altitude_m=_number(environment.get("altitude_m")),
            vertical_accuracy_m=_number(environment.get("vertical_accuracy_m")),
            relative_altitude_m=_number(environment.get("relative_altitude_m")),
            recorded_at_unix_seconds=_number(environment.get("recorded_at_unix_seconds")),
            camera_m=camera, yaw_degrees=yaw,
        ))
    return samples


# --- Robust statistics -----------------------------------------------------------------------------

def circular_mean_degrees(angles, weights=None) -> tuple[float, float]:
    """Weighted unit-vector mean in [0, 360) and the mean resultant length R in [0, 1]."""
    radians = np.radians(np.asarray(angles, dtype=np.float64))
    w = np.ones_like(radians) if weights is None else np.asarray(weights, dtype=np.float64)
    s, c = float(np.sum(w * np.sin(radians))), float(np.sum(w * np.cos(radians)))
    resultant = math.hypot(s, c) / float(np.sum(w))
    return math.degrees(math.atan2(s, c)) % 360.0, resultant


def robust_heading(angles, accuracies) -> dict | None:
    """Accuracy-weighted circular mean after MAD rejection; spread is the circular std (deg)."""
    angles, accuracies = np.asarray(angles, dtype=np.float64), np.asarray(accuracies, dtype=np.float64)
    if len(angles) == 0:
        return None
    weights = 1.0 / np.maximum(accuracies, 1.0) ** 2
    mean, _ = circular_mean_degrees(angles, weights)
    deviation = np.asarray(wrap_degrees(angles - mean))
    center = mean + float(np.median(deviation))                      # circular median about the mean
    deviation = np.asarray(wrap_degrees(angles - center))
    mad = float(np.median(np.abs(deviation)))
    gate = np.maximum(max(OUTLIER_SIGMAS * MAD_SCALE * mad, MIN_HEADING_GATE_DEG), 2 * accuracies)
    inliers = np.abs(deviation) <= gate
    heading, resultant = circular_mean_degrees(angles[inliers], weights[inliers])
    spread = math.degrees(math.sqrt(max(0.0, -2 * math.log(max(resultant, 1e-12)))))
    floor = CORRELATION_FLOOR * float(accuracies[inliers].min())      # compass errors are correlated too
    accuracy = max(math.sqrt(1 / float(np.sum(weights[inliers]))), spread, floor)
    return {"heading_degrees": heading, "inliers": inliers, "spread_degrees": spread, "accuracy_degrees": accuracy}


def robust_position(east_north: np.ndarray, sigmas: np.ndarray) -> dict:
    """1/sigma^2-weighted mean of 2D points after MAD rejection of distances to the median."""
    median = np.median(east_north, axis=0)
    distance = np.linalg.norm(east_north - median, axis=1)
    scale = MAD_SCALE * float(np.median(distance))
    gate = np.maximum(max(OUTLIER_SIGMAS * scale, MIN_POSITION_GATE_M), 2 * sigmas)
    inliers = distance <= gate
    weights = 1.0 / np.maximum(sigmas[inliers], 1.0) ** 2
    mean = (east_north[inliers] * weights[:, None]).sum(axis=0) / weights.sum()
    spread = math.sqrt(float((weights * np.sum((east_north[inliers] - mean) ** 2, axis=1)).sum() / weights.sum()))
    return {"mean": mean, "inliers": inliers, "spread_m": spread,
            "standard_error_m": math.sqrt(1 / float(weights.sum()))}


# --- Estimation ------------------------------------------------------------------------------------

def _chronological(samples: list[GeoSample]) -> list[GeoSample]:
    """Capture order: recording time, then manifest order (stable)."""
    return [s for _, s in sorted(enumerate(samples), key=lambda item: (
        item[1].recorded_at_unix_seconds if item[1].recorded_at_unix_seconds is not None else math.inf, item[0]))]


def _distinct(samples: list[GeoSample], key) -> list[GeoSample]:
    """First (earliest) sample of each distinct reading."""
    seen, result = set(), []
    for sample in _chronological(samples):
        if key(sample) not in seen:
            seen.add(key(sample))
            result.append(sample)
    return result


def _usable_position(s: GeoSample, max_accuracy: float) -> bool:
    return (s.latitude is not None and s.longitude is not None and abs(s.latitude) < MAX_LATITUDE
            and -180 <= s.longitude <= 180 and s.horizontal_accuracy_m is not None
            and 0 <= s.horizontal_accuracy_m <= max_accuracy)


def _usable_heading(s: GeoSample, max_accuracy: float) -> bool:
    return (s.heading_degrees is not None and s.heading_accuracy_degrees is not None
            and 0 <= s.heading_accuracy_degrees <= max_accuracy)


def estimate_from_samples(samples: list[GeoSample], *, yaw_correction: bool = True,
                          max_horizontal_accuracy_m: float = MAX_HORIZONTAL_ACCURACY_M,
                          max_heading_accuracy_degrees: float = MAX_HEADING_ACCURACY_DEG) -> tuple[dict | None, str | None]:
    """(GeoReference dict, None) or (None, reason).

    The phone attaches its latest cached CLLocation/CLHeading to every depth frame (distance and heading
    filters of 3 m / 3 deg), so identical readings are one measurement: each distinct reading counts once,
    with the camera pose of the first frame that carried it (closest to where it was taken).
    """
    headed = _distinct([s for s in samples if _usable_heading(s, max_heading_accuracy_degrees)],
                       lambda s: (s.heading_degrees, s.heading_accuracy_degrees))
    positioned = _distinct([s for s in samples if _usable_position(s, max_horizontal_accuracy_m)],
                           lambda s: (s.latitude, s.longitude, s.horizontal_accuracy_m, s.altitude_m))
    if not positioned:
        return None, f"no GPS fix with horizontal accuracy <= {max_horizontal_accuracy_m:g} m"
    if not headed:
        return None, f"no compass heading with accuracy <= {max_heading_accuracy_degrees:g} deg"

    corrected = [s.heading_degrees - (s.yaw_degrees if yaw_correction and s.yaw_degrees is not None else 0.0)
                 for s in headed]
    heading = robust_heading(corrected, [s.heading_accuracy_degrees for s in headed])
    heading_deg = round(heading["heading_degrees"], 6) % 360.0

    # Shift every fix from its camera to the ARKit origin (ScanController's camera -> origin offset).
    origins = []
    for s in positioned:
        cx, cz = (s.camera_m[0], s.camera_m[2]) if s.camera_m else (0.0, 0.0)
        try:
            origins.append(LocalProjection(s.latitude, s.longitude, heading_deg).coordinate(-cx, -cz))
        except GeoError:
            origins.append(None)
    kept = [(s, o) for s, o in zip(positioned, origins) if o is not None]
    if not kept:
        return None, "every GPS fix fell outside the map's coverage"
    lat0, lon0 = kept[0][1]
    east_north = offset_m(lat0, lon0, [o[0] for _, o in kept], [o[1] for _, o in kept])
    sigmas = np.array([s.horizontal_accuracy_m for s, _ in kept])
    position = robust_position(east_north, sigmas)
    latitude, longitude = LocalProjection(lat0, lon0).coordinate(position["mean"][0], -position["mean"][1])

    inlier_samples = [s for (s, _), ok in zip(kept, position["inliers"]) if ok]
    lever = float(np.mean([math.hypot(s.camera_m[0], s.camera_m[2]) if s.camera_m else 0.0 for s in inlier_samples]))
    # GPS errors are correlated in time, so never claim better than half the best inlier fix.
    floor = CORRELATION_FLOOR * min(s.horizontal_accuracy_m for s in inlier_samples)
    base = max(position["standard_error_m"], position["spread_m"], floor)
    accuracy = math.hypot(base, lever * math.radians(heading["accuracy_degrees"]))

    result = {
        "latitude": round(latitude, 8),
        "longitude": round(longitude, 8),
        "heading_degrees": round(heading_deg, 3),
        "horizontal_accuracy_m": round(accuracy, 2),
        "method": "sensor_fusion" if len(inlier_samples) > 1 or len(headed) > 1 else "single_fix",
        "samples_used": len(inlier_samples),
        "heading_accuracy_degrees": round(heading["accuracy_degrees"], 2),
        "uncertainty": {
            "position_spread_m": round(position["spread_m"], 2),
            "position_standard_error_m": round(position["standard_error_m"], 2),
            "heading_spread_degrees": round(heading["spread_degrees"], 2),
            "camera_lever_arm_m": round(lever, 2),
        },
        "samples": {
            "total": len(samples),
            "distinct_fixes": len(positioned),
            "position_outliers": int(len(kept) - position["inliers"].sum()),
            "distinct_headings": len(headed),
            "heading_used": int(heading["inliers"].sum()),
            "heading_outliers": int(len(headed) - heading["inliers"].sum()),
            "yaw_corrected": bool(yaw_correction and any(s.yaw_degrees is not None for s in headed)),
        },
    }
    altitude = origin_altitude(inlier_samples or positioned)
    if altitude is not None:
        result["altitude_m"] = altitude
    return result, None


def origin_altitude(samples: list[GeoSample]) -> float | None:
    """GPS altitude of the ARKit origin: camera altitude minus the camera's local height."""
    values, weights = [], []
    for s in samples:
        if s.altitude_m is None or s.vertical_accuracy_m is None or not 0 <= s.vertical_accuracy_m <= MAX_VERTICAL_ACCURACY_M:
            continue
        values.append(s.altitude_m - (s.camera_m[1] if s.camera_m else 0.0))
        weights.append(1 / max(s.vertical_accuracy_m, 1.0) ** 2)
    if not values:
        return None
    return round(float(np.average(values, weights=weights)), 2)


def level_hints(samples: list[GeoSample]) -> dict | None:
    """Cluster barometric relative altitude into floors; level 0 holds the earliest sample.

    CMAltimeter's relative altitude starts at zero when capture begins, so it is consistent within one
    scan. People dwell on floors and pass quickly through stairs, so floors are the peaks of a smoothed
    altitude histogram (non-maximum suppressed LEVEL_GAP_M apart) and every sample joins its nearest
    peak. A capture spanning a storey without distinct peaks (a steady climb) is quantised by the
    nominal storey height instead. Level indices are the offset to level 0 divided by the storey height
    (estimated from the floor spacing when plausible, else nominal).
    """
    usable = [s for s in _chronological(samples) if s.relative_altitude_m is not None]
    if len(usable) < 2:
        return None
    altitudes = np.array([s.relative_altitude_m for s in usable])
    low, span = float(altitudes.min()), float(np.ptp(altitudes))
    bins = int(np.ceil((span + 1.0) / LEVEL_BIN_M)) + 1
    histogram = np.bincount(np.floor((altitudes - low + 0.5) / LEVEL_BIN_M).astype(int), minlength=bins)
    smooth = np.convolve(np.pad(histogram.astype(float), 2), np.array([1, 2, 3, 2, 1]) / 9.0, mode="valid")
    padded = np.concatenate(([-1.0], smooth, [-1.0]))
    occupied = np.flatnonzero(smooth > 0)
    # A floor must stand clearly above the transit density (stairs, ramps) between floors.
    threshold = max(0.2 * smooth.max(), 2.0 * float(np.median(smooth[occupied[0]:occupied[-1] + 1])))
    peaks = [i for i in range(len(smooth))
             if padded[i + 1] >= padded[i] and padded[i + 1] > padded[i + 2] and smooth[i] >= threshold]
    kept: list[float] = []
    for i in sorted(peaks, key=lambda i: (-smooth[i], i)):
        center = low - 0.5 + (i + 0.5) * LEVEL_BIN_M
        if all(abs(center - k) >= LEVEL_GAP_M for k in kept):
            kept.append(center)
    if not kept:
        kept = [float(np.median(altitudes))]
    if len(kept) <= 1 and span >= FLOOR_HEIGHT_RANGE_M[0]:
        labels = np.round((altitudes - altitudes[0]) / NOMINAL_FLOOR_HEIGHT_M).astype(int)
    else:
        labels = np.argmin(np.abs(altitudes[:, None] - np.asarray(kept)[None, :]), axis=1)
    groups = sorted(set(labels.tolist()), key=lambda g: float(np.median(altitudes[labels == g])))
    clusters = [[s for s, label in zip(usable, labels) if label == g] for g in groups]
    centers = [float(np.median(altitudes[labels == g])) for g in groups]
    plausible = [g for g in np.diff(centers) if FLOOR_HEIGHT_RANGE_M[0] <= g <= FLOOR_HEIGHT_RANGE_M[1]]
    floor_height = float(np.median(plausible)) if plausible else None
    base = groups.index(int(labels[0]))
    indices = [round((c - centers[base]) / (floor_height or NOMINAL_FLOOR_HEIGHT_M)) for c in centers]
    if len(set(indices)) != len(indices):                # e.g. a mezzanine: fall back to rank order
        indices = [i - base for i in range(len(clusters))]
    levels = [{"index": int(index), "relative_altitude_m": round(center, 2), "samples": len(cluster),
               "observation_ids": sorted(s.observation_id for s in cluster)}
              for index, center, cluster in zip(indices, centers, clusters)]
    return {
        "method": "barometric_relative_altitude",
        "levels": levels,
        "level_count": len(levels),
        "multi_level": len(levels) > 1,
        "floor_height_m": round(floor_height, 2) if floor_height else None,
        "vertical_span_m": round(span, 2),
        "origin_level": 0,
    }


# --- Device-provided reference ---------------------------------------------------------------------

def device_reference(semantics: dict | None) -> tuple[dict | None, str | None]:
    """`semantics.json` `geographic_reference` from the phone, validated like BuildingMapReference."""
    reference = (semantics or {}).get("geographic_reference") if isinstance(semantics, dict) else None
    if not isinstance(reference, dict):
        return None, None
    raw_heading, raw_accuracy = reference.get("heading_degrees"), reference.get("horizontal_accuracy_m")
    latitude, longitude = _number(reference.get("latitude")), _number(reference.get("longitude"))
    heading = 0.0 if raw_heading is None else _number(raw_heading)      # Swift's default heading is 0
    accuracy = None if raw_accuracy is None else _number(raw_accuracy)
    try:
        if latitude is None or longitude is None:
            raise GeoError("latitude/longitude missing or not finite")
        if heading is None:
            raise GeoError("heading is not finite")
        if raw_accuracy is not None and accuracy is None:
            raise GeoError("horizontal accuracy is not finite")
        LocalProjection(latitude, longitude, heading, accuracy).validate()
    except GeoError as error:
        return None, f"semantics.json geographic_reference ignored: {error}"
    return {
        "latitude": latitude,
        "longitude": longitude,
        "heading_degrees": round(heading % 360.0, 6),
        "horizontal_accuracy_m": accuracy,
        "method": "device_reference",
        "samples_used": 0,
    }, None


def cross_check(primary: dict, other: dict) -> dict:
    """Distance and heading difference between two references (e.g. device vs. sensor estimate)."""
    east, north = offset_m(primary["latitude"], primary["longitude"], other["latitude"], other["longitude"])[0]
    return {"method": other["method"], "distance_m": round(math.hypot(east, north), 2),
            "heading_difference_degrees": round(abs(wrap_degrees(other["heading_degrees"] - primary["heading_degrees"])), 2),
            "samples_used": other.get("samples_used", 0)}
