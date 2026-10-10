"""Gather scan evidence from the backend, run the OpenCV passes, and publish one analysis."""
from __future__ import annotations

import base64
from datetime import datetime, timezone
from typing import Callable

import cv2
import numpy as np

from . import __version__, doors, floor_map, signs
from .client import Backend
from .geometry import matrix
from .inputs import Box, Frame, ScanInputs, Surface

NOTICE = ("Automated OpenCV screening of measured evidence. Floor maps, sign/text candidates, and "
          "clearance checks are NOT verified accessible routes or ADA certification; review before use.")


def _stack(rows: list, columns: int) -> np.ndarray:
    return np.asarray(rows, dtype=np.float64).reshape(-1, columns) if rows else np.zeros((0, columns))


def gather(backend: Backend, scan_id: str) -> ScanInputs:
    base = f"/scans/{Backend.segment(scan_id)}"
    original = backend.get_json(base)
    inputs = ScanInputs(scan_id=scan_id)
    inputs.surfaces = [Surface(s["id"], s["kind"], matrix(s["map_from_surface"]), s["dimensions_m"])
                       for s in original.get("surfaces", [])]
    inputs.objects = [Box(o["id"], o["category"], matrix(o["map_from_object"]), o["dimensions_m"],
                          o.get("confidence", "unknown")) for o in original.get("objects", [])]

    scene = None
    native = backend.optional_json(f"{base}/native-mesh")
    meshes = native["meshes"] if native else None
    inputs.sources["mesh"] = "native_arkit_mesh" if native else "none"
    if not meshes:
        scene = backend.get_json(f"{base}/scene")
        meshes = scene.get("meshes") or []
        if meshes:
            inputs.sources["mesh"] = "portable_scene_mesh"
    vertices, triangles, offset = [], [], 0
    for mesh in meshes:
        vertices.extend(mesh["vertices"])
        triangles.extend((np.asarray(mesh["triangles"], dtype=np.int64).reshape(-1, 3) + offset).tolist())
        offset += len(mesh["vertices"])
    inputs.mesh_vertices, inputs.mesh_triangles = _stack(vertices, 3), np.asarray(triangles, dtype=np.int64).reshape(-1, 3)

    preview = backend.optional_json(f"{base}/raw-preview?mode=smoothed&max_points=150000")
    if preview:
        inputs.sources["depth"] = f"native_arkit_depth ({preview.get('packageFormat', 'unknown')})"
        inputs.frames = [Frame(f["id"], _stack(f["points"], 5), f.get("colorAsset")) for f in preview["frames"]]
        inputs.points = np.concatenate([f.points[:, :3] for f in inputs.frames]) if inputs.frames else np.zeros((0, 3))
    else:
        scene = scene or backend.get_json(f"{base}/scene")
        inputs.points = _stack([p["position"] for p in scene.get("point_cloud", [])], 3)
        inputs.sources["depth"] = "portable_scene_point_cloud" if len(inputs.points) else "none"

    track = backend.optional_json(f"{base}/camera-track")
    inputs.camera_positions = _stack([p["position_m"] for p in (track or {}).get("poses", [])], 3)
    inputs.sources["camera_track"] = f"{len(inputs.camera_positions)} poses"
    inputs.sources["roomplan"] = f"{len(inputs.surfaces)} surfaces, {len(inputs.objects)} objects"
    return inputs


def analyze(inputs: ScanInputs, read_image: Callable[[str], np.ndarray | None]) -> dict:
    fm = floor_map.build(inputs)
    door_results = doors.check(inputs, fm)
    sign_results, keyframes = signs.analyze(inputs.frames, read_image)
    notices = [NOTICE]
    if fm is None:
        notices.append("No floor map: the scan has no usable floor, mesh, depth, or camera evidence.")
    if not keyframes:
        notices.append("No RGB keyframes were available, so signs and text were not analysed.")
    floor_result = None
    if fm is not None:
        floor_result = dict(fm.result)
        floor_result["image_png_base64"] = base64.b64encode(floor_map.render(fm, door_results)).decode()
    return {
        "schema_version": 1,
        "scan_id": inputs.scan_id,
        "frame": "shared_arkit_session",
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "worker": {"name": "inview-worker", "version": __version__, "opencv": cv2.__version__},
        "sources": inputs.sources,
        "floor_map": floor_result,
        "doors": door_results,
        "signs": sign_results,
        "summary": {
            "walkable_area_m2": floor_result["walkable_area_m2"] if floor_result else None,
            "narrow_passages": len(floor_result["narrow_passages"]) if floor_result else 0,
            "doors_checked": len(door_results),
            "doors_below_min_width": sum(not d["meets_clear_width"] for d in door_results),
            "sign_candidates": sum(s["kind"] != "text_region" for s in sign_results),
            "text_regions": sum(s["kind"] == "text_region" for s in sign_results),
            "keyframes_examined": keyframes,
        },
        "notices": notices,
    }


def process(backend: Backend, scan_id: str, publish: bool = True) -> dict:
    inputs = gather(backend, scan_id)
    base = f"/scans/{Backend.segment(scan_id)}"

    def read_image(name: str) -> np.ndarray | None:
        data = np.frombuffer(backend.get_bytes(f"{base}/color/{Backend.segment(name)}"), np.uint8)
        return cv2.imdecode(data, cv2.IMREAD_COLOR)

    result = analyze(inputs, read_image)
    if publish:
        backend.put_json(f"{base}/analysis", result)
    return result
