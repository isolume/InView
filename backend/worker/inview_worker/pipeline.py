"""Gather scan evidence from the backend, run the OpenCV passes, and publish one analysis."""
from __future__ import annotations

import logging

import numpy as np

from .client import Backend, BackendError
from .core import ScanContext, Stage, registry, runner
from .geometry import matrix
from .inputs import Box, Frame, ScanInputs, Surface

log = logging.getLogger(__name__)


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


class BackendSource:
    """Package manifest and files of one scan, read through the authenticated API (cached)."""

    def __init__(self, backend: Backend, scan_id: str):
        self.backend, self.base = backend, f"/scans/{Backend.segment(scan_id)}"
        self._assets: dict[str, bytes | None] = {}

    def manifest(self) -> dict | None:
        return self.backend.optional_json(f"{self.base}/manifest")

    def asset(self, name: str) -> bytes | None:
        if name not in self._assets:
            try:
                self._assets[name] = self.backend.get_bytes(f"{self.base}/assets/{Backend.segment(name)}")
            except BackendError as error:
                if error.status != 404:
                    raise
                self._assets[name] = None
        return self._assets[name]


def analyze(ctx: ScanContext, stages: list[Stage] | None = None) -> dict:
    """Run every registered stage (or `stages`) and return the analysis document."""
    return runner.run(ctx, stages)


def process(backend: Backend, scan_id: str, publish: bool = True) -> dict:
    ctx = ScanContext(scan_id, gather(backend, scan_id), BackendSource(backend, scan_id))
    result = analyze(ctx)
    if publish:
        backend.put_json(f"/scans/{Backend.segment(scan_id)}/analysis", result)
        for publish_product in registry.publishers():
            try:
                publish_product(backend, scan_id, result, ctx.products)
            except Exception as error:  # noqa: BLE001 - a publisher must not lose the stored analysis
                log.error("publisher %s failed: %s", publish_product.__qualname__, error)
    return result
