"""Replay a synthetic scan through the backend's continuous-capture `/streams` API, as the iPhone does.

Each package observation becomes a stream chunk: the upright keyframe is rotated back to the
sensor-native orientation the phone streams (with intrinsics scaled to it), depth sidecars become
portable depth values, and every chunk carries the observation's geographic/building environment
sample and interpolated movement poses since the previous keyframe. RoomPlan surfaces/objects ride in
the first chunk; `semantics.json` (navigation context) and the native `roomplan.json` are attached
before finishing. The backend reconstructs the stream and packages it as a scan for the analysis
pipeline, exactly like a real continuous scan.

    python -m inview_worker.synthetic.stream --url http://127.0.0.1:3000 [--seed 1] [--building]
"""
from __future__ import annotations

import argparse
import base64
import json
import sys
import time
import uuid

import cv2
import numpy as np

from ..client import Backend, BackendError
from . import building as building_module
from . import package as package_module

SENSOR_LONG_SIDE = 640  # Phone streams keep colour ≤ 1 MP; depth must share the image's aspect ratio.


def _matrix(values) -> np.ndarray:
    return np.asarray(values, dtype=np.float64).reshape(4, 4, order="F")


def _column_major(m: np.ndarray) -> list[float]:
    return [round(float(v), 6) for v in m.reshape(-1, order="F")]


def _movement(previous: np.ndarray | None, current: np.ndarray, t0: float, t1: float, steps: int = 3) -> list[dict]:
    """Poses strictly between two keyframes: translation interpolated, rotation of the later frame."""
    if previous is None or t1 <= t0:
        return []
    poses = []
    for k in range(1, steps + 1):
        alpha = k / (steps + 1)
        m = current.copy()
        m[:3, 3] = (1 - alpha) * previous[:3, 3] + alpha * current[:3, 3]
        poses.append({"t": round(t0 + alpha * (t1 - t0), 6), "m": _column_major(m), "tracking": "normal",
                      "mapping": "mapped"})
    return poses


def chunks_from_package(archive: bytes) -> tuple[dict, list[dict], dict[str, bytes]]:
    """(stream manifest, chunks, attachments) reproducing what the iPhone streams for this scan."""
    files = package_module.members(archive)
    capture = json.loads(files["capture.json"])
    manifest = json.loads(files["package-manifest.json"])
    capture_id = capture["id"]
    stream_id = capture_id if len(capture_id) == 36 else str(uuid.uuid5(uuid.NAMESPACE_URL, f"inview:{capture_id}"))
    stream_manifest = {"schema_version": 1, "id": stream_id, "map_id": stream_id, "floor_id": capture.get("floor_id", "ground"),
                       "coordinates": capture["coordinates"]}
    chunks, previous, previous_t = [], None, None
    observations = [o for o in manifest.get("observations", []) if o.get("raw_depth") and o.get("rgb_asset")]
    for sequence, observation in enumerate(sorted(observations, key=lambda o: o["timestamp_seconds"])):
        upright = cv2.imdecode(np.frombuffer(files[observation["rgb_asset"]], np.uint8), cv2.IMREAD_COLOR)
        sensor = cv2.rotate(upright, cv2.ROTATE_90_COUNTERCLOCKWISE)  # Undo the upright (clockwise) rotation.
        image = observation["image"]
        scale = SENSOR_LONG_SIDE / max(image["width"], image["height"])
        width, height = round(image["width"] * scale), round(image["height"] * scale)
        sensor = cv2.resize(sensor, (width, height), interpolation=cv2.INTER_AREA)
        jpeg = cv2.imencode(".jpg", sensor, [cv2.IMWRITE_JPEG_QUALITY, 85])[1].tobytes()
        depth = observation["raw_depth"]
        dw, dh, row = depth["width"], depth["height"], depth["bytes_per_row"]
        values = np.frombuffer(files[depth["raw_asset"]], "<f4").reshape(dh, row // 4)[:, :dw]
        confidence = (np.frombuffer(files[depth["confidence_asset"]], np.uint8)
                      .reshape(dh, depth.get("confidence_bytes_per_row") or dw)[:, :dw]
                      if depth.get("confidence_asset") else np.full((dh, dw), 2, np.uint8))
        depth_values = [round(float(v), 4) if np.isfinite(v) and v > 0 else None for v in values.reshape(-1)]
        pose = _matrix(observation["map_from_camera"])
        t = float(observation["timestamp_seconds"])
        chunk = {
            "sequence": sequence,
            "color_jpeg": base64.b64encode(jpeg).decode(),
            "frame": {"id": observation["id"], "timestamp_seconds": t, "pixel_orientation": "sensor_native",
                      "map_from_camera": _column_major(pose),
                      "camera": {"image_width": width, "image_height": height, "fx": image["fx"] * scale,
                                 "fy": image["fy"] * scale, "cx": image["cx"] * scale, "cy": image["cy"] * scale},
                      "depth": {"width": dw, "height": dh, "values_m": depth_values,
                                "confidence": [int(min(2, c)) for c in confidence.reshape(-1)]}},
            "surfaces": capture.get("surfaces", []) if sequence == 0 else [],
            "objects": capture.get("objects", []) if sequence == 0 else [],
            "poses": _movement(previous, pose, previous_t or 0.0, t),
        }
        if depth.get("environment"):
            chunk["environment"] = {k: v for k, v in depth["environment"].items() if v is None or isinstance(v, (int, float))}
        chunks.append(chunk)
        previous, previous_t = pose, t
    attachments = {name: files[name] for name in ("roomplan.json", "semantics.json", "text-observations.json")
                   if name in files and files[name] not in (b"[]", b"")}
    return stream_manifest, chunks, attachments


def replay(backend: Backend, archive: bytes, semantics: dict | None = None, wait_seconds: float = 300) -> str:
    """Streams the scan, finishes it, requests the reconstruction and waits until the backend has
    packaged it as a scan. Returns the scan id."""
    manifest, chunks, attachments = chunks_from_package(archive)
    if semantics is not None:
        attachments["semantics.json"] = json.dumps(semantics).encode()
    stream_id = manifest["id"]
    base = f"/streams/{stream_id}"
    backend._request("POST", "/streams", json.dumps(manifest).encode())
    for chunk in chunks:
        backend._request("PUT", f"{base}/chunks/{chunk['sequence']}", json.dumps(chunk).encode())
    for name, data in attachments.items():
        backend._request("PUT", f"{base}/assets/{name}", data)
    backend._request("POST", f"{base}/finish", json.dumps({"chunk_count": len(chunks)}).encode())
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            backend.get_bytes(f"{base}/result")
            break
        except BackendError as error:
            if error.status not in (503, 409) or time.monotonic() > deadline:
                raise
            time.sleep(2)
    while backend.optional_json(f"/scans/{stream_id}/manifest") is None:
        if time.monotonic() > deadline:
            raise TimeoutError("The backend did not package the stream as a scan in time.")
        time.sleep(1)
    return stream_id


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://127.0.0.1:3000")
    parser.add_argument("--token-file")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--building", action="store_true", help="multi-room building instead of the single room")
    args = parser.parse_args(argv)
    token = None
    if args.token_file:
        with open(args.token_file) as handle:
            token = handle.read().strip() or None
    if args.building:
        archive, truth = building_module.build(seed=args.seed, max_observations=24)
        reference = truth.get("georef") or {}
    else:
        archive, reference = package_module.build(), {}
    semantics = {"schema_version": 1, "coordinate_frame": "shared_arkit_session",
                 "access_points": [{"id": "synthetic-pin", "kind": "destination", "name": "Main Reception",
                                    "position": [0.0, 0.0, 0.0], "source": "manual"}]}
    if reference.get("latitude") is not None:
        semantics["geographic_reference"] = {k: reference[k] for k in ("latitude", "longitude", "heading_degrees")
                                             if k in reference}
    scan_id = replay(Backend(args.url, token), archive, semantics)
    print(scan_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
