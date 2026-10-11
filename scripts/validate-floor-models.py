#!/usr/bin/env python3
"""Validate standalone floor GLBs, their combined export, and the offline viewer.

Requires NumPy. The default paths validate the current InView Floor 2 scan model
and retained Floor 3 video model; no assumption is made that both share provenance.
Only the validation JSON is written. All model and archive files are read-only.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys
import zipfile

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DIR = ROOT / "models/walkthrough-building/floors-2-3"
DEFAULT_ARCHIVE = ROOT / "models/walkthrough-building/floors-2-3-video.zip"
COMPONENTS = {5120: (np.dtype("i1"), 1), 5121: (np.dtype("u1"), 1),
              5122: (np.dtype("<i2"), 2), 5123: (np.dtype("<u2"), 2),
              5125: (np.dtype("<u4"), 4), 5126: (np.dtype("<f4"), 4)}
TYPES = {"SCALAR": (1, 1), "VEC2": (1, 2), "VEC3": (1, 3), "VEC4": (1, 4),
         "MAT2": (2, 2), "MAT3": (3, 3), "MAT4": (4, 4)}
WORLD_TOLERANCE_M = 1e-5
VIEWER_TOLERANCE_M = 1.1e-5  # Viewer vertices and normals are serialized to five decimals.
NORMAL_TOLERANCE = 1e-4
DOUBLED_TRIANGLE_AREA_THRESHOLD = 1e-12


def sha(data): return hashlib.sha256(data).hexdigest()

def require(condition, message):
    if not condition: raise ValueError(message)


def integer(value, label, minimum=0):
    require(isinstance(value, int) and not isinstance(value, bool) and value >= minimum, f"{label} must be an integer >= {minimum}")
    return value


def finite_array(values, shape, label):
    array = np.asarray(values, dtype=np.float64)
    require(array.shape == shape and np.isfinite(array).all(), f"{label} must contain finite values with shape {shape}")
    return array


def node_matrix(node):
    if "matrix" in node:
        require(not any(k in node for k in ("translation", "rotation", "scale")), "Node matrix and TRS cannot both be present")
        matrix = finite_array(node["matrix"], (16,), "Node matrix").reshape(4, 4, order="F")
        require(np.allclose(matrix[3], [0, 0, 0, 1], atol=1e-7, rtol=0), "Node matrix is not affine")
        return matrix
    translation = finite_array(node.get("translation", [0, 0, 0]), (3,), "Node translation")
    scale = finite_array(node.get("scale", [1, 1, 1]), (3,), "Node scale")
    x, y, z, w = finite_array(node.get("rotation", [0, 0, 0, 1]), (4,), "Node quaternion")
    require(abs(x*x + y*y + z*z + w*w - 1) <= 1e-5, "Node quaternion is not normalized")
    rotation = np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
                         [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
                         [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]])
    result = np.eye(4); result[:3, :3] = rotation @ np.diag(scale); result[:3, 3] = translation
    return result


def triangles(indices, mode):
    if mode == 4:
        require(len(indices) % 3 == 0, "Triangle index count is not divisible by three")
        return indices.reshape(-1, 3)
    if mode == 5:
        rows = [[indices[i], indices[i+1], indices[i+2]] if i % 2 == 0 else [indices[i+1], indices[i], indices[i+2]]
                for i in range(max(0, len(indices)-2))]
        return np.asarray(rows, dtype=np.int64).reshape(-1, 3)
    if mode == 6:
        return np.asarray([[indices[0], indices[i], indices[i+1]] for i in range(1, len(indices)-1)], dtype=np.int64).reshape(-1, 3)
    require(mode in (0, 1, 2, 3), f"Invalid primitive mode {mode}")
    return np.empty((0, 3), dtype=np.int64)


class GLB:
    def __init__(self, path):
        self.path = path; self.bytes = path.read_bytes(); self.document = {}; self.binary = b""
        self.arrays = []; self.primitives = []; self.world_objects = []
        self.report = {"file": path.name, "sha256": sha(self.bytes), "bytes": len(self.bytes),
                       "passed": False, "errors": [], "warnings": [], "counts": {}}
        self.normal_min = math.inf; self.normal_max = -math.inf; self.minimum_area = math.inf

    def error(self, label, exception): self.report["errors"].append(f"{label}: {exception}")

    def read_chunks(self):
        require(len(self.bytes) >= 20, "GLB is shorter than its header and first chunk")
        magic, version, declared = struct.unpack_from("<III", self.bytes)
        require(magic == 0x46546C67 and version == 2, "Invalid GLB magic or version")
        require(declared == len(self.bytes), "GLB declared length differs from file length")
        offset, chunks = 12, []
        while offset < len(self.bytes):
            require(offset % 4 == 0 and offset + 8 <= len(self.bytes), "Invalid GLB chunk alignment/header range")
            length, kind = struct.unpack_from("<II", self.bytes, offset); offset += 8
            require(length % 4 == 0 and offset + length <= len(self.bytes), "Invalid GLB chunk length/range")
            chunks.append((kind, self.bytes[offset:offset+length])); offset += length
        require(chunks and chunks[0][0] == 0x4E4F534A, "JSON must be the first GLB chunk")
        require(sum(kind == 0x4E4F534A for kind, _ in chunks) == 1, "GLB requires exactly one JSON chunk")
        require(sum(kind == 0x004E4942 for kind, _ in chunks) <= 1, "GLB has multiple BIN chunks")
        self.document = json.loads(chunks[0][1]); self.binary = next((data for kind, data in chunks if kind == 0x004E4942), b"")
        require(self.document.get("asset", {}).get("version") == "2.0", "Asset version is not glTF 2.0")
        buffers = self.document.get("buffers", [])
        require(len(buffers) == 1 and "uri" not in buffers[0], "Standalone GLB must use exactly one embedded BIN buffer")
        declared_buffer = integer(buffers[0].get("byteLength"), "Buffer byteLength", 1)
        require(declared_buffer <= len(self.binary) <= declared_buffer + 3, "BIN padding or declared buffer length is invalid")
        for index, view in enumerate(self.document.get("bufferViews", [])):
            require(view.get("buffer") == 0, f"bufferView {index} references another buffer")
            start = integer(view.get("byteOffset", 0), "bufferView byteOffset")
            length = integer(view.get("byteLength"), "bufferView byteLength", 1)
            require(start + length <= declared_buffer, f"bufferView {index} exceeds declared buffer")
            if "byteStride" in view:
                stride = integer(view["byteStride"], "bufferView byteStride", 4)
                require(stride <= 252 and stride % 4 == 0, f"bufferView {index} has invalid byteStride")
            if "target" in view: require(view["target"] in (34962, 34963), f"bufferView {index} has invalid target")
        self.report["counts"].update({key: len(self.document.get(key, [])) for key in
                                     ("scenes", "nodes", "meshes", "materials", "buffers", "bufferViews", "accessors", "textures", "images")})

    def data_array(self, view_index, offset, count, component, data_type, stride_override=None):
        views = self.document.get("bufferViews", [])
        require(isinstance(view_index, int) and 0 <= view_index < len(views), "Accessor bufferView index is invalid")
        require(component in COMPONENTS and data_type in TYPES, "Accessor componentType or type is invalid")
        view = views[view_index]; dtype, size = COMPONENTS[component]; columns, rows = TYPES[data_type]
        offset = integer(offset, "Accessor byteOffset")
        # glTF pads each matrix column to four-byte boundaries for small components.
        column_stride = ((rows * size + 3) // 4) * 4 if columns > 1 else rows * size
        element_size = columns * column_stride
        stride = stride_override if stride_override is not None else view.get("byteStride", element_size)
        require(stride >= element_size and stride % size == 0, "Accessor stride is shorter than element or misaligned")
        start = view.get("byteOffset", 0) + offset
        require(offset % size == 0 and start % size == 0, "Accessor component alignment is invalid")
        require(offset + (count-1) * stride + element_size <= view["byteLength"], "Accessor exceeds bufferView byte range")
        if columns > 1 and column_stride != rows * size:
            fields = [np.ndarray((count,), dtype=dtype, buffer=self.binary, offset=start + col * column_stride + row * size,
                                 strides=(stride,)) for col in range(columns) for row in range(rows)]
            return np.stack(fields, axis=1).copy()
        return np.ndarray((count, columns*rows), dtype=dtype, buffer=self.binary, offset=start,
                          strides=(stride, size)).copy()

    def accessor(self, index, accessor):
        count = integer(accessor.get("count"), "Accessor count", 1)
        component, data_type = accessor.get("componentType"), accessor.get("type")
        require(component in COMPONENTS and data_type in TYPES, "Accessor componentType/type is unsupported")
        if "bufferView" in accessor:
            array = self.data_array(accessor["bufferView"], accessor.get("byteOffset", 0), count, component, data_type)
        else:
            require("sparse" in accessor, "Accessor has neither a bufferView nor sparse values")
            columns, rows = TYPES[data_type]; array = np.zeros((count, columns * rows), dtype=COMPONENTS[component][0])
        if "sparse" in accessor:
            sparse = accessor["sparse"]; n = integer(sparse.get("count"), "Sparse count", 1)
            require(n <= count, "Sparse count exceeds accessor count")
            ind, val = sparse["indices"], sparse["values"]
            require(ind.get("componentType") in (5121, 5123, 5125), "Sparse index componentType is invalid")
            indices = self.data_array(ind["bufferView"], ind.get("byteOffset", 0), n, ind["componentType"], "SCALAR", COMPONENTS[ind["componentType"]][1]).ravel()
            require(indices.max() < count and np.all(indices[1:] > indices[:-1]), "Sparse indices must be strictly increasing and in range")
            columns, rows = TYPES[data_type]; size = COMPONENTS[component][1]
            packed_stride = columns * (((rows*size+3)//4)*4 if columns > 1 else rows*size)
            values = self.data_array(val["bufferView"], val.get("byteOffset", 0), n, component, data_type, packed_stride)
            array[indices] = values
        require(np.isfinite(array).all(), "Accessor has nonfinite numeric values")
        for key, actual in (("min", array.min(axis=0)), ("max", array.max(axis=0))):
            if key in accessor:
                declared = finite_array(accessor[key], (array.shape[1],), f"Accessor declared {key}")
                tolerance = np.maximum(1e-7, np.abs(actual) * 1e-6) if component == 5126 else 0
                require(np.all(abs(actual - declared) <= tolerance), f"Accessor declared {key} does not match numeric values")
        self.report["counts"]["numeric_components_checked"] = self.report["counts"].get("numeric_components_checked", 0) + array.size
        if accessor.get("normalized", False):
            require(component != 5126, "Float accessor cannot be normalized")
            if np.issubdtype(array.dtype, np.signedinteger): array = np.maximum(array.astype(np.float64)/np.iinfo(array.dtype).max, -1)
            else: array = array.astype(np.float64)/np.iinfo(array.dtype).max
        return array

    def read_meshes(self):
        for mesh_index, mesh in enumerate(self.document.get("meshes", [])):
            mesh_primitives = []
            for primitive_index, primitive in enumerate(mesh.get("primitives", [])):
                try:
                    attrs = primitive.get("attributes", {}); require("POSITION" in attrs, "Primitive is missing POSITION")
                    def attribute(name):
                        index = attrs[name]; require(isinstance(index, int) and 0 <= index < len(self.arrays), f"{name} accessor index is invalid")
                        require(self.arrays[index] is not None, f"{name} accessor failed validation")
                        return self.arrays[index]
                    positions = attribute("POSITION"); require(positions.shape[1] == 3, "POSITION is not VEC3")
                    for name in attrs:
                        require(len(attribute(name)) == len(positions), f"Attribute {name} count differs from POSITION")
                        accessor = self.document["accessors"][attrs[name]]
                        if "bufferView" in accessor:
                            view = self.document["bufferViews"][accessor["bufferView"]]
                            require((view.get("byteOffset", 0) + accessor.get("byteOffset", 0)) % 4 == 0,
                                    f"Vertex attribute {name} is not four-byte aligned")
                            require(accessor.get("byteOffset", 0) % 4 == 0, f"Vertex attribute {name} byteOffset is not four-byte aligned")
                    normals = attribute("NORMAL") if "NORMAL" in attrs else None
                    if normals is not None:
                        require(normals.shape == positions.shape, "NORMAL is not matching VEC3")
                        lengths = np.linalg.norm(normals, axis=1)
                        self.normal_min = min(self.normal_min, float(lengths.min())); self.normal_max = max(self.normal_max, float(lengths.max()))
                        require(np.all(abs(lengths-1) <= NORMAL_TOLERANCE), "Primitive contains non-unit normals")
                        self.report["counts"]["normals_checked"] = self.report["counts"].get("normals_checked", 0) + len(normals)
                    else: self.report["warnings"].append(f"mesh {mesh_index} primitive {primitive_index} has no normals")
                    if "indices" in primitive:
                        index = primitive["indices"]; require(isinstance(index, int) and 0 <= index < len(self.arrays), "Index accessor reference is invalid")
                        require(self.document["accessors"][index]["componentType"] in (5121, 5123, 5125), "Index accessor must use an unsigned integer component")
                        require(not self.document["accessors"][index].get("normalized", False), "Index accessor cannot be normalized")
                        require(self.document["accessors"][index]["type"] == "SCALAR" and self.arrays[index] is not None, "Index accessor is invalid")
                        indices = self.arrays[index].ravel().astype(np.int64)
                    else: indices = np.arange(len(positions), dtype=np.int64)
                    require(indices.size and indices.min() >= 0 and indices.max() < len(positions), "Primitive index is outside vertex range")
                    tri = triangles(indices, primitive.get("mode", 4))
                    if len(tri):
                        points = positions[tri].astype(np.float64); doubled = np.linalg.norm(np.cross(points[:,1]-points[:,0], points[:,2]-points[:,0]), axis=1)
                        self.minimum_area = min(self.minimum_area, float(doubled.min())/2)
                        count = int(np.count_nonzero(doubled <= DOUBLED_TRIANGLE_AREA_THRESHOLD))
                        self.report["counts"]["degenerate_triangles"] = self.report["counts"].get("degenerate_triangles", 0) + count
                        if count:
                            self.error(f"mesh {mesh_index} primitive {primitive_index}", ValueError(f"Primitive contains {count} degenerate triangles"))
                    if "material" in primitive: require(0 <= primitive["material"] < len(self.document.get("materials", [])), "Material reference is invalid")
                    mesh_primitives.append({"positions": positions.astype(np.float64), "normals": normals, "triangles": tri})
                    for name, count in (("mesh_primitives", 1), ("unique_mesh_vertices", len(positions)), ("indices_checked", len(indices)), ("unique_mesh_triangles", len(tri))):
                        self.report["counts"][name] = self.report["counts"].get(name, 0) + count
                except (ValueError, IndexError, KeyError, TypeError) as exc: self.error(f"mesh {mesh_index} primitive {primitive_index}", exc)
            self.primitives.append(mesh_primitives)

    def scene_graph(self):
        nodes, scenes = self.document.get("nodes", []), self.document.get("scenes", [])
        require(scenes, "GLB has no scene")
        selected = integer(self.document.get("scene", 0), "Default scene")
        require(selected < len(scenes), "Default scene index is invalid")
        matrices, parents = [], {}
        for index, node in enumerate(nodes):
            matrices.append(node_matrix(node))
            if "mesh" in node: require(isinstance(node["mesh"], int) and 0 <= node["mesh"] < len(self.primitives), f"Node {index} mesh reference is invalid")
            children = node.get("children", []); require(len(children) == len(set(children)), f"Node {index} repeats children")
            for child in children:
                require(isinstance(child, int) and 0 <= child < len(nodes), f"Node {index} child reference is invalid")
                require(child not in parents, f"Node {child} has multiple parents")
                parents[child] = index
        reached, world = set(), {}
        def visit(index, parent, stack, inherited_floor=None, collect=True):
            require(index not in stack, "Scene graph contains a cycle")
            matrix = parent @ matrices[index]; require(np.isfinite(matrix).all(), f"Node {index} world matrix is nonfinite")
            require(index not in world or np.allclose(world[index], matrix, atol=1e-10, rtol=0), "Node is reached with conflicting world transforms")
            world[index] = matrix
            if collect: reached.add(index)
            node = nodes[index]
            floor = node.get("extras", {}).get("floor", inherited_floor)
            if collect and "mesh" in node and index not in mesh_visited:
                mesh_visited.add(index); objects = []
                for primitive in self.primitives[node["mesh"]]:
                    p = primitive["positions"]; positions = p @ matrix[:3,:3].T + matrix[:3,3]
                    require(np.isfinite(positions).all(), f"Node {index} has nonfinite world vertices")
                    normals = None
                    if primitive["normals"] is not None:
                        require(abs(np.linalg.det(matrix[:3,:3])) > 1e-15, f"Node {index} normal matrix is singular")
                        normals = primitive["normals"] @ np.linalg.inv(matrix[:3,:3])
                        lengths = np.linalg.norm(normals, axis=1); require(np.isfinite(lengths).all() and np.all(lengths > 0), "World normals are invalid")
                        normals /= lengths[:, None]
                    tri = primitive["triangles"]
                    if len(tri):
                        q = positions[tri]; doubled = np.linalg.norm(np.cross(q[:,1]-q[:,0], q[:,2]-q[:,0]), axis=1)
                        count = int(np.count_nonzero(doubled <= DOUBLED_TRIANGLE_AREA_THRESHOLD))
                        if count:
                            self.error(f"node {index} world geometry", ValueError(f"Node has {count} degenerate world triangles"))
                    objects.append({"positions": positions, "normals": normals, "triangles": tri})
                self.world_objects.append({"node_index": index, "name": node.get("name", f"node-{index}"), "floor": floor,
                                           "extras": node.get("extras", {}), "matrix": matrix, "primitives": objects})
            for child in node.get("children", []): visit(child, matrix, stack | {index}, floor, collect)
        mesh_visited = set()
        for scene_index, scene in enumerate(scenes):
            roots = scene.get("nodes", []); require(len(roots) == len(set(roots)), f"Scene {scene_index} repeats roots")
            for index in roots:
                require(isinstance(index, int) and 0 <= index < len(nodes), f"Scene {scene_index} root reference is invalid")
                require(index not in parents, f"Scene {scene_index} root is also a child")
                visit(index, np.eye(4), set(), collect=scene_index == selected)
        # Validate cycles even in graph branches not reached from the selected scene.
        for index in range(len(nodes)):
            chain, cursor = set(), index
            while cursor in parents:
                require(cursor not in chain, "Unused scene graph branch contains a cycle")
                chain.add(cursor); cursor = parents[cursor]
        counts = self.report["counts"]
        counts["mesh_nodes"] = len(self.world_objects); counts["scene_nodes_reached"] = len(reached)
        counts["instanced_triangles"] = sum(len(p["triangles"]) for obj in self.world_objects for p in obj["primitives"])
        counts["mesh_nodes_by_floor"] = dict(Counter(str(obj["floor"]) for obj in self.world_objects))
        counts["estimated_from_video_by_floor"] = {str(floor): dict(Counter(str(obj["extras"].get("estimated_from_video")) for obj in self.world_objects if obj["floor"] == floor)) for floor in set(obj["floor"] for obj in self.world_objects)}
        require(self.world_objects, "Scene has no mesh nodes")
        all_positions = np.concatenate([p["positions"] for obj in self.world_objects for p in obj["primitives"]])
        low, high = all_positions.min(axis=0), all_positions.max(axis=0)
        self.report["bounds_y_up_m"] = {"min": low.tolist(), "max": high.tolist(), "dimensions": (high-low).tolist()}

    def validate(self):
        try: self.read_chunks()
        except (ValueError, IndexError, KeyError, TypeError, struct.error) as exc: self.error("GLB container", exc); return self
        for index, accessor in enumerate(self.document.get("accessors", [])):
            try: self.arrays.append(self.accessor(index, accessor))
            except (ValueError, IndexError, KeyError, TypeError) as exc: self.arrays.append(None); self.error(f"accessor {index}", exc)
        self.read_meshes()
        try: self.scene_graph()
        except (ValueError, IndexError, KeyError, TypeError, np.linalg.LinAlgError) as exc: self.error("scene graph", exc)
        if math.isfinite(self.normal_min): self.report["normal_length_range"] = [self.normal_min, self.normal_max]
        if math.isfinite(self.minimum_area): self.report["minimum_triangle_area_local_m2"] = self.minimum_area
        self.report["passed"] = not self.report["errors"]
        return self


def sorted_triangles(obj):
    """Canonicalize world triangle coordinates without relying on vertex/node order."""
    rows = []
    for primitive in obj["primitives"]:
        points = primitive["positions"][primitive["triangles"]]
        # Sorted vertices discard only cyclic starting point and winding, retaining
        # every triangle's exact three coordinates and its multiplicity.
        ordered = []
        for tri in points:
            order = np.lexsort((tri[:,2], tri[:,1], tri[:,0])); ordered.append(tri[order].ravel())
        if ordered: rows.append(np.asarray(ordered))
    if not rows: return np.empty((0,9))
    result = np.concatenate(rows); order = np.lexsort(tuple(result[:,i] for i in range(8,-1,-1)))
    return result[order]


def compare_floor_exports(combined, floors):
    errors, maximum, compared = [], 0.0, 0
    by_name = {(obj["floor"], obj["name"]): obj for obj in combined.world_objects}
    if len(by_name) != len(combined.world_objects): errors.append("Combined model repeats floor/name mesh identities")
    expected = set()
    for floor, model in floors.items():
        seen = set()
        for obj in model.world_objects:
            key = (floor, obj["name"]); expected.add(key)
            if obj["floor"] != floor: errors.append(f"{model.path.name}: node {obj['name']} has floor {obj['floor']} metadata")
            if key in seen: errors.append(f"{model.path.name}: duplicate node name {obj['name']}")
            seen.add(key)
            other = by_name.get(key)
            if other is None: errors.append(f"Combined model is missing floor {floor} node {obj['name']}"); continue
            a, b = sorted_triangles(obj), sorted_triangles(other)
            if a.shape != b.shape: errors.append(f"Floor {floor} node {obj['name']}: standalone/combined triangle count differs"); continue
            difference = float(np.max(abs(a-b))) if a.size else 0; maximum = max(maximum, difference); compared += 1
            if difference > WORLD_TOLERANCE_M: errors.append(f"Floor {floor} node {obj['name']}: world geometry differs by {difference:.8g} m")
    extra = set(by_name) - expected
    if extra: errors.append(f"Combined model has {len(extra)} nodes absent from standalone floor exports")
    return {"passed": not errors, "errors": errors, "combined_is_union_of_floor_exports": not errors,
            "objects_compared": compared, "maximum_world_geometry_difference_m": maximum,
            "tolerance_m": WORLD_TOLERANCE_M, "identity": "floor extras and node names; world triangle coordinates are canonicalized"}


def viewer_check(path, combined):
    source = path.read_bytes(); scene = json.loads(source); errors = []; by_floor = defaultdict(list); count = 0
    for index, mesh in enumerate(scene["meshes"]):
        try:
            vertices = np.asarray(mesh["vertices"], dtype=np.float64); normals = np.asarray(mesh["normals"], dtype=np.float64); tri = np.asarray(mesh["triangles"], dtype=np.int64)
            require(vertices.ndim == 2 and vertices.shape[1] == 3 and np.isfinite(vertices).all(), "Viewer vertices are invalid")
            require(normals.shape == vertices.shape and np.isfinite(normals).all(), "Viewer normals are invalid")
            require(np.all(abs(np.linalg.norm(normals,axis=1)-1) <= NORMAL_TOLERANCE), "Viewer normals are not unit vectors")
            require(tri.ndim == 2 and tri.shape[1] == 3 and tri.size and tri.min() >= 0 and tri.max() < len(vertices), "Viewer triangle indices are invalid")
            by_floor[mesh["floor"]].append(vertices); count += len(tri)
        except (ValueError, IndexError, KeyError, TypeError) as exc: errors.append(f"Viewer mesh {index}: {exc}")
    report = {"file": path.name, "sha256": sha(source), "passed": False, "errors": errors, "triangle_count": count,
              "bounds_tolerance_m": VIEWER_TOLERANCE_M, "floors": {}}
    if by_floor:
        all_positions = np.concatenate([p for arrays in by_floor.values() for p in arrays]); bounds = np.array([all_positions.min(0),all_positions.max(0)])
        declared = np.array([scene["bounds"]["min"],scene["bounds"]["max"]],dtype=np.float64)
        require(declared.shape == (2,3) and np.isfinite(declared).all(), "Viewer declared bounds are invalid")
        difference = float(np.max(abs(bounds-declared))); report["declared_bounds_maximum_difference_m"] = difference
        if difference > VIEWER_TOLERANCE_M: errors.append(f"Viewer declared bounds differ from vertices by {difference:.8g} m")
        if count != combined.report["counts"].get("instanced_triangles"): errors.append("Viewer triangle count differs from combined GLB")
        for floor, arrays in by_floor.items():
            meshes = [obj for obj in combined.world_objects if obj["floor"] == floor]
            if not meshes: errors.append(f"Viewer floor {floor} has no matching GLB geometry"); continue
            world = np.concatenate([p["positions"] for obj in meshes for p in obj["primitives"]]); viewer = np.concatenate(arrays)
            delta = float(np.max(abs(np.array([viewer.min(0),viewer.max(0)])-np.array([world.min(0),world.max(0)]))))
            viewer_count = sum(len(mesh["triangles"]) for mesh in scene["meshes"] if mesh["floor"] == floor)
            glb_count = sum(len(p["triangles"]) for obj in meshes for p in obj["primitives"])
            report["floors"][str(floor)] = {"viewer_meshes": len(arrays), "glb_mesh_nodes": len(meshes), "viewer_triangles": viewer_count,
                                             "glb_triangles": glb_count, "maximum_bounds_difference_m": delta}
            if len(arrays) != len(meshes) or viewer_count != glb_count or delta > VIEWER_TOLERANCE_M: errors.append(f"Viewer floor {floor} bounds or counts differ from combined GLB")
    report["passed"] = not errors
    return report, scene


def retained_floor_check(directory, archive_path, scene):
    errors, files = [], []
    with zipfile.ZipFile(archive_path) as archive:
        for name in ("floor-3.glb", "floor-3.usdz", "floor-3.png", "floor-3-plan.png"):
            archived = archive.read("floors-2-3/" + name); current = (directory/name).read_bytes(); unchanged = sha(archived) == sha(current)
            files.append({"file": name, "archive_sha256": sha(archived), "current_sha256": sha(current), "unchanged": unchanged})
            if not unchanged: errors.append(f"Retained {name} changed from video archive")
        original = json.loads(archive.read("floors-2-3/viewer-scene.json"))
    old = {m["name"]: m for m in original["meshes"] if m["floor"] == 3}; new = {m["name"]: m for m in scene["meshes"] if m["floor"] == 3}
    require(len(old) == len([m for m in original["meshes"] if m["floor"] == 3]) and len(new) == len([m for m in scene["meshes"] if m["floor"] == 3]), "Floor 3 viewer repeats mesh names")
    if set(old) != set(new): errors.append("Retained Floor 3 viewer mesh identities changed")
    maximum = 0; exact = 0
    for name in set(old) & set(new):
        a, b = old[name], new[name]
        if a == b: exact += 1; continue
        if a["triangles"] != b["triangles"] or a["color"] != b["color"] or a.get("zone") != b.get("zone"): errors.append(f"Floor 3 viewer mesh {name}: topology, color or zone changed")
        for field in ("vertices", "normals"):
            x, y = np.asarray(a[field]), np.asarray(b[field])
            if x.shape != y.shape: errors.append(f"Floor 3 viewer mesh {name}: {field} count changed"); continue
            difference = float(np.max(abs(x-y))); maximum = max(maximum, difference)
            if difference > VIEWER_TOLERANCE_M: errors.append(f"Floor 3 viewer mesh {name}: {field} changed by {difference:.8g}")
    old_labels = sorted((p for p in original.get("labels", []) if p.get("floor") == 3), key=lambda p:json.dumps(p,sort_keys=True))
    new_labels = sorted((p for p in scene.get("labels", []) if p.get("floor") == 3), key=lambda p:json.dumps(p,sort_keys=True))
    if old_labels != new_labels: errors.append("Retained Floor 3 viewer labels changed")
    return {"passed": not errors, "errors": errors, "archive": str(archive_path.relative_to(ROOT)) if archive_path.is_relative_to(ROOT) else str(archive_path),
            "files": files, "viewer_meshes_compared": len(set(old)&set(new)), "viewer_meshes_exactly_unchanged": exact,
            "viewer_maximum_geometry_difference_m": maximum, "viewer_tolerance_m": VIEWER_TOLERANCE_M,
            "viewer_labels_unchanged": old_labels == new_labels}


def polygon_area(polygon):
    points = finite_array(polygon, (len(polygon), 2), "Floor polygon")
    require(len(points) >= 3, "Floor polygon has fewer than three vertices")
    other = np.roll(points, -1, axis=0)
    return abs(float(np.sum(points[:,0]*other[:,1] - other[:,0]*points[:,1]))) / 2


def point_in_polygon(point, polygon, tolerance=2e-5):
    """Accept the interior or a point within rounding tolerance of its boundary."""
    inside = False
    point = np.asarray(point)
    for a, b in zip(polygon, polygon[1:] + polygon[:1]):
        a, b = np.asarray(a), np.asarray(b); edge = b-a
        length2 = float(edge @ edge)
        projected = a + edge * min(1, max(0, float((point-a) @ edge) / length2)) if length2 else a
        if np.linalg.norm(point-projected) <= tolerance: return True
        if (a[1] > point[1]) != (b[1] > point[1]):
            crossing = (b[0]-a[0])*(point[1]-a[1])/(b[1]-a[1])+a[0]
            if point[0] < crossing: inside = not inside
    return inside


def floor_area_retention(model, source_path, original_path, projection_path):
    """Retain overlapping source polygons; a lossy union cannot satisfy this sum."""
    source = json.loads(source_path.read_bytes()); original = json.loads(original_path.read_bytes())
    projection = json.loads(projection_path.read_bytes()); errors = []
    old_floors = [p for p in original["footprints"] if p["kind"] == "floor"]
    require(isinstance(source, list) and len(source) == len(old_floors)+1,
            "Display floor source must retain the old regions plus one native-floor addition")
    unchanged = source[:len(old_floors)] == old_floors
    if not unchanged: errors.append("The old measured display floor regions differ from original-floor-2.json")
    native = [item for item in projection["withheld_floors"] if item["native_completed_roomplan"]]
    require(len(native) == 1, "Expected one completed native RoomPlan floor outline")
    additional = source[-1]["polygon"]; native_outline = native[0]["footprint"]["polygon"]
    within_native = all(point_in_polygon(point, native_outline) for point in additional)
    if not within_native: errors.append("Additional display floor piece is outside the completed native floor outline")
    if polygon_area(additional) > polygon_area(native_outline) + 1e-4:
        errors.append("Additional display floor area exceeds the completed native floor area")
    ids = ("0252CB01-29DC-4136-8A98-AB2076782D1E", "457D4F40-982C-48BA-854F-F35DCF158A80")
    anchors = []
    for identifier in ids:
        matches = [point for point in original["points"] if point["id"] == identifier and point["kind"] == "elevator"]
        require(len(matches) == 1, f"Original map must have exactly one elevator anchor {identifier}")
        p = matches[0]["position"]; anchors.append(np.array([p[0],p[2]],dtype=np.float64))
    # 2.37 m is the authored separation of the existing -1.30 / 1.07 model
    # elevator anchors; compute the current model-to-map scale from original pins.
    scale = float(np.linalg.norm(anchors[1]-anchors[0])) / 2.37
    require(math.isfinite(scale) and 0.5 <= scale <= 2, "Elevator-derived model-to-map scale is invalid")
    floors = {}
    for obj in model.world_objects:
        match = re.fullmatch(r"Floor 2 · floor (\d+)", obj["name"])
        if obj["floor"] == 2 and match:
            index = int(match.group(1)); require(index not in floors, "Duplicate exported display floor index")
            floors[index] = obj
    if set(floors) != set(range(len(source))): errors.append("Exported named display floor meshes do not match all source polygon indices")
    source_areas = [polygon_area(p["polygon"]) for p in source]
    exported_areas = {}
    for index, obj in floors.items():
        surface_area = 0.0
        for primitive in obj["primitives"]:
            points = primitive["positions"][primitive["triangles"]]
            normals = np.cross(points[:,1]-points[:,0],points[:,2]-points[:,0])
            horizontal = np.ptp(points[:,:,1],axis=1) <= 1e-6
            upward = normals[:,1] > 0
            surface_area += float(np.sum(normals[horizontal & upward,1])) / 2
        exported_areas[index] = surface_area * scale * scale
        if index >= len(old_floors) and obj["extras"].get("routing_coverage") is not False:
            errors.append("The native display-floor addition is incorrectly labeled as routing coverage")
    source_total, exported_total = sum(source_areas), sum(exported_areas.values())
    tolerance = max(1e-4, source_total * 1e-6)
    difference = abs(source_total-exported_total)
    if difference > tolerance: errors.append(f"Exported display floor area loses or adds {difference:.9g} m2 compared with source polygons")
    return {"passed": not errors, "errors": errors,
            "source_file": source_path.name, "source_sha256": sha(source_path.read_bytes()),
            "original_measured_floor_regions_unchanged": unchanged, "original_floor_regions": len(old_floors),
            "source_display_floor_regions": len(source), "exported_display_floor_meshes": len(floors),
            "native_completed_source_id": native[0]["source_id"], "native_addition_within_completed_outline": within_native,
            "model_to_map_scale_from_elevators": scale, "source_polygon_area_sum_m2": source_total,
            "exported_upward_horizontal_triangle_area_sum_m2": exported_total,
            "absolute_area_difference_m2": difference, "area_tolerance_m2": tolerance,
            "source_polygon_areas_m2": source_areas,
            "exported_floor_mesh_areas_m2": {str(i): exported_areas[i] for i in sorted(exported_areas)},
            "comparison": "Sum each source polygon separately, including old overlaps; do not union source coverage"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=DEFAULT_DIR)
    parser.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--floor-source", type=Path)
    parser.add_argument("--original-map", type=Path)
    parser.add_argument("--registered-projection", type=Path)
    args = parser.parse_args(); directory = args.directory.resolve(); archive = args.archive.resolve()
    output = args.output or directory / "glb-validation.json"
    floor_source = args.floor_source or directory / "illustration-floors.json"
    original_map = args.original_map or directory.parent / "floor-2-evidence/original-floor-2.json"
    registered_projection = args.registered_projection or directory.parent / "floor-2-evidence/registered-projection.json"
    input_paths = [directory/name for name in ("building.glb", "floor-2.glb", "floor-3.glb", "viewer-scene.json", "floor-3.usdz", "floor-3.png", "floor-3-plan.png")] + [archive]
    input_paths.extend([floor_source, original_map, registered_projection])
    initial_hashes = {str(p):sha(p.read_bytes()) for p in input_paths}
    models = {name: GLB(directory / (name + ".glb")).validate() for name in ("building", "floor-2", "floor-3")}
    errors = [f"{name}.glb: {error}" for name, model in models.items() for error in model.report["errors"]]
    comparisons = {}
    for name, action in (("alignment", lambda: compare_floor_exports(models["building"], {2:models["floor-2"],3:models["floor-3"]})),):
        try: comparisons[name] = action()
        except (ValueError,IndexError,KeyError,TypeError) as exc: comparisons[name] = {"passed": False,"errors":[str(exc)]}
    try: viewer, scene = viewer_check(directory / "viewer-scene.json", models["building"]); comparisons["viewer_comparison"] = viewer
    except (ValueError,IndexError,KeyError,TypeError) as exc: scene = {}; comparisons["viewer_comparison"] = {"passed":False,"errors":[str(exc)]}
    try: comparisons["retained_floor_3"] = retained_floor_check(directory, archive, scene)
    except (ValueError,IndexError,KeyError,TypeError,zipfile.BadZipFile) as exc: comparisons["retained_floor_3"] = {"passed":False,"errors":[str(exc)]}
    try: comparisons["floor_2_display_area_retention"] = floor_area_retention(models["floor-2"],floor_source,original_map,registered_projection)
    except (ValueError,IndexError,KeyError,TypeError) as exc: comparisons["floor_2_display_area_retention"] = {"passed":False,"errors":[str(exc)]}
    for name, comparison in comparisons.items(): errors.extend(f"{name}: {e}" for e in comparison["errors"])
    changed = [str(p) for p in input_paths if initial_hashes[str(p)] != sha(p.read_bytes())]
    if changed: errors.append("Validation inputs changed during the run: " + ", ".join(changed))
    report = {"format": "glTF 2.0 binary", "passed": not errors, "errors": errors,
              "checks": ["GLB header/chunk/buffer boundaries", "Accessor byte ranges, stride, component alignment, sparse indices, finite values and declared extrema",
                         "Index bounds and vertex attribute counts", "Unit local and world normals", "No local/world degenerate triangles",
                         "Scene graph references, cycles and finite transforms", "Standalone floor world triangles match combined export by floor/name identity",
                         "Viewer triangle counts and world bounds agree within five-decimal serialization tolerance",
                         "Floor 2 upward display floor triangle area retains all source polygons, including overlapping old measured floors",
                         "Retained Floor 3 GLB/USDZ/PNGs and viewer geometry match archived video assets", "Input hashes unchanged during validation"],
              "files": [models[name].report for name in ("building","floor-2","floor-3")], **comparisons,
              "source_hashes_unchanged_during_validation": not changed}
    output.write_text(json.dumps(report,indent=2,allow_nan=False)+"\n")
    print(json.dumps({"passed": report["passed"], "errors": errors[:20], "error_count": len(errors),
                      "output": str(output), "mesh_nodes": {name:model.report["counts"].get("mesh_nodes") for name,model in models.items()},
                      "triangles": {name:model.report["counts"].get("instanced_triangles") for name,model in models.items()}}))
    sys.exit(0 if report["passed"] else 1)


if __name__ == "__main__": main()
