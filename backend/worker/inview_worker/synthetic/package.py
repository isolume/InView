"""Deterministic synthetic `.inviewscan.tar` in the iPhone's format (see CaptureStore.makeArchive).

A ray-cast 4 m × 4 m × 2.6 m room: camera at (0, 1.4, 0) looking −Z, a green EXIT sign centred on the
north wall at (0, 2.0, −2), RoomPlan floor/walls/door, a native ARKit mesh, one calibrated depth
observation (binary sidecars) and its upright 480×640 JPEG keyframe. Portable frames are omitted from
`capture.json`, as the iPhone does when its JSON layer is too large.

    python -m inview_worker.synthetic.package out.inviewscan.tar
"""
from __future__ import annotations

import io
import json
import sys
import tarfile

import cv2
import numpy as np

SCAN_ID = "synthetic-walk"
IMAGE_W, IMAGE_H, FOCAL, CX, CY = 1920, 1440, 1400.0, 960.0, 720.0
CAMERA = np.array([0.0, 1.4, 0.0])
SIGN_X, SIGN_Y = (-0.25, 0.25), (1.88, 2.12)
TRUTH = {
    "sign_center_m": [0.0, 2.0, -2.0],
    "floor_y_m": 0.0,
    "room_area_m2": 16.0,
    "door": {"id": "door", "width_m": 0.76, "height_m": 2.0},
}


def _pose(x=0.0, y=0.0, z=0.0, yaw=0.0) -> list[float]:
    c, s = np.cos(np.radians(yaw)), np.sin(np.radians(yaw))
    m = np.eye(4)
    m[:3, :3] = [[c, 0, s], [0, 1, 0], [-s, 0, c]]
    m[:3, 3] = [x, y, z]
    return m.reshape(-1, order="F").tolist()


def _rays(u: np.ndarray, v: np.ndarray) -> np.ndarray:
    """Camera rays (z = −1, ARKit depth is distance along −Z) for sensor-native normalized u/v."""
    return np.stack(((u * IMAGE_W - CX) / FOCAL, -(v * IMAGE_H - CY) / FOCAL, -np.ones_like(u)), -1)


def _cast(directions: np.ndarray) -> np.ndarray:
    depth = np.full(directions.shape[:-1], np.inf)
    for axis, bound in ((0, 2.0), (0, -2.0), (2, -2.0), (2, 2.0), (1, 0.0), (1, 2.6)):
        with np.errstate(divide="ignore", invalid="ignore"):
            s = (bound - CAMERA[axis]) / directions[..., axis]
            hit = CAMERA + directions * s[..., None]
        inside = ((s > 0) & (np.abs(hit[..., 0]) <= 2.001) & (np.abs(hit[..., 2]) <= 2.001)
                  & (hit[..., 1] >= -0.001) & (hit[..., 1] <= 2.601))
        depth = np.where(inside & (s < depth), s, depth)
    return depth


def depth_buffer(width: int = 256, height: int = 192) -> np.ndarray:
    v, u = np.mgrid[0:height, 0:width]
    return _cast(_rays((u + 0.5) / width, (v + 0.5) / height)).astype("<f4")


def keyframe(width: int = 480, height: int = 640) -> bytes:
    py, px = np.mgrid[0:height, 0:width]
    u, v = py / height, 1 - px / width  # upright JPEG = sensor-native landscape rotated right
    directions = _rays(u, v)
    with np.errstate(invalid="ignore"):
        hit = CAMERA + directions * _cast(directions)[..., None]
    image = np.full((height, width, 3), 170, np.uint8)
    image[hit[..., 1] < 0.01] = (120, 130, 140)
    sign = ((np.abs(hit[..., 2] + 2) < 0.01) & (hit[..., 0] > SIGN_X[0]) & (hit[..., 0] < SIGN_X[1])
            & (hit[..., 1] > SIGN_Y[0]) & (hit[..., 1] < SIGN_Y[1]))
    image[sign] = (40, 160, 30)
    ys, xs = np.nonzero(sign)
    scale = (xs.max() - xs.min()) / 110
    origin = (int(xs.min() + 0.12 * (xs.max() - xs.min())), int(ys.max() - 0.3 * (ys.max() - ys.min())))
    cv2.putText(image, "EXIT", origin, cv2.FONT_HERSHEY_SIMPLEX, scale, (255, 255, 255), 2)
    return cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 92])[1].tobytes()


def room_mesh(divisions: int = 8) -> tuple[np.ndarray, np.ndarray]:
    quads = [
        [(-2, 0, -2), (2, 0, -2), (2, 0, 2), (-2, 0, 2)],
        [(-2, 0, -2), (2, 0, -2), (2, 2.6, -2), (-2, 2.6, -2)],
        [(-2, 0, 2), (2, 0, 2), (2, 2.6, 2), (-2, 2.6, 2)],
        [(-2, 0, -2), (-2, 0, 2), (-2, 2.6, 2), (-2, 2.6, -2)],
        [(2, 0, -2), (2, 0, 2), (2, 2.6, 2), (2, 2.6, -2)],
    ]
    vertices, faces, n = [], [], divisions + 1
    for quad in quads:
        a, b, c, d = map(np.array, quad)
        base = len(vertices)
        for i in range(n):
            for j in range(n):
                s, t = i / divisions, j / divisions
                vertices.append((1 - s) * ((1 - t) * a + t * b) + s * ((1 - t) * d + t * c))
        for i in range(divisions):
            for j in range(divisions):
                k = base + i * n + j
                faces += [[k, k + 1, k + n], [k + 1, k + n + 1, k + n]]
    return np.asarray(vertices, "<f4"), np.asarray(faces, "<u4")


def capture_json(scan_id: str) -> dict:
    return {
        "schema_version": 1, "id": scan_id, "map_id": "synthetic-map", "floor_id": "ground",
        "coordinates": {"units": "meters", "up_axis": "y", "handedness": "right"},
        "metadata": {"source": "synthetic_ios_package", "raw_upload_omissions": ["depth_frames_exceed_upload_limit"]},
        "surfaces": [
            {"id": "floor", "kind": "floor", "map_from_surface": _pose(), "dimensions_m": [4, 0, 4]},
            {"id": "north", "kind": "wall", "map_from_surface": _pose(z=-2, y=1.3), "dimensions_m": [4, 2.6, 0]},
            {"id": "south", "kind": "wall", "map_from_surface": _pose(z=2, y=1.3), "dimensions_m": [4, 2.6, 0]},
            {"id": "east", "kind": "wall", "map_from_surface": _pose(x=2, y=1.3, yaw=90), "dimensions_m": [4, 2.6, 0]},
            {"id": "west", "kind": "wall", "map_from_surface": _pose(x=-2, y=1.3, yaw=90), "dimensions_m": [4, 2.6, 0]},
            {"id": "door", "kind": "door", "map_from_surface": _pose(x=1.2, z=2, y=1.0), "dimensions_m": [0.76, 2.0, 0]},
        ],
        "objects": [], "meshes": [], "frames": [],
    }


def build(scan_id: str = SCAN_ID) -> bytes:
    files: dict[str, bytes] = {
        "capture.json": json.dumps(capture_json(scan_id)).encode(),
        "roomplan.json": b"[]",
        "worldmap.archive": b"\x00",
    }
    depth = depth_buffer()
    files["f0.depth-f32le"] = depth.tobytes()
    files["f0.confidence-u8"] = np.full(depth.shape, 2, np.uint8).tobytes()
    files["f0.color.jpg"] = keyframe()
    vertices, faces = room_mesh()
    files["m0.mesh-vertices"] = vertices.tobytes()
    files["m0.mesh-faces"] = faces.tobytes()
    files["m0.mesh-normals"] = np.zeros_like(vertices).tobytes()
    files["m0.mesh-classification-u8"] = bytes(len(faces))
    manifest = {
        "schema_version": 1, "capture_id": scan_id, "map_id": "synthetic-map", "floor_id": "ground",
        "coordinate_frame": {"units": "meters", "up_axis": "y", "handedness": "right", "name": "shared_arkit_session"},
        "assets": [{"path": name, "role": "portable_capture" if name == "capture.json" else "opaque_sidecar",
                    "media_type": "application/octet-stream", "bytes": len(data)} for name, data in sorted(files.items())],
        "observations": [{
            "id": "f0", "timestamp_seconds": 1.0, "rgb_asset": "f0.color.jpg", "map_from_camera": _pose(y=1.4),
            "image": {"width": IMAGE_W, "height": IMAGE_H, "fx": FOCAL, "fy": FOCAL, "cx": CX, "cy": CY},
            "raw_depth": {"raw_asset": "f0.depth-f32le", "confidence_asset": "f0.confidence-u8", "smoothed_asset": None,
                          "width": 256, "height": 192, "bytes_per_row": 1024, "pixel_format": 1717855600,
                          "confidence_bytes_per_row": 256,
                          "environment": {"recorded_at_unix_seconds": 1_791_000_000.0, "latitude": 33.7756,
                                          "longitude": -84.3963, "horizontal_accuracy_m": 6.0,
                                          "heading_degrees": 90.0, "heading_accuracy_degrees": 10.0}},
        }],
        "mesh_anchors": [{
            "id": "m0", "map_from_anchor": _pose(), "vertices_asset": "m0.mesh-vertices", "faces_asset": "m0.mesh-faces",
            "normals_asset": "m0.mesh-normals", "classification_asset": "m0.mesh-classification-u8",
            "vertex_offset": 0, "vertex_stride": 12, "vertex_format": 30, "vertex_count": len(vertices),
            "bytes_per_index": 4, "face_count": len(faces), "indices_per_face": 3,
            "normal_offset": 0, "normal_stride": 12, "normal_format": 30,
        }],
    }
    files["package-manifest.json"] = json.dumps(manifest).encode()
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data in files.items():
            info = tarfile.TarInfo(f"{scan_id}/{name}")
            info.size, info.mtime = len(data), 0
            tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def members(archive: bytes) -> dict[str, bytes]:
    """Files of a package keyed by filename (for MemorySource-based tests)."""
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        return {m.name.split("/", 1)[1]: tar.extractfile(m).read() for m in tar.getmembers() if m.isfile()}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    with open(sys.argv[1], "wb") as output:
        output.write(build())
