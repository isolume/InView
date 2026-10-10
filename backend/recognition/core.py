"""Dependency-free protocol and conservative sensor-grid sampling helpers."""
from __future__ import annotations

import base64
import binascii
import math

# Keep canonical labels aligned with scene.rs/model_meshes.rs. These are display
# categories, not claims about accessible clearance or unseen object geometry.
PROMPTS = (
    ("chair", "chair"), ("armchair", "chair"), ("table", "table"),
    ("round table", "round_table"), ("sofa", "sofa"), ("bench", "bench"),
    ("cabinet", "cabinet"), ("shelving unit", "cabinet"),
    ("potted plant", "plant"), ("square planter", "square_planter"),
    ("bed", "bed"), ("sink", "sink"), ("lectern", "lectern"),
    ("podium", "lectern"), ("trash bin", "waste_bin"),
    ("open trash bin", "open_bin"), ("sign stand", "sign_stand"),
    ("charging stand", "charging_stand"), ("railing", "railing"),
    ("ottoman", "ottoman"), ("floor caution sign", "floor_sign"), ("rug", "rug"),
)
MINIMUM_SCORE = 0.45
MAX_DETECTIONS = 16
MAX_SAMPLES = 2048
MAX_DEPTH_PIXELS = 512 * 512
MAX_COLOR_PIXELS = 1024 * 1024
MAX_JPEG_BYTES = 4 * 1024 * 1024
MAX_REQUEST_BYTES = 6 * 1024 * 1024


def decode_request(value):
    """Validate one bounded frame, returning its ID, JPEG and depth dimensions."""
    required = {"request_id", "color_jpeg", "depth_width", "depth_height"}
    if (not isinstance(value, dict) or not required <= set(value)
            or set(value) - required - {"image_rotation_degrees"}):
        raise ValueError("Invalid recognition request fields.")
    request_id = value["request_id"]
    if not isinstance(request_id, str) or not 0 < len(request_id) <= 256:
        raise ValueError("Invalid recognition request ID.")
    width, height = value["depth_width"], value["depth_height"]
    if (type(width) is not int or type(height) is not int or width <= 0 or height <= 0
            or width * height > MAX_DEPTH_PIXELS):
        raise ValueError("Invalid recognition depth dimensions.")
    encoded = value["color_jpeg"]
    if not isinstance(encoded, str) or len(encoded) > (MAX_JPEG_BYTES + 2) // 3 * 4:
        raise ValueError("Invalid recognition JPEG payload.")
    try:
        jpeg = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("Invalid recognition JPEG encoding.") from None
    if not jpeg or len(jpeg) > MAX_JPEG_BYTES:
        raise ValueError("Invalid recognition JPEG payload.")
    rotation = value.get("image_rotation_degrees", 0)
    if type(rotation) is not int or rotation not in (0, 90, 180, 270):
        raise ValueError("Invalid recognition image rotation.")
    return request_id, jpeg, width, height, rotation


def canonical_category(class_id):
    if type(class_id) is not int or not 0 <= class_id < len(PROMPTS):
        return None
    return PROMPTS[class_id][1]


def sample_depth_indices(mask, depth_width, depth_height, max_samples=MAX_SAMPLES,
                         image_rotation_degrees=0):
    """Map original-image masks by pixel centers, erode on the depth grid, sample.

    Erosion excludes the outer depth-grid row/column and any pixel whose 8
    neighbors include background. No mask averaging or coordinate rotation occurs.
    Even sampling includes both ends of sorted row-major support, keeping coverage.
    """
    height = len(mask)
    width = len(mask[0]) if height else 0
    if not width or any(len(row) != width for row in mask):
        raise ValueError("Invalid recognition mask dimensions.")
    if depth_width < 3 or depth_height < 3:
        return []
    rotation = image_rotation_degrees
    sensor_width, sensor_height = (height, width) if rotation in (90, 270) else (width, height)
    xs = [min(sensor_width - 1, (2 * x + 1) * sensor_width // (2 * depth_width))
          for x in range(depth_width)]
    ys = [min(sensor_height - 1, (2 * y + 1) * sensor_height // (2 * depth_height))
          for y in range(depth_height)]
    if getattr(mask, "ndim", None) == 2:
        # Inference provides NumPy masks. Vectorize the same operation without
        # making NumPy/Torch a requirement for protocol and mocked-mask tests.
        import numpy as np
        sensor = np.rot90(mask, rotation // 90) if rotation else mask
        grid = sensor[np.ix_(ys, xs)] > 0.5
        eroded = grid[1:-1, 1:-1].copy()
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                eroded &= grid[1 + dy:depth_height - 1 + dy,
                               1 + dx:depth_width - 1 + dx]
        rows, cols = np.nonzero(eroded)
        support = (rows + 1) * depth_width + cols + 1
        if len(support) > max_samples:
            selection = np.arange(max_samples) * (len(support) - 1) // (max_samples - 1)
            support = support[selection]
        return support.tolist()
    grid = bytearray(depth_width * depth_height)
    for y, source_y in enumerate(ys):
        offset = y * depth_width
        for x, source_x in enumerate(xs):
            # Logical inverse rotation avoids copying each full-resolution mask:
            # read its corresponding inference pixel from the native sensor grid.
            if rotation == 90:
                value = mask[source_x][sensor_height - 1 - source_y]
            elif rotation == 180:
                value = mask[sensor_height - 1 - source_y][sensor_width - 1 - source_x]
            elif rotation == 270:
                value = mask[sensor_width - 1 - source_x][source_y]
            else:
                value = mask[source_y][source_x]
            grid[offset + x] = bool(value > 0.5)
    support = []
    for y in range(1, depth_height - 1):
        for x in range(1, depth_width - 1):
            index = y * depth_width + x
            if all(grid[index + dy * depth_width + dx]
                   for dy in (-1, 0, 1) for dx in (-1, 0, 1)):
                support.append(index)
    if len(support) <= max_samples:
        return support
    return [support[i * (len(support) - 1) // (max_samples - 1)]
            for i in range(max_samples)]


def detections_from_masks(predictions, depth_width, depth_height, image_rotation_degrees=0):
    """Validate/filter predictions, returning bounded canonical mask observations."""
    candidates = []
    for order, (class_id, score, mask) in enumerate(predictions):
        category = canonical_category(class_id)
        if category and math.isfinite(score) and MINIMUM_SCORE <= score <= 1:
            candidates.append((score, order, category, mask))
    candidates.sort(key=lambda item: (-item[0], item[1]))
    detections = []
    for score, _, category, mask in candidates:
        indices = sample_depth_indices(mask, depth_width, depth_height,
                                       image_rotation_degrees=image_rotation_degrees)
        if indices:
            detections.append({"category": category, "score": float(score),
                               "depth_indices": indices})
        if len(detections) == MAX_DETECTIONS:
            break
    return detections
