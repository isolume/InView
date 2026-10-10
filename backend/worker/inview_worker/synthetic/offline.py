"""Build a ScanContext straight from `.inviewscan.tar` files, without a backend.

Mirrors the backend decoding (backend/src/raw_lidar.rs): binary float32 depth with row strides,
confidence filtering, pinhole unprojection into the shared ARKit frame with sensor-native u/v, and
native mesh vertices/faces transformed by `map_from_anchor`. Used by tests and offline runs.
"""
from __future__ import annotations

import json

import numpy as np

from ..core import MemorySource, ScanContext
from ..geometry import matrix, transform
from ..inputs import Box, Frame, ScanInputs, Surface
from .package import members


def _depth_points(observation: dict, files: dict[str, bytes], stride: int = 2) -> np.ndarray:
    depth = observation["raw_depth"]
    width, height, row = depth["width"], depth["height"], depth["bytes_per_row"]
    values = np.frombuffer(files[depth["raw_asset"]], "<f4").reshape(height, row // 4)[:, :width]
    keep = np.isfinite(values) & (values > 0.1) & (values < 30)
    if depth.get("confidence_asset"):
        conf_row = depth.get("confidence_bytes_per_row") or width
        confidence = np.frombuffer(files[depth["confidence_asset"]], np.uint8).reshape(height, conf_row)[:, :width]
        keep &= confidence > 0
    ys, xs = np.mgrid[0:height:stride, 0:width:stride]
    d = values[ys, xs]
    keep = keep[ys, xs]
    u, v = (xs + 0.5) / width, (ys + 0.5) / height
    image = observation["image"]
    local = np.column_stack((
        (u[keep] * image["width"] - image["cx"]) * d[keep] / image["fx"],
        -(v[keep] * image["height"] - image["cy"]) * d[keep] / image["fy"],
        -d[keep],
    ))
    world = transform(matrix(observation["map_from_camera"]), local)
    return np.column_stack((world, u[keep], v[keep]))


def inputs_from_files(files: dict[str, bytes]) -> tuple[ScanInputs, dict | None]:
    capture = json.loads(files["capture.json"])
    manifest = json.loads(files["package-manifest.json"]) if "package-manifest.json" in files else None
    inputs = ScanInputs(scan_id=capture["id"])
    inputs.surfaces = [Surface(s["id"], s["kind"], matrix(s["map_from_surface"]), s["dimensions_m"])
                       for s in capture.get("surfaces", [])]
    inputs.objects = [Box(o["id"], o["category"], matrix(o["map_from_object"]), o["dimensions_m"],
                          o.get("confidence", "unknown")) for o in capture.get("objects", [])]
    vertices, triangles = [], []
    for anchor in (manifest or {}).get("mesh_anchors", []):
        stride = anchor["vertex_stride"] // 4
        raw = np.frombuffer(files[anchor["vertices_asset"]], "<f4")
        local = raw[anchor["vertex_offset"] // 4:].reshape(-1, stride)[:anchor["vertex_count"], :3]
        dtype = "<u2" if anchor["bytes_per_index"] == 2 else "<u4"
        faces = np.frombuffer(files[anchor["faces_asset"]], dtype)[:anchor["face_count"] * 3].reshape(-1, 3)
        offset = sum(len(v) for v in vertices)
        vertices.append(transform(matrix(anchor["map_from_anchor"]), local.astype(np.float64)))
        triangles.append(faces.astype(np.int64) + offset)
    if vertices:
        inputs.mesh_vertices, inputs.mesh_triangles = np.concatenate(vertices), np.concatenate(triangles)
        inputs.sources["mesh"] = "native_arkit_mesh"
    observations = [o for o in (manifest or {}).get("observations", []) if o.get("raw_depth")]
    inputs.frames = [Frame(o["id"], _depth_points(o, files), o.get("rgb_asset")) for o in observations]
    if inputs.frames:
        inputs.points = np.concatenate([f.points[:, :3] for f in inputs.frames])
        inputs.sources["depth"] = "native_arkit_depth (binary_sidecars)"
    poses = [matrix(o["map_from_camera"])[:3, 3] for o in (manifest or {}).get("observations", []) if o.get("map_from_camera")]
    inputs.camera_positions = np.asarray(poses).reshape(-1, 3)
    inputs.sources["roomplan"] = f"{len(inputs.surfaces)} surfaces, {len(inputs.objects)} objects"
    return inputs, manifest


def context_from_archive(archive: bytes) -> ScanContext:
    files = members(archive)
    inputs, manifest = inputs_from_files(files)
    return ScanContext(inputs.scan_id, inputs, MemorySource(manifest, files))
